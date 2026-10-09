# frozen_string_literal: true

require "json"
require_relative "errors"

module Estate
  module Monitor
    # POST /internal/errors — where browsers and the TV report.
    #
    # 2026-10-09: a plain Rack app rather than a route on the engine, for two
    # reasons. The engine is mounted at /internal/metrics, so anything it owns
    # lives under that path, and the browser contract is /internal/errors. And
    # this endpoint must be the opposite of the metrics one: open to anybody,
    # no bearer, no login, no CSRF — a page that dies before sign-in is the
    # report we most want. Rack is below all of that by construction; nothing
    # an app adds to ApplicationController (an auth filter, protect_from_forgery,
    # a Pundit check) can reach it, so no app can break it by accident.
    #
    #   mount Estate::Monitor::ErrorsApp => "/internal/errors"
    #
    # The answer is 202 whatever happened to the events — dropped by the rate
    # limit, over size, reporting disabled — so a client never has a reason to
    # retry, and a page in a crash loop cannot become a request loop. The one
    # exception is a body that is not JSON at all: that is a bug in the
    # sender, and a 400 is what shows up in its developer tools.
    class ErrorsApp
      MAX_BODY = 64 * 1024
      MAX_EVENTS = 10
      BROWSER_SOURCES = %w[client tv].freeze

      ACCEPTED = [202, { "content-type" => "application/json", "cache-control" => "no-store" }, ["{}"]].freeze

      def self.call(env)
        new.call(env)
      end

      def call(env)
        return [405, { "allow" => "POST", "content-type" => "application/json" }, ["{}"]] unless env["REQUEST_METHOD"] == "POST"

        body = read(env)
        return accepted if body.nil?

        payload = parse(body)
        return [400, { "content-type" => "application/json" }, ['{"error":"invalid json"}']] if payload == :invalid
        return accepted unless Monitor.reporting?

        request = build_request(env)
        events = extract(payload)
        allowed = Errors.limiter.allow(Errors.ip_for(request) || "unknown", events.size)
        events.first(allowed).each do |raw|
          # sendBeacon cannot set headers and fetch-on-pagehide may not wait
          # for an answer, so an event is all we get; `client` unless it says
          # it is the TV.
          event = Errors::Event.normalize(raw, default_source: "client", sources: BROWSER_SOURCES)
          Errors.record(event, request: request)
        end
        accepted
      rescue StandardError
        accepted
      end

      private

      def accepted
        [ACCEPTED[0], ACCEPTED[1].dup, ACCEPTED[2].dup]
      end

      # Read one byte past the limit so "exactly 64 KB" and "more" are
      # distinguishable without trusting Content-Length, which a client can
      # omit. Over the limit is dropped, not refused: see the class comment.
      def read(env)
        length = env["CONTENT_LENGTH"].to_i
        return nil if length > MAX_BODY

        input = env["rack.input"]
        return nil if input.nil?

        input.rewind if input.respond_to?(:rewind)
        body = input.read(MAX_BODY + 1).to_s
        body.bytesize > MAX_BODY ? nil : body
      end

      # Whatever the content type said. sendBeacon with a string sends
      # text/plain, and a Blob of application/json would be a CORS-preflighted
      # type the beacon is not allowed to send, so the type is not evidence.
      def parse(body)
        JSON.parse(body)
      rescue JSON::ParserError, EncodingError
        :invalid
      end

      # `{ "events": [...] }` per the contract; a bare array or a single event
      # are accepted too, because a hand-written fetch in an app that is not
      # using the kit is exactly where a mistake like that happens.
      def extract(payload)
        list = case payload
               when Hash then payload.key?("events") ? payload["events"] : [payload]
               when Array then payload
               else []
               end
        Array(list).first(MAX_EVENTS)
      end

      def build_request(env)
        defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : Rack::Request.new(env)
      end
    end
  end
end
