# frozen_string_literal: true

require_relative "errors"

module Estate
  module Monitor
    # A page asking for files this deploy no longer has.
    #
    # 2026-10-09, 19:57Z: Football white-screened on an iPhone and nothing
    # reached the inbox. The phone had restored an old index.html from its
    # cache — there is no GET / in the log — and asked for the JS and CSS that
    # page was built with. A later deploy had deleted both, so each was a 404
    # (ActionController::RoutingError, on the ignore list, correctly: bots
    # probe for files all day). No app code ran, so the browser reporter never
    # loaded either. The only witness was the server, and it said nothing.
    #
    # So the server says it: a 404 for one of the app's own built assets, from
    # something that looks like a browser, is a client running a stale page.
    # Reported as `source: client` because that is where the fault is, and
    # fingerprinted `stale-asset` so every such report is one group per app.
    #
    # Inserted by the engine just below ActionDispatch::Static, so a file that
    # exists is served before it gets here and the 404 it sees is the app's
    # final answer, whatever ShowExceptions made of the RoutingError. Nothing
    # is done on the way in; on the way out it is one status check, and only
    # for a 404 a prefix and extension check — a request pays nothing more.
    class StaleAssets
      DEFAULT_PATHS = %w[/assets/].freeze
      EXTENSIONS = %w[.js .mjs .css].freeze
      # Every browser still says Mozilla/; most scripts do not, and the ones
      # that do say what they are as well.
      BROWSER = %r{Mozilla/}
      NOT_A_PERSON = /bot|crawler|spider|curl|python|go-http/i

      class << self
        attr_accessor :coalescer

        def asset?(path)
          Array(Monitor.stale_asset_paths).any? { |prefix| path.start_with?(prefix.to_s) } &&
            EXTENSIONS.include?(File.extname(path).downcase)
        end

        def browser?(user_agent)
          user_agent.match?(BROWSER) && !user_agent.match?(NOT_A_PERSON)
        end
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)
        notice(env) if response[0].to_i == 404
        response
      rescue StandardError => e
        # An app with show_exceptions off lets the RoutingError reach us
        # instead of a 404. Same page, same report; the error goes on up.
        notice(env) if e.class.name == "ActionController::RoutingError"
        raise
      end

      private

      def notice(env)
        return unless Monitor.report_stale_assets && Monitor.reporting?
        return unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        path = "#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
        return unless self.class.asset?(path)

        user_agent = env["HTTP_USER_AGENT"].to_s
        return unless self.class.browser?(user_agent)

        # Everything the report needs is taken now: the report goes out seconds
        # after this response, by which time the request is gone.
        request = defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : Rack::Request.new(env)
        ip = Errors.ip_for(request)
        facts = { "ua" => user_agent, "referer" => env["HTTP_REFERER"], "accept" => env["HTTP_ACCEPT"],
                  "user_id" => Errors.user_id_for(request), "ip" => ip }
        self.class.coalescer.add(ip || "unknown", path, facts)
      rescue StandardError
        nil
      end

      # One stale page asks for several files — the entry script, its CSS,
      # a chunk or two — within a second of each other. Reported one by one,
      # that is three events for one phone; the group count would say three
      # times what happened. So the first 404 from an address opens a
      # five-second window, the rest join it, and the window closes into one
      # event listing every path.
      #
      # The opening is what the rate limiter counts (the browser endpoint's
      # thirty a minute per address), so a page reloading itself in a loop is
      # throttled like any other client. A background thread, started on the
      # first stale page in each process, closes windows once a second, so
      # nothing here ever waits in a request. A window still open when the
      # process exits is lost: the next phone to load that page reports again.
      class Coalescer
        WINDOW = 5
        TICK = 1
        MAX_PATHS = 20
        # Addresses with a window open at once. Past it a new one is dropped,
        # not remembered: memory stays bounded however many phones are stale.
        MAX_PENDING = 1_000

        Entry = Struct.new(:opened_at, :paths, :facts)

        def initialize(window: WINDOW, tick: TICK, threaded: true,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @window = window
          @tick = tick
          @threaded = threaded
          @clock = clock
          @mutex = Mutex.new
          @pid = Process.pid
          @pending = {}
          @thread = nil
        end

        def add(key, path, facts)
          opened = @mutex.synchronize do
            forked!
            if (entry = @pending[key])
              entry.paths << path unless entry.paths.include?(path) || entry.paths.size >= MAX_PATHS
              next false
            end
            next false if @pending.size >= MAX_PENDING
            next false if Errors.limiter.allow(key).zero?

            @pending[key] = Entry.new(@clock.call, [path], facts)
            true
          end
          start_thread if opened && @threaded
          opened
        rescue StandardError
          false
        end

        # Reports every window that has run its five seconds — or all of them,
        # with force. Returns how many were reported. The thread calls it; so
        # do the specs.
        def flush(force: false)
          due = @mutex.synchronize do
            forked!
            now = @clock.call
            keys = @pending.select { |_, entry| force || now - entry.opened_at >= @window }.keys
            keys.map { |key| @pending.delete(key) }
          end
          due.each { |entry| report(entry) }
          due.size
        rescue StandardError
          0
        end

        def pending
          @mutex.synchronize { @pending.size }
        end

        private

        def report(entry)
          facts = entry.facts
          context = {
            "path" => entry.paths.first, "paths" => entry.paths,
            "ua" => facts["ua"], "referer" => facts["referer"], "accept" => facts["accept"],
            "ip_hash" => Errors.ip_hash(facts["ip"]), "release" => Monitor.resolved_release
          }
          Errors.capture_message(
            "A phone asked for #{entry.paths.first}, which this deploy no longer has",
            level: "error", source: "client", kind: "stale_asset", fingerprint: "stale-asset",
            context: context, user_id: facts["user_id"], ip: facts["ip"]
          )
        rescue StandardError
          nil
        end

        # Caller holds @mutex. A forked child's windows are its parent's.
        def forked!
          return if @pid == Process.pid

          @pid = Process.pid
          @pending = {}
          @thread = nil
        end

        def start_thread
          @mutex.synchronize do
            return if @thread&.alive?

            @thread = Thread.new { run }
            @thread.name = "estate-monitor-stale-assets" if @thread.respond_to?(:name=)
            @thread.report_on_exception = false
          end
        end

        def run
          loop do
            sleep @tick
            flush
          rescue StandardError
            nil
          end
        end
      end

      # Created at load, like Errors' delivery: two threads seeing the first
      # stale page of a boot at once must not build two of them.
      @coalescer = Coalescer.new
    end
  end
end
