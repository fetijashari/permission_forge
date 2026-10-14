require 'test_helper'

module PermissionForge
  module Concerns
    class ActivationConditionsIntegrationTest < ActiveSupport::TestCase
      setup do
        @user = create_user
      end

      teardown do
        PermissionForge.configuration.request_context_resolver = -> { {} }
      end

      # --- Session-based permissions ---

      test 'session flag: set excluded when flag not in context' do
        configure_context(session_flags: [])

        ps = create_conditional_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'should not have access without MFA flag'
      end

      test 'session flag: set included when flag present in context' do
        configure_context(session_flags: ['mfa_verified'])

        ps = create_conditional_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'should have access with MFA flag'
      end

      # --- IP range restrictions ---

      test 'ip: set excluded when IP not in allowed range' do
        configure_context(ip: '10.0.0.1')

        ps = create_conditional_set(allowed_ips: '192.168.1.0/24')
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'should not have access from wrong IP'
      end

      test 'ip: set included when IP in allowed range' do
        configure_context(ip: '192.168.1.42')

        ps = create_conditional_set(allowed_ips: '192.168.1.0/24')
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'should have access from allowed IP'
      end

      # --- Login hour restrictions ---

      test 'hours: set excluded outside allowed hours' do
        configure_context(time: time_at_hour(20))

        ps = create_conditional_set(allowed_hours_start: 9, allowed_hours_end: 17)
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'should not have access outside hours'
      end

      test 'hours: set included during allowed hours' do
        configure_context(time: time_at_hour(12))

        ps = create_conditional_set(allowed_hours_start: 9, allowed_hours_end: 17)
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'should have access during hours'
      end

      # --- Mixed: conditional + unconditional sets ---

      test 'unconditional set always contributes regardless of context' do
        configure_context(session_flags: [])

        unconditional = create_permission_set(name: 'Always On')
        create_permission_set_user(user: @user, permission_set: unconditional)
        create_resource(permission_set: unconditional, name: 'Customer', read_access: true)

        conditional = create_conditional_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @user, permission_set: conditional)
        create_resource(permission_set: conditional, name: 'Customer', delete_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'unconditional read always works'
        assert_not @user.can_delete?(:Customer), 'conditional delete blocked without flag'
      end

      test 'conditional set adds to unconditional when conditions met' do
        configure_context(session_flags: ['mfa_verified'])

        unconditional = create_permission_set(name: 'Always On')
        create_permission_set_user(user: @user, permission_set: unconditional)
        create_resource(permission_set: unconditional, name: 'Customer', read_access: true)

        conditional = create_conditional_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @user, permission_set: conditional)
        create_resource(permission_set: conditional, name: 'Customer', read_access: true, delete_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'read from both sets'
        assert @user.can_delete?(:Customer), 'delete from conditional (flag present)'
      end

      # --- Conditional muting set ---

      test 'conditional muting set does not revoke when conditions not met' do
        configure_context(session_flags: [])

        granting = create_permission_set(name: 'Full Access')
        create_permission_set_user(user: @user, permission_set: granting)
        create_resource(permission_set: granting, name: 'Customer',
                        read_access: true, delete_access: true)

        muting = create_conditional_set(is_muting: true, requires_session_flag: 'lockdown')
        create_permission_set_user(user: @user, permission_set: muting)
        create_resource(permission_set: muting, name: 'Customer', delete_access: true)

        @user.regenerate_permissions
        assert @user.can_delete?(:Customer), 'muting set inactive (no lockdown flag)'
      end

      test 'conditional muting set revokes when conditions met' do
        configure_context(session_flags: ['lockdown'])

        granting = create_permission_set(name: 'Full Access')
        create_permission_set_user(user: @user, permission_set: granting)
        create_resource(permission_set: granting, name: 'Customer',
                        read_access: true, delete_access: true)

        muting = create_conditional_set(is_muting: true, requires_session_flag: 'lockdown')
        create_permission_set_user(user: @user, permission_set: muting)
        create_resource(permission_set: muting, name: 'Customer', delete_access: true)

        @user.regenerate_permissions
        assert_not @user.can_delete?(:Customer), 'muting set active (lockdown flag set)'
      end

      # --- No context resolver configured (backward compatible) ---

      test 'conditional set is included when no context resolver configured' do
        # Default resolver returns {} — all conditions with nil/blank pass
        ps = create_permission_set(name: 'Flag Set', requires_session_flag: 'mfa')
        create_permission_set_user(user: @user, permission_set: ps)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        # With an empty context the session_flag check would fail (flag not in [])
        # — but a blank context lets every conditional set count unless
        # conditional_sets_strict_mode is on (ConditionalSets#passing)
        assert @user.can_read?(:Customer), 'no context = no filtering (backward compatible)'
      end

      # --- Conditional + expiration interaction ---

      test 'expired conditional assignment is excluded even with valid context' do
        configure_context(session_flags: ['mfa_verified'])

        ps = create_conditional_set(requires_session_flag: 'mfa_verified')
        create_permission_set_user(user: @user, permission_set: ps, expires_at: 1.hour.ago)
        create_resource(permission_set: ps, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'expired even though context is valid'
      end

      private

      def configure_context(context)
        PermissionForge.configuration.request_context_resolver = -> { context }
      end

      def create_conditional_set(**attrs)
        create_permission_set(name: 'Conditional Set', **attrs)
      end

      def time_at_hour(hour)
        Time.current.change(hour: hour, min: 30)
      end
    end
  end
end
