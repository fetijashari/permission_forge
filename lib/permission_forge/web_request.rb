# frozen_string_literal: true

require 'rack/body_proxy'

module PermissionForge
  # The one definition of "a web request is in progress": the Rack request
  # the host application is serving right now, from the top of its
  # middleware stack until the response is finished. Every request the
  # application serves passes through Middleware (the engine puts it first
  # in the host's stack, Engine: `config.app_middleware.unshift`), so the
  # host's own controllers, the mounted engine's admin screens and API, and
  # every middleware below it (a tenant lookup, an authentication
  # middleware) count, as do the before_actions of the host's
  # ApplicationController.
  #
  # Outside one: background jobs run by a worker, `perform_later` on an
  # adapter that runs elsewhere (`:async` runs on its own threads), Action
  # Cable channel actions (they run on the cable server's worker pool), rake
  # tasks, `bin/rails runner`, the console, and ActionController::TestCase
  # controller tests (they call the controller without the middleware
  # stack; integration and system tests go through it). Inside one: a job
  # run with `perform_now` (or the `:inline` adapter) and a mail delivered
  # with `deliver_now` during the request.
  #
  # It decides config.masked_attributes_nil_user_strategy = :hide_in_requests
  # (Configuration#masked_attributes_without_user_for) and where
  # field.unmasked_without_user is recorded.
  #
  # The state is ExecutionState slot :pf_web_request (the request's env), in
  # the :execution scope — seen by every fiber of the request (an
  # Enumerator, a streamed body) and by the thread ActionController::Live
  # runs the action in, which shares the request's isolated state — and
  # kept at the end of an executor run: the middleware sets it before the
  # request's run starts and puts back what it found when the response is
  # finished (`rack.response_finished`, else when the server closes the
  # body), or at once when the application raises. A slot left behind (a
  # body nobody closes) hides more where it is seen, never less.
  #
  # Under Rails' :thread isolation the fibers of a thread share the slot: a
  # fiber-based server (Falcon) needs `config.active_support.isolation_level
  # = :fiber`, as Rails itself does.
  #
  # @api private
  module WebRequest
    KEY = :pf_web_request

    # Recorded request values are cut to this many characters (as the audit
    # context's request id and IP are).
    VALUE_LIMIT = 255

    class << self
      # @return [Boolean] whether this code runs inside a web request
      def active?
        !ExecutionState[KEY].nil?
      end

      # @return [Hash, nil] the Rack env of the request in progress
      def env
        ExecutionState[KEY]
      end

      # The request in progress, for an audit event or a log line: its
      # method, path (without the query string) and, once the router has
      # matched it, endpoint ("controller_path#action"); {} outside a
      # request. Read when asked, never kept.
      #
      # @return [Hash{String => String, nil}]
      def details
        env = self.env
        return {} unless env

        request = ActionDispatch::Request.new(env)
        { 'method' => cut(request.request_method), 'path' => cut(request.path), 'endpoint' => endpoint(request) }
      rescue StandardError
        {}
      end

      # Runs the block as a web request (tests; Middleware keeps it past the
      # block itself).
      #
      # @param env [Hash] a Rack env
      # @return the block's value
      def within(env = {}, &)
        ExecutionState.with(KEY, env, &)
      end

      private

      # What the router matched, read without writing: Request#path_parameters
      # would store {} in the env of a request not routed yet (canary
      # :path_parameters_key).
      def endpoint(request)
        params = request.get_header(ActionDispatch::Http::Parameters::PARAMETERS_KEY)
        controller = params[:controller] if params.is_a?(Hash)
        cut("#{controller}##{params[:action]}") if controller
      end

      def cut(value)
        value.to_s[0, VALUE_LIMIT].presence
      end
    end

    # Marks every request the host application serves (see WebRequest).
    # First in the host's middleware stack, above ActionDispatch::Executor.
    #
    # @api private
    class Middleware
      # @param app [#call] the next middleware
      def initialize(app)
        @app = app
      end

      # @param env [Hash]
      # @return [Array] the Rack response, its body wrapped when the server
      #   does not announce `rack.response_finished`
      def call(env)
        restore = ExecutionState.set_until_restored(KEY, env)
        returned = false
        begin
          status, headers, body = @app.call(env)
          returned = true
        ensure
          restore.call unless returned
        end
        [status, headers, finished(env, body, restore)]
      end

      private

      # Until the response is finished: Rack 3 servers call the
      # `rack.response_finished` callbacks once it is sent (ActionDispatch::Executor
      # completes its run there too); others close the body.
      def finished(env, body, restore)
        callbacks = env['rack.response_finished']
        return Rack::BodyProxy.new(body, &restore) unless callbacks

        callbacks << restore
        body
      end
    end
  end
end
