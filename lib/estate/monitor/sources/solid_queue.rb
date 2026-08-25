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
      MAX_ARGUMENTS_LENGTH = 300

      module_function

      SLOWEST_LIMIT = 5

      def snapshot
        {
          processes: safe(:processes),
          running: safe(:running),
          queues: safe(:queues),
          recurring: safe(:recurring),
          failures: safe(:failures),
          totals: safe(:totals),
          timing: safe(:timing)
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

      def recurring
        task_class.order(:key).map do |t|
          {
            key: t.key,
            class_name: (t.class_name if t.respond_to?(:class_name)),
            schedule: t.schedule,
            last_enqueued_at: (t.last_enqueued_at&.utc&.iso8601 if t.respond_to?(:last_enqueued_at))
          }
        end
      end

      def failures(limit = FAILURE_LIMIT)
        cols = failed_class.column_names
        legacy = cols.include?("error_class")

        failed_class.includes(:job).order(created_at: :desc).limit(limit).map do |f|
          job = f.job
          error_class, error_message =
            if legacy
              [f.error_class, f.error_message]
            else
              combined = f.error.to_s
              [combined.split(": ", 2)[0], combined.split(": ", 2)[1]]
            end

          {
            queue: job.queue_name, class_name: job.class_name,
            error_class:, error_message: truncate(error_message),
            arguments: filter_arguments(job.arguments),
            failed_at: f.created_at&.utc&.iso8601
          }
        end
      end

      def totals
        {
          ready: ready_class.count,
          claimed: claimed_class.count,
          failed: failed_class.count,
          finished_last_24h: begin
            finished_class.where(finished_at: 24.hours.ago..).count
          rescue StandardError
            nil
          end
        }
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
        finished = finished_class
                     .where(finished_at: 1.hour.ago..)
                     .where.not(created_at: nil)
                     .pluck(:class_name, :created_at, :finished_at)
                     .filter_map do |name, created, done|
                       next if created.nil? || done.nil?
                       [ name, ((done - created) * 1000).round ]
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

      def process_class = "SolidQueue::Process".constantize
      def ready_class = "SolidQueue::ReadyExecution".constantize
      def claimed_class = "SolidQueue::ClaimedExecution".constantize
      def failed_class = "SolidQueue::FailedExecution".constantize
      def finished_class = "SolidQueue::FinishedExecution".constantize
      def task_class = "SolidQueue::RecurringTask".constantize
    end
  end
end
