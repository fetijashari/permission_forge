require 'test_helper'

module PermissionForge
  module Services
    class GdprFieldAuditorExtendedTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'model with all GDPR columns mapped produces no unmapped findings' do
        # Customer has email and name columns that match GDPR patterns
        create_resource_field(resource: @resource, name: 'email', mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: @resource, name: 'name', mask_access: true, mask_strategy: 'first1_last4')

        report = GdprFieldAuditor.call
        unmapped = report.select { |r| r[:type] == :unmapped_column && r[:resource] == 'Customer' }
        assert_empty unmapped
      end

      test 'model with unmapped email column produces unmapped finding' do
        # Don't create any fields for email
        report = GdprFieldAuditor.call
        unmapped = report.select { |r| r[:type] == :unmapped_column && r[:resource] == 'Customer' }

        email_finding = unmapped.find { |r| r[:column] == 'email' }
        assert email_finding, 'Expected unmapped_column finding for email'
        assert_equal 'email', email_finding[:pattern_matched]
      end

      test 'model with email ResourceField with mask_access true produces no finding' do
        create_resource_field(resource: @resource, name: 'email', mask_access: true, mask_strategy: 'email')

        report = GdprFieldAuditor.call
        unmapped = report.select { |r| r[:type] == :unmapped_column && r[:resource] == 'Customer' && r[:column] == 'email' }
        assert_empty unmapped
      end

      test 'model with email ResourceField with mask_access false produces unmasked_field finding' do
        create_resource_field(resource: @resource, name: 'email', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field && r[:field_name] == 'email' }
        assert_equal 1, unmasked.size
      end

      test 'model class that cannot be constantized is skipped' do
        create_resource(permission_set: @permission_set, name: 'NonexistentModel')

        assert_nothing_raised do
          GdprFieldAuditor.call
        end
      end

      test 'non-PII unmapped column produces no finding' do
        # domain, supplier_id are not GDPR patterns
        report = GdprFieldAuditor.call
        unmapped = report.select { |r| r[:type] == :unmapped_column && r[:resource] == 'Customer' }

        assert_not(unmapped.any? { |r| r[:column] == 'domain' })
        assert_not(unmapped.any? { |r| r[:column] == 'supplier_id' })
      end

      test 'empty resources table produces empty report' do
        PermissionForge::Resource.destroy_all

        report = GdprFieldAuditor.call
        assert_empty report
      end

      test 'multiple resources with mixed mapped and unmapped columns' do
        # Customer has email (unmapped) + Supplier has name (unmapped)
        create_resource(permission_set: @permission_set, name: 'Supplier')

        report = GdprFieldAuditor.call
        unmapped = report.select { |r| r[:type] == :unmapped_column }

        customer_findings = unmapped.select { |r| r[:resource] == 'Customer' }
        supplier_findings = unmapped.select { |r| r[:resource] == 'Supplier' }

        assert(customer_findings.any? { |r| r[:column] == 'email' })
        assert(supplier_findings.any? { |r| r[:column] == 'name' })
      end
    end
  end
end
