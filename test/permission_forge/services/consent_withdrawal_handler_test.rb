require 'test_helper'

module PermissionForge
  module Services
    class ConsentWithdrawalHandlerTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @marketing_set = create_permission_set(
          name: 'Marketing Consent Access',
          requires_session_flag: 'marketing_consent'
        )
        @analytics_set = create_permission_set(
          name: 'Analytics Consent Access',
          requires_session_flag: 'analytics_consent'
        )
        @regular_set = create_permission_set(name: 'Regular Access')
        create_permission_set_user(user: @user, permission_set: @marketing_set)
        create_permission_set_user(user: @user, permission_set: @analytics_set)
        create_permission_set_user(user: @user, permission_set: @regular_set)
      end

      test 'revokes only consent-gated sets matching the flag' do
        result = ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent')

        assert_equal 1, result[:revoked_sets]
        assert result[:invalidated]
        assert_not PermissionSetUser.exists?(user: @user, permission_set: @marketing_set)
        assert PermissionSetUser.exists?(user: @user, permission_set: @analytics_set)
        assert PermissionSetUser.exists?(user: @user, permission_set: @regular_set)
      end

      test 'does not revoke sets with different consent flag' do
        result = ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent')

        assert PermissionSetUser.exists?(user: @user, permission_set: @analytics_set)
        assert_equal 1, result[:revoked_sets]
      end

      test 'returns zero when no matching consent-gated sets exist' do
        result = ConsentWithdrawalHandler.call(user: @user, consent_flag: 'nonexistent_consent')

        assert_equal 0, result[:revoked_sets]
        assert_not result[:invalidated]
      end

      test 'does not invalidate when nothing was revoked' do
        result = ConsentWithdrawalHandler.call(user: @user, consent_flag: 'nonexistent_consent')

        assert_equal false, result[:invalidated]
      end

      test 'dry run returns affected sets without revoking' do
        result = ConsentWithdrawalHandler.call(
          user: @user,
          consent_flag: 'marketing_consent',
          dry_run: true
        )

        assert_equal 0, result[:revoked_sets]
        assert_equal true, result[:dry_run]
        assert_includes result[:affected_sets], 'Marketing Consent Access'
        assert_equal 1, result[:affected_assignment_count]
        # Assignment still exists
        assert PermissionSetUser.exists?(user: @user, permission_set: @marketing_set)
      end

      test 'handles multiple sets with the same consent flag' do
        second_marketing_set = create_permission_set(
          name: 'Marketing Email Access',
          requires_session_flag: 'marketing_consent'
        )
        create_permission_set_user(user: @user, permission_set: second_marketing_set)

        result = ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent')

        assert_equal 2, result[:revoked_sets]
        assert_not PermissionSetUser.exists?(user: @user, permission_set: @marketing_set)
        assert_not PermissionSetUser.exists?(user: @user, permission_set: second_marketing_set)
      end

      test 'raises ArgumentError when user is nil' do
        assert_raises(ArgumentError) do
          ConsentWithdrawalHandler.call(user: nil, consent_flag: 'marketing_consent')
        end
      end

      test 'raises ArgumentError when consent_flag is blank' do
        assert_raises(ArgumentError) do
          ConsentWithdrawalHandler.call(user: @user, consent_flag: '')
        end
      end
    end
  end
end
