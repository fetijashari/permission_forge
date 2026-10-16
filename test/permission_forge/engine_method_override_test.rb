# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Field test round 7 (D#67): the admin's edit and delete forms POST with a
  # hidden `_method` (patch / delete), which Rack::MethodOverride turns into
  # the verb the route wants. `rails new --api` leaves Rack::MethodOverride
  # out of the application's stack, so with the three middlewares the docs
  # name every such form answered 404 ("No route matches [POST] …"). The
  # engine brings its own (PermissionForge::AdminMethodOverride, in the
  # engine's middleware stack: it runs for the engine's routes only) — and
  # leaves the JSON API's paths alone: a JSON client says the verb it means.
  #
  # The engine is called directly, behind the cookie, session and flash
  # middlewares and nothing else, as an API-only host has it.
  class EngineMethodOverrideTest < ActiveSupport::TestCase
    setup do
      @old_forgery = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = false
      @set = create_permission_set(name: 'Sales rep')
      @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true, edit_access: true)
      @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
      @rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'name', field_value: 'x')
    end

    teardown do
      ActionController::Base.allow_forgery_protection = @old_forgery
    end

    test 'the engine stack holds the admin method override' do
      assert_includes PermissionForge::Engine.middleware.map(&:klass), PermissionForge::AdminMethodOverride
      assert_operator PermissionForge::AdminMethodOverride, :<, Rack::MethodOverride
    end

    test 'an admin form posted with _method=delete reaches the destroy route' do
      env = engine_call(:post, "/permission_sets/#{@set.id}/resources/Customer/rules/#{@rule.id}", '_method' => 'delete')

      assert_equal 'DELETE', env['REQUEST_METHOD']
      assert_equal %w[permission_forge/permission_set_rules destroy], routed(env)
      assert_not PermissionSetRule.exists?(@rule.id), 'the rule is deleted'
    end

    test 'an admin form posted with _method=patch reaches the update route' do
      env = engine_call(:post, "/permission_sets/#{@set.id}/resources/Customer/fields/email",
                        '_method' => 'patch', 'field' => { 'level' => 'read', 'label' => 'E-mail' })

      assert_equal 'PATCH', env['REQUEST_METHOD']
      assert_equal %w[permission_forge/resource_fields update], routed(env)
    end

    test 'the JSON API is left alone: _method and the override header do not change its verb' do
      path = "/api/permission_sets/#{@set.uuid}"
      env = engine_call(:post, path, '_method' => 'delete')

      assert_equal 'POST', env['REQUEST_METHOD']
      assert_not_equal 'destroy', routed(env)&.last
      assert PermissionSet.exists?(@set.id)

      env = engine_call(:post, path, {}, 'HTTP_X_HTTP_METHOD_OVERRIDE' => 'DELETE')

      assert_equal 'POST', env['REQUEST_METHOD']
      assert PermissionSet.exists?(@set.id)
    end

    test 'a POST without _method stays a POST' do
      env = engine_call(:post, "/permission_sets/#{@set.id}/duplicate")

      assert_equal 'POST', env['REQUEST_METHOD']
    end

    private

    # One request to the engine behind the cookie, session and flash
    # middlewares (what the docs tell an API-only host to add); the env as
    # the engine left it.
    def engine_call(verb, path, params = {}, headers = {})
      env = Rack::MockRequest.env_for(path, method: verb.to_s.upcase, params: params)
      env.merge!(Rails.application.env_config, headers, 'SCRIPT_NAME' => '/permission_forge')
      app = ActionDispatch::Cookies.new(ActionDispatch::Session::CookieStore.new(ActionDispatch::Flash.new(PermissionForge::Engine),
                                                                                key: '_pf_test_session'))
      status, _headers, body = app.call(env)
      body.close if body.respond_to?(:close)
      env.merge('pf.status' => status)
    end

    # [controller, action] the engine's router dispatched to, or nil (no route).
    def routed(env)
      params = env['action_dispatch.request.path_parameters']
      params && [params[:controller], params[:action]]
    end
  end
end
