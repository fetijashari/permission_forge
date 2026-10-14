require 'test_helper'

module PermissionForge
  class PermissionSetConditionsTest < ActiveSupport::TestCase
    # --- conditional? / unconditional? ---

    test 'unconditional? returns true for set with no conditions' do
      ps = create_permission_set
      assert ps.unconditional?
      assert_not ps.conditional?
    end

    test 'conditional? returns true with requires_session_flag' do
      ps = create_permission_set(requires_session_flag: 'mfa_verified')
      assert ps.conditional?
    end

    test 'conditional? returns true with allowed_ips' do
      ps = create_permission_set(allowed_ips: '192.168.1.0/24')
      assert ps.conditional?
    end

    test 'conditional? returns true with allowed_hours_start' do
      ps = create_permission_set(allowed_hours_start: 9, allowed_hours_end: 17)
      assert ps.conditional?
    end

    # --- Scopes ---

    test '.conditional scope returns only conditional sets' do
      unconditional = create_permission_set(name: 'Unconditional')
      conditional = create_permission_set(name: 'Conditional', requires_session_flag: 'mfa')

      scope = PermissionForge::PermissionSet.conditional
      assert_includes scope, conditional
      assert_not_includes scope, unconditional
    end

    test '.unconditional scope returns only unconditional sets' do
      unconditional = create_permission_set(name: 'Unconditional')
      conditional = create_permission_set(name: 'Conditional', allowed_ips: '10.0.0.0/8')

      scope = PermissionForge::PermissionSet.unconditional
      assert_includes scope, unconditional
      assert_not_includes scope, conditional
    end

    # --- Validations ---

    test 'allowed_hours_start validates range 0-23' do
      ps = create_permission_set
      ps.allowed_hours_start = 24
      assert_not ps.valid?
      assert ps.errors[:allowed_hours_start].any?
    end

    test 'allowed_hours_end validates range 0-23' do
      ps = create_permission_set
      ps.allowed_hours_end = -1
      assert_not ps.valid?
      assert ps.errors[:allowed_hours_end].any?
    end

    test 'allowed_hours_start nil is valid' do
      ps = create_permission_set(allowed_hours_start: nil)
      assert ps.valid?
    end

    test 'allowed_hours within range is valid' do
      ps = create_permission_set(allowed_hours_start: 0, allowed_hours_end: 23)
      assert ps.valid?
    end

    # --- Deep clone preserves conditions ---

    test 'deep_clone preserves all activation conditions' do
      ps = create_permission_set(
        requires_session_flag: 'mfa_verified',
        allowed_ips: '10.0.0.0/8',
        allowed_hours_start: 9,
        allowed_hours_end: 17
      )
      create_resource(permission_set: ps, name: 'Customer', read_access: true)

      cloned = ps.deep_clone(name: 'Cloned')
      assert_equal 'mfa_verified', cloned.requires_session_flag
      assert_equal '10.0.0.0/8', cloned.allowed_ips
      assert_equal 9, cloned.allowed_hours_start
      assert_equal 17, cloned.allowed_hours_end
    end
  end
end
