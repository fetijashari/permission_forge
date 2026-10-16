# frozen_string_literal: true

require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    # rake permission_forge:audit, `conditions` check: stored activation
    # conditions the validation would refuse today (they are unjudgeable at
    # read time: a muting set applies always, a granting set never passes),
    # and resources with an explicit row for a name that is also a variant
    # of another row (the explicit row decides since 0.15).
    class SecurityAuditConditionsCheckTest < ActiveSupport::TestCase
      def audit
        SecurityAudit.call(configuration: PermissionForge.configuration, checks: [SecurityAuditChecks::ConditionsCheck],
                           environment: 'test')
      end

      def finding(code) = audit.findings.find { |f| f.code == code }

      def stored(**attrs)
        set = create_permission_set(name: attrs.delete(:name), is_muting: attrs.delete(:is_muting) || false)
        set.update_columns(attrs)
        set.reload
      end

      test 'the check is registered and quiet on a clean install' do
        assert_includes SecurityAudit.checks, SecurityAuditChecks::ConditionsCheck
        create_permission_set(allowed_ips: '10.0.0.0/8', allowed_hours_start: 9, allowed_hours_end: 17)

        assert_empty audit.findings
      end

      test 'incomplete_conditions lists every stored row the validation would refuse, saying what each does now' do
        lockdown = stored(name: 'Lockdown', is_muting: true, allowed_ips: '10.0.0.0/8, office')
        create_permission_set_user(user: create_user, permission_set: lockdown)
        stored(name: 'Night shift', allowed_hours_start: 22, allowed_hours_end: 22)
        stored(name: 'Half window', allowed_hours_start: 9)
        stored(name: 'Out of range', allowed_hours_start: 25, allowed_hours_end: 3)

        found = finding(:incomplete_conditions)

        assert_equal :medium, found.severity
        assert_equal 'conditions', found.check
        items = found.items
        assert_equal 4, items.size
        assert_match(/Lockdown \(muting\): IP entry “office” is not an IP address or CIDR range .*applies to every request.*1 person/, items[0])
        assert_match(/Night shift: start hour 22 equals end hour 22 .*never passes/, items[1])
        assert_match(/Half window: end hour missing .*never passes/, items[2])
        assert_match(/Out of range: hour outside 0–23 .*never passes/, items[3])
        assert_match(/refuses|Fix/, found.detail)
      end

      test 'variant_rows_conflict lists resources holding a row and an explicit row for its variant' do
        set = create_permission_set(name: 'Sales')
        orders = create_resource(permission_set: set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', read_access: true, edit_access: true)
        create_resource_field(resource: orders, name: 'owner_uuid', read_access: false)
        plain = create_resource(permission_set: set, name: 'Customer', read_access: true)
        create_resource_field(resource: plain, name: 'supplier_id', read_access: true)

        found = finding(:variant_rows_conflict)

        assert_equal :info, found.severity
        assert_equal ['Sales › PfVariantOrder: owner_id (Editable) → owner_uuid (Hidden): the owner_uuid row decides'], found.items
      end

      test 'a switched-off row or set is not a conflict' do
        set = create_permission_set(name: 'Off')
        orders = create_resource(permission_set: set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', read_access: true)
        create_resource_field(resource: orders, name: 'owner_uuid', read_access: false, is_active: false)

        assert_nil finding(:variant_rows_conflict)
      end
    end
  end
end
