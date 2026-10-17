# frozen_string_literal: true

require 'rack/body_proxy'

module PermissionForge
  # The one definition of "a web request is in progress": the Rack request
  # the host application is serving right now, from Middleware until the
  # response is finished. The engine puts Middleware at the top of the
  # host's stack (Engine: `config.app_middleware.unshift`), unless a
  # middleware is inserted above it (`config.middleware.insert_before 0`, as
  # rack-cors documents, or a gem that inserts at 0 later): StackCheck warns
  # at boot and SecurityAudit lists them. So the host's own controllers, the
  # mounted engine's admin screens and API, every middleware below it (a
  # tenant lookup, an authentication middleware) and the before_actions of
  # the host's ApplicationController count.
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
  # the :execution scope, kept at the end of an executor run: the middleware
  # sets it before the request's run starts and puts back what it found when
  # the response is finished (`rack.response_finished`, else when the server
  # closes the body), or at once when the application raises. Under Rails'
  # :thread isolation (the default) every fiber of the request's thread sees
  # it (an Enumerator, a streamed body), and so does the thread
  # ActionController::Live runs the action in (it shares the request's
  # isolated state). Under `isolation_level = :fiber` each fiber has a state
  # of its own: a fiber the request starts (Enumerator#next, a Live thread)
  # does not see it, and a read there is outside the request — Falcon needs
  # :fiber, as Rails itself does.
  #
  # A slot left behind (a server that neither runs the callbacks nor closes
  # the body) hides more where it is seen, never less, and is never put back
  # by a later request: an env whose application call has returned is not
  # a request in progress around the next one.
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

    # Marks every request the host application serves (see WebRequest). At
    # the top of the host's middleware stack, above ActionDispatch::Executor
    # (StackCheck names what was inserted above it).
    #
    # @api private
    class Middleware
      # Set in the env once the application has returned the response: an
      # env still in the slot then is no request around the next one.
      RETURNED = 'permission_forge.web_request.returned'

      # @param app [#call] the next middleware
      def initialize(app)
        @app = app
      end

      # @param env [Hash]
      # @return [Array] the Rack response, its body wrapped when the server
      #   does not announce `rack.response_finished`
      def call(env)
        finish = Finish.new(env)
        returned = false
        begin
          status, headers, body = @app.call(env)
          returned = true
        ensure
          returned ? env[RETURNED] = true : finish.call
        end
        [status, headers, finished(env, body, finish)]
      end

      private

      # Until the response is finished: Rack 3 servers call the
      # `rack.response_finished` callbacks once it is sent (ActionDispatch::Executor
      # completes its run there too); others close the body.
      def finished(env, body, finish)
        callbacks = env['rack.response_finished']
        return Rack::BodyProxy.new(body, &finish) unless callbacks

        callbacks << finish
        body
      end
    end

    # The end of one request: puts back what the slot held (a request around
    # it, or nothing) and, for the outermost request, forgets what runtime
    # events it published once (Audit::Runtime.once?): reads made above
    # ActionDispatch::Executor are outside its run, which would not clear
    # them.
    #
    # @api private
    class Finish
      # @param env [Hash] the request's env, which the slot holds from now on
      def initialize(env)
        ExecutionState.put_back(KEY, nil) if Finish.left_behind?(ExecutionState[KEY])
        @outermost = !WebRequest.active?
        @restore = ExecutionState.set_until_restored(KEY, env)
      end

      # Whether the env in the slot is a request left behind: its application
      # call returned and nobody finished its response (not a request around
      # the next one).
      #
      # @param env [Hash, nil]
      # @return [Boolean]
      def self.left_behind?(env)
        env.is_a?(Hash) && env[Middleware::RETURNED] == true
      end

      # Takes and ignores the arguments of a `rack.response_finished` callback.
      # @return [void]
      def call(*)
        Audit::Runtime.reset! if @restore.call && @outermost
      end

      # @return [Proc] for Rack::BodyProxy's block
      def to_proc = method(:call).to_proc
    end

    # Whether anything sits above Middleware in the built stack, read once the
    # application has booted (BootChecks; SecurityAudit): a read there is
    # outside the request, so :hide_in_requests does not hide it and :bypass
    # does not record it.
    #
    # @api private
    module StackCheck
      class << self
        # @param application [Rails::Application, nil]
        # @return [Array<String>, nil] the names above Middleware (every name
        #   when it is not in the stack at all); nil when the stack cannot be
        #   read yet
        def middlewares_above(application = default_application)
          names = application && ApiOnlyAdmin.middleware_names(application)
          return unless names

          names.first(names.index(Middleware.name) || names.size)
        end

        # The boot warning, under the strategies that depend on the request
        # being marked: :hide_in_requests (reads above are not hidden) and
        # :bypass (they are not recorded).
        #
        # @param config [Configuration]
        # @return [void]
        def check(config, application = default_application)
          strategy = config.masked_attributes_nil_user_strategy
          return if strategy == :hide

          above = middlewares_above(application)
          return if above.blank?

          if strategy == :hide_in_requests
            Warnings.emit(:web_request_middleware_above_hide, message(above, 'are not hidden'), severity: :security, audience: :server)
          else
            Warnings.emit(:web_request_middleware_above_record, message(above, 'are not recorded'), severity: :config, audience: :server)
          end
        end

        # @param above [Array<String>]
        # @return [String]
        def message(above, consequence)
          "#{above.join(', ')} #{above.one? ? 'runs' : 'run'} above PermissionForge::WebRequest::Middleware: masked " \
            "attributes read there with nobody signed in #{consequence} (masked_attributes_nil_user_strategy). Move " \
            'the middleware below it (config.middleware.insert_after PermissionForge::WebRequest::Middleware, ...) ' \
            'if it reads masked models.'
        end

        private

        def default_application
          Rails.application if defined?(Rails) && Rails.respond_to?(:application)
        end
      end
    end
  end
end
