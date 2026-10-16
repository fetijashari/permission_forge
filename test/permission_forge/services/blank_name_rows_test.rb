# frozen_string_literal: true

require 'test_helper'

# Declares blank virtual field names next to a valid one (customers table).
class PfBlankVirtualNames < ApplicationRecord
  self.table_name = 'customers'

  def self.extra_fields_for_permissions
    ['', nil, '  ', 'virtual_ok']
  end
end

module PermissionForge
  module Services
    # Names must not be blank (sets, groups, fields, actions). A host whose
    # extra_fields_for_permissions lists a blank name must still be able to
    # add the resource and sync fields, and rows with a blank name that
    # predate the validation stay editable in their other attributes.
    class BlankNameRowsTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      test 'the field generator skips blank virtual field names, with a log line' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        resource = create_resource(permission_set: @set, name: 'PfBlankVirtualNames')
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)

        fields = ResourceFieldGenerator.call(resource: resource)

        assert_includes fields.map(&:name), 'virtual_ok'
        assert(fields.map(&:name).none?(&:blank?))
        assert_match(/blank field name.*PfBlankVirtualNames/, log.string)
      ensure
        Rails.logger = original
      end

      test 'rows with a blank name that predate the validation can still be toggled' do
        action = create_resource_action(resource: @resource, name: 'export')
        field = create_resource_field(resource: @resource, name: 'email')
        action.update_columns(name: '')
        field.update_columns(name: '')
        @set.update_columns(name: '')

        assert action.reload.update(is_permitted: true), action.errors.full_messages.to_sentence
        assert field.reload.update(read_access: false), field.errors.full_messages.to_sentence
        assert @set.reload.update(is_active: false), @set.errors.full_messages.to_sentence
      end

      test 'a new row or a rename to a blank name is refused' do
        action = create_resource_action(resource: @resource, name: 'export')

        assert_not action.update(name: ' ')
        assert_includes action.errors[:name], I18n.t('permission_forge.validations.name_blank')
        assert_not PermissionForge::ResourceField.new(resource: @resource, name: '').valid?
        assert_not PermissionForge::PermissionSetGroup.new(name: '').valid?
      end

      # The admin's presets / Sync (ColumnFields) and the Fields tab's bulk
      # add (ChangeSet) take the model's field names from the catalog, blank
      # ones included: a blank name is no row, never a 500.
      test 'the admin paths skip a blank virtual field name like the generator does' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        set = create_permission_set
        resource = create_resource(permission_set: set, name: 'PfBlankVirtualNames')
        names = ['', ' ', 'virtual_ok', 'domain']

        created = PermissionForge::Admin::ColumnFields.new(resource, muting: false).create(names, 'read')
        assert_equal 2, created

        other = create_resource(permission_set: create_permission_set, name: 'PfBlankVirtualNames')
        PermissionForge::Admin::ChangeSet.new(permission_set: other.permission_set,
                                             params: { bulk: { resource_id: other.id.to_s, keys: names, level: 'read' } }).apply!

        assert_equal %w[domain virtual_ok], other.resource_fields.reload.map(&:name).sort
      end

      # A copy cannot recreate a row the validations refuse: the clone leaves
      # the blank-named rows out, copies the rest, and says so.
      test 'cloning a set with blank-named field and action rows skips those rows and copies the rest' do
        field = create_resource_field(resource: @resource, name: 'email')
        create_resource_field(resource: @resource, name: 'domain')
        action = create_resource_action(resource: @resource, name: 'export')
        create_resource_action(resource: @resource, name: 'sync')
        field.update_columns(name: '')
        action.update_columns(name: '')
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)

        copy = PermissionSetCloner.call(permission_set: @set, attrs: { name: 'Copy' })
        copied = copy.resources.find_by!(name: 'Customer')

        assert_equal %w[domain], copied.resource_fields.map(&:name)
        assert_equal %w[sync], copied.resource_actions.map(&:name)
        assert_match(/skipped 2 row\(s\) with a blank name/, log.string)
      ensure
        Rails.logger = original
      end
    end
  end
end
