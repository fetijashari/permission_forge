require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    class PermissionHashBuilderTest < ActiveSupport::TestCase
      # G5f (plan-final.md §2 SD): the admin levels a field row can have.
      LEVELS = PermissionForge::Admin::FieldLevel::GRANTING
      # The ResourceField flags of each admin level, plus "no row".
      VARIANT_CASES = (LEVELS.keys + [nil]).product(LEVELS.keys).freeze

      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true,
          create_access: false,
          edit_access: true,
          delete_access: false
        )
        @field_name = create_resource_field(
          resource: @resource, name: 'name', label: 'Name',
          read_access: true, edit_access: true
        )
        @field_email = create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false
        )
      end

      test 'returns a hash with resources key' do
        result = build_hash
        assert result.key?(:resources)
      end

      test 'includes the resource permissions' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert perms[:read_access]
        assert_not perms[:create_access]
        assert perms[:edit_access]
        assert_not perms[:delete_access]
      end

      test 'includes field permissions' do
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert_equal({ read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }, fields['name'])
        assert_equal({ read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' }, fields['email'])
      end

      test 'includes source permission sets' do
        sources = build_hash.dig(:resources, 'Customer', :source_permission_sets)
        assert_equal 1, sources.size
        assert_equal @permission_set.uuid, sources.first[:uuid]
      end

      test 'includes empty permission_set_rules when none exist' do
        rules = build_hash.dig(:resources, 'Customer', :permission_set_rules)
        assert_equal [], rules
      end

      test 'creates _uuid variant for _id fields the model has' do
        orders = create_resource(permission_set: @permission_set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', label: 'Owner', read_access: true, edit_access: false)
        fields = build_hash.dig(:resources, 'PfVariantOrder', :fields)
        assert fields.key?('owner_uuid')
        assert fields['owner_uuid'][:read_access]
      end

      test 'no _uuid variant entry for a name the model does not have' do
        create_resource_field(resource: @resource, name: 'supplier_id', label: 'Supplier', read_access: true)
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields.key?('supplier_id')
        assert_not fields.key?('supplier_uuid'), 'Customer has no supplier_uuid'
      end

      test 'includes rules when they exist' do
        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: 'current_user',
          operator: 'equal'
        )
        rules = build_hash.dig(:resources, 'Customer', :permission_set_rules)
        assert_equal 1, rules.size
        assert_equal 'supplier_id', rules.first[:field_name]
        assert_equal 'equal', rules.first[:operator]
      end

      test 'skips inactive resources' do
        @resource.update!(is_active: false)
        assert_not build_hash[:resources].key?('Customer')
      end

      # --- Mask fields in hash ---

      test 'includes mask_access and mask_strategy in field hash' do
        create_resource_field(
          resource: @resource, name: 'phone', label: 'Phone',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'last4'
        )
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['phone'][:mask_access]
        assert_equal 'last4', fields['phone'][:mask_strategy]
      end

      test 'mask fields default to false/full for non-masked fields' do
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert_not fields['name'][:mask_access]
        assert_equal 'full', fields['name'][:mask_strategy]
      end

      # --- Resource actions in hash ---

      test 'includes empty actions hash when no resource actions' do
        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert_equal({}, actions)
      end

      test 'includes resource actions in hash' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'sync', is_permitted: false)

        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert_equal({ is_permitted: true }, actions[:export])
        assert_equal({ is_permitted: false }, actions[:sync])
      end

      test 'skips inactive resource actions' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true, is_active: true)
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true, is_active: false)

        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert actions.key?(:export)
        assert_not actions.key?(:sync)
      end

      # --- Multi-permission-set merging (TRUE / most-permissive wins) ---

      test 'multi-set: TRUE wins for resource CRUD when first set denies and second grants' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        @resource.update!(read_access: false, create_access: false, edit_access: false, delete_access: false)
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, create_access: true, edit_access: true, delete_access: true)

        perms = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :permissions)
        assert perms[:read_access], 'read_access should be true (TRUE wins)'
        assert perms[:create_access], 'create_access should be true (TRUE wins)'
        assert perms[:edit_access], 'edit_access should be true (TRUE wins)'
        assert perms[:delete_access], 'delete_access should be true (TRUE wins)'
      end

      test 'multi-set: TRUE wins for resource CRUD when first set grants and second denies' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        @resource.update!(read_access: true, edit_access: true)
        create_resource(permission_set: set_b, name: 'Customer', read_access: false, edit_access: false)

        perms = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :permissions)
        assert perms[:read_access], 'read_access should be true (TRUE wins)'
        assert perms[:edit_access], 'edit_access should be true (TRUE wins)'
      end

      test 'multi-set: TRUE wins for field read/edit access' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        @field_name.update!(read_access: false, edit_access: false)
        create_resource_field(resource: res_b, name: 'name', label: 'Name', read_access: true, edit_access: true)

        fields = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :fields)
        assert fields['name'][:read_access], 'field read_access should be true (TRUE wins)'
        assert fields['name'][:edit_access], 'field edit_access should be true (TRUE wins)'
      end

      test 'multi-set: FALSE wins for mask_access (unmasked = most permissive)' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        @field_email.update!(mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: res_b, name: 'email', label: 'Email', read_access: true, edit_access: false, mask_access: false,
                              mask_strategy: 'full')

        fields = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :fields)
        assert_not fields['email'][:mask_access], 'mask_access should be false (FALSE = unmasked wins)'
      end

      test 'multi-set: FALSE wins for mask_access regardless of order' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        @field_email.update!(mask_access: false, mask_strategy: 'full')
        create_resource_field(resource: res_b, name: 'email', label: 'Email', read_access: true, edit_access: false, mask_access: true,
                              mask_strategy: 'email')

        fields = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :fields)
        assert_not fields['email'][:mask_access], 'mask_access should be false (FALSE = unmasked wins regardless of order)'
      end

      test 'multi-set: mask_access stays true when ALL sets mask' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        @field_email.update!(mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: res_b, name: 'email', label: 'Email', read_access: true, edit_access: false, mask_access: true,
                              mask_strategy: 'last4')

        fields = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :fields)
        assert fields['email'][:mask_access], 'mask_access should be true when all sets mask'
      end

      test 'multi-set: mask_strategy uses first strategy encountered' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        @field_email.update!(mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: res_b, name: 'email', label: 'Email', read_access: true, edit_access: false, mask_access: true,
                              mask_strategy: 'last4')

        fields = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :fields)
        assert_equal 'email', fields['email'][:mask_strategy], 'first strategy should win'
      end

      test 'multi-set: TRUE wins for resource action is_permitted' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        create_resource_action(resource: res_b, name: 'export', is_permitted: true)

        actions = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :actions)
        assert actions[:export][:is_permitted], 'is_permitted should be true (TRUE wins)'
      end

      test 'multi-set: TRUE wins for resource action is_permitted regardless of order' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true)
        create_resource_action(resource: res_b, name: 'sync', is_permitted: false)

        actions = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :actions)
        assert actions[:sync][:is_permitted], 'is_permitted should be true (TRUE wins regardless of order)'
      end

      test 'multi-set: resource action stays denied when ALL sets deny' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        create_resource_action(resource: res_b, name: 'export', is_permitted: false)

        actions = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :actions)
        assert_not actions[:export][:is_permitted], 'is_permitted should be false when all sets deny'
      end

      test 'multi-set: rules accumulate from all permission sets' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer')
        create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Rule A', field_name: 'supplier_id')
        create_permission_set_rule(permission_set: set_b, resource: res_b, name: 'Rule B', field_name: 'domain')

        rules = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :permission_set_rules)
        assert_equal 2, rules.size
        rule_names = rules.map { |r| r[:name] }
        assert_includes rule_names, 'Rule A'
        assert_includes rule_names, 'Rule B'
      end

      test 'multi-set: source_permission_sets lists all contributing sets' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        create_resource(permission_set: set_b, name: 'Customer')

        sources = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :source_permission_sets)
        assert_equal 2, sources.size
        uuids = sources.map { |s| s[:uuid] }
        assert_includes uuids, @permission_set.uuid
        assert_includes uuids, set_b.uuid
      end

      # --- ViewAll / ModifyAll in hash ---

      test 'includes view_all and modify_all in resource permissions' do
        @resource.update!(view_all: true, modify_all: true)
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert perms[:view_all]
        assert perms[:modify_all]
      end

      test 'view_all and modify_all default to false' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert_not perms[:view_all]
        assert_not perms[:modify_all]
      end

      test 'multi-set: TRUE wins for view_all' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        @resource.update!(view_all: false)
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, view_all: true)

        perms = build_hash_with([@permission_set, set_b]).dig(:resources, 'Customer', :permissions)
        assert perms[:view_all], 'view_all should be true (TRUE wins)'
      end

      private

      # --- G5f: explicit row over derived variant, read OR / mask AND (plan-final.md §2 SD) ---

      def orders_hash(sets)
        build_hash_with(sets).dig(:resources, 'PfVariantOrder', :fields)
      end

      def level_entry(level)
        LEVELS.fetch(level).merge(mask_strategy: 'full')
      end

      # For every (owner_uuid level or no row) × (owner_id level) on one
      # PfVariantOrder resource, in both row orders: the owner_uuid entry is
      # the explicit row's flags when the row exists, the derived variant's
      # (= owner_id's) when it does not.
      test 'G5f: the owner_uuid entry is the explicit row when there is one, else the derived variant, in either order' do
        VARIANT_CASES.each do |uuid_level, id_level|
          [true, false].each do |uuid_first|
            set = create_permission_set
            orders = create_resource(permission_set: set, name: 'PfVariantOrder', read_access: true)
            rows = []
            rows << ['owner_uuid', LEVELS.fetch(uuid_level)] if uuid_level
            rows << ['owner_id', LEVELS.fetch(id_level)]
            rows.reverse! unless uuid_first
            rows.each { |name, flags| create_resource_field(resource: orders, name: name, **flags) }

            expected = level_entry(uuid_level || id_level)
            assert_equal expected, orders_hash([set])['owner_uuid'], "uuid=#{uuid_level.inspect} id=#{id_level} uuid_first=#{uuid_first}"
            assert_equal level_entry(id_level), orders_hash([set])['owner_id']
          end
        end
      end

      # Random row sets per name across sets: read is the OR over the rows
      # of the name (own rows, and derived variants where the resource has
      # no own row), the mask the AND over the read-granting ones, the
      # strategy the first read-granting row's.
      test 'G5f property: read is OR over rows, mask is AND over read-granting rows, explicit over derived' do
        random = Random.new(20_261_015)
        12.times do |round|
          sets = Array.new(random.rand(1..3)) { create_permission_set }
          rows = sets.flat_map do |set|
            orders = create_resource(permission_set: set, name: 'PfVariantOrder', read_access: true)
            names = %w[owner_id owner_uuid].select { random.rand < 0.75 }
            names.map do |name|
              level = LEVELS.keys.sample(random: random)
              strategy = %w[full email last4].sample(random: random)
              create_resource_field(resource: orders, name: name, mask_strategy: strategy, **LEVELS.fetch(level))
              [set, name, LEVELS.fetch(level).merge(mask_strategy: strategy)]
            end
          end
          next if rows.empty?

          fields = orders_hash(sets)
          %w[owner_id owner_uuid].each do |name|
            counted = rows.select do |set, row_name, _|
              row_name == name || (name == 'owner_uuid' && row_name == 'owner_id' && rows.none? { |s, n, _| s == set && n == 'owner_uuid' })
            end
            next assert_nil(fields[name], "round #{round}: #{name} has no row") if counted.empty?

            reading = counted.map(&:last).select { |flags| flags[:read_access] }
            expected = {
              read_access: reading.any?,
              edit_access: counted.map(&:last).any? { |flags| flags[:read_access] && flags[:edit_access] },
              mask_access: reading.any? && reading.all? { |flags| flags[:mask_access] },
              mask_strategy: reading.first&.fetch(:mask_strategy) || 'full'
            }
            assert_equal expected, fields[name], "round #{round}: #{name} from #{counted.map { |s, n, f| [s.id, n, f] }.inspect}"
          end
        end
      end

      # D.4: a Resource row with edit, delete or Modify All but not the
      # permission they depend on (written past ValidatesDependency) grants
      # only what the dependency allows.
      test 'resource flags count edit and delete only with read, Modify All only with View All' do
        @resource.update!(view_all: true, modify_all: true, delete_access: true)
        @resource.update_columns(read_access: false, view_all: false)

        perms = build_hash.dig(:resources, 'Customer', :permissions)

        assert_equal({ read_access: false, create_access: false, edit_access: false, delete_access: false,
                       view_all: false, modify_all: false }, perms)
        assert_equal perms, PermissionForge::Services::PermissionHashBuilder.granted_flags(@resource.reload)
      end

      def build_hash
        build_hash_with([@permission_set])
      end

      def build_hash_with(permission_sets)
        PermissionForge::Services::PermissionHashBuilder.call(
          user: @user,
          permission_sets: permission_sets
        )
      end
    end
  end
end
