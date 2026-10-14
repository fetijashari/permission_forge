require 'test_helper'
require 'rails/generators/test_case'
require 'generators/permission_forge/upgrade/upgrade_generator'

module PermissionForge
  module Generators
    # The upgrade migrations must target the app's real tables: the prefix
    # comes from the app's configuration unless --table-prefix overrides it.
    class UpgradeGeneratorTest < Rails::Generators::TestCase
      tests PermissionForge::Generators::UpgradeGenerator
      destination File.expand_path('../../../tmp/upgrade_generator', __dir__)

      setup do
        # One directory per process: parallel workers run these tests at once.
        self.destination_root = "#{self.class.destination_root}_#{Process.pid}"
        prepare_destination
        @old_prefix = PermissionForge.configuration.table_name_prefix
        @old_tenant_model = PermissionForge.configuration.tenant_model
        PermissionForge.configuration.tenant_model = nil
      end

      teardown do
        PermissionForge.configuration.table_name_prefix = @old_prefix
        PermissionForge.configuration.tenant_model = @old_tenant_model
        FileUtils.rm_rf(destination_root)
      end

      test 'uses the configured empty prefix by default' do
        PermissionForge.configuration.table_name_prefix = ''

        run_generator

        assert_migration 'db/migrate/permission_forge_add_resource_fields_unique_index.rb' do |content|
          assert_match 'table = :resource_fields', content
          assert_match 'GROUP BY resource_id, name', content
          assert_no_match(/permission_forge_resource/, content)
        end
        assert_migration 'db/migrate/permission_forge_add_admin_ui_columns.rb', /add_column :resource_fields,/
      end

      test 'uses a custom configured prefix by default' do
        PermissionForge.configuration.table_name_prefix = 'acl_'

        run_generator

        assert_migration 'db/migrate/permission_forge_add_admin_ui_columns.rb', /add_column :acl_resource_fields,/
      end

      test 'an explicit --table-prefix wins over the configuration' do
        PermissionForge.configuration.table_name_prefix = ''

        run_generator ['--table-prefix=permission_forge_']

        assert_migration 'db/migrate/permission_forge_add_admin_ui_columns.rb',
                         /add_column :permission_forge_resource_fields,/
      end

      test 'audit events migration honours the prefix and the configured tenant column' do
        PermissionForge.configuration.table_name_prefix = 'acl_'

        run_generator ['--tenant-column=account_id']

        assert_migration 'db/migrate/permission_forge_add_audit_events.rb' do |content|
          assert_match 'create_table :acl_audit_events', content
          assert_match 'add_column_once :acl_permission_set_users, :reviewed_at', content
          assert_match(/t\.column\s+:account_id, tenant_key_type/, content)
          assert_match "add_index_once table, :account_id, name: 'idx_pf_audit_tenant'", content
        end
      end

      test 'audit events migration follows the configured tenant model' do
        PermissionForge.configuration.table_name_prefix = ''
        PermissionForge.configuration.tenant_model = 'Billing::Org'

        run_generator

        assert_migration 'db/migrate/permission_forge_add_audit_events.rb', /t\.column\s+:org_id, tenant_key_type/
      end

      test 'audit events migration has no tenant column without tenancy' do
        PermissionForge.configuration.table_name_prefix = ''

        run_generator

        assert_migration 'db/migrate/permission_forge_add_audit_events.rb' do |content|
          assert_no_match(/account_id|idx_pf_audit_tenant/, content)
        end
      end

      test 'foreign-key columns are never prefixed, whatever the table prefix' do
        PermissionForge.configuration.table_name_prefix = 'acl_'

        run_generator

        assert_migration 'db/migrate/permission_forge_add_resource_fields_unique_index.rb' do |content|
          assert_match 'table = :acl_resource_fields', content
          assert_match 'GROUP BY resource_id, name', content
          assert_match 'WHERE resource_id = ', content
          assert_match 'columns = %i[resource_id name]', content
          assert_match 'add_index table, columns, unique: true', content
          assert_no_match(/acl_resource_id/, content)
        end
      end

      test 'generated migrations are valid Ruby' do
        PermissionForge.configuration.table_name_prefix = ''
        run_generator

        %w[add_resource_fields_unique_index add_admin_ui_columns add_audit_events].each do |name|
          assert_migration "db/migrate/permission_forge_#{name}.rb" do |content|
            assert RubyVM::InstructionSequence.compile(content)
          end
        end
      end
    end
  end
end
