require 'test_helper'

module PermissionForge
  module Generators
    # Runs the install migration exactly as the generator renders it and checks
    # the schema it produces against what the models need. The rest of the
    # suite runs on test/dummy/db/schema.rb with an empty prefix, so it cannot
    # see a migration that creates the wrong columns.
    class InstallMigrationSchemaTest < ActiveSupport::TestCase
      MODELS = {
        PermissionForge::PermissionSetGroup => 'permission_set_groups',
        PermissionForge::PermissionSet => 'permission_sets',
        PermissionForge::Resource => 'resources',
        PermissionForge::ResourceField => 'resource_fields',
        PermissionForge::ResourceAction => 'resource_actions',
        PermissionForge::PermissionSetRule => 'permission_set_rules',
        PermissionForge::PermissionSetUser => 'permission_set_users',
        PermissionForge::PermissionSetGroupUser => 'permission_set_group_users',
        PermissionForge::AuditEvent => 'audit_events'
      }.freeze

      UNIQUE_INDEXES = {
        'resources' => %w[permission_set_id name],
        'resource_fields' => %w[resource_id name],
        'resource_actions' => %w[resource_id name],
        'permission_set_users' => %w[permission_set_id user_id],
        'permission_set_group_users' => %w[permission_set_group_id user_id]
      }.freeze

      %w[permission_forge_ acl_].each do |prefix|
        test "prefix #{prefix.inspect}: every foreign key the models use exists in the generated table" do
          columns = migrate(prefix)

          MODELS.each do |model, base|
            model.reflect_on_all_associations(:belongs_to).each do |association|
              assert_includes columns.fetch(base).keys, association.foreign_key.to_s,
                              "#{prefix}#{base} has no #{association.foreign_key} column " \
                              "(needed by #{model.name}##{association.name})"
            end
          end
        end

        test "prefix #{prefix.inspect}: generated tables match the schema the suite runs on" do
          columns = migrate(prefix)

          MODELS.each_value do |base|
            assert_equal column_types(base), columns.fetch(base), "#{prefix}#{base} differs from test/dummy/db/schema.rb"
          end
        end

        test "prefix #{prefix.inspect}: unique indexes sit on the columns the models validate" do
          migrate(prefix)

          UNIQUE_INDEXES.each do |base, expected_columns|
            index = connection.indexes("#{prefix}#{base}").find { |i| i.unique && i.columns == expected_columns }
            assert index, "#{prefix}#{base} has no unique index on #{expected_columns.join(', ')}"
          end
        end
      end

      # Where DDL is not transactional (MySQL commits it at once), the tables
      # outlive the test's rollback and are dropped by hand: after the test,
      # and before it in case an interrupted run left some behind.
      teardown { drop_generated_tables }

      private

      def connection
        ActiveRecord::Base.connection
      end

      # Renders and runs the migration inside the test transaction (SQLite and
      # PostgreSQL DDL is transactional, so the tables vanish on rollback) and
      # returns { base table name => { column name => type } }.
      def migrate(prefix)
        @generated_prefix = prefix
        drop_generated_tables
        release_index_names
        migration = migration_class(prefix).new
        ActiveRecord::Migration.suppress_messages { migration.exec_migration(connection, :up) }

        MODELS.values.index_with { |base| column_types("#{prefix}#{base}") }
      end

      # The migration class exactly as the generator would write it, defined
      # inside a throwaway namespace so repeated runs do not reopen a constant.
      def migration_class(prefix)
        version = "[#{ActiveRecord::Migration.current_version}]"
        source = render_install_template('migration.rb.tt', table_prefix: prefix, tenant_column: 'account_id', migration_version: version)
        Module.new.tap { |namespace| namespace.module_eval(source) }.const_get(:CreatePermissionForgeTables)
      end

      def column_types(table)
        connection.columns(table).to_h { |column| [column.name, column.type] }
      end

      def drop_generated_tables
        return if @generated_prefix.nil? || connection.supports_ddl_transactions?

        connection.disable_referential_integrity do
          MODELS.each_value { |base| connection.drop_table("#{@generated_prefix}#{base}", if_exists: true) }
        end
      end

      # Index names are database-wide in SQLite and PostgreSQL, and the
      # migration uses fixed idx_pf_* names, some of which
      # test/dummy/db/schema.rb already owns. Drop those for the duration of
      # the test (rolled back with it). Where the drop could not be rolled
      # back, index names belong to their table and nothing has to give way.
      def release_index_names
        return unless connection.supports_ddl_transactions?

        MODELS.each_value do |base|
          connection.indexes(base).each do |index|
            connection.remove_index(base, name: index.name) if index.name.start_with?('idx_pf_')
          end
        end
      end
    end
  end
end
