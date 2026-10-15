require 'test_helper'
require_relative '../field_variant_models'

module PermissionForge
  module Services
    # The merger merges ResourceField rows, and nothing else. The implicit
    # entries of extra (virtual) fields are ExtraFieldDefaults' job
    # (extra_field_defaults_test.rb).
    class FieldPermissionMergerTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'name', read_access: true)
      end

      def merge(resource = @resource, fields: {}, **)
        FieldPermissionMerger.call(fields: fields, resource: resource, **)
      end

      # An `email` row on a Customer resource of its own set.
      def row(**attrs)
        resource = create_resource(permission_set: create_permission_set, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'email', label: 'Email', **attrs)
      end

      # The `email` entry after merging the rows' resources in the given order.
      def merged(rows)
        rows.each_with_object({}) { |field, fields| merge(field.resource, fields: fields) }['email']
      end

      test 'merges the rows of the resource and adds no entry for extra fields the model declares' do
        assert_equal %w[full_address contact_count], ::Customer.extra_fields_for_permissions

        assert_equal({ 'name' => { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' } }, merge)
      end

      test 'skips a switched-off row' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, is_active: false)

        assert_equal %w[name], merge.keys
      end

      test 'merges into the hash it is given: read and edit are OR-ed, the mask is AND-ed, the first strategy stays' do
        create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        other = create_resource(permission_set: create_permission_set, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: other, name: 'email', read_access: true, edit_access: true, mask_strategy: 'last4')
        fields = merge

        assert_same fields, merge(other, fields: fields)
        assert_equal({ read_access: true, edit_access: true, mask_access: false, mask_strategy: 'email' }, fields['email'])
      end

      # A row that grants no read (the admin UI's Hidden: read=f, mask=f) used
      # to take part in the mask AND, so Masked in one set plus Hidden in
      # another read as plaintext — in either order.
      test 'a row that grants no read never votes on the mask or the strategy, in any order' do
        masked = row(read_access: true, mask_access: true, mask_strategy: 'email')
        hidden = row(read_access: false, mask_access: false)
        other = row(read_access: true, mask_access: true, mask_strategy: 'last4')
        open = row(read_access: true, mask_access: false)

        [masked, hidden].permutation.each do |rows|
          assert_equal({ read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' },
                       merged(rows), rows.map(&:resource_id).inspect)
        end
        [masked, other, hidden].permutation.each do |rows|
          entry = merged(rows)
          first_masked = rows.find(&:mask_access)

          assert_equal [true, true, first_masked.mask_strategy],
                       entry.values_at(:read_access, :mask_access, :mask_strategy), rows.map(&:resource_id).inspect
        end
        [open, hidden].permutation.each do |rows|
          assert_equal({ read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
                       merged(rows), rows.map(&:resource_id).inspect)
        end
      end

      test 'an entry only hidden rows configured keeps the hash shape and stays hidden' do
        hidden = row(read_access: false, mask_access: false, mask_strategy: 'last4')

        assert_equal({ read_access: false, edit_access: false, mask_access: false, mask_strategy: 'full' }, merged([hidden]))
      end

      test 'merge_row is the one definition of merging a row into an entry' do
        entry = {}
        masked = row(read_access: true, mask_access: true, mask_strategy: 'email')

        assert_same entry, FieldPermissionMerger.merge_row(entry, masked)
        assert_equal({ read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }, entry)
      end

      test 'writes the variants the given configuration maps a field to, when the model has them' do
        orders = create_resource(permission_set: @set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', read_access: true)
        create_resource_field(resource: orders, name: 'supplier_id', read_access: true)
        plain = PermissionForge::Configuration.new
        plain.field_variant_mappings = {}

        assert_equal %w[owner_id owner_uuid supplier_id], merge(orders).keys.sort, 'PfVariantOrder has no supplier_uuid'
        assert_equal %w[owner_id supplier_id], merge(orders, configuration: plain).keys.sort
      end
    end
  end
end
