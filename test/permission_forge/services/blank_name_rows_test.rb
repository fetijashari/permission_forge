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
    end
  end
end
