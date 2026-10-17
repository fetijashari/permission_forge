# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # WebRequest: the one definition of "a web request is in progress" — set by
  # its middleware at the top of the host's stack until the response is
  # finished, and nowhere else.
  class WebRequestTest < ActiveSupport::TestCase
    Middleware = WebRequest::Middleware

    def env_for(path = '/public/page', **)
      Rack::MockRequest.env_for("http://localhost#{path}", **)
    end

    # Calls the middleware around `app` (env => [status, headers, body]).
    def serve(env = env_for, &app)
      Middleware.new(app).call(env)
    end

    def ok(body = ['ok']) = [200, {}, body]

    teardown { ExecutionState.delete(WebRequest::KEY) }

    test 'the engine puts the middleware at the top of the host application\'s stack' do
      assert_equal 'PermissionForge::WebRequest::Middleware', Rails.application.middleware.first.name
      executor = Rails.application.middleware.map(&:name).index('ActionDispatch::Executor')
      assert_operator executor, :>, 0, 'above ActionDispatch::Executor, so the request is marked before its run starts'
    end

    test 'outside a request nothing is a web request' do
      assert_not WebRequest.active?
      assert_nil WebRequest.env
      assert_equal({}, WebRequest.details)
    end

    test 'below the middleware the request is a web request, with its env, until the server closes the body' do
      env = env_for
      seen = nil
      _status, _headers, body = serve(env) do |inner|
        seen = [WebRequest.active?, WebRequest.env.equal?(inner)]
        ok
      end

      assert_equal [true, true], seen
      assert WebRequest.active?, 'a streamed body is still the request: it ends when the body is closed'
      body.each { |_chunk| assert WebRequest.active? }
      body.close
      assert_not WebRequest.active?
    end

    test 'with rack.response_finished the request ends when the server runs the callbacks, and the body is left alone' do
      callbacks = []
      env = env_for
      env['rack.response_finished'] = callbacks
      body = ['ok']
      _status, _headers, returned = serve(env) { ok(body) }

      assert_same body, returned
      assert WebRequest.active?
      callbacks.each { |callback| callback.call(env, 200, {}, nil) }
      assert_not WebRequest.active?
    end

    test 'an application that raises ends the request at once, and the error goes on' do
      error = assert_raises(RuntimeError) { serve { raise 'boom' } }

      assert_equal 'boom', error.message
      assert_not WebRequest.active?
    end

    test 'a request served inside another puts back the outer request when it ends' do
      outer = env_for('/outer')
      inner_seen = nil
      _status, _headers, body = serve(outer) do
        _s, _h, inner_body = serve(env_for('/inner')) do |inner|
          inner_seen = WebRequest.env.equal?(inner)
          ok
        end
        inner_body.close
        [200, {}, [WebRequest.env.equal?(outer).to_s]]
      end

      assert inner_seen
      assert_equal ['true'], body.to_enum.to_a
      body.close
      assert_not WebRequest.active?
    end

    # The slot cannot be cleaned from another thread: it stays where it was
    # set, which hides more there, never less.
    test 'a response finished on another thread empties nothing there, and leaves the request\'s thread marked' do
      _status, _headers, body = serve { ok }
      other = Thread.new do
        ExecutionState[WebRequest::KEY] = :other_request
        body.close
        ExecutionState[WebRequest::KEY]
      end.value

      assert_equal :other_request, other, 'the other thread\'s own request is left alone'
      assert WebRequest.active?, 'fails closed: still marked on the request\'s thread'
    end

    # The slot is kept at the end of an executor run (:keep): a run completed
    # inside the request — ActionDispatch::Executor's run!(reset: true)
    # completes one left open — must not end the request (fails open).
    test 'a run completed inside the request does not end it' do
      executor = Rails.application.executor
      outer = executor.run!
      seen = nil
      _status, _headers, body = serve do
        executor.run!(reset: true).complete!
        seen = WebRequest.active?
        ok
      end

      assert seen
      body.close
    ensure
      outer&.complete!
    end

    # A server that neither runs the callbacks nor closes the body leaves the
    # slot set: the next request must not put that request back when it ends.
    test 'a request left unfinished is not put back by the next request on the thread' do
      serve(env_for('/leaked')) { ok } # body never closed
      _status, _headers, body = serve(env_for('/next')) { ok }
      body.close

      assert_not WebRequest.active?
    end

    # Reads made above ActionDispatch::Executor are outside its run, which
    # would not clear what runtime events published once there.
    test 'the outermost request forgets what it published once; a request inside it leaves that to the outer one' do
      _status, _headers, body = serve do
        Audit::Runtime.once?('rule.bypassed', 'Customer', 'x', 'y', nil)
        _s, _h, inner = serve(env_for('/inner')) { ok }
        inner.close
        [200, {}, [ExecutionState[Audit::Runtime::ONCE_KEY].size.to_s]]
      end

      assert_equal ['1'], body.to_enum.to_a, 'the inner request kept the outer one\'s memo'
      body.close
      assert_nil ExecutionState[Audit::Runtime::ONCE_KEY]
    end

    # --- StackCheck --------------------------------------------------------------------

    def app_with(*above)
      stack = ActionDispatch::MiddlewareStack.new
      stack.use Rack::ETag
      stack.unshift Middleware
      above.reverse_each { |klass| stack.insert_before(0, klass) }
      Struct.new(:middleware).new(stack)
    end

    def boot_log(config, application)
      io = StringIO.new
      Rails.logger = ActiveSupport::Logger.new(io)
      WebRequest::StackCheck.check(config, application)
      io.string
    end

    test 'StackCheck names the middlewares inserted above the request marker' do
      assert_equal [], WebRequest::StackCheck.middlewares_above, 'the dummy application: nothing above it'
      assert_equal %w[Rack::Head], WebRequest::StackCheck.middlewares_above(app_with(Rack::Head))
      assert_nil WebRequest::StackCheck.middlewares_above(Struct.new(:middleware).new(Object.new)), 'a stack not built yet'
    end

    test 'the boot check warns while the strategy depends on the request, naming what runs above' do
      config = Configuration.new
      application = app_with(Rack::Head)

      config.masked_attributes_nil_user_strategy = :hide_in_requests
      assert_match(/SECURITY warning: Rack::Head runs above PermissionForge::WebRequest::Middleware: .* are not hidden/,
                   boot_log(config, application))
      config.masked_attributes_nil_user_strategy = :bypass
      log = boot_log(config, application)
      assert_match(/Rack::Head runs above .* are not recorded/, log)
      assert_not_includes log, 'SECURITY'
      config.masked_attributes_nil_user_strategy = :hide
      assert_empty boot_log(config, application), ':hide does not depend on the request'
      config.masked_attributes_nil_user_strategy = :hide_in_requests
      assert_empty boot_log(config, app_with), 'nothing above it'
    end

    test 'details name the method, the path and, once routed, the endpoint, and write nothing into the env' do
      env = env_for('/public/customers/7?token=secret', method: 'POST')

      WebRequest.within(env) do
        assert_equal({ 'method' => 'POST', 'path' => '/public/customers/7', 'endpoint' => nil }, WebRequest.details)
        assert_not env.key?(ActionDispatch::Http::Parameters::PARAMETERS_KEY), 'reading must not route the request'

        env[ActionDispatch::Http::Parameters::PARAMETERS_KEY] = { controller: 'public/customers', action: 'show' }
        assert_equal 'public/customers#show', WebRequest.details['endpoint']
      end
    end

    test 'a long path is cut to the limit' do
      WebRequest.within(env_for("/#{'a' * 400}")) do
        assert_equal WebRequest::VALUE_LIMIT, WebRequest.details['path'].size
      end
    end
  end
end
