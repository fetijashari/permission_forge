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

      # P5/P5b: an owner_uuid row (Hidden) next to an owner_id row (Editable)
      # on one resource used to be OR-ed with the derived variant, so the
      # admin's Hidden read as Editable, in either row order.
      test 'an explicit row for a variant name wins over the derived variant within a resource, in either order' do
        [%w[owner_uuid owner_id], %w[owner_id owner_uuid]].each do |order|
          orders = create_resource(permission_set: create_permission_set, name: 'PfVariantOrder', read_access: true)
          rows = { 'owner_uuid' => { read_access: false, edit_access: false },
                   'owner_id' => { read_access: true, edit_access: true } }
          order.each { |name| create_resource_field(resource: orders, name: name, **rows[name]) }

          fields = merge(orders)

          assert_equal({ read_access: false, edit_access: false, mask_access: false, mask_strategy: 'full' },
                       fields['owner_uuid'], order.inspect)
          assert_equal({ read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }, fields['owner_id'])
        end
      end

      test 'the explicit row decides the mask of a variant name too, whichever row is older' do
        orders = create_resource(permission_set: @set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: orders, name: 'owner_id', read_access: true, mask_access: true, mask_strategy: 'last4')
        create_resource_field(resource: orders, name: 'owner_uuid', read_access: true, mask_access: true, mask_strategy: 'email')

        assert_equal 'email', merge(orders)['owner_uuid'][:mask_strategy]
      end

      test 'a derived variant still merges across resources where no resource of its own names it' do
        first = create_resource(permission_set: create_permission_set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: first, name: 'owner_uuid', read_access: false)
        second = create_resource(permission_set: create_permission_set, name: 'PfVariantOrder', read_access: true)
        create_resource_field(resource: second, name: 'owner_id', read_access: true)

        fields = merge(first)
        merge(second, fields: fields)

        assert_equal true, fields['owner_uuid'][:read_access], 'the second set grants owner_uuid through owner_id (granting sets add)'
      end

      test 'targets_of lists own names first, then the variants no row of the resource names' do
        orders = create_resource(permission_set: @set, name: 'PfVariantOrder', read_access: true)
        uuid_row = create_resource_field(resource: orders, name: 'owner_uuid', read_access: false)
        id_row = create_resource_field(resource: orders, name: 'owner_id', read_access: true)
        price_row = create_resource_field(resource: orders, name: 'price_cents', read_access: true)

        targets = FieldPermissionMerger.targets_of([uuid_row, id_row, price_row], FieldVariants.new('PfVariantOrder'))

        assert_equal [['owner_uuid', uuid_row, nil], ['owner_id', id_row, nil], ['price_cents', price_row, nil],
                      ['price', price_row, 'price_cents']], targets
      end

      # D.4: a row with edit but no read (written past ValidatesDependency)
      # used to grant edit, so PermitsAttributes kept a key the user may not read.
      test 'merge_row counts edit only with read' do
        entry = {}
        past_validation = row(read_access: true, edit_access: true)
        past_validation.update_columns(read_access: false)
        FieldPermissionMerger.merge_row(entry, past_validation.reload)

        assert_equal({ read_access: false, edit_access: false, mask_access: false, mask_strategy: 'full' }, entry)

        FieldPermissionMerger.merge_row(entry, row(read_access: true, edit_access: true))
        assert_equal [true, true], entry.values_at(:read_access, :edit_access)
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
