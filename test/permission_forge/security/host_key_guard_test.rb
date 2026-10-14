require 'test_helper'

module PermissionForge
  module Security
    # An integer column silently truncates a UUID or string key to its leading
    # digits ('1aaa…' and '1bbb…' both become 1), which makes different users —
    # or different tenants — share permission data. HostKeyGuard turns that
    # into a ConfigurationError at the point where permissions are read or
    # assignments are written. The test schema has integer user_id columns, so
    # pointing user_class at a string-keyed model reproduces a mistyped install.
    class HostKeyGuardTest < ActiveSupport::TestCase
      ANN = '1aaaaaaa-0000-4000-8000-000000000001'.freeze
      BOB = '1bbbbbbb-0000-4000-8000-000000000002'.freeze

      setup do
        @set = create_permission_set
        create_resource(permission_set: @set, name: 'Customer', read_access: true, delete_access: true)
      end

      test 'integer user keys pass and permissions work' do
        user = create_user
        create_permission_set_user(user: user, permission_set: @set)

        assert PermissionForge::Services::HostKeyGuard.verify!
        assert user.can_read?(:Customer)
      end

      test 'a string-keyed user model over integer columns is reported with table, column and both types' do
        use_text_key_users

        error = assert_raises(PermissionForge::ConfigurationError) { PermissionForge::Services::HostKeyGuard.verify! }

        assert_match(/permission_set_users\.user_id/, error.message)
        assert_match(/permission_set_group_users\.user_id/, error.message)
        assert_match(/TextKeyUser/, error.message)
        assert_match(/integer/, error.message)
        assert_match(/string/, error.message)
      end

      test 'reading permissions raises instead of serving another user sets' do
        use_text_key_users
        bob = TextKeyUser.create!(id: BOB, name: 'Bob')

        assert_raises(PermissionForge::ConfigurationError) { bob.permissions_hash }
        assert_raises(PermissionForge::ConfigurationError) { bob.can_delete?(:Customer) }
      end

      test 'writing an assignment raises instead of storing a truncated id' do
        use_text_key_users

        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge::PermissionSetUser.create!(uuid: SecureRandom.uuid, permission_set: @set, user_id: ANN)
        end
        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge::PermissionSetGroupUser.create!(uuid: SecureRandom.uuid, user_id: ANN,
                                                          permission_set_group: create_permission_set_group)
        end
        assert_equal 0, PermissionForge::PermissionSetUser.count
        assert_equal 0, PermissionForge::PermissionSetGroupUser.count
      end

      test 'a string-keyed tenant model over integer tenant columns is reported' do
        PermissionForge.configuration.tenant_model = 'TextKeyTenant'
        PermissionForge.configuration.tenant_column = :account_id

        error = assert_raises(PermissionForge::ConfigurationError) { PermissionForge::Services::HostKeyGuard.verify! }

        assert_match(/permission_sets\.account_id/, error.message)
        assert_match(/TextKeyTenant/, error.message)
      end

      test 'the audit log tenant column is checked too: a truncated tenant would show one tenant the events of another' do
        PermissionForge.configuration.tenant_model = 'TextKeyTenant'
        PermissionForge.configuration.tenant_column = :account_id

        error = assert_raises(PermissionForge::ConfigurationError) { PermissionForge::Services::HostKeyGuard.verify! }

        assert_match(/audit_events\.account_id/, error.message)
      end

      test 'an audit table that is not there yet does not hide the other columns' do
        PermissionForge.configuration.tenant_model = 'TextKeyTenant'
        PermissionForge.configuration.tenant_column = :account_id
        audit = PermissionForge::AuditEvent
        audit.define_singleton_method(:table_exists?) { false }

        error = assert_raises(PermissionForge::ConfigurationError) { PermissionForge::Services::HostKeyGuard.verify! }

        assert_match(/permission_sets\.account_id/, error.message)
        assert_no_match(/audit_events/, error.message)
      ensure
        audit.singleton_class.send(:remove_method, :table_exists?) if audit&.singleton_class&.method_defined?(:table_exists?, false)
      end

      test 'the guard checks again after the configuration changes' do
        assert PermissionForge::Services::HostKeyGuard.verify!

        use_text_key_users
        assert_raises(PermissionForge::ConfigurationError) { PermissionForge::Services::HostKeyGuard.verify! }

        PermissionForge.configuration.user_class = 'User'
        assert PermissionForge::Services::HostKeyGuard.verify!
      end

      private

      def use_text_key_users
        PermissionForge.configuration.user_class = 'TextKeyUser'
      end
    end
  end
end
