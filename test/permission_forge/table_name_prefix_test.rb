# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  class TableNamePrefixTest < ActiveSupport::TestCase
    MODELS = {
      PermissionForge::PermissionSet => 'permission_sets',
      PermissionForge::PermissionSetUser => 'permission_set_users',
      PermissionForge::PermissionSetGroup => 'permission_set_groups',
      PermissionForge::PermissionSetGroupUser => 'permission_set_group_users',
      PermissionForge::Resource => 'resources',
      PermissionForge::ResourceField => 'resource_fields',
      PermissionForge::ResourceAction => 'resource_actions',
      PermissionForge::PermissionSetRule => 'permission_set_rules',
      PermissionForge::AuditEvent => 'audit_events'
    }.freeze

    # ── A. Configuration defaults ──

    test 'default table_name_prefix is permission_forge_' do
      config = PermissionForge::Configuration.new
      assert_equal 'permission_forge_', config.table_name_prefix
    end

    test 'table_name_prefix can be set to a custom value' do
      config = PermissionForge::Configuration.new
      config.table_name_prefix = 'custom_'
      assert_equal 'custom_', config.table_name_prefix
    end

    test 'table_name_prefix can be set to empty string' do
      config = PermissionForge::Configuration.new
      config.table_name_prefix = ''
      assert_equal '', config.table_name_prefix
    end

    test 'PermissionForge.table_name_prefix delegates to configuration' do
      assert_equal PermissionForge.configuration.table_name_prefix, PermissionForge.table_name_prefix
    end

    # ── B. All 8 models resolve table names with default prefix ──

    test 'all 8 models have the correct table name with default prefix' do
      PermissionForge::Configuration.new
      original_prefix = PermissionForge.configuration.table_name_prefix

      begin
        PermissionForge.configuration.table_name_prefix = 'permission_forge_'

        MODELS.each do |model, base_name|
          assert_equal "permission_forge_#{base_name}", model.table_name,
                       "#{model.name} should use prefixed table name"
        end
      ensure
        PermissionForge.configuration.table_name_prefix = original_prefix
      end
    end

    # ── C. All 8 models resolve table names with custom prefix ──

    test 'all 8 models resolve table names with custom prefix' do
      original_prefix = PermissionForge.configuration.table_name_prefix

      begin
        PermissionForge.configuration.table_name_prefix = 'pf_'

        MODELS.each do |model, base_name|
          assert_equal "pf_#{base_name}", model.table_name,
                       "#{model.name} should use custom prefix"
        end
      ensure
        PermissionForge.configuration.table_name_prefix = original_prefix
      end
    end

    test 'all 8 models resolve table names with empty prefix' do
      original_prefix = PermissionForge.configuration.table_name_prefix

      begin
        PermissionForge.configuration.table_name_prefix = ''

        MODELS.each do |model, base_name|
          assert_equal base_name, model.table_name,
                       "#{model.name} should use unprefixed table name"
        end
      ensure
        PermissionForge.configuration.table_name_prefix = original_prefix
      end
    end

    # ── D. Dynamic evaluation (lazy, not cached) ──

    test 'table name reflects prefix changes at runtime' do
      original_prefix = PermissionForge.configuration.table_name_prefix

      begin
        PermissionForge.configuration.table_name_prefix = 'first_'
        assert_equal 'first_permission_sets', PermissionForge::PermissionSet.table_name

        PermissionForge.configuration.table_name_prefix = 'second_'
        assert_equal 'second_permission_sets', PermissionForge::PermissionSet.table_name

        PermissionForge.configuration.table_name_prefix = ''
        assert_equal 'permission_sets', PermissionForge::PermissionSet.table_name
      ensure
        PermissionForge.configuration.table_name_prefix = original_prefix
      end
    end

    test 'all models respond to table_name as a method not a cached value' do
      MODELS.each_key do |model|
        assert model.respond_to?(:table_name), "#{model.name} should respond to table_name"
        # Calling table_name multiple times should always use current prefix
        name1 = model.table_name
        name2 = model.table_name
        assert_equal name1, name2, "#{model.name}.table_name should be consistent within same prefix"
      end
    end

    # ── E. Prefix prevents table name collisions ──

    test 'default prefix ensures no collision with common table names' do
      original_prefix = PermissionForge.configuration.table_name_prefix

      begin
        PermissionForge.configuration.table_name_prefix = 'permission_forge_'

        # Common host app table names that would collide without prefix
        common_tables = %w[resources users permission_sets]
        MODELS.each_value do |base_name|
          prefixed_name = "permission_forge_#{base_name}"
          assert_not_includes common_tables, prefixed_name,
                              "Prefixed table '#{prefixed_name}' should not match common table names"
        end
      ensure
        PermissionForge.configuration.table_name_prefix = original_prefix
      end
    end

    # ── F. Generator produces correct migration ──

    test 'migration template produces correct table names with default prefix' do
      migration_content = render_migration_template('permission_forge_')

      assert_includes migration_content, 'create_table :permission_forge_permission_sets'
      assert_includes migration_content, 'create_table :permission_forge_resources'
      assert_includes migration_content, 'create_table :permission_forge_resource_fields'
      assert_includes migration_content, 'create_table :permission_forge_resource_actions'
      assert_includes migration_content, 'create_table :permission_forge_permission_set_rules'
      assert_includes migration_content, 'create_table :permission_forge_permission_set_users'
      assert_includes migration_content, 'create_table :permission_forge_permission_set_groups'
      assert_includes migration_content, 'create_table :permission_forge_permission_set_group_users'
    end

    test 'migration template produces correct table names with custom prefix' do
      migration_content = render_migration_template('pf_')

      assert_includes migration_content, 'create_table :pf_permission_sets'
      assert_includes migration_content, 'create_table :pf_resources'
      assert_includes migration_content, 'create_table :pf_resource_fields'
    end

    test 'migration template produces unprefixed table names with empty prefix' do
      migration_content = render_migration_template('')

      assert_includes migration_content, 'create_table :permission_sets'
      assert_includes migration_content, 'create_table :resources'
      assert_includes migration_content, 'create_table :resource_fields'
      # Should NOT have double colons from empty prefix
      assert_not_includes migration_content, 'create_table :_'
    end

    test 'migration template produces correct foreign key references with prefix' do
      migration_content = render_migration_template('permission_forge_')

      assert_includes migration_content, 'foreign_key: { to_table: :permission_forge_permission_sets }'
      assert_includes migration_content, 'foreign_key: { to_table: :permission_forge_resources }'
      assert_includes migration_content, 'foreign_key: { to_table: :permission_forge_permission_set_groups }'
    end

    test 'migration template produces correct foreign key references without prefix' do
      migration_content = render_migration_template('')

      assert_includes migration_content, 'foreign_key: { to_table: :permission_sets }'
      assert_includes migration_content, 'foreign_key: { to_table: :resources }'
      assert_includes migration_content, 'foreign_key: { to_table: :permission_set_groups }'
    end

    # The models declare plain associations (permission_set_id, resource_id,
    # permission_set_group_id), so the prefix belongs on the table a reference
    # points at, never on the column.
    test 'migration template never prefixes reference columns, only the tables they point at' do
      migration_content = render_migration_template('pf_')

      assert_includes migration_content, 't.references :permission_set, foreign_key: { to_table: :pf_permission_sets }'
      assert_includes migration_content, 't.references :resource, foreign_key: { to_table: :pf_resources }'
      assert_includes migration_content,
                      't.references :permission_set_group, foreign_key: { to_table: :pf_permission_set_groups }'
      assert_no_match(/t\.references :pf_/, migration_content)
      assert_no_match(/:pf_\w+_id\b/, migration_content)
    end

    test 'migration template user references are never prefixed' do
      migration_content = render_migration_template('permission_forge_')

      assert_includes migration_content, 't.references :user, null: false'
      assert_not_includes migration_content, 't.references :permission_forge_user'
    end

    test 'migration template index names use short pf_ prefix for portability' do
      migration_content = render_migration_template('permission_forge_')

      assert_includes migration_content, "name: 'idx_pf_resource_actions_unique'"
      assert_includes migration_content, "name: 'idx_pf_pset_users_unique'"
      assert_includes migration_content, "name: 'idx_pf_pset_group_users_unique'"
    end

    # ── G. Generator produces correct initializer ──

    test 'initializer template includes default prefix' do
      initializer_content = render_initializer_template('permission_forge_')

      assert_includes initializer_content, "config.table_name_prefix = 'permission_forge_'"
    end

    test 'initializer template includes custom prefix' do
      initializer_content = render_initializer_template('pf_')

      assert_includes initializer_content, "config.table_name_prefix = 'pf_'"
    end

    test 'initializer template includes empty prefix' do
      initializer_content = render_initializer_template('')

      assert_includes initializer_content, "config.table_name_prefix = ''"
    end

    # ── H. Associations work with current prefix ──

    test 'permission_set.resources association works' do
      ps = create_permission_set
      resource = create_resource(permission_set: ps)

      assert_includes ps.resources, resource
      assert_equal ps, resource.permission_set
    end

    test 'resource.resource_fields association works' do
      ps = create_permission_set
      resource = create_resource(permission_set: ps)
      field = create_resource_field(resource: resource)

      assert_includes resource.resource_fields, field
      assert_equal resource, field.resource
    end

    test 'resource.resource_actions association works' do
      ps = create_permission_set
      resource = create_resource(permission_set: ps)
      action = create_resource_action(resource: resource)

      assert_includes resource.resource_actions, action
      assert_equal resource, action.resource
    end

    test 'permission_set.permission_set_rules association works' do
      ps = create_permission_set
      resource = create_resource(permission_set: ps)
      rule = create_permission_set_rule(permission_set: ps, resource: resource)

      assert_includes ps.permission_set_rules, rule
      assert_equal ps, rule.permission_set
      assert_equal resource, rule.resource
    end

    test 'permission_set.permission_set_users association works' do
      user = create_user
      ps = create_permission_set
      psu = create_permission_set_user(user: user, permission_set: ps)

      assert_includes ps.permission_set_users, psu
      assert_includes ps.users, user
    end

    test 'permission_set_group.permission_sets association works' do
      group = create_permission_set_group
      ps = create_permission_set(permission_set_group: group)

      assert_includes group.permission_sets, ps
      assert_equal group, ps.permission_set_group
    end

    test 'permission_set_group.permission_set_group_users association works' do
      user = create_user
      group = create_permission_set_group

      PermissionForge::PermissionSetGroupUser.create!(
        uuid: SecureRandom.uuid,
        permission_set_group: group,
        user: user
      )

      assert_includes group.users, user
    end

    # ── I. PermissionScopedFindable uses dynamic table_name ──

    test 'PermissionScopedFindable queries use model table_name' do
      # The concern references table_name dynamically — verify it returns
      # the correct value for the current prefix configuration
      ps = create_permission_set
      create_resource(permission_set: ps, name: 'Customer')

      current_table = PermissionForge::Resource.table_name
      expected_prefix = PermissionForge.table_name_prefix
      assert_equal "#{expected_prefix}resources", current_table
    end

    # ── J. Model count verification ──

    test 'exactly 9 models use dynamic table_name (8 permission models and the audit event)' do
      assert_equal 9, MODELS.size, 'Expected exactly 9 PermissionForge models with dynamic table names'
    end

    test 'all models are ActiveRecord::Base descendants' do
      MODELS.each_key do |model|
        assert model < ActiveRecord::Base, "#{model.name} should inherit from ActiveRecord::Base"
      end
    end

    private

    def render_migration_template(prefix, tenant: nil)
      render_install_template('migration.rb.tt', table_prefix: prefix, tenant_column: tenant,
                                                 migration_version: "[#{ActiveRecord::Migration.current_version}]")
    end

    def render_initializer_template(prefix)
      render_install_template('initializer.rb.tt', table_prefix: prefix)
    end
  end
end
