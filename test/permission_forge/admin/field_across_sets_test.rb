require 'test_helper'

module PermissionForge
  module Admin
    class FieldAcrossSetsTest < ActiveSupport::TestCase
      setup do
        @sales = create_permission_set(name: 'Sales rep')
        @managers = create_permission_set(name: 'Managers')
        @contractors = create_permission_set(name: 'Contractors', is_muting: true)
        @resources = [@sales, @managers, @contractors].to_h { |set| [set.name, create_resource(permission_set: set)] }
      end

      def rows(key = 'email')
        FieldAcrossSets.call('Customer', key)
      end

      def in_effect
        rows.to_h { |row| [row[:set].name, row[:in_effect]] }
      end

      test 'rows come granting sets first, then by name, with the field row and the people count' do
        email = create_resource_field(resource: @resources['Managers'], name: 'email')
        create_permission_set_user(user: create_user, permission_set: @managers)
        create_resource(permission_set: create_permission_set(name: 'Elsewhere'), name: 'Supplier')

        assert_equal(['Managers', 'Sales rep', 'Contractors'], rows.map { |row| row[:set].name })
        assert_equal([email, nil, nil], rows.map { |row| row[:field] })
        assert_equal([1, 0, 0], rows.map { |row| row[:people] })
        assert_equal @resources['Managers'], rows.first[:resource]
        assert_equal %i[field in_effect people resource set], rows.first.keys.sort
      end

      # Like ActionAcrossSets#rows: the row (or, without a row, the resource).
      test 'rows say whether the field counts in each set right now' do
        create_resource_field(resource: @resources['Managers'], name: 'email', is_active: false)
        create_resource_field(resource: @resources['Contractors'], name: 'email')

        assert_equal({ 'Managers' => false, 'Sales rep' => true, 'Contractors' => true }, in_effect)

        @resources['Sales rep'].update!(is_active: false)
        @contractors.update!(is_active: false)

        assert_equal({ 'Managers' => false, 'Sales rep' => false, 'Contractors' => false }, in_effect)
      end

      test 'a switched-off row of another field does not switch this one off' do
        create_resource_field(resource: @resources['Managers'], name: 'domain', is_active: false)
        create_resource_field(resource: @resources['Managers'], name: 'email')

        assert_equal({ 'Managers' => true, 'Sales rep' => true, 'Contractors' => true }, in_effect)
      end
    end
  end
end
