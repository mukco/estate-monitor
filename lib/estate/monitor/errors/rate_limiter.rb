# frozen_string_literal: true

module Estate
  module Monitor
    module Errors
      # Thirty events a minute per address, counted in this process.
      #
      # 2026-10-09: the browser endpoint is open to anybody — it has to be, a
      # page that dies before sign-in is the one we most want to hear from — so
      # something has to stop one tab in a render loop (or one stranger with
      # curl) from filling the estate. Not Rack::Attack: not every app has it,
      # and an error reporter that needs a cache store configured before it
      # works is one that quietly does not work.
      #
      # A fixed one-minute window rather than a sliding one. The cost is that a
      # burst straddling the minute can get through twice, which for a family
      # estate is sixty error reports instead of thirty; the gain is that the
      # whole table is thrown away at each rollover, so memory is bounded by
      # how many addresses one minute saw, and never by how long the app has
      # been up. `max_keys` caps even that: past it, a new address in the same
      # minute is refused rather than remembered.
      #
      # Per process, so a Puma running two workers lets an address through
      # twice. That is the price of not needing a shared store, and still an
      # order of magnitude short of a problem.
      class RateLimiter
        def initialize(limit: 30, period: 60, max_keys: 10_000,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @limit = limit
          @period = period
          @max_keys = max_keys
          @clock = clock
          @mutex = Mutex.new
          @window = nil
          @counts = {}
        end

        # How many of `wanted` events from `key` may go through now. The rest
        # are the caller's to drop — partially, so the first few of an
        # over-limit batch still arrive.
        def allow(key, wanted = 1)
          @mutex.synchronize do
            window = (@clock.call / @period).floor
            if window != @window
              @window = window
              @counts = {}
            end
            return 0 if !@counts.key?(key) && @counts.size >= @max_keys

            used = @counts.fetch(key, 0)
            granted = [[@limit - used, 0].max, wanted].min
            @counts[key] = used + granted
            granted
          end
        end

        def size
          @mutex.synchronize { @counts.size }
        end
      end
    end
  end
end
