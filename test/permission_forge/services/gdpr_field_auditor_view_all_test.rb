require 'test_helper'

module PermissionForge
  module Services
    class GdprFieldAuditorViewAllTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
      end

      test 'reports view_all on resource with PII fields' do
        resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          view_all: true
        )
        create_resource_field(resource: resource, name: 'email', mask_access: true, mask_strategy: 'email')

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :view_all_on_pii_resource }

        assert_equal 1, findings.size
        assert_equal 'Customer', findings.first[:resource_name]
        assert_includes findings.first[:bypasses], 'view_all'
        assert_includes findings.first[:pii_fields], 'email'
      end

      test 'reports modify_all on resource with PII fields' do
        resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          view_all: true,
          modify_all: true
        )
        create_resource_field(resource: resource, name: 'name', mask_access: true, mask_strategy: 'first1_last4')

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :view_all_on_pii_resource }

        assert_equal 1, findings.size
        assert_includes findings.first[:bypasses], 'view_all'
        assert_includes findings.first[:bypasses], 'modify_all'
      end

      test 'does not report view_all on resource without PII fields' do
        resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          view_all: true
        )
        create_resource_field(resource: resource, name: 'domain', mask_access: false)

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :view_all_on_pii_resource }

        assert_empty findings
      end

      test 'does not report when view_all and modify_all are both false' do
        resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          view_all: false,
          modify_all: false
        )
        create_resource_field(resource: resource, name: 'email', mask_access: true, mask_strategy: 'email')

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :view_all_on_pii_resource }

        assert_empty findings
      end

      test 'reports cross-set unmasking when same PII field is masked in one set and unmasked in another' do
        set_a = create_permission_set(name: 'Set A')
        set_b = create_permission_set(name: 'Set B')
        resource_a = create_resource(permission_set: set_a, name: 'Customer')
        resource_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_field(resource: resource_a, name: 'email', mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: resource_b, name: 'email', mask_access: false)

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :cross_set_unmasking }

        assert_equal 1, findings.size
        assert_equal 'email', findings.first[:field_name]
        assert_equal 'Set B', findings.first[:permission_set]
      end

      test 'does not report cross-set unmasking when all sets mask the field' do
        set_a = create_permission_set(name: 'Set A')
        set_b = create_permission_set(name: 'Set B')
        resource_a = create_resource(permission_set: set_a, name: 'Customer')
        resource_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_field(resource: resource_a, name: 'email', mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: resource_b, name: 'email', mask_access: true, mask_strategy: 'email')

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :cross_set_unmasking }

        assert_empty findings
      end

      test 'does not report view_all in a muting set, where it takes the bypass away' do
        muting = create_permission_set(name: 'No view all', is_muting: true)
        resource = create_resource(permission_set: muting, name: 'Customer', view_all: true)
        create_resource_field(resource: resource, name: 'email', mask_access: true, mask_strategy: 'email')

        assert_empty(GdprFieldAuditor.call.select { |r| r[:type] == :view_all_on_pii_resource })
      end

      test 'does not report view_all on a switched-off resource or set' do
        off_resource = create_resource(permission_set: @permission_set, name: 'Customer', view_all: true, is_active: false)
        create_resource_field(resource: off_resource, name: 'email', mask_access: true, mask_strategy: 'email')
        off_set = create_permission_set(name: 'Off', is_active: false)
        in_off_set = create_resource(permission_set: off_set, name: 'Customer', view_all: true)
        create_resource_field(resource: in_off_set, name: 'email', mask_access: true, mask_strategy: 'email')

        assert_empty(GdprFieldAuditor.call.select { |r| r[:type] == :view_all_on_pii_resource })
      end

      # Masks only combine within one resource: Supplier.email unmasked says
      # nothing about Customer.email.
      test 'does not report cross-set unmasking for the same field name on another resource' do
        set_a = create_permission_set(name: 'Set A')
        set_b = create_permission_set(name: 'Set B')
        customer = create_resource(permission_set: set_a, name: 'Customer')
        supplier = create_resource(permission_set: set_b, name: 'Supplier')
        create_resource_field(resource: customer, name: 'email', mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: supplier, name: 'email', mask_access: false)

        assert_empty(GdprFieldAuditor.call.select { |r| r[:type] == :cross_set_unmasking })
      end

      test 'does not report cross-set unmasking within a single set' do
        customer = create_resource(permission_set: @permission_set, name: 'Customer')
        supplier = create_resource(permission_set: @permission_set, name: 'Supplier')
        create_resource_field(resource: customer, name: 'email', mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: supplier, name: 'email', mask_access: false)

        assert_empty(GdprFieldAuditor.call.select { |r| r[:type] == :cross_set_unmasking })
      end

      test 'does not report cross-set unmasking for non-PII fields' do
        set_a = create_permission_set(name: 'Set A')
        set_b = create_permission_set(name: 'Set B')
        resource_a = create_resource(permission_set: set_a, name: 'Customer')
        resource_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_field(resource: resource_a, name: 'domain', mask_access: true, mask_strategy: 'full')
        create_resource_field(resource: resource_b, name: 'domain', mask_access: false)

        report = GdprFieldAuditor.call
        findings = report.select { |r| r[:type] == :cross_set_unmasking }

        assert_empty findings
      end
    end
  end
end
