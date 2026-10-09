# frozen_string_literal: true

require "json"
require "net/http"
require "time"

module Estate
  module Monitor
    module Errors
      # Gets events from this process to the estate, and never makes the app
      # wait for that or fail because of it.
      #
      # 2026-10-09. The shape, and why:
      #
      # * One buffer per process, under one mutex. `push` is the only thing a
      #   request thread does — append and return — so a slow or absent estate
      #   costs a request nothing. Puma serves on many threads, and Solid Queue
      #   running inside Puma adds more, so every touch of the buffer is locked.
      #
      # * A background thread sends. It wakes every two seconds, or at once
      #   when twenty events are waiting, and posts batches of at most fifty
      #   and at most 512 KB — the estate's own ceilings for one request.
      #
      # * Failure keeps the events and backs off: 2 s, 4 s, 8 s … five minutes.
      #   The buffer holds 500 and then drops the oldest, because a loop that
      #   is still failing is better described by its latest events than by
      #   its first, and memory must not grow with the length of an outage.
      #
      # * The same buffer is readable as the `errors` section of
      #   /internal/metrics, so when pushes keep failing (the WARP proxy, a
      #   firewall, a wrong ESTATE_URL) the estate's five-minute scrape picks
      #   the events up anyway. Every event carries an `event_id` and the estate
      #   dedupes on it, so an event that arrives both ways is stored once.
      #
      # * Forks get a clean slate. Puma's workers and Solid Queue's supervisor
      #   are forked; a thread does not survive fork, and the parent's buffer
      #   is the parent's to send. Every entry point checks the pid first.
      #
      # Nothing here raises into the caller. The point of an error reporter is
      # lost the moment it becomes a source of errors.
      class Delivery
        MAX_BUFFER = 500
        BATCH_EVENTS = 50
        # Under the estate's 512 KB so the envelope and any byte-count rounding
        # never tip a full batch into a 413.
        BATCH_BYTES = 500 * 1024
        FLUSH_EVERY = 2
        FLUSH_AT = 20
        MAX_BACKOFF = 300
        TIMEOUT = 5

        # What the scrape gets. A healthy app has nothing here; an app whose
        # pushes have been failing for an hour has a full buffer, and the
        # metrics payload must not become half a megabyte because of it. The
        # rest are served by the next scrape.
        SCRAPE_EVENTS = 100
        SCRAPE_BYTES = 256 * 1024
        # Shown to two scrapes, then forgotten. Once is enough when the estate
        # stored it; the second showing covers a scrape whose response was lost
        # on the way back. Without a limit a dead push path would serve the
        # same five hundred events to every scrape for ever.
        SCRAPE_SHOWINGS = 2

        Entry = Struct.new(:event, :bytes, :showings)

        attr_reader :interval

        def initialize(url: -> { Monitor.estate_url }, token: -> { Monitor.token },
                       app: -> { Monitor.resolved_app_name }, transport: nil,
                       interval: FLUSH_EVERY, threaded: true, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @url = url
          @token = token
          @app = app
          @transport = transport || method(:post)
          @interval = interval
          @threaded = threaded
          @clock = clock
          @mutex = Mutex.new
          @wake = ConditionVariable.new
          @flushing = Mutex.new
          clear_state
        end

        def push(event)
          @mutex.synchronize do
            forked!
            bytes = JSON.generate(event).bytesize
            @buffer << Entry.new(event, bytes, 0)
            while @buffer.size > MAX_BUFFER
              @buffer.shift
              @dropped += 1
            end
            @wake.signal if @buffer.size >= FLUSH_AT
          end
          start_thread if @threaded
          event["event_id"]
        rescue StandardError
          nil
        end

        # Sends everything that is due, batch by batch, until the buffer is
        # empty or the estate stops accepting. Returns how many were accepted.
        # The thread calls it; so do the specs and at_exit.
        def flush(force: false)
          return 0 unless @flushing.try_lock

          begin
            sent = 0
            loop do
              batch = take_batch(force: force)
              break if batch.empty?

              outcome = deliver(batch)
              sent += batch.size if outcome == :delivered
              break unless outcome == :delivered
            end
            sent
          ensure
            @flushing.unlock
          end
        rescue StandardError
          0
        end

        # The `errors` section of /internal/metrics.
        def snapshot
          @mutex.synchronize do
            forked!
            shown = []
            size = 0
            @buffer.each do |entry|
              break if shown.size >= SCRAPE_EVENTS
              break if size + entry.bytes > SCRAPE_BYTES && shown.any?

              shown << entry
              size += entry.bytes
            end
            shown.each { |entry| entry.showings += 1 }
            events = shown.map(&:event)
            @buffer.reject! { |entry| entry.showings >= SCRAPE_SHOWINGS }

            {
              pending: @buffer.size,
              delivered: @delivered,
              dropped: @dropped,
              rejected: @rejected,
              consecutive_failures: @failures,
              last_delivered_at: @last_delivered_at,
              last_error: @last_error,
              last_error_at: @last_error_at,
              events: events
            }
          end
        end

        def pending
          @mutex.synchronize { @buffer.size }
        end

        # Specs only: everything back to a fresh process.
        def reset!
          stop
          @mutex.synchronize { clear_state }
        end

        def stop
          thread = @mutex.synchronize do
            @stopping = true
            @wake.signal
            @thread
          end
          thread&.join(1)
          @mutex.synchronize { @thread = nil; @stopping = false }
        end

        private

        def clear_state
          @pid = Process.pid
          @buffer = []
          @delivered = 0
          @dropped = 0
          @rejected = 0
          @failures = 0
          @next_attempt = 0
          @last_delivered_at = nil
          @last_error = nil
          @last_error_at = nil
          @thread = nil
          @stopping = false
        end

        # Caller holds @mutex.
        def forked!
          clear_state if @pid != Process.pid
        end

        def take_batch(force:)
          @mutex.synchronize do
            forked!
            return [] if !force && @clock.call < @next_attempt

            batch = []
            bytes = 0
            @buffer.each do |entry|
              break if batch.size >= BATCH_EVENTS
              break if bytes + entry.bytes > BATCH_BYTES && batch.any?

              batch << entry
              bytes += entry.bytes
            end
            batch
          end
        end

        def deliver(batch)
          token = @token.call
          return :skipped if token.nil? || token.to_s.empty?

          body = JSON.generate(app: @app.call, events: batch.map(&:event))
          status, error = @transport.call(@url.call, token, body)
          outcome = classify(status)

          @mutex.synchronize do
            case outcome
            when :delivered
              remove(batch)
              @delivered += batch.size
              @failures = 0
              @next_attempt = 0
              @last_delivered_at = Time.now.utc.iso8601
            when :rejected
              # 429: the estate has already counted these against the app's
              # budget and dropped them; 413: this batch can never fit. Sending
              # either again only repeats the answer.
              remove(batch)
              @rejected += batch.size
              note_failure("HTTP #{status}")
            else
              note_failure(error || "HTTP #{status}")
            end
          end
          outcome
        end

        def classify(status)
          return :failed if status.nil?
          return :delivered if status.between?(200, 299)
          return :rejected if [413, 429].include?(status)

          :failed
        end

        def remove(batch)
          ids = batch.to_h { |entry| [entry.event["event_id"], true] }
          @buffer.reject! { |entry| ids.key?(entry.event["event_id"]) }
        end

        def note_failure(message)
          @failures += 1
          @last_error = message.to_s[0, 300]
          @last_error_at = Time.now.utc.iso8601
          @next_attempt = @clock.call + [2**@failures, MAX_BACKOFF].min
        end

        # Lazily, per process: the first event after boot (or after a fork)
        # starts the thread. A process that never reports never runs one.
        def start_thread
          @mutex.synchronize do
            return if @thread&.alive? || @stopping

            @thread = Thread.new { run }
            @thread.name = "estate-monitor-errors" if @thread.respond_to?(:name=)
            @thread.report_on_exception = false
          end
          register_at_exit
        end

        def run
          loop do
            @mutex.synchronize do
              # The size check covers a signal sent while this thread was busy
              # sending (or not yet started), which a condition variable forgets.
              # Not while backing off, or a full buffer would spin this loop.
              due = @buffer.size >= FLUSH_AT && @clock.call >= @next_attempt
              @wake.wait(@mutex, @interval) unless @stopping || due
              return if @stopping
            end
            flush
          rescue StandardError
            # Whatever went wrong, the next tick tries again; a dead sender
            # would leave the buffer to the scrape alone.
            nil
          end
        end

        # One last attempt when the process exits — a deploy stops the old
        # container about two seconds after the error that might explain why
        # it needed stopping. Bounded by the HTTP timeouts.
        def register_at_exit
          return if @at_exit_pid == Process.pid

          @at_exit_pid = Process.pid
          # Skipped when the estate has just been failing: waiting out two
          # timeouts in a container that is being stopped helps nobody, and the
          # events were already exposed to the scrape.
          at_exit { flush(force: true) if pending.positive? && @failures.zero? }
        end

        # Through ENV proxies on purpose: Net::HTTP honours HTTPS_PROXY and
        # NO_PROXY, so an app on WARP egress reaches the estate directly once
        # estate.edwardsfamily.app is in NO_PROXY, and is visibly failing (in
        # `last_error`) until it is.
        def post(url, token, body)
          uri = URI.join(url.to_s.end_with?("/") ? url.to_s : "#{url}/", "api/ingest/events")
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                         open_timeout: TIMEOUT, read_timeout: TIMEOUT,
                                                         write_timeout: TIMEOUT) do |http|
            request = Net::HTTP::Post.new(uri.request_uri,
                                          "Authorization" => "Bearer #{token}",
                                          "Content-Type" => "application/json",
                                          "Accept" => "application/json")
            request.body = body
            http.request(request)
          end
          [response.code.to_i, nil]
        rescue StandardError => e
          [nil, "#{e.class}: #{e.message}"]
        end
      end
    end
  end
end
