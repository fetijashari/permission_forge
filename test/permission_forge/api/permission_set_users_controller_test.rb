# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetUsersControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @user = create_user
      end

      test 'GET index returns users assigned to a permission set' do
        create_permission_set_user(user: @user, permission_set: @ps)

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/users"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['data'].size
        assert_equal @user.id, json['data'].first['user_id']
      end

      test 'POST create assigns a user to a permission set' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal @user.id, json.dig('data', 'user_id')
        assert_equal @ps.id, json.dig('data', 'permission_set_id')
      end

      test 'DELETE destroy removes a user from a permission set' do
        psu = create_permission_set_user(user: @user, permission_set: @ps)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/users/#{psu.uuid}"

        assert_response :no_content
        assert_nil PermissionForge::PermissionSetUser.find_by(id: psu.id)
      end

      # --- Expiration ---

      test 'POST create accepts expires_at' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: {
          user_id: @user.id,
          expires_at: 1.week.from_now.iso8601
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_not_nil json.dig('data', 'expires_at')
      end

      test 'GET index returns expires_at for each assignment' do
        create_permission_set_user(user: @user, permission_set: @ps, expires_at: 1.week.from_now)

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/users"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_not_nil json['data'].first['expires_at']
      end

      test 'POST create with nil expires_at creates permanent assignment' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }

        assert_response :created
        json = JSON.parse(response.body)
        assert_nil json.dig('data', 'expires_at')
      end

      # --- expires_at: ISO 8601 only (Time.zone.parse read "tuesday" as today 00:00) ---

      UNREADABLE_EXPIRY = ['tuesday', 'next tuesday-ish', '2026-13-45', 'banana', '2030-02-30', '2030-10-22T24:00',
                           '2030-10-22T10', '2030-10-22 10:00 +0200', '22/10/2030', '1761127200'].freeze

      test 'an expires_at that is not ISO 8601 is a 422 and assigns nobody, single and bulk' do
        UNREADABLE_EXPIRY.each do |value|
          post users_path, params: { user_id: @user.id, expires_at: value }, as: :json
          assert_response :unprocessable_entity, value
          assert_equal({ 'expires_at' => [I18n.t('permission_forge.api.errors.not_iso8601_time')] },
                       JSON.parse(response.body).dig('error', 'messages'), value)

          post "#{users_path}/bulk", params: { user_ids: [@user.id], bulk_action: 'assign', expires_at: value }, as: :json
          assert_response :unprocessable_entity, value
        end

        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'a number for expires_at is a 422' do
        post users_path, params: { user_id: @user.id, expires_at: 1_761_127_200 }, as: :json

        assert_response :unprocessable_entity
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'every accepted expires_at form is stored as the time it names, single and bulk' do
        accepted_expiry_forms.each do |value, expected|
          post users_path, params: { user_id: @user.id, expires_at: value }, as: :json
          assert_response :created, value
          assert_equal expected, PermissionForge::PermissionSetUser.find_by!(user_id: @user.id).expires_at, value
          PermissionForge::PermissionSetUser.where(user_id: @user.id).destroy_all

          post "#{users_path}/bulk", params: { user_ids: [@user.id], bulk_action: 'assign', expires_at: value }, as: :json
          assert_response :ok, value
          assert_equal expected, PermissionForge::PermissionSetUser.find_by!(user_id: @user.id).expires_at, value
          PermissionForge::PermissionSetUser.where(user_id: @user.id).destroy_all
        end
      end

      test 'a date or a time without an offset is read in Time.zone' do
        in_zone('Europe/Berlin') do
          post users_path, params: { user_id: @user.id, expires_at: '2030-07-01' }, as: :json
          assert_response :created
          # The end of 1 July in Berlin (CEST), as stored (microseconds).
          assert_equal Time.utc(2030, 7, 1, 21, 59, Rational(59_999_999, 1_000_000)),
                       PermissionForge::PermissionSetUser.find_by!(user_id: @user.id).expires_at

          PermissionForge::PermissionSetUser.where(user_id: @user.id).destroy_all
          post users_path, params: { user_id: @user.id, expires_at: '2030-07-01 10:00' }, as: :json
          assert_equal Time.utc(2030, 7, 1, 8, 0), PermissionForge::PermissionSetUser.find_by!(user_id: @user.id).expires_at
        end
      end

      # --- expires_at must be after now: an assignment that has ended grants nothing ---

      test 'an expires_at that is not in the future is a 422 and assigns nobody, single and bulk' do
        refusal = { 'expires_at' => [I18n.t('permission_forge.api.errors.expires_at_past')] }
        [1.minute.ago.iso8601, '2020-01-01', Time.zone.yesterday.iso8601].each do |value|
          post users_path, params: { user_id: @user.id, expires_at: value }, as: :json
          assert_response :unprocessable_entity, value
          assert_equal refusal, JSON.parse(response.body).dig('error', 'messages'), value

          post "#{users_path}/bulk", params: { user_ids: [@user.id], bulk_action: 'assign', expires_at: value }, as: :json
          assert_response :unprocessable_entity, value
          assert_equal refusal, JSON.parse(response.body).dig('error', 'messages'), value
        end

        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'now itself is refused: the end must be after the moment of the request' do
        travel_to Time.zone.local(2030, 5, 5, 12, 0) do
          post users_path, params: { user_id: @user.id, expires_at: '2030-05-05T12:00' }, as: :json
          assert_response :unprocessable_entity
        end
      end

      test 'a date alone is the end of that day, so today is accepted and lasts through it' do
        travel_to Time.zone.local(2030, 5, 5, 18, 30) do
          post users_path, params: { user_id: @user.id, expires_at: '2030-05-05' }, as: :json
          assert_response :created
          assignment = PermissionForge::PermissionSetUser.find_by!(user_id: @user.id)
          assert_equal Time.zone.local(2030, 5, 5, 23, 59, 59), assignment.expires_at.change(usec: 0)
          assert_not assignment.expired?
        end
      end

      test 'a bulk revoke ignores an expires_at in the past' do
        create_permission_set_user(user: @user, permission_set: @ps)
        post "#{users_path}/bulk", params: { user_ids: [@user.id], bulk_action: 'revoke', expires_at: '2020-01-01' }, as: :json

        assert_response :ok
        assert_equal 1, JSON.parse(response.body).dig('data', 'revoked')
      end

      test 'a blank expires_at is a permanent assignment' do
        post users_path, params: { user_id: @user.id, expires_at: '' }, as: :json

        assert_response :created
        assert_nil PermissionForge::PermissionSetUser.find_by!(user_id: @user.id).expires_at
      end

      # --- Bulk operations ---

      test 'POST bulk assigns multiple users' do
        user2 = create_user(name: 'User 2')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id, user2.id],
          bulk_action: 'assign'
        }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json.dig('data', 'assigned')
        assert_equal 2, json.dig('data', 'invalidated')
      end

      test 'POST bulk revokes multiple users' do
        user2 = create_user(name: 'User 2')
        create_permission_set_user(user: @user, permission_set: @ps)
        create_permission_set_user(user: user2, permission_set: @ps)

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id, user2.id],
          bulk_action: 'revoke'
        }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json.dig('data', 'revoked')
      end

      test 'POST bulk returns error for invalid action' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id],
          bulk_action: 'invalid'
        }

        assert_response :unprocessable_entity
      end

      private

      def users_path = "/permission_forge/api/permission_sets/#{@ps.uuid}/users"

      # The app's time zone for the block. use_zone first: it restores the
      # zone it read on entry.
      def in_zone(name, &)
        previous = Time.zone_default
        Time.use_zone(name) do
          Time.zone_default = ActiveSupport::TimeZone[name]
          yield
        ensure
          Time.zone_default = previous
        end
      end

      # value → the time it names (a date alone: the end of that day in
      # Time.zone, as stored, to the microsecond; no offset: read in Time.zone).
      def accepted_expiry_forms
        {
          '2030-10-22' => Time.zone.local(2030, 10, 22).end_of_day.change(usec: 999_999),
          '2030-10-22T10:00' => Time.zone.local(2030, 10, 22, 10, 0),
          '2030-10-22 10:00' => Time.zone.local(2030, 10, 22, 10, 0),
          '2030-10-22T10:00:30' => Time.zone.local(2030, 10, 22, 10, 0, 30),
          '2030-10-22T10:00:30.25' => Time.zone.local(2030, 10, 22, 10, 0, 30.25),
          '2030-10-22T10:00:00Z' => Time.utc(2030, 10, 22, 10, 0),
          '2030-10-22T10:00+02:00' => Time.utc(2030, 10, 22, 8, 0),
          '2030-10-22T10:00:00.5-05:30' => Time.utc(2030, 10, 22, 15, 30, 0.5),
          ' 2030-10-22T10:00:00Z ' => Time.utc(2030, 10, 22, 10, 0)
        }
      end
    end
  end
end
