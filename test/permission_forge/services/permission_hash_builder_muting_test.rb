require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    class PermissionHashBuilderMutingTest < ActiveSupport::TestCase
      setup do
        @user = create_user

        # Granting set: broad CRM access
        @granting_set = create_permission_set(name: 'CRM Access')
        create_permission_set_user(user: @user, permission_set: @granting_set)
        @granting_resource = create_resource(
          permission_set: @granting_set, name: 'Customer',
          read_access: true, create_access: true, edit_access: true, delete_access: true,
          view_all: true, modify_all: true
        )
        @field_name = create_resource_field(
          resource: @granting_resource, name: 'name', label: 'Name',
          read_access: true, edit_access: true
        )
        @field_email = create_resource_field(
          resource: @granting_resource, name: 'email', label: 'Email',
          read_access: true, edit_access: true, mask_access: false
        )
        @action_export = create_resource_action(
          resource: @granting_resource, name: 'export', is_permitted: true
        )
        @action_sync = create_resource_action(
          resource: @granting_resource, name: 'sync', is_permitted: true
        )

        # Muting set: restrict junior users
        # In muting sets, true means "revoke this permission". Dependency validation is
        # skipped for muting sets since the semantics are inverted.
        @muting_set = create_permission_set(name: 'Junior Restriction', is_muting: true)
        create_permission_set_user(user: @user, permission_set: @muting_set)
        @muting_resource = create_resource(
          permission_set: @muting_set, name: 'Customer',
          read_access: false, create_access: false, edit_access: false, delete_access: true,
          view_all: true, modify_all: true
        )
      end

      # --- Basic muting of resource CRUD ---

      test 'muting set revokes delete_access granted by another set' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert_not perms[:delete_access], 'delete_access should be muted (revoked)'
      end

      test 'muting set revokes view_all granted by another set' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert_not perms[:view_all], 'view_all should be muted'
      end

      test 'muting set revokes modify_all granted by another set' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert_not perms[:modify_all], 'modify_all should be muted'
      end

      test 'muting set does NOT revoke permissions it does not define as true' do
        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert perms[:read_access], 'read_access should NOT be muted (muting resource has read_access: false)'
        assert perms[:create_access], 'create_access should NOT be muted'
        assert perms[:edit_access], 'edit_access should NOT be muted'
      end

      # --- Field-level muting ---

      test 'muting set revokes field read_access' do
        create_resource_field(
          resource: @muting_resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert_not fields['email'][:read_access], 'email read_access should be muted'
      end

      test 'muting set revokes field edit_access' do
        create_resource_field(
          resource: @muting_resource, name: 'name', label: 'Name',
          read_access: false, edit_access: true
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert_not fields['name'][:edit_access], 'name edit_access should be muted'
      end

      test 'muting set does NOT revoke field access it does not define as true' do
        create_resource_field(
          resource: @muting_resource, name: 'name', label: 'Name',
          read_access: false, edit_access: false
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['name'][:read_access], 'name read_access should NOT be muted'
        assert fields['name'][:edit_access], 'name edit_access should NOT be muted'
      end

      test 'muting set forces mask_access to true on a field' do
        create_resource_field(
          resource: @muting_resource, name: 'email', label: 'Email',
          read_access: false, edit_access: false, mask_access: true, mask_strategy: 'email'
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['email'][:mask_access], 'email mask_access should be forced to true by muting set'
      end

      test 'muting set does not affect fields it does not define' do
        # Muting set has no 'name' field defined
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['name'][:read_access], 'name read_access should be unaffected'
        assert fields['name'][:edit_access], 'name edit_access should be unaffected'
      end

      # --- Muting the resource's read or edit reaches every field ---

      test 'muting the resource read revokes read and edit on every field of the resource' do
        create_resource_field(resource: @granting_resource, name: 'owner_id', label: 'Owner', read_access: true, edit_access: true)
        @muting_resource.update!(read_access: true)

        fields = build_hash.dig(:resources, 'Customer', :fields)
        # owner_id is no Customer column, and owner_uuid no Customer name: no variant entry (FieldVariants)
        assert_equal %w[contact_count email full_address name owner_id], fields.keys.sort
        fields.each do |name, entry|
          assert_equal [false, false], entry.values_at(:read_access, :edit_access), name
        end
        assert_equal false, build_hash.dig(:resources, 'Customer', :permissions, :read_access)
      end

      test 'muting the resource edit mutes the flag only: the field rows are left alone' do
        @muting_resource.update!(edit_access: true)

        assert_equal false, build_hash.dig(:resources, 'Customer', :permissions, :edit_access)
        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert_equal [true, true], fields['name'].values_at(:read_access, :edit_access)
        assert_equal [true, true], fields['email'].values_at(:read_access, :edit_access)
        assert_equal [true, true], fields['full_address'].values_at(:read_access, :edit_access)
      end

      test 'a switched-off muting resource mutes no field' do
        @muting_resource.update!(read_access: true, is_active: false)

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['name'][:read_access]
        assert fields['name'][:edit_access]
      end

      # --- Field variant muting (regression: muting must cover _uuid/_cents variants) ---
      # PfVariantOrder has owner_uuid and price, so the variants are entries.

      def variant_resources
        granting = create_resource(permission_set: @granting_set, name: 'PfVariantOrder', read_access: true, edit_access: true)
        muting = create_resource(permission_set: @muting_set, name: 'PfVariantOrder', read_access: false)
        [granting, muting]
      end

      test 'muting a _id field also revokes read on its _uuid variant' do
        granting, muting = variant_resources
        # Granting set exposes owner_id (and its owner_uuid variant).
        create_resource_field(resource: granting, name: 'owner_id', label: 'Owner', read_access: true, edit_access: true)
        # Muting set revokes read on owner_id.
        create_resource_field(resource: muting, name: 'owner_id', label: 'Owner', read_access: true, edit_access: false)

        fields = build_hash.dig(:resources, 'PfVariantOrder', :fields)
        assert_not fields['owner_id'][:read_access], 'owner_id read_access should be muted'
        assert_not fields['owner_uuid'][:read_access], 'owner_uuid variant read_access must also be muted'
      end

      test 'muting a _cents field also forces mask on its base-name variant' do
        granting, muting = variant_resources
        create_resource_field(resource: granting, name: 'price_cents', label: 'Price',
                              read_access: true, edit_access: true, mask_access: false)
        create_resource_field(resource: muting, name: 'price_cents', label: 'Price',
                              read_access: false, edit_access: false, mask_access: true, mask_strategy: 'full')

        fields = build_hash.dig(:resources, 'PfVariantOrder', :fields)
        assert fields['price_cents'][:mask_access], 'price_cents mask_access forced true'
        assert fields['price'][:mask_access], 'price base-name variant mask_access must also be forced true'
      end

      # --- Action-level muting ---

      test 'muting set revokes action is_permitted' do
        create_resource_action(
          resource: @muting_resource, name: 'export', is_permitted: true
        )

        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert_not actions[:export][:is_permitted], 'export should be muted'
      end

      test 'muting set does NOT revoke action with is_permitted false in muting set' do
        create_resource_action(
          resource: @muting_resource, name: 'sync', is_permitted: false
        )

        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert actions[:sync][:is_permitted], 'sync should NOT be muted (muting action has is_permitted: false)'
      end

      test 'muting set does not affect actions it does not define' do
        # Muting set has no actions defined
        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert actions[:export][:is_permitted], 'export should be unaffected when muting set has no actions'
        assert actions[:sync][:is_permitted], 'sync should be unaffected'
      end

      # --- source_permission_sets includes muting sets ---

      test 'source_permission_sets includes both granting and muting sets' do
        sources = build_hash.dig(:resources, 'Customer', :source_permission_sets)
        assert_equal 2, sources.size
        uuids = sources.map { |s| s[:uuid] }
        assert_includes uuids, @granting_set.uuid
        assert_includes uuids, @muting_set.uuid
      end

      test 'source_permission_sets identifies muting sets with is_muting flag' do
        sources = build_hash.dig(:resources, 'Customer', :source_permission_sets)
        granting_source = sources.find { |s| s[:uuid] == @granting_set.uuid }
        muting_source = sources.find { |s| s[:uuid] == @muting_set.uuid }

        assert_not granting_source[:is_muting], 'granting source should not be flagged as muting'
        assert muting_source[:is_muting], 'muting source should be flagged as muting'
      end

      # --- Edge case: muting set for a resource not in any granting set ---

      test 'muting set for unknown resource is ignored (no crash)' do
        create_resource(
          permission_set: @muting_set, name: 'Supplier',
          read_access: true, create_access: true
        )

        result = build_hash
        assert_not result[:resources].key?('Supplier'), 'Supplier should NOT appear (muting-only resource)'
      end

      # --- Edge case: only muting sets, no granting sets ---

      test 'only muting sets produce empty permissions hash' do
        # Remove user from granting set
        PermissionForge::PermissionSetUser.where(
          permission_set: @granting_set, user: @user
        ).destroy_all

        result = build_hash_with([@muting_set])
        assert_equal({}, result[:resources], 'no resources when only muting sets')
      end

      # --- Edge case: multiple muting sets stacking ---

      test 'multiple muting sets stack their revocations' do
        extra_muting_set = create_permission_set(name: 'Extra Restriction', is_muting: true)
        create_permission_set_user(user: @user, permission_set: extra_muting_set)
        create_resource(
          permission_set: extra_muting_set, name: 'Customer',
          read_access: true, create_access: true, edit_access: false, delete_access: false
        )

        perms = build_hash_with([@granting_set, @muting_set, extra_muting_set]).dig(:resources, 'Customer', :permissions)
        # @muting_set revokes delete, view_all, modify_all
        # extra_muting_set revokes read, create
        assert_not perms[:read_access], 'read_access muted by second muting set'
        assert_not perms[:create_access], 'create_access muted by second muting set'
        assert_not perms[:delete_access], 'delete_access muted by first muting set'
        assert perms[:edit_access], 'edit_access should survive (neither muting set targets it)'
      end

      # --- Edge case: muting set is inactive ---

      test 'inactive muting set does not revoke permissions' do
        @muting_set.update!(is_active: false)
        # Only pass active sets (as regenerate_permissions would)
        active_sets = [@granting_set]

        perms = build_hash_with(active_sets).dig(:resources, 'Customer', :permissions)
        assert perms[:delete_access], 'delete_access should NOT be muted (muting set is inactive)'
        assert perms[:view_all], 'view_all should NOT be muted'
      end

      # --- Edge case: muting set resource is inactive ---

      test 'inactive resource in muting set does not revoke permissions' do
        @muting_resource.update!(is_active: false)

        perms = build_hash.dig(:resources, 'Customer', :permissions)
        assert perms[:delete_access], 'delete_access should NOT be muted (muting resource is inactive)'
      end

      # --- Edge case: granting set and muting set with disjoint resources ---

      test 'muting set only affects resources it defines' do
        # Create a granting resource for Supplier (not in muting set)
        create_resource(
          permission_set: @granting_set, name: 'Supplier',
          read_access: true, create_access: true
        )

        result = build_hash
        supplier_perms = result.dig(:resources, 'Supplier', :permissions)
        assert supplier_perms[:read_access], 'Supplier read_access should be unaffected by muting set'
        assert supplier_perms[:create_access], 'Supplier create_access should be unaffected'
      end

      # --- Edge case: muting set with inactive field ---

      test 'inactive field in muting set does not revoke access' do
        create_resource_field(
          resource: @muting_resource, name: 'email', label: 'Email',
          read_access: true, edit_access: true, is_active: false
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['email'][:read_access], 'email read_access should NOT be muted (muting field is inactive)'
        assert fields['email'][:edit_access], 'email edit_access should NOT be muted'
      end

      # --- Edge case: muting set with inactive action ---

      test 'inactive action in muting set does not revoke permission' do
        create_resource_action(
          resource: @muting_resource, name: 'export', is_permitted: true, is_active: false
        )

        actions = build_hash.dig(:resources, 'Customer', :actions)
        assert actions[:export][:is_permitted], 'export should NOT be muted (muting action is inactive)'
      end

      # --- Integration: multiple granting sets + muting set ---

      test 'muting set applies after multi-set merge (most-permissive then subtract)' do
        extra_granting_set = create_permission_set(name: 'Extra Access')
        create_permission_set_user(user: @user, permission_set: extra_granting_set)
        create_resource(
          permission_set: extra_granting_set, name: 'Customer',
          read_access: true, create_access: false, edit_access: true, delete_access: true
        )

        # Granting merge: read=true, create=true, edit=true, delete=true
        # Muting: revokes delete, view_all, modify_all
        perms = build_hash_with([@granting_set, extra_granting_set, @muting_set]).dig(:resources, 'Customer', :permissions)
        assert perms[:read_access], 'read_access merged then preserved'
        assert perms[:create_access], 'create_access merged then preserved'
        assert perms[:edit_access], 'edit_access merged then preserved'
        assert_not perms[:delete_access], 'delete_access merged then muted'
        assert_not perms[:view_all], 'view_all muted'
        assert_not perms[:modify_all], 'modify_all muted'
      end

      # --- Muting does NOT add rules ---

      test 'muting set rules are NOT accumulated (muting only subtracts, does not add constraints)' do
        create_permission_set_rule(
          permission_set: @granting_set, resource: @granting_resource,
          name: 'Granting Rule', field_name: 'supplier_id'
        )
        create_permission_set_rule(
          permission_set: @muting_set, resource: @muting_resource,
          name: 'Muting Rule', field_name: 'domain'
        )

        rules = build_hash.dig(:resources, 'Customer', :permission_set_rules)
        rule_names = rules.map { |r| r[:name] }
        assert_includes rule_names, 'Granting Rule'
        assert_not_includes rule_names, 'Muting Rule', 'muting set rules should not be accumulated'
      end

      # --- Ordering: granting processed first, then muting ---

      test 'muting always applied after granting regardless of input order' do
        # Pass muting set BEFORE granting set
        perms = build_hash_with([@muting_set, @granting_set]).dig(:resources, 'Customer', :permissions)
        assert_not perms[:delete_access], 'delete_access should be muted regardless of set order'
        assert perms[:read_access], 'read_access should be preserved regardless of set order'
      end

      # --- Field muting + masking combination ---

      test 'muting set can both revoke edit and force masking on same field' do
        create_resource_field(
          resource: @muting_resource, name: 'email', label: 'Email',
          read_access: false, edit_access: true, mask_access: true, mask_strategy: 'email'
        )

        fields = build_hash.dig(:resources, 'Customer', :fields)
        assert fields['email'][:read_access], 'email read_access preserved (muting read_access is false)'
        assert_not fields['email'][:edit_access], 'email edit_access muted'
        assert fields['email'][:mask_access], 'email mask_access forced to true'
      end

      private

      def build_hash
        build_hash_with([@granting_set, @muting_set])
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
