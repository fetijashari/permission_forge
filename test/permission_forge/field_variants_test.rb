require 'test_helper'
require_relative 'field_variant_models'

module PermissionForge
  # A field row's setting reaches its variants (`owner_id` → `owner_uuid`,
  # `price_cents` → `price`) only where the model has them. The default
  # mapping used to add an `owner_uuid` entry to a Customer that has no such
  # column, and the admin's Effective access listed a field "Owner uuid" and
  # counted it (field test a-onboarding #41, b-admin-ui #67).
  class FieldVariantsTest < ActiveSupport::TestCase
    setup do
      @user = create_user
      @set = create_permission_set(name: 'Orders')
      create_permission_set_user(user: @user, permission_set: @set)
      @orders = create_resource(permission_set: @set, name: 'PfVariantOrder', read_access: true, edit_access: true)
    end

    def build(user = @user)
      sets = PermissionForge::PermissionSet.active.where(id: user.permission_set_users.select(:permission_set_id))
                                           .order(:created_at, :id).to_a
      Services::PermissionHashBuilder.call(user: user, permission_sets: sets)[:resources]
    end

    test 'a variant counts when the model has it as a column, reader, alias, writer or declared virtual field' do
      variants = FieldVariants.new('PfVariantOrder')

      assert_equal %w[owner_uuid], variants.call('owner_id'), 'column'
      assert_equal %w[price], variants.call('price_cents'), 'reader'
      assert_equal %w[account_uuid], variants.call('account_id'), 'alias_attribute'
      assert_equal %w[team_uuid], variants.call(:team_id), 'writer only'
      assert_equal %w[region_uuid], variants.call('region_id'), 'declared virtual field'
      assert_equal [], variants.call('supplier_id'), 'no supplier_uuid on the model'
      assert_equal [], variants.call('title'), 'no mapping'
    end

    test 'the dummy Customer has no owner_uuid or supplier_uuid' do
      variants = FieldVariants.new('Customer')

      assert_equal [], variants.call('owner_id')
      assert_equal [], variants.call('supplier_id')
    end

    test 'a Resource whose model cannot be read keeps every variant, as before' do
      assert_equal %w[owner_uuid], FieldVariants.new('NotAModelInThisApp').call('owner_id'), 'no such constant'
      assert_equal %w[owner_uuid], FieldVariants.new('PermissionForge').call('owner_id'), 'not a model'

      replace_singleton_method(PfVariantOrder, :attribute_names) { raise ActiveRecord::ConnectionNotEstablished, 'gone' }
      assert_equal %w[supplier_uuid], FieldVariants.new('PfVariantOrder').call('supplier_id'), 'schema unreadable'
    ensure
      PfVariantOrder.singleton_class.send(:remove_method, :attribute_names) if PfVariantOrder.singleton_class.method_defined?(:attribute_names, false)
    end

    test 'the configured mappings decide which names are variants' do
      config = PermissionForge::Configuration.new
      config.field_variant_mappings = { /_ref\z/ => ->(name) { name.sub(/_ref\z/, '_uuid') } }

      assert_equal [], FieldVariants.new('PfVariantOrder', config).call('owner_id')
      assert_equal %w[account_uuid], FieldVariants.new('PfVariantOrder', config).call('account_ref')
    end

    test 'the permission hash has entries for the real variants only' do
      %w[owner_id price_cents supplier_id].each do |name|
        create_resource_field(resource: @orders, name: name, read_access: true, edit_access: true)
      end

      fields = build['PfVariantOrder'][:fields]

      assert_equal %w[owner_id owner_uuid price price_cents region_uuid supplier_id], fields.keys.sort
      assert_equal fields['owner_id'], fields['owner_uuid']
      assert_equal fields['price_cents'], fields['price']
    end

    test 'a muting set still mutes a real variant' do
      create_resource_field(resource: @orders, name: 'owner_id', read_access: true, edit_access: true)
      muting = create_permission_set(name: 'Mute owner', is_muting: true)
      muted = create_resource(permission_set: muting, name: 'PfVariantOrder', read_access: false)
      create_resource_field(resource: muted, name: 'owner_id', read_access: true, mask_access: true)
      create_permission_set_user(user: @user, permission_set: muting)

      fields = build['PfVariantOrder'][:fields]

      assert_equal [false, false, true], fields['owner_uuid'].values_at(:read_access, :edit_access, :mask_access)
      assert_equal fields['owner_id'], fields['owner_uuid']
    end

    # A serializer can still emit a name the model does not have
    # (`supplier_uuid` computed in a view): it follows the field it is a
    # variant of, as when the hash had an entry for it — even under a
    # strategy that passes unconfigured keys.
    test 'a response key that is a variant the model lacks follows its base field' do
      PermissionForge.configuration.unconfigured_field_strategy = :pass_through
      create_resource_field(resource: @orders, name: 'supplier_id', read_access: false)
      create_resource_field(resource: @orders, name: 'owner_id', read_access: true, mask_access: true, mask_strategy: 'last4')
      @user.regenerate_permissions

      result = Services::FiltersResponseAttributes.call(
        attributes: { 'supplier_id' => 7, 'supplier_uuid' => 'sup-1234', 'owner_id' => 12_345, 'title' => 'x' },
        resource_name: 'PfVariantOrder', user: @user
      )

      assert_equal({ 'owner_id' => '*2345', 'title' => 'x' }, result)
      assert_nil @user.permissions_hash_for(:PfVariantOrder)[:fields][:supplier_uuid], 'no entry in the hash'
    end

    test 'Effective access lists and counts the model fields only, as the engine' do
      create_resource_field(resource: @orders, name: 'owner_id', read_access: true)
      create_resource_field(resource: @orders, name: 'supplier_id', read_access: true)

      outcome = Admin::EffectiveAccess.call(user: @user).find { |resource| resource.name == 'PfVariantOrder' }
      names = outcome.fields.reject(&:unconfigured).map(&:name)

      assert_includes names, 'owner_uuid'
      assert_not_includes names, 'supplier_uuid'
      assert_equal build['PfVariantOrder'][:fields].keys.sort, names.sort
    end
  end
end
