require 'test_helper'
require_relative '../nested_attribute_models'

module PermissionForge
  module Services
    class PermitsAttributesTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true,
          edit_access: true
        )
        create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'email', label: 'Email', read_access: true, edit_access: false)
        create_resource_field(resource: @resource, name: 'domain', label: 'Domain', read_access: true, edit_access: true)

        @customer = create_customer
        @user.regenerate_permissions
        Current.user = @user
      end

      def permit(params, resource: @customer)
        PermissionForge::Services::PermitsAttributes.call(resource: resource, permitted_params: params)
      end

      # A Supplier resource where only :name is editable.
      def configure_supplier
        supplier_resource = create_resource(permission_set: @permission_set, name: 'Supplier', read_access: true, edit_access: true)
        create_resource_field(resource: supplier_resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: supplier_resource, name: 'uuid', read_access: true, edit_access: false)
        @user.regenerate_permissions
      end

      test 'filters out fields without edit access' do
        result = permit({ name: 'New Name', email: 'new@email.com', domain: 'new.com' })

        assert result.key?(:name)
        assert result.key?(:domain)
        assert_not result.key?(:email)
      end

      test 'returns empty hash when no user' do
        Current.user = nil

        assert_equal({}, permit({ name: 'New Name' }))
      end

      test 'returns empty hash when no resource' do
        assert_equal({}, permit({ name: 'test' }, resource: nil))
      end

      test 'returns empty hash when no params' do
        assert_equal({}, permit({}))
      end

      # --- report: true — what was dropped, for a "Not saved: …" message ---

      test 'report: true answers the same filtered hash plus the dropped paths' do
        params = { name: 'New Name', email: 'new@email.com', status: 'vip', domain: 'new.com' }
        result = PermitsAttributes.call(resource: @customer, permitted_params: params, report: true)

        assert_kind_of PermitsAttributes::Result, result
        assert_equal permit(params), result.params
        assert_equal %w[email status], result.dropped
        assert_predicate result, :dropped?
        assert_equal %w[email status], result.dropped_fields
      end

      test 'without report: the return value is the plain filtered hash, as before' do
        assert_equal({ name: 'x' }, permit({ name: 'x', email: 'e' }))
      end

      test 'report: true lists nothing when every key is kept' do
        result = PermitsAttributes.call(resource: @customer, permitted_params: { name: 'x' }, report: true)

        assert_equal [], result.dropped
        assert_not result.dropped?
      end

      test 'report: true names nested paths and their top-level key' do
        configure_supplier
        result = PermitsAttributes.call(resource: PfNestedCustomer, report: true,
                                        permitted_params: { email: 'e', supplier_attributes: { name: 'Acme', uuid: 'u' } })

        assert_equal({ supplier_attributes: { name: 'Acme' } }, result.params)
        assert_equal %w[email supplier_attributes.uuid], result.dropped
        assert_equal %w[email supplier_attributes], result.dropped_fields
      end

      test 'report: true with nobody signed in lists every key' do
        Current.user = nil
        result = PermitsAttributes.call(resource: @customer, permitted_params: { name: 'x', email: 'e' }, report: true)

        assert_equal({}, result.params)
        assert_equal %w[name email], result.dropped
      end

      test 'report: true with no model to filter for lists every key, with or without a user' do
        [@user, nil].each do |user|
          Current.user = user
          result = PermitsAttributes.call(resource: nil, permitted_params: { name: 'x', email: 'e' }, report: true)

          assert_equal({}, result.params)
          assert_equal %w[name email], result.dropped, "user: #{user.inspect}"
        end
        assert_equal({}, PermitsAttributes.call(resource: nil, permitted_params: { name: 'x' }))
        assert_equal [], PermitsAttributes.call(resource: nil, permitted_params: {}, report: true).dropped
      end

      test 'report: true collects the dropped keys even when nobody listens to params.filtered' do
        PermissionForge::Audit.send(:emitting) do # nothing is instrumented while emitting
          assert_not PermissionForge::Audit.instrument?(PermitsAttributes::EVENT)
          result = PermitsAttributes.call(resource: @customer, permitted_params: { name: 'x', email: 'e' }, report: true)

          assert_equal %w[email], result.dropped
        end
      end

      test 'removes array field when it matches a field permission without edit access' do
        create_resource_field(resource: @resource, name: 'tags', label: 'Tags', read_access: true, edit_access: false)
        @user.regenerate_permissions
        result = permit({ tags: %w[ruby rails], name: 'Test' })

        assert_not result.key?(:tags)
        assert result.key?(:name)
      end

      test 'does not mutate the caller params' do
        params = { name: 'New Name', email: 'new@email.com' }
        frozen_copy = params.dup
        permit(params)

        assert_equal frozen_copy, params, 'input params must be unchanged'
      end

      # --- the shape of a value never opens a key (pre-release review core-security #4) ---

      # A Hash or an Array of Hashes under a non-editable key used to be
      # taken for a nested payload and filtered against the parent's fields,
      # so `email: { name: 'x' }` kept the payload because `name` is editable.
      test 'a key the user cannot edit is dropped whatever the shape of its value' do
        params = ActionController::Parameters.new(
          name: 'ok', email: { name: 'attacker@x' }, uuid: [{ name: 'a' }, 'evil.com'], contacts: [{ name: 'x' }],
          supplier: { name: 'x' }
        ).permit!

        assert_equal({ 'name' => 'ok' }, permit(params))
      end

      test 'an editable key keeps a Hash or Array value as it is' do
        assert_equal({ domain: { 'tld' => 'com' }, name: ['a', { b: 1 }] }, permit({ domain: { 'tld' => 'com' }, name: ['a', { b: 1 }] }))
      end

      # --- nested attributes --------------------------------------------------------------

      test 'a *_attributes key is a nested payload only for an association that accepts nested attributes' do
        configure_supplier
        payload = { supplier_attributes: { name: 'Acme', uuid: 'u' } }

        assert_equal({}, permit(payload), 'Customer accepts no nested attributes: the key is a field the user cannot edit')
        assert_equal({ supplier_attributes: { name: 'Acme' } }, permit(payload, resource: PfNestedCustomer))
      end

      test 'nested *_attributes are filtered against the child resource, not the parent' do
        configure_supplier
        result = permit({ supplier_attributes: { name: 'Acme', uuid: 'should-be-dropped', domain: 'editable-on-customer' } },
                        resource: PfNestedCustomer.find(@customer.id))

        assert_equal({ supplier_attributes: { name: 'Acme' } }, result)
      end

      test 'a nested record keeps its id' do
        configure_supplier

        assert_equal({ supplier_attributes: { id: 5, name: 'Acme' } },
                     permit({ supplier_attributes: { id: 5, name: 'Acme', _destroy: '1' } }, resource: PfNestedCustomer))
      end

      # The payload used to be filtered against the parent's fields when the
      # child was not configured: `name` is editable on Customer, so a user
      # with no Supplier grant could write a Supplier's name.
      test 'a nested payload for a model the user has no entry for is dropped; the parent fallback is opt-in' do
        params = ActionController::Parameters.new(name: 'x', email: 'e', supplier_attributes: { name: 'pwned', id: 5 }).permit!

        assert_equal({ 'name' => 'x' }, permit(params, resource: PfNestedCustomer))

        PermissionForge.configuration.nested_attributes_parent_fallback = true
        assert_equal({ 'name' => 'x', 'supplier_attributes' => { 'name' => 'pwned', 'id' => 5 } }, permit(params, resource: PfNestedCustomer))
      end

      test 'collection payloads are filtered per record: an Array, the index Hash, a record Hash with an id' do
        supplier = create_supplier
        each = { name: 'A', email: 'bad@x.com', domain: 'ok.com' }

        assert_equal({ customers_attributes: [{ name: 'A', domain: 'ok.com' }] },
                     permit({ customers_attributes: [each, 'evil', 7, [each]] }, resource: PfNestedSupplier))
        assert_equal({ customers_attributes: { '0' => { name: 'A', domain: 'ok.com' } } },
                     permit({ customers_attributes: { '0' => each, '1' => 'junk' } }, resource: PfNestedSupplier.find(supplier.id)))
        assert_equal({ customers_attributes: { id: @customer.id, name: 'A' } },
                     permit({ customers_attributes: { id: @customer.id, name: 'A', email: 'b' } }, resource: PfNestedSupplier),
                     'a record Hash with an id: the id of a row the user may reach (security/nested_record_rules_test)')
      end

      test 'a has_one or belongs_to payload that is not one record is dropped' do
        configure_supplier

        assert_equal({}, permit({ supplier_attributes: 'junk' }, resource: PfNestedCustomer))
        assert_equal({}, permit({ supplier_attributes: [{ name: 'x' }] }, resource: PfNestedCustomer))
        assert_equal({}, permit({ contacts_attributes: 'junk' }, resource: PfNestedCustomer))
      end

      test 'nested index-hash form is filtered per record against the child' do
        configure_supplier
        params = { contacts_attributes: { '0' => { name: 'A', uuid: 'bad' }, '1' => { name: 'B', domain: 'not-a-supplier-field' } } }

        assert_equal({ contacts_attributes: { '0' => { name: 'A' }, '1' => { name: 'B' } } }, permit(params, resource: PfNestedCustomer))
      end
    end
  end
end
