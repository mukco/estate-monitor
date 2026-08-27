# frozen_string_literal: true

require "active_record"
require "json"

module Estate
  module Monitor
    module SolidQueueSource
      STALE_HEARTBEAT = 5.minutes
      FAILURE_LIMIT = 10
      # Enough to see what is wedged; past that, the count is the story.
      RUNNING_LIMIT = 20
      # Long enough that a quiet app still has something on the page, short
      # enough to stay one small query and one screen.
      RECENT_LIMIT = 25
      MAX_ARGUMENTS_LENGTH = 300
      SLOWEST_LIMIT = 5

      # Solid Queue kills a claim whose worker stopped answering and files the
      # result as a failure. It is a failure of the container, not of the job —
      # a deploy in the middle of a nightly warm produces one every time — and
      # a panel that cannot tell the two apart shows a permanent red number
      # that nobody can act on. Named here so the count can be split.
      PRUNED_ERROR = "ProcessPrunedError"

      module_function

      def snapshot
        {
          processes: safe(:processes),
          running: safe(:running),
          recent: safe(:recent),
          queues: safe(:queues),
          recurring: safe(:recurring),
          failures: safe(:failures),
          failure_counts: safe(:failure_counts),
          totals: safe(:totals),
          timing: safe(:timing),
          retention: safe(:retention)
        }
      end

      def safe(name)
        send(name)
      rescue StandardError => e
        { unavailable: "#{e.class}: #{e.message}" }
      end

      def processes
        rows = process_class.order(:kind, :name).map do |p|
          {
            kind: p.kind, name: p.name, pid: p.pid,
            last_heartbeat_at: p.last_heartbeat_at&.utc&.iso8601,
            stale: p.last_heartbeat_at.nil? || p.last_heartbeat_at < STALE_HEARTBEAT.ago
          }
        end
        { count: rows.size, stale_count: rows.count { |r| r[:stale] }, rows: }
      end

      def queues
        counts = Hash.new { |h, k| h[k] = { ready: 0, claimed: 0 } }
        count_by_queue(ready_class).each { |q, n| counts[q][:ready] = n }
        count_by_queue(claimed_class).each { |q, n| counts[q][:claimed] = n }
        failed = count_by_queue(failed_class)
        counts.keys.union(failed.keys).sort.to_h { |q| [q, counts[q].merge(failed: failed[q] || 0)] }
      end

      # What is in flight *right now*, by name.
      #
      # totals[:claimed] has always said how many, and a number is what stands
      # in front of the question anybody actually has. "claimed: 3" cannot tell
      # you that all three are the same import, wedged since breakfast.
      #
      # A claimed execution joins back to its job, so the class and queue are
      # one hop away, and the claim's own created_at is when a worker picked it
      # up — which is the age worth showing, because a job claimed forty
      # minutes ago is the one to go and look at.
      #
      # This will usually be empty, and that is not a fault. A reader polls
      # once a minute and these jobs take seconds, so the odds of catching one
      # mid-flight are small — which is the whole reason `recent` exists below.
      def running(limit = RUNNING_LIMIT)
        rows = claimed_class.includes(:job).order(created_at: :asc).limit(limit).filter_map do |claim|
          job = claim.job
          next if job.nil?

          {
            class_name: job.class_name,
            queue: job.queue_name,
            claimed_at: claim.created_at&.utc&.iso8601,
            process_id: (claim.process_id if claim.respond_to?(:process_id))
          }.compact
        end
        { count: claimed_class.count, rows: rows }
      end

      # When each recurring task last actually fired, and when the schedule
      # says it was last due.
      #
      # This used to read `last_enqueued_at` off the task row behind a
      # respond_to? guard. There is no such column and never was — the guard
      # swallowed it, and every recurring task on every app has reported "no
      # last run" since the section shipped. The record of a run lives in
      # solid_queue_recurring_executions, one row per (task_key, run_at), which
      # is one grouped query for the lot of them.
      #
      # `due_at` is the schedule's own previous occurrence, which the task can
      # work out because it holds the cron string. Reporting both and judging
      # neither is deliberate: "should have run at 07:00, last ran at 06:00
      # yesterday" is a fact this app can state, and whether that is worth
      # waking somebody over belongs to whoever watches the estate.
      #
      # Mind `retention` below when reading a nil. A recurring execution is
      # deleted with the job it enqueued, so a task that fired outside the
      # retention window reports nil here — which means "no run on record",
      # not "never ran".
      def recurring
        last_runs = last_run_by_task
        task_class.order(:key).map do |t|
          {
            key: t.key,
            class_name: (t.class_name if t.respond_to?(:class_name)),
            schedule: t.schedule,
            last_enqueued_at: last_runs[t.key]&.utc&.iso8601,
            due_at: previous_due(t)
          }
        end
      end

      def last_run_by_task
        recurring_execution_class.group(:task_key).maximum(:run_at)
      rescue StandardError
        {}
      end

      # Per row rather than for the lot, because one unparseable schedule
      # should cost its own row and not the whole section.
      def previous_due(task)
        return nil unless task.respond_to?(:previous_time)

        task.previous_time&.utc&.iso8601
      rescue StandardError
        nil
      end

      def failures(limit = FAILURE_LIMIT)
        failed_class.includes(:job).order(created_at: :desc).limit(limit).map do |f|
          job = f.job
          error_class, error_message = error_details(f)

          {
            queue: job&.queue_name, class_name: job&.class_name,
            error_class:, error_message: truncate(error_message),
            pruned: error_class.to_s.include?(PRUNED_ERROR),
            arguments: filter_arguments(job&.arguments),
            failed_at: f.created_at&.utc&.iso8601
          }
        end
      end

      # A failed execution stores one JSON object — exception_class, message,
      # backtrace — and Solid Queue reads the three back for you.
      #
      # What was here instead was `error.to_s.split(": ", 2)`, splitting the
      # serialised hash at its first colon-space and calling the halves a class
      # and a message. The first ": " in a pruned-process failure falls inside
      # the message, at "last heartbeat at: ", so the panel was titling rows
      # `{"exception_class"=>"...", "message"=>"Process was found dead and
      # pruned (last heartbeat at` and detailing them `2026-08-26 10:51:59
      # -0400)", "backtrace"=>nil}`. The reader grew a regex to put the two
      # back together and could not, because the closing quote was on the far
      # side of the cut.
      def error_details(failure)
        return [failure.exception_class, failure.message] if failure.respond_to?(:exception_class)

        hash = parse_error(failure.error)
        [hash["exception_class"], hash["message"]]
      end

      def parse_error(raw)
        raw = JSON.parse(raw) if raw.is_a?(String)
        raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      # Nothing ever deletes a failed execution, so `totals[:failed]` is every
      # failure the app has had since the table was created. It is a fine
      # number to know and a useless one to lead with: on an app that has been
      # deployed through a nightly warm a few times it is permanently red, and
      # a real error arriving tomorrow moves it from 16 to 17.
      #
      # These are the same rows counted over windows, and with the killed-by-a
      # -restart ones separated out, so a reader can say "two yesterday, both
      # of them a lost container" instead of "sixteen".
      def failure_counts
        {
          total: failed_class.count,
          last_24h: failed_class.where(created_at: 24.hours.ago..).count,
          last_7d: failed_class.where(created_at: 7.days.ago..).count,
          pruned: pruned_count
        }
      end

      def pruned_count
        # Raw SQL, not `arel_table[:error].matches`: the column is declared
        # `serialize :error, coder: JSON`, so Arel casts the bind value through
        # that coder and the pattern reaches the database as a JSON string,
        # quotes and all — matching nothing, silently, for ever.
        failed_class.where("#{failed_class.quoted_table_name}.error LIKE ?", "%#{PRUNED_ERROR}%").count
      rescue StandardError
        nil
      end

      def totals
        {
          ready: ready_class.count,
          claimed: claimed_class.count,
          failed: failed_class.count,
          finished_last_24h: finished_scope.where(finished_at: 24.hours.ago..).count
        }
      end

      # What has finished lately, newest first.
      #
      # The section the panel most needed and did not have. Ready, running and
      # failed all describe an instant, and an instant is the one thing a
      # reader polling once a minute cannot see: a queue that has run four
      # hundred jobs today looks exactly like a queue that has run none. This
      # is the log of the work, which is what "is the nightly warm still
      # happening" actually asks for.
      def recent(limit = RECENT_LIMIT)
        rows = finished_scope.order(finished_at: :desc).limit(limit)
                             .pluck(:class_name, :queue_name, :created_at, :finished_at)
                             .map do |name, queue, created, done|
          { class_name: name, queue: queue, finished_at: done&.utc&.iso8601,
            turnaround_ms: turnaround_ms(created, done) }.compact
        end
        { count: rows.length, rows: rows }
      end

      # How long jobs are taking, from the rows Solid Queue already keeps.
      #
      # Turnaround rather than run time: created_at to finished_at is what the
      # thing waiting on the job actually experienced, and it is the only span
      # the schema can answer for — there is no started_at, so a job that sat in
      # a queue for a minute and ran for a second is not distinguishable from
      # one that ran for a minute, and pretending otherwise would be worse than
      # saying the honest number.
      #
      # Read rather than counted, unlike the request histogram: these are rows
      # that persist, so a window can simply be selected.
      def timing
        finished = finished_scope
                     .where(finished_at: 1.hour.ago..)
                     .where.not(created_at: nil)
                     .pluck(:class_name, :created_at, :finished_at)
                     .filter_map do |name, created, done|
                       ms = turnaround_ms(created, done)
                       [ name, ms ] if ms
                     end

        return { finished_last_hour: 0 } if finished.empty?

        ms = finished.map(&:last).sort
        {
          finished_last_hour: finished.length,
          turnaround_ms: {
            p50: ms[(ms.length * 0.5).floor],
            p90: ms[(ms.length * 0.9).floor] || ms.last,
            max: ms.last
          },
          # By class rather than by job: five rows of the same nightly sweep say
          # one thing, and the name is what somebody would go and look at.
          slowest: finished.group_by(&:first)
                           .map { |name, rows| { class_name: name, count: rows.length, max_ms: rows.map(&:last).max } }
                           .sort_by { |r| -r[:max_ms] }
                           .first(SLOWEST_LIMIT)
        }
      end

      # How far back the two history sections can see.
      #
      # Solid Queue deletes finished jobs older than this, and a recurring
      # execution goes with the job it enqueued. Without the number, a reader
      # cannot tell "this weekly task has never run" from "this weekly task ran
      # on Sunday and Sunday has been swept".
      #
      # It is the configured window, not a measurement: `clear_finished_jobs_after`
      # defaults to a day whether or not anything is scheduled to act on it, so an
      # app with no sweep reports 86400 while in fact keeping everything for ever.
      # Family Hub did exactly that until it was given the sweep the other four
      # already had. The error is in the safe direction — a reader forgives a gap
      # that was not really swept — but do not read this as "rows older than this
      # are gone".
      def retention
        configured = defined?(::SolidQueue) && ::SolidQueue.respond_to?(:clear_finished_jobs_after)
        { finished_jobs_after_seconds: (::SolidQueue.clear_finished_jobs_after&.to_i if configured) }
      end

      def turnaround_ms(created, finished)
        return nil if created.nil? || finished.nil?

        ((finished - created) * 1000).round
      end

      def filter_arguments(args)
        s = args.is_a?(String) ? args : Array(args).to_json
        parsed = JSON.parse(s)
        parsed.is_a?(Array) && parsed.size > MAX_ARGUMENTS_LENGTH ? parsed[0, MAX_ARGUMENTS_LENGTH] + ["..."] : parsed
      rescue JSON::ParserError, TypeError
        truncate(s.to_s)
      end

      def truncate(s, max = 500)
        s.to_s[0, max]
      end

      def count_by_queue(execution_class)
        if execution_class.column_names.include?("queue_name")
          execution_class.group(:queue_name).count
        else
          execution_class.joins(:job).group("solid_queue_jobs.queue_name").count
        end
      end

      # A finished job is a job row with a finishing time, and has been for as
      # long as Solid Queue has had a 1.0. What stood here was
      # `SolidQueue::FinishedExecution`, a class that does not exist in any
      # released version — so `timing` reported `NameError: uninitialized
      # constant` on every app it was ever deployed to, and `finished_last_24h`
      # rescued to nil beside it. Neither number has ever been shown.
      def finished_scope = job_class.where.not(finished_at: nil)

      def process_class = "SolidQueue::Process".constantize
      def ready_class = "SolidQueue::ReadyExecution".constantize
      def claimed_class = "SolidQueue::ClaimedExecution".constantize
      def failed_class = "SolidQueue::FailedExecution".constantize
      def job_class = "SolidQueue::Job".constantize
      def task_class = "SolidQueue::RecurringTask".constantize
      def recurring_execution_class = "SolidQueue::RecurringExecution".constantize
    end
  end
end
