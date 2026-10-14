require 'test_helper'

module PermissionForge
  module ControllerActions
    # The guard end to end: real requests against the dummy app's controllers.
    #
    #   CustomersController          guarded, no declaration (convention → Customer)
    #   Customers::MergesController  guarded, create → the `merge` action on Customer
    #   ReportsController            not guarded, no model
    class GuardIntegrationTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @old_resolver = PermissionForge.configuration.current_user_resolver

        @user = create_user
        @set = create_permission_set(name: 'Support')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @set)
        sign_in @user
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      # Current is reset when a request starts, so the user is handed to the
      # request through the resolver instead of Current.user.
      def sign_in(user)
        PermissionForge.configuration.current_user_resolver = -> { user }
      end

      def block_unconfigured!
        PermissionForge.configuration.unconfigured_action_strategy = :block
      end

      # --- CRUD actions -----------------------------------------------------------

      test 'REST actions follow the CRUD flags of the resource' do
        get '/customers'
        assert_response :ok

        get '/customers/1'
        assert_response :ok

        @resource.update!(read_access: false)

        get '/customers'
        assert_response :forbidden

        get '/customers/1'
        assert_response :forbidden
      end

      test 'a user in no set is refused a managed resource under either strategy' do
        sign_in create_user

        get '/customers'
        assert_response :forbidden

        block_unconfigured!

        get '/customers'
        assert_response :forbidden
      end

      # --- custom actions ---------------------------------------------------------

      test 'an action nobody lists follows unconfigured_action_strategy' do
        get '/customers/export'
        assert_response :ok

        post '/customers/1/archive'
        assert_response :ok

        block_unconfigured!

        get '/customers/export'
        assert_response :forbidden

        post '/customers/1/archive'
        assert_response :forbidden
      end

      test 'a listed action is allowed only when it is permitted, under either strategy' do
        export = create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        get '/customers/export'
        assert_response :forbidden

        export.update!(is_permitted: true)

        get '/customers/export'
        assert_response :ok

        block_unconfigured!

        get '/customers/export'
        assert_response :ok

        export.update!(is_permitted: false)

        get '/customers/export'
        assert_response :forbidden
      end

      test 'listing an action in any set makes it managed for everyone' do
        post '/customers/1/archive'
        assert_response :ok

        other = create_permission_set(name: 'Managers')
        managed = create_resource(permission_set: other, name: 'Customer', read_access: true)
        create_resource_action(resource: managed, name: 'archive', is_permitted: true)

        post '/customers/1/archive'
        assert_response :forbidden

        create_permission_set_user(user: @user, permission_set: other)

        post '/customers/1/archive'
        assert_response :ok
      end

      test 'a muting set takes a permitted action away' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        muting = create_permission_set(name: 'No exports', is_muting: true)
        muted = create_resource(permission_set: muting, name: 'Customer', read_access: false)
        create_resource_action(resource: muted, name: 'export', is_permitted: true)

        get '/customers/export'
        assert_response :ok

        create_permission_set_user(user: @user, permission_set: muting)

        get '/customers/export'
        assert_response :forbidden

        get '/customers'
        assert_response :ok
      end

      # --- declared mapping -------------------------------------------------------

      test 'the merge controller is checked as the merge action, not as create' do
        post '/customers/1/merge'
        assert_response :ok

        merge = create_resource_action(resource: @resource, name: 'merge', is_permitted: false)

        post '/customers/1/merge'
        assert_response :forbidden

        @resource.update!(create_access: true)

        post '/customers/1/merge'
        assert_response :forbidden

        merge.update!(is_permitted: true)
        @resource.update!(create_access: false)

        post '/customers/1/merge'
        assert_response :ok
      end

      test 'the merge action follows unconfigured_action_strategy while nobody lists it' do
        block_unconfigured!

        post '/customers/1/merge'
        assert_response :forbidden
      end

      # --- unguarded and unmapped -------------------------------------------------

      test 'a controller without the guard is never checked' do
        block_unconfigured!
        PermissionForge.configuration.nil_user_strategy = :deny

        get '/reports'
        assert_response :ok

        sign_in nil

        get '/reports'
        assert_response :ok
      end

      # --- no current user --------------------------------------------------------

      test 'no current user passes under nil_user_strategy :bypass' do
        sign_in nil

        get '/customers'
        assert_response :ok

        post '/customers/1/archive'
        assert_response :ok
      end

      test 'no current user is refused under nil_user_strategy :deny and :raise' do
        sign_in nil

        %i[deny raise].each do |strategy|
          PermissionForge.configuration.nil_user_strategy = strategy

          get '/customers'
          assert_response :forbidden

          get '/customers/export'
          assert_response :forbidden

          post '/customers/1/merge'
          assert_response :forbidden
        end
      end

      # --- bypass -----------------------------------------------------------------

      test 'action_guard_bypass lets the chosen users through' do
        block_unconfigured!
        outsider = create_user(name: 'Admin')
        received = []
        PermissionForge.configuration.action_guard_bypass = lambda do |user, controller|
          received << [user, controller.class.name, controller.action_name]
          user == outsider
        end

        post '/customers/1/archive'
        assert_response :forbidden

        sign_in outsider

        post '/customers/1/archive'
        assert_response :ok

        post '/customers/1/merge'
        assert_response :ok

        assert_equal [[@user, 'CustomersController', 'archive'], [outsider, 'CustomersController', 'archive'],
                      [outsider, 'Customers::MergesController', 'create']], received
      end

      test 'a raising bypass refuses instead of letting the request through' do
        block_unconfigured!
        PermissionForge.configuration.action_guard_bypass = ->(_user, _controller) { raise 'boom' }

        post '/customers/1/archive'
        assert_response :forbidden

        get '/customers'
        assert_response :ok
      end

      # --- changes take effect on the next request --------------------------------

      test 'revoking the assignment refuses the next request' do
        get '/customers'
        assert_response :ok

        PermissionForge::PermissionSetUser.where(user_id: @user.id).destroy_all

        get '/customers'
        assert_response :forbidden
      end
    end
  end
end
