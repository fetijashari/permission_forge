require 'test_helper'

module PermissionForge
  module Services
    class FiltersResponseAttributesAuditHookTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true
        )
        create_resource_field(
          resource: @resource, name: 'name', label: 'Name',
          read_access: true, edit_access: true
        )
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: @resource, name: 'secret', label: 'Secret',
          read_access: false, edit_access: false
        )
        @user.regenerate_permissions
        Current.user = @user
        @original_hook = PermissionForge.configuration.on_field_filtered
      end

      teardown do
        PermissionForge.configuration.on_field_filtered = @original_hook
      end

      test 'hook not configured does not error' do
        PermissionForge.configuration.on_field_filtered = nil
        result = filter(name: 'Acme', secret: 'hidden')
        assert_equal({ name: 'Acme' }, result)
      end

      test 'hook called for each field with correct params' do
        calls = []
        PermissionForge.configuration.on_field_filtered = lambda { |**args|
          calls << args
        }

        filter(name: 'Acme', email: 'john@example.com', secret: 'hidden')

        assert_equal 3, calls.size

        name_call = calls.find { |c| c[:field_name] == :name }
        assert_equal :passed, name_call[:action]
        assert_equal 'Customer', name_call[:resource_name]
        assert_equal @user, name_call[:user]

        email_call = calls.find { |c| c[:field_name] == :email }
        assert_equal :masked, email_call[:action]

        secret_call = calls.find { |c| c[:field_name] == :secret }
        assert_equal :hidden, secret_call[:action]
      end

      test 'hook that raises does not break filtering' do
        PermissionForge.configuration.on_field_filtered = lambda { |**_args|
          raise 'boom!'
        }

        result = filter(name: 'Acme', email: 'john@example.com')
        assert_equal 'Acme', result[:name]
        assert_equal 'j***@example.com', result[:email]
      end

      test 'hidden field triggers hook with action hidden' do
        calls = []
        PermissionForge.configuration.on_field_filtered = lambda { |**args|
          calls << args
        }

        filter(secret: 'hidden')
        assert_equal 1, calls.size
        assert_equal :hidden, calls.first[:action]
      end

      test 'masked field triggers hook with action masked' do
        calls = []
        PermissionForge.configuration.on_field_filtered = lambda { |**args|
          calls << args
        }

        filter(email: 'john@example.com')
        assert_equal 1, calls.size
        assert_equal :masked, calls.first[:action]
      end

      test 'passed field triggers hook with action passed' do
        calls = []
        PermissionForge.configuration.on_field_filtered = lambda { |**args|
          calls << args
        }

        filter(name: 'Acme')
        assert_equal 1, calls.size
        assert_equal :passed, calls.first[:action]
      end

      private

      def filter(attributes)
        FiltersResponseAttributes.call(
          attributes: attributes,
          resource_name: 'Customer',
          user: @user
        )
      end
    end
  end
end
