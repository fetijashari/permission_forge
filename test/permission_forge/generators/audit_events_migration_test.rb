require 'test_helper'
require 'erb'

module PermissionForge
  module Generators
    # The install and upgrade migrations must produce the audit_events table
    # docs/audit-log.md describes and the new columns on the existing tables,
    # on a scratch database, for every prefix and tenancy mode.
    class AuditEventsMigrationTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      INSTALL = File.expand_path('../../../lib/generators/permission_forge/install/templates/migration.rb.tt', __dir__)
      UPGRADE = File.expand_path('../../../lib/generators/permission_forge/upgrade/templates/add_audit_events.rb.tt', __dir__)

      INDEXES = {
        'idx_pf_audit_uuid' => [%w[uuid], true],
        'idx_pf_audit_occurred' => [%w[occurred_at], false],
        'idx_pf_audit_event' => [%w[event occurred_at], false],
        'idx_pf_audit_subject' => [%w[subject_user_id occurred_at], false],
        'idx_pf_audit_pset' => [%w[permission_set_id occurred_at], false],
        'idx_pf_audit_pset_uuid' => [%w[permission_set_uuid occurred_at], false],
        'idx_pf_audit_record' => [%w[record_type record_id occurred_at], false],
        'idx_pf_audit_actor' => [%w[actor_id occurred_at], false],
        'idx_pf_audit_correlation' => [%w[correlation_id], false]
      }.freeze

      NOT_NULL = %w[uuid occurred_at event category actor_type source created_at].freeze
      STRINGS = %w[uuid event category actor_type actor_id actor_label source record_type record_id record_uuid record_label
                   permission_set_uuid subject_user_id reason request_id ip correlation_id].freeze

      class Scratch < ActiveRecord::Base
        self.abstract_class = true
      end

      setup do
        @rendered_classes = []
        @adapter = ActiveRecord::Base.connection.adapter_name.downcase
        @conn = connect_scratch
      end

      teardown do
        Scratch.remove_connection
        drop_scratch
        @rendered_classes.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
      end

      test 'install migration builds the contract table with the default prefix' do
        run_install(prefix: 'permission_forge_')
        assert_contract('permission_forge_', tenant: nil)
        assert_new_columns('permission_forge_')
      end

      test 'install migration builds the contract table with an empty prefix' do
        run_install(prefix: '')
        assert_contract('', tenant: nil)
        assert_new_columns('')
      end

      test 'install migration adds the tenant column and its index when tenancy is on' do
        run_install(prefix: '', tenant: 'account_id')
        assert_contract('', tenant: 'account_id')
        assert_equal ['account_id'], @conn.indexes('audit_events').find { |i| i.name == 'idx_pf_audit_tenant' }.columns
      end

      test 'upgrade migration creates the table and columns on an install that predates them' do
        [['permission_forge_', nil], ['', nil], ['', 'account_id']].each do |prefix, tenant|
          drop_all
          create_legacy_tables(prefix)
          run_upgrade(prefix: prefix, tenant: tenant)
          assert_contract(prefix, tenant: tenant)
          assert_new_columns(prefix)
        end
      end

      test 'upgrade migration twice is a no-op' do
        create_legacy_tables('')
        run_upgrade(prefix: '')
        before = snapshot
        run_upgrade(prefix: '')
        assert_equal before, snapshot
      end

      test 'upgrade migration against a fresh install is a no-op' do
        run_install(prefix: '', tenant: 'account_id')
        before = snapshot
        run_upgrade(prefix: '', tenant: 'account_id')
        assert_equal before, snapshot
      end

      test 'upgrade migration completes a table that exists without its indexes' do
        create_legacy_tables('')
        run_upgrade(prefix: '')
        @conn.remove_index 'audit_events', name: 'idx_pf_audit_actor'
        run_upgrade(prefix: '')
        assert_includes index_names('audit_events'), 'idx_pf_audit_actor'
      end

      test 'upgrade down refuses to drop the audit log' do
        run_install(prefix: '')
        error = assert_raises(ActiveRecord::IrreversibleMigration) { run_upgrade(prefix: '', direction: :down) }
        assert_match(/evidence/, error.message)
        assert @conn.table_exists?('audit_events')
        assert @conn.column_exists?('permission_set_users', :reviewed_at)
      end

      test 'upgrade adds the tenant column and index to a table created without tenancy' do
        create_legacy_tables('')
        run_upgrade(prefix: '')
        run_upgrade(prefix: '', tenant: 'account_id')
        assert_contract('', tenant: 'account_id')
      end

      test 'a long prefix keeps every audit index name within the PostgreSQL limit' do
        prefix = 'a_rather_long_company_prefix_'
        run_install(prefix: prefix, tenant: 'account_id')
        assert_short_index_names("#{prefix}audit_events")

        drop_all
        create_legacy_tables(prefix)
        run_upgrade(prefix: prefix, tenant: 'account_id')
        assert_short_index_names("#{prefix}audit_events")
      end

      private

      def render(path, prefix:, tenant:, user_id_type: 'bigint', tenant_id_type: 'bigint')
        context = Struct.new(:migration_version, :table_prefix, :tenant_column, :user_id_type, :tenant_id_type)
        owner = context.new("[#{ActiveRecord::Migration.current_version}]", prefix, tenant, user_id_type, tenant_id_type)
        ERB.new(File.read(path), trim_mode: '-').result(owner.instance_eval { binding })
      end

      def run_migration(source, direction)
        name = source[/^class (\w+)/, 1]
        @rendered_classes << name
        Object.send(:remove_const, name) if Object.const_defined?(name)
        TOPLEVEL_BINDING.eval(source)
        migration = Object.const_get(name).new
        migration.suppress_messages { migration.exec_migration(@conn, direction) }
      end

      def run_install(prefix:, tenant: nil)
        run_migration(render(INSTALL, prefix: prefix, tenant: tenant), :up)
      end

      def run_upgrade(prefix:, tenant: nil, direction: :up)
        run_migration(render(UPGRADE, prefix: prefix, tenant: tenant), direction)
      end

      def create_legacy_tables(prefix)
        @conn.create_table("#{prefix}permission_set_users") { |t| t.datetime :expires_at }
        @conn.create_table("#{prefix}permission_set_group_users") { |t| t.bigint :user_id }
        @conn.create_table("#{prefix}resource_fields") { |t| t.datetime :sensitive_acknowledged_at }
      end

      # Foreign keys first: MySQL ignores `force: :cascade` and refuses to
      # drop a table another one references.
      def drop_all
        remove_foreign_keys
        @conn.tables.each { |t| @conn.drop_table(t, force: :cascade) }
      end

      def remove_foreign_keys
        # SQLite drops a referenced table with force: :cascade (and Rails < 8.1
        # cannot remove its unnamed foreign keys one by one).
        return if @conn.adapter_name.casecmp?('SQLite')

        @conn.tables.each { |t| @conn.foreign_keys(t).each { |fk| @conn.remove_foreign_key(t, name: fk.name) } }
      end

      def index_names(table)
        @conn.indexes(table).map(&:name)
      end

      def assert_short_index_names(table)
        names = index_names(table)
        assert_equal 10, names.size
        assert(names.all? { |n| n.length <= 63 }, "index names too long: #{names.inspect}")
        assert_operator table.length, :<=, 63
      end

      def snapshot
        @conn.tables.sort.to_h { |table| [table, [column_signature(table), index_signature(table)]] }
      end

      def column_signature(table)
        @conn.columns(table).map { |c| [c.name, c.sql_type, c.null] }
      end

      def index_signature(table)
        @conn.indexes(table).map { |i| [i.name, i.columns, i.unique] }.sort
      end

      def assert_contract(prefix, tenant:)
        table = "#{prefix}audit_events"
        columns = @conn.columns(table).index_by(&:name)
        assert_equal expected_columns(tenant).sort, columns.keys.sort, 'exactly the contract columns (no updated_at)'
        assert_column_types(columns, tenant)
        assert_nullability(columns)
        assert_contract_indexes(table, tenant)
        assert_empty @conn.foreign_keys(table), 'events outlive records: no foreign keys'
      end

      def expected_columns(tenant)
        STRINGS + %w[occurred_at permission_set_id data created_at id] + [tenant].compact
      end

      def assert_column_types(columns, tenant)
        types = STRINGS.to_h { |c| [c, :string] }.merge('data' => :text, 'occurred_at' => :datetime, 'created_at' => :datetime)
        assert_equal types, columns.slice(*types.keys).transform_values(&:type)
        assert_equal 6, columns['occurred_at'].precision
        ['permission_set_id', tenant].compact.each { |c| assert_match(/bigint/i, columns[c].sql_type, c) }
      end

      def assert_nullability(columns)
        NOT_NULL.each { |c| assert_not columns[c].null, "#{c} should be NOT NULL" }
        (columns.keys - NOT_NULL - ['id']).each { |c| assert columns[c].null, "#{c} should be nullable" }
      end

      def assert_contract_indexes(table, tenant)
        indexes = @conn.indexes(table).index_by(&:name)
        INDEXES.each do |name, (cols, unique)|
          assert indexes[name], "missing index #{name}"
          assert_equal [cols, unique], [indexes[name].columns, indexes[name].unique]
        end
        assert_equal INDEXES.size + (tenant ? 1 : 0), indexes.size
      end

      def assert_new_columns(prefix)
        { 'permission_set_users' => %w[reviewed_at reviewed_by_id reason],
          'permission_set_group_users' => %w[reason],
          'resource_fields' => %w[sensitive_acknowledged_by_id] }.each do |table, names|
          columns = @conn.columns("#{prefix}#{table}").index_by(&:name)
          names.each do |name|
            assert columns[name], "#{table}.#{name} missing"
            assert columns[name].null, "#{table}.#{name} should be nullable"
          end
        end
        assert_user_id_types(prefix)
      end

      # reviewed_by_id and sensitive_acknowledged_by_id have the type of user_id.
      def assert_user_id_types(prefix)
        sets = @conn.columns("#{prefix}permission_set_users").index_by(&:name)
        fields = @conn.columns("#{prefix}resource_fields").index_by(&:name)
        user_id = sets['user_id'] || return # the legacy fixture has no user_id
        [sets['reviewed_by_id'], fields['sensitive_acknowledged_by_id']].each do |column|
          assert_equal [user_id.type, user_id.limit], [column.type, column.limit]
        end
      end

      # A separate connection so the dummy app's schema is never touched.
      def connect_scratch
        config = ActiveRecord::Base.connection_db_config.configuration_hash.dup
        main = ActiveRecord::Base.connection
        case @adapter
        when /postg/
          main.execute('DROP SCHEMA IF EXISTS pf_gen_scratch CASCADE')
          main.execute('CREATE SCHEMA pf_gen_scratch')
          config[:schema_search_path] = 'pf_gen_scratch'
        when /mysql|trilogy/
          main.execute('DROP DATABASE IF EXISTS permission_forge_gen_scratch')
          main.execute('CREATE DATABASE permission_forge_gen_scratch')
          config[:database] = 'permission_forge_gen_scratch'
        end
        Scratch.establish_connection(config)
        Scratch.connection
      end

      def drop_scratch
        main = ActiveRecord::Base.connection
        case @adapter
        when /postg/ then main.execute('DROP SCHEMA IF EXISTS pf_gen_scratch CASCADE')
        when /mysql|trilogy/ then main.execute('DROP DATABASE IF EXISTS permission_forge_gen_scratch')
        end
      end
    end
  end
end
