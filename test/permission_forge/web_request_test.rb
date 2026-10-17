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

    test 'the engine puts the middleware first in the host application\'s stack' do
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
