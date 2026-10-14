require 'test_helper'

module PermissionForge
  module Concerns
    # Covers the diagnostic surface of MaskedAttributes (.explain / .explain_all
    # and their private helpers) plus the virtual-attribute serialization path —
    # edges not exercised by masked_attributes_test.rb / _write_back_test.rb.
    class MaskedAttributesEdgesTest < ActiveSupport::TestCase
      # Subclass Customer (same pattern as MaskedAttributesTest) so the concern
      # is guaranteed to be applied regardless of file run order, and so we can
      # define a virtual (non-column) attribute for the serialization fallback.
      class EdgeCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        # The concern resolves the resource name via self.class.name.to_sym.
        def self.name
          'Customer'
        end

        # Virtual attribute — not a column, so read_attribute_for_serialization
        # must fall back to the default (method dispatch) path.
        def display_label
          "label:#{read_attribute(:name)}"
        end
      end

      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
        create_resource_field(
          resource: @resource, name: 'name', label: 'Name',
          read_access: true, edit_access: true
        )
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: @resource, name: 'domain', label: 'Domain',
          read_access: false
        )
        @user.regenerate_permissions
        Current.user = @user

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through

        @customer = EdgeCustomer.create!(
          uuid: SecureRandom.uuid,
          name: 'Acme Corp',
          email: 'contact@acme.com',
          domain: 'acme.com'
        )
      end

      # --- .explain ---------------------------------------------------------

      # A subclass is masked through its parent; its own include is then a
      # no-op, and explain must still say the concern applies (it read the
      # subclass's own flag, so the answer depended on load order).
      test 'explain reports the concern applied for a subclass masked through its parent' do
        parent = Class.new(EdgeCustomer)
        child = Class.new(parent)

        assert PermissionForge::Concerns::MaskedAttributes.explain(child.new, :email)[:masked_attributes_applied]
        assert PermissionForge::Concerns::MaskedAttributes.applied_in_chain?(child)
      end

      test 'explain reports full diagnostics for a masked field' do
        result = PermissionForge::Concerns::MaskedAttributes.explain(@customer, :email)

        assert_equal :email, result[:attribute]
        assert_equal 'Customer', result[:class]
        assert result[:masked_attributes_applied]
        refute result[:is_primary_key]
        assert result[:current_user_present]
        assert result[:user_responds_to_field_permissions]
        assert result[:resource_in_permissions_hash]
        assert result[:field_configured]
        assert result[:field_entry][:mask_access]
        assert_equal 'email', result[:field_entry][:mask_strategy]
        assert_equal :pass_through, result[:unconfigured_field_strategy]
        assert result[:omit_hidden_in_attributes_hash]
        assert_equal 'contact@acme.com', result[:raw_value]
        assert_equal 'c***@acme.com', result[:returned_value]
      end

      test 'explain reports a hidden field as configured but returning the hidden sentinel' do
        result = PermissionForge::Concerns::MaskedAttributes.explain(@customer, :domain)

        assert result[:field_configured]
        refute result[:field_entry][:read_access]
        assert_equal 'acme.com', result[:raw_value]
        assert_nil result[:returned_value]
      end

      test 'explain reports an unconfigured field with no field entry' do
        result = PermissionForge::Concerns::MaskedAttributes.explain(@customer, :uuid)

        refute result[:field_configured]
        assert_nil result[:field_entry]
        assert_equal @customer.read_attribute_before_type_cast(:uuid), result[:returned_value]
      end

      test 'explain reflects the primary key bypass' do
        result = PermissionForge::Concerns::MaskedAttributes.explain(@customer, :id)

        assert result[:is_primary_key]
        assert_equal 'id', result[:primary_key]
        assert_equal @customer.id, result[:returned_value]
      end

      test 'explain reports the nil-user bypass' do
        Current.user = nil
        result = PermissionForge::Concerns::MaskedAttributes.explain(@customer, :domain)

        refute result[:current_user_present]
        refute result[:user_responds_to_field_permissions]
        refute result[:resource_in_permissions_hash]
        refute result[:field_configured]
        assert_equal 'acme.com', result[:raw_value]
        assert_equal 'acme.com', result[:returned_value], 'nil user must bypass masking entirely'
      end

      # --- .explain_all -----------------------------------------------------

      test 'explain_all returns a decision row for every column and prints a table' do
        rows = nil
        out, = capture_io do
          rows = PermissionForge::Concerns::MaskedAttributes.explain_all(@customer)
        end

        virtual_rows, column_rows = rows.partition { |row| row[:virtual] }
        assert_equal(::Customer.column_names, column_rows.map { |row| row[:attribute] })
        assert_equal(%w[full_address contact_count], virtual_rows.map { |row| row[:attribute] })

        by_attr = rows.index_by { |row| row[:attribute] }
        assert_equal :primary_key_skipped, by_attr['id'][:decision]
        assert_equal :passed_raw, by_attr['name'][:decision]
        assert_equal :masked, by_attr['email'][:decision]
        assert_equal :hidden_no_read_access, by_attr['domain'][:decision]
        assert_equal :unconfigured, by_attr['supplier_id'][:decision]

        assert by_attr['email'][:configured]
        assert by_attr['email'][:read_access]
        assert by_attr['email'][:mask_access]
        assert_equal 'email', by_attr['email'][:mask_strategy]
        refute by_attr['supplier_id'][:configured]
        assert_equal 'Acme Corp', by_attr['name'][:returned]
        assert_equal 'c***@acme.com', by_attr['email'][:returned]
        assert_nil by_attr['domain'][:returned]

        assert_match(/decision=masked/, out)
        assert_match(/decision=hidden_no_read_access/, out)
        assert_match(/email/, out)
      end

      test 'explain_all reports no_user_bypassed for every non-primary-key column when user is nil' do
        Current.user = nil
        rows = nil
        capture_io do
          rows = PermissionForge::Concerns::MaskedAttributes.explain_all(@customer)
        end

        pk_rows, other_rows = rows.reject { |row| row[:virtual] }.partition { |row| row[:attribute] == 'id' }
        pk_decisions = pk_rows.map { |row| row[:decision] }
        assert_equal [:primary_key_skipped], pk_decisions
        assert other_rows.any?
        assert(other_rows.all? { |row| row[:decision] == :no_user_bypassed })
      end

      test 'explain_all lists virtual readers and says when model-level masking is off for them' do
        rows = nil
        out, = capture_io do
          rows = PermissionForge::Concerns::MaskedAttributes.explain_all(@customer)
        end
        row = rows.find { |candidate| candidate[:attribute] == 'full_address' }

        assert row[:virtual]
        assert_equal :virtual_masking_off, row[:decision]
        assert_equal 'Acme Corp, acme.com', row[:raw]
        assert_equal 'Acme Corp, acme.com', row[:returned]
        assert_match(/full_address\s+decision=virtual_masking_off/, out)
      end

      # --- read_attribute_for_serialization ---------------------------------

      test 'read_attribute_for_serialization falls back to method dispatch for virtual attributes' do
        assert_equal 'label:Acme Corp', @customer.read_attribute_for_serialization('display_label')
      end

      test 'read_attribute_for_serialization still masks real columns' do
        assert_equal 'c***@acme.com', @customer.read_attribute_for_serialization('email')
        assert_nil @customer.read_attribute_for_serialization('domain')
      end

      test 'as_json with a virtual method serializes it through the fallback path' do
        json = @customer.as_json(methods: [:display_label])
        assert_equal 'label:Acme Corp', json['display_label']
        refute json.key?('domain')
      end
    end
  end
end
