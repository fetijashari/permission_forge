require 'test_helper'

module PermissionForge
  module Concerns
    class HasUuidTest < ActiveSupport::TestCase
      test 'auto-generates uuid when blank on create' do
        ps = PermissionForge::PermissionSet.create!(
          uuid: nil,
          name: 'Auto UUID',
          is_active: true,
          is_editable: true
        )
        assert_not_nil ps.uuid
        assert_match(/\A[0-9a-f-]{36}\z/, ps.uuid)
      end

      test 'does not overwrite existing uuid' do
        custom_uuid = 'custom-uuid-1234'
        ps = PermissionForge::PermissionSet.create!(
          uuid: custom_uuid,
          name: 'Custom UUID',
          is_active: true,
          is_editable: true
        )
        assert_equal custom_uuid, ps.uuid
      end

      test 'validates uuid uniqueness' do
        ps1 = create_permission_set
        ps2 = PermissionForge::PermissionSet.new(
          uuid: ps1.uuid,
          name: 'Duplicate UUID',
          is_active: true,
          is_editable: true
        )
        assert_not ps2.valid?
        assert_includes ps2.errors[:uuid], 'has already been taken'
      end
    end
  end
end
