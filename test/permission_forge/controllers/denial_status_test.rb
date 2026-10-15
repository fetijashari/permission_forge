# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # A denial the host does not rescue answers 403, as in production: Rails'
  # exceptions app renders the status the engine registered in
  # config.action_dispatch.rescue_responses (the dummy app raises instead,
  # show_exceptions = :none, so these tests switch error pages on for the
  # request). A host's rescue_from still decides.
  #
  #   PfAuditProbesController#show  Customer.find_by! under the row rules
  #   CustomersController#index     the action guard (Customer, read)
  #
  # Both rescue their error in the dummy app; the tests take the handlers
  # away (or put their own) for the duration of the test.
  class DenialStatusTest < ActionDispatch::IntegrationTest
    ROW_DENIAL = 'PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError'
    ACTION_DENIAL = 'PermissionForge::ActionNotAuthorizedError'

    setup do
      @old_resolver = PermissionForge.configuration.current_user_resolver
      @user = create_user(name: 'Grace')
      @set = create_permission_set(name: 'Support')
      @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers only', include_nulls: false,
                                 failure_message: 'You can only open your own customers')
      create_permission_set_user(user: @user, permission_set: @set)
      @theirs = create_customer(name: 'Theirs', supplier_id: @user.id + 1000)
      user = @user
      PermissionForge.configuration.current_user_resolver = -> { user }
    end

    teardown do
      PermissionForge.configuration.current_user_resolver = @old_resolver
    end

    test 'both denials are registered as 403 where ActionDispatch reads them' do
      assert_equal :forbidden, ActionDispatch::ExceptionWrapper.rescue_responses[ROW_DENIAL]
      assert_equal :forbidden, ActionDispatch::ExceptionWrapper.rescue_responses[ACTION_DENIAL]
      assert_equal 403, ActionDispatch::ExceptionWrapper.status_code_for_exception(ROW_DENIAL)
      assert_equal 403, ActionDispatch::ExceptionWrapper.status_code_for_exception(ACTION_DENIAL)
    end

    test 'an unrescued row-rule denial answers 403 with an empty page, and JSON for a JSON request' do
      without_rescue_handlers(PfAuditProbesController) do
        production_error_pages do
          get "/pf_audit_probe/customers/#{@theirs.id}"
          assert_response :forbidden
          assert_empty response.body, 'Rails ships no public/403.html'

          get "/pf_audit_probe/customers/#{@theirs.id}", headers: { 'Accept' => 'application/json' }
          assert_response :forbidden
          assert_equal({ 'status' => 403, 'error' => 'Forbidden' }, response.parsed_body)
        end
      end
    end

    test 'an unrescued action guard denial answers 403' do
      @resource.update!(read_access: false)

      without_rescue_handlers(CustomersController) do
        production_error_pages do
          get '/customers'
          assert_response :forbidden
        end
      end
    end

    test 'a host rescue_from still decides, and reads the rule messages without parsing' do
      without_rescue_handlers(PfAuditProbesController) do
        PfAuditProbesController.rescue_from(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do |error|
          render json: { error: error.failure_messages }, status: :not_found
        end
        production_error_pages { get "/pf_audit_probe/customers/#{@theirs.id}" }
      end

      assert_response :not_found
      assert_equal({ 'error' => ['You can only open your own customers'] }, response.parsed_body)
    end

    test 'a host rescue_from still decides for the action guard' do
      @resource.update!(read_access: false)

      without_rescue_handlers(CustomersController) do
        CustomersController.rescue_from(PermissionForge::ActionNotAuthorizedError) do |error|
          render plain: "No #{error.action} on #{error.resource}", status: :unauthorized
        end
        production_error_pages { get '/customers' }
      end

      assert_response :unauthorized
      assert_equal 'No index on Customer', response.body
    end

    private

    # The controller's own rescue_from handlers (and its parents') are gone
    # for the block; one it declares inside the block is the only one.
    def without_rescue_handlers(controller)
      saved = controller.rescue_handlers
      controller.rescue_handlers = []
      yield
    ensure
      controller.rescue_handlers = saved
    end

    # Errors rendered as in production: ShowExceptions with the public
    # exceptions app, no debug page.
    def production_error_pages
      env = Rails.application.env_config
      keys = %w[action_dispatch.show_exceptions action_dispatch.show_detailed_exceptions]
      saved = keys.to_h { |key| [key, env.fetch(key, :absent)] }
      env['action_dispatch.show_exceptions'] = :all
      env['action_dispatch.show_detailed_exceptions'] = false
      yield
    ensure
      saved.each { |key, value| value == :absent ? env.delete(key) : env[key] = value }
    end
  end
end
