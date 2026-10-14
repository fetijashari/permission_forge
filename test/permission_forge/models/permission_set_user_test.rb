require 'test_helper'

module PermissionForge
  class PermissionSetUserTest < ActiveSupport::TestCase
    setup do
      @user = create_user
      @permission_set = create_permission_set
      @psu = create_permission_set_user(user: @user, permission_set: @permission_set)
    end

    test 'belongs to permission_set' do
      assoc = PermissionForge::PermissionSetUser.reflect_on_association(:permission_set)
      assert_equal :belongs_to, assoc.macro
    end

    test 'belongs to user' do
      assoc = PermissionForge::PermissionSetUser.reflect_on_association(:user)
      assert_equal :belongs_to, assoc.macro
    end

    test 'deactivated? returns false for active user' do
      assert_not @psu.deactivated?
    end

    test 'deactivated? returns true for deactivated user' do
      @user.update!(deactivated: true)
      assert @psu.deactivated?
    end
  end
end
