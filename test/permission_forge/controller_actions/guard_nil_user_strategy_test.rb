# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module ControllerActions
    # config.action_guard_nil_user_strategy decides what the controller guard
    # does for a mapped action with no current user, apart from
    # nil_user_strategy (row rules and masking): an app can keep record
    # lookups open for background code and still refuse guarded actions to
    # signed-out requests. nil (the default) follows nil_user_strategy, so
    # existing hosts see no change; new installs get :deny.
    class GuardNilUserStrategyTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.current_user_resolver = -> {}
        @set = create_permission_set(name: 'Support')
        create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
        PermissionForge.configuration.action_guard_nil_user_strategy = nil
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      def decide(**config)
        configuration = Configuration.new
        config.each { |key, value| configuration.public_send("#{key}=", value) }
        Authorizer.call(controller_path: 'customers', action_name: 'index', user: nil, configuration: configuration)
      end

      test 'the default is nil: follow nil_user_strategy' do
        assert_nil Configuration.new.action_guard_nil_user_strategy
        assert_equal :nil_user_bypassed, decide.reason
        assert_equal :nil_user_denied, decide(nil_user_strategy: :deny).reason
      end

      test ':deny refuses a mapped action while nil_user_strategy stays :bypass' do
        assert_equal :nil_user_denied, decide(action_guard_nil_user_strategy: :deny).reason
        assert_equal :nil_user_denied, decide(action_guard_nil_user_strategy: :raise).reason
        assert_equal :nil_user_denied, decide(action_guard_nil_user_strategy: 'deny').reason
        assert_raises(PermissionForge::ConfigurationError) { decide(action_guard_nil_user_strategy: 'unknown') }
      end

      test ':bypass lets a mapped action through while nil_user_strategy denies' do
        assert_equal :nil_user_bypassed, decide(action_guard_nil_user_strategy: :bypass, nil_user_strategy: :deny).reason
      end

      test 'end to end: a signed-out request to a guarded action is refused under :deny' do
        PermissionForge.configuration.action_guard_nil_user_strategy = :deny

        get '/customers'
        assert_response :forbidden

        get '/reports' # not guarded
        assert_response :ok
      end

      test 'end to end: the default keeps following nil_user_strategy :bypass' do
        get '/customers'
        assert_response :ok
      end

      test 'the install initializer sets :deny for new installs' do
        assert_match(/^  config\.action_guard_nil_user_strategy = :deny$/, render_install_template('initializer.rb.tt'))
      end
    end
  end
end
