require 'test_helper'

module PermissionForge
  class PermissionSetNameLengthTest < ActiveSupport::TestCase
    test 'name at max length is valid' do
      ps = PermissionForge::PermissionSet.new(
        uuid: SecureRandom.uuid, name: 'a' * 255, is_active: true, is_editable: true
      )
      assert ps.valid?, "Errors: #{ps.errors.full_messages}"
    end

    test 'name exceeding max length is invalid' do
      ps = PermissionForge::PermissionSet.new(
        uuid: SecureRandom.uuid, name: 'a' * 256, is_active: true, is_editable: true
      )
      assert_not ps.valid?
      assert ps.errors[:name].any?
    end

    test 'cloning with a very long name is invalid' do
      original = create_permission_set(name: 'a' * 250)
      error = assert_raises(ActiveRecord::RecordInvalid) do
        original.deep_clone(name: 'a' * 256)
      end
      assert_match(/Name/, error.message)
    end
  end
end
