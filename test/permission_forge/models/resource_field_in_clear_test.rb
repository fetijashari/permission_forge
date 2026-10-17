# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # "Readable in the clear" has one definition: ResourceField#exposes_in_clear?
  # (a loaded row) and ResourceField.exposing_in_clear (its SQL twin) — the
  # GDPR audit, the security audit, Home's privacy card and the boot warning
  # all ask it. Every flag combination, the ones the validations refuse
  # included (written past the model), gives the same answer both ways.
  class ResourceFieldInClearTest < ActiveSupport::TestCase
    setup do
      @resource = create_resource(permission_set: create_permission_set, name: 'Customer')
    end

    test 'the predicate and the scope agree on every combination of active, read and mask' do
      [true, false].product([true, false], [true, false]).each do |active, read, mask|
        field = create_resource_field(resource: @resource, name: "f_#{active}_#{read}_#{mask}", mask_strategy: 'full')
        field.update_columns(is_active: active, read_access: read, mask_access: mask)
        field.reload

        expected = active && read && !mask
        assert_equal expected, field.exposes_in_clear?, "predicate for active=#{active} read=#{read} mask=#{mask}"
        assert_equal expected, PermissionForge::ResourceField.exposing_in_clear.exists?(field.id),
                     "scope for active=#{active} read=#{read} mask=#{mask}"
      end
    end
  end
end
