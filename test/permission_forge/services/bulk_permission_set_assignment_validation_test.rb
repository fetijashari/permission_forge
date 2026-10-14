require 'test_helper'

module PermissionForge
  module Services
    class BulkPermissionSetAssignmentValidationTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
      end

      test 'action assign works' do
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set, user_ids: [@user.id], action: :assign
        )
        assert_equal 1, result[:assigned]
      end

      test 'action revoke works' do
        create_permission_set_user(user: @user, permission_set: @permission_set)
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set, user_ids: [@user.id], action: :revoke
        )
        assert_equal 1, result[:revoked]
      end

      test 'action delete_all raises ArgumentError' do
        assert_raises(ArgumentError) do
          BulkPermissionSetAssignment.call(
            permission_set: @permission_set, user_ids: [@user.id], action: 'delete_all'
          )
        end
      end

      test 'action nil raises ArgumentError' do
        assert_raises(ArgumentError) do
          BulkPermissionSetAssignment.call(
            permission_set: @permission_set, user_ids: [@user.id], action: nil
          )
        end
      end

      test 'action empty string raises ArgumentError' do
        assert_raises(ArgumentError) do
          BulkPermissionSetAssignment.call(
            permission_set: @permission_set, user_ids: [@user.id], action: ''
          )
        end
      end

      test 'action ASSIGN wrong case raises ArgumentError' do
        assert_raises(ArgumentError) do
          BulkPermissionSetAssignment.call(
            permission_set: @permission_set, user_ids: [@user.id], action: 'ASSIGN'
          )
        end
      end

      test 'VALID_ACTIONS constant is frozen' do
        assert BulkPermissionSetAssignment::VALID_ACTIONS.frozen?
        assert_equal %i[assign revoke], BulkPermissionSetAssignment::VALID_ACTIONS
      end
    end
  end
end
