require 'test_helper'

module PermissionForge
  module Services
    class GdprFieldAuditorTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'reports unmasked GDPR fields' do
        create_resource_field(resource: @resource, name: 'email', mask_access: false)

        PermissionForge.configuration.gdpr_defaults = true
        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }

        assert(unmasked.any? { |r| r[:field_name] == 'email' })
        email_finding = unmasked.find { |r| r[:field_name] == 'email' }
        assert_equal 'email', email_finding[:suggested_strategy]
        assert_equal 'Customer', email_finding[:resource_name]
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'ignores already-masked fields' do
        create_resource_field(resource: @resource, name: 'email', mask_access: true, mask_strategy: 'email')

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        assert_empty unmasked
      end

      test 'ignores non-GDPR fields' do
        create_resource_field(resource: @resource, name: 'domain', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        # domain is not a GDPR pattern, so should not appear as unmasked
        assert_not(unmasked.any? { |r| r[:field_name] == 'domain' })
      end

      test 'reports phone fields with last4 strategy' do
        create_resource_field(resource: @resource, name: 'phone', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        phone_finding = unmasked.find { |r| r[:field_name] == 'phone' }
        assert phone_finding
        assert_equal 'last4', phone_finding[:suggested_strategy]
      end

      test 'reports name fields with first1_last4 strategy' do
        create_resource_field(resource: @resource, name: 'first_name', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        name_finding = unmasked.find { |r| r[:field_name] == 'first_name' }
        assert name_finding
        assert_equal 'first1_last4', name_finding[:suggested_strategy]
      end

      test 'reports address fields with full strategy' do
        create_resource_field(resource: @resource, name: 'street', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        street_finding = unmasked.find { |r| r[:field_name] == 'street' }
        assert street_finding
        assert_equal 'full', street_finding[:suggested_strategy]
      end

      test 'respects custom gdpr_field_patterns' do
        create_resource_field(resource: @resource, name: 'tax_id', mask_access: false)

        original_patterns = PermissionForge.configuration.gdpr_field_patterns
        PermissionForge.configuration.gdpr_field_patterns = { /tax_id/ => 'last4' }

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        assert_equal 1, unmasked.size
        assert_equal 'last4', unmasked.first[:suggested_strategy]
      ensure
        PermissionForge.configuration.gdpr_field_patterns = original_patterns
      end

      test 'includes permission_set name in report' do
        create_resource_field(resource: @resource, name: 'email', mask_access: false)

        report = GdprFieldAuditor.call
        unmasked = report.select { |r| r[:type] == :unmasked_field }
        email_finding = unmasked.find { |r| r[:field_name] == 'email' }
        assert_equal @permission_set.name, email_finding[:permission_set]
      end

      # --- Virtual fields ---

      def implicit_grants(report = GdprFieldAuditor.call)
        report.select { |r| r[:type] == :implicit_virtual_grant }
      end

      def unmapped(report = GdprFieldAuditor.call)
        report.select { |r| r[:type] == :unmapped_column }
      end

      test 'reports a sensitive declared virtual field left on the implicit grant, per Permission Set' do
        finding = implicit_grants.sole

        assert_equal({ type: :implicit_virtual_grant, resource_name: 'Customer', field_name: 'full_address',
                       suggested_strategy: 'full', permission_set: @permission_set.name }, finding)
        assert_not(unmapped.any? { |r| r[:column] == 'full_address' })
      end

      test 'a virtual field with a row is not an implicit grant' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: true, mask_access: true, mask_strategy: 'full')

        assert_empty implicit_grants
      end

      # The engine skips a switched-off row, so the field is still granted by default.
      test 'a virtual field whose only row is switched off is still an implicit grant' do
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)

        assert_equal 'full_address', implicit_grants.sole[:field_name]
      end

      test 'muting, inactive and unreadable resources give no implicit grant' do
        @resource.update!(read_access: false)
        create_resource(permission_set: create_permission_set(name: 'Mute', is_muting: true), name: 'Customer')
        create_resource(permission_set: create_permission_set(name: 'Off', is_active: false), name: 'Customer')
        create_resource(permission_set: create_permission_set(name: 'Resource off'), name: 'Customer', is_active: false)

        assert_empty implicit_grants
      end

      test 'under :unconfigured a sensitive virtual field nobody configured is an unmapped column' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        report = GdprFieldAuditor.call

        assert_empty implicit_grants(report)
        assert_includes unmapped(report), { type: :unmapped_column, resource: 'Customer', column: 'full_address',
                                            pattern_matched: 'full', virtual: true }
        assert_not(unmapped(report).any? { |r| r[:column] == 'contact_count' })

        create_resource_field(resource: @resource, name: 'full_address', read_access: false)
        assert_not(unmapped.any? { |r| r[:column] == 'full_address' })
      end

      # The engine skips a switched-off row, so the column is back on
      # unconfigured_field_strategy: nobody has it mapped.
      test 'a column whose only row is switched off is an unmapped column' do
        row = create_resource_field(resource: @resource, name: 'email', mask_access: true, mask_strategy: 'email')
        assert_not(unmapped.any? { |r| r[:column] == 'email' })

        row.update!(is_active: false)
        assert_includes unmapped, { type: :unmapped_column, resource: 'Customer', column: 'email', pattern_matched: 'email' }
      end

      test 'a column with an active row in any Permission Set is mapped' do
        create_resource_field(resource: @resource, name: 'email', is_active: false)
        other = create_resource(permission_set: create_permission_set(name: 'Managers'), name: 'Customer')
        create_resource_field(resource: other, name: 'email', mask_access: true, mask_strategy: 'email')

        assert_not(unmapped.any? { |r| r[:column] == 'email' })
      end

      test 'under :unconfigured a virtual field whose only row is switched off is an unmapped column' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        create_resource_field(resource: @resource, name: 'full_address', read_access: false, is_active: false)

        assert_includes unmapped, { type: :unmapped_column, resource: 'Customer', column: 'full_address',
                                    pattern_matched: 'full', virtual: true }
      end

      # The engine skips a switched-off row, so it is "unmapped" — reporting it
      # as "unmasked" too would tell the admin to mask a row that does nothing.
      test 'a switched-off unmasked row is reported once, as an unmapped column' do
        create_resource_field(resource: @resource, name: 'email', mask_access: false, is_active: false)

        types = GdprFieldAuditor.call.select { |r| [r[:field_name], r[:column]].include?('email') }.map { |r| r[:type] }

        assert_equal [:unmapped_column], types
      end

      test 'a row in a switched-off resource, a switched-off set or a muting set does not map a column' do
        off_resource = create_resource(permission_set: create_permission_set(name: 'Off resource'), name: 'Supplier',
                                       is_active: false)
        off_set = create_resource(permission_set: create_permission_set(name: 'Off set', is_active: false), name: 'Supplier')
        muting = create_resource(permission_set: create_permission_set(name: 'Muting', is_muting: true), name: 'Supplier',
                                 read_access: false)
        [off_resource, off_set, muting].each do |resource|
          create_resource_field(resource: resource, name: 'name', read_access: true, mask_access: false)
        end

        report = GdprFieldAuditor.call.select { |r| [r[:resource], r[:resource_name]].include?('Supplier') }

        assert_equal [[:unmapped_column, 'name']], report.map { |r| [r[:type], r[:column]] }.uniq
        assert_empty(report.select { |r| r[:type] == :unmasked_field })
      end

      test 'cross-set unmasking only compares rows in effect' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        off_set = create_resource(permission_set: create_permission_set(name: 'Off set', is_active: false), name: 'Customer')
        create_resource_field(resource: off_set, name: 'email', read_access: true, mask_access: false)

        assert_empty(GdprFieldAuditor.call.select { |r| r[:type] == :cross_set_unmasking })

        off_set.permission_set.update!(is_active: true)

        unmasking = GdprFieldAuditor.call.select { |r| r[:type] == :cross_set_unmasking }
        assert_equal(['Off set'], unmasking.map { |r| r[:permission_set] })
      end

      test 'unmapped columns carry no virtual key' do
        email = unmapped.find { |r| r[:column] == 'email' }

        assert_equal({ type: :unmapped_column, resource: 'Customer', column: 'email', pattern_matched: 'email' }, email)
      end

      test 'takes an injected configuration' do
        strict = PermissionForge::Configuration.new
        strict.extra_fields_default_access = :unconfigured

        assert_empty implicit_grants(GdprFieldAuditor.call(configuration: strict))
      end
    end
  end
end
