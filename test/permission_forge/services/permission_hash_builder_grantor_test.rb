# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/declares_audit_user_class'

module PermissionForge
  module Services
    # source_permission_sets names who granted (and last changed) each
    # assignment: by uuid when the audit user model has one, else by id. Most
    # host user models have no uuid column, and the install defaults stamp
    # created_by_id (audit_trail_enabled = true) whenever a signed-in admin
    # assigns a set — a build that asked every user for a uuid raised from
    # then on, for every check of the assignee (pre-release integrity review B2).
    class PermissionHashBuilderGrantorTest < ActiveSupport::TestCase
      include DeclaresAuditUserClass

      # The users table seen through a model without a uuid attribute: a host
      # user model that never had the column.
      class UuidlessAdmin < ActiveRecord::Base
        self.table_name = 'users'
        self.ignored_columns += ['uuid']
      end

      setup do
        @user = create_user
        @admin = create_user(name: 'Ada Admin')
        @set = create_permission_set(name: 'Support')
        create_resource(permission_set: @set, name: 'Customer', read_access: true)
        PermissionForge.configuration.audit_trail_enabled = true
      end

      teardown do
        use_audit_user_class('User')
      end

      test 'the grantor is named by uuid when the audit user model has one' do
        assign(created_by_id: @admin.id, updated_by_id: @admin.id)

        source = source_of(User.find(@user.id))

        assert_equal @admin.uuid, source[:permission_set_granted_by]
        assert_equal @admin.uuid, source[:permission_set_granted_updated_by]
      end

      test 'the grantor is named by id when the audit user model has no uuid' do
        use_audit_user_class(UuidlessAdmin.name)
        assign(created_by_id: @admin.id, updated_by_id: @admin.id)
        user = User.find(@user.id)

        source = assert_nothing_raised { source_of(user) }

        assert_equal @admin.id, source[:permission_set_granted_by]
        assert_equal @admin.id, source[:permission_set_granted_updated_by]
        assert user.can_read?(:Customer)
      end

      test 'an assignment nobody stamped names no grantor' do
        use_audit_user_class(UuidlessAdmin.name)
        assign

        source = source_of(User.find(@user.id))

        assert_nil source[:permission_set_granted_by]
        assert_nil source[:permission_set_granted_updated_by]
      end

      private

      def assign(**attrs)
        create_permission_set_user(user: @user, permission_set: @set, **attrs)
      end

      def source_of(user)
        user.permissions_hash.dig(:permissions, :resources, :Customer, :source_permission_sets).sole
      end

      # What HasAuditTrail declares when the model loads with that audit
      # user class configured.
      def use_audit_user_class(name)
        declare_audit_user_class(name)
      end
    end
  end
end
