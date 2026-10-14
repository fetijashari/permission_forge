# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # The admin screens refuse what a locked record holds, on every path —
    # including the toast "Undo" of a removal (restore), group membership,
    # and moving a set into or out of a locked group. On a locked Permission
    # Set access can still be narrowed — removing holders (one, offboarding,
    # undo of an add, bulk) and moving an end date earlier — never widened.
    class HierarchicalLockHtmlTest < ActionDispatch::IntegrationTest
      ROOT = '/permission_forge'

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @set = create_permission_set(name: 'Seeded')
        @holder = create_user(name: 'Hana Holder')
        @user = create_user(name: 'Uma User')
        @assignment = create_permission_set_user(user: @holder, permission_set: @set)
        @group = create_permission_set_group(name: 'System')
        @member = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @holder)
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      def assert_lock_refused(message = I18n.t('permission_forge.flash.not_editable'), &)
        assert_difference(-> { PermissionForge::AuditEvent.where(event: 'admin.lock_refused').count }, 1, &)
        assert_equal message, flash[:alert]
      end

      test 'restore (undo of a removal) does not re-create an assignment on a locked set' do
        @set.update!(is_editable: false)

        assert_no_difference -> { PermissionForge::PermissionSetUser.count } do
          assert_lock_refused(I18n.t('permission_forge.flash.locked_widening')) do
            post "#{ROOT}/assignments/restore", params: { permission_set_id: @set.id, user_id: @user.id }
          end
        end
      end

      def assert_no_lock_refusal(&)
        assert_no_difference(-> { PermissionForge::AuditEvent.where(event: 'admin.lock_refused').count }, &)
      end

      test 'a holder can be removed from a locked set, and the toast offers no Undo (it would re-grant)' do
        @set.update!(is_editable: false)

        get "#{ROOT}/assignments/#{@assignment.id}/remove"
        assert_response :ok
        assert_no_lock_refusal { delete "#{ROOT}/assignments/#{@assignment.id}" }

        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
        assert_audit_event('assignment.revoked', record_uuid: @assignment.uuid)
        assert_nil flash[:pf_undo]
      end

      test 'undo of an assignment removes holders of a set locked since' do
        @set.update!(is_editable: false)

        assert_no_lock_refusal { post "#{ROOT}/assignments/undo", params: { ids: [@assignment.id] } }
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
      end

      test 'offboarding removes every assignment, locked sets included' do
        other = create_permission_set(name: 'Open')
        open_assignment = create_permission_set_user(user: @holder, permission_set: other)
        @set.update!(is_editable: false)

        assert_no_lock_refusal { delete "#{ROOT}/people/#{@holder.id}/remove_all" }
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)
        assert_not PermissionForge::PermissionSetUser.exists?(open_assignment.id)
      end

      test 'bulk revoke works on a locked set, bulk assign does not' do
        @set.update!(is_editable: false)
        base = "#{ROOT}/permission_sets/#{@set.id}/bulk_assignment"

        get "#{base}/revoke", params: { user_ids: [@holder.id] }
        assert_response :ok
        delete "#{base}/revoke", params: { user_ids: [@holder.id] }
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)

        assert_lock_refused(I18n.t('permission_forge.flash.locked_widening')) { post base, params: { user_ids: [@user.id] } }
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'on a locked set an end date can be set or moved earlier, never cleared or moved later' do
        @set.update!(is_editable: false)
        path = "#{ROOT}/assignments/#{@assignment.id}"

        assert_no_lock_refusal { patch path, params: { expiry: '30d' } } # none before: narrows
        thirty = @assignment.reload.expires_at
        assert thirty

        assert_no_lock_refusal { patch path, params: { expiry: '1w' } } # earlier: narrows
        week = @assignment.reload.expires_at
        assert_operator week, :<, thirty

        widening = I18n.t('permission_forge.flash.locked_widening')
        assert_lock_refused(widening) { patch path, params: { expiry: '30d' } } # later: widens
        assert_lock_refused(widening) { patch path, params: { expiry: 'extend30' } }
        assert_lock_refused(widening) { patch path, params: { expiry: 'never' } } # cleared: widens
        assert_equal week, @assignment.reload.expires_at
      end

      test 'a locked group gains and loses no member' do
        @group.update!(is_editable: false)

        assert_no_difference -> { PermissionForge::PermissionSetGroupUser.count } do
          assert_lock_refused { post "#{ROOT}/groups/#{@group.id}/members", params: { user_id: @user.id } }
          assert_lock_refused { delete "#{ROOT}/groups/#{@group.id}/members/#{@member.id}" }
        end
      end

      test 'a set is not moved into a locked group from the set editor' do
        @group.update!(is_editable: false)

        assert_lock_refused do
          patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { permission_set_group_id: @group.id } } }
        end
        assert_nil @set.reload.permission_set_group_id
      end

      test 'a set is not moved out of a locked group from the set editor' do
        @set.update!(permission_set_group: @group)
        @group.update!(is_editable: false)

        assert_lock_refused do
          patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { permission_set_group_id: '' } } }
        end
        assert_equal @group.id, @set.reload.permission_set_group_id
      end

      test 'a set in a locked group is not deleted' do
        @set.update!(permission_set_group: @group)
        @group.update!(is_editable: false)

        assert_lock_refused { get "#{ROOT}/permission_sets/#{@set.id}/delete" }
        assert_lock_refused { delete "#{ROOT}/permission_sets/#{@set.id}" }
        assert PermissionForge::PermissionSet.exists?(@set.id)
      end

      test 'a duplicate of a set in a locked group lands outside the group, and the flash says so' do
        @set.update!(permission_set_group: @group)
        @group.update!(is_editable: false)

        assert_difference -> { PermissionForge::PermissionSet.count }, 1 do
          post "#{ROOT}/permission_sets/#{@set.id}/duplicate"
        end

        copy = PermissionForge::PermissionSet.order(:id).last
        assert_nil copy.permission_set_group_id
        assert_equal I18n.t('permission_forge.flash.permission_sets.duplicated_outside_group', name: 'Seeded', group: 'System'),
                     flash[:notice]
      end

      test 'duplicating a locked group makes editable copies of its sets' do
        @set.update!(permission_set_group: @group, is_editable: false)
        @group.update!(is_editable: false)

        post "#{ROOT}/groups/#{@group.id}/duplicate"

        copy = PermissionForge::PermissionSetGroup.order(:id).last
        assert copy.is_editable
        assert(copy.permission_sets.all?(&:is_editable))
      end

      test 'a new set is not created inside a locked group' do
        @group.update!(is_editable: false)

        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          assert_lock_refused do
            post "#{ROOT}/permission_sets", params: { name: 'Inside', type: 'granting', permission_set_group_id: @group.id }
          end
        end
      end

      test 'on a locked set, choosing the same end date again is no change, not a widening' do
        @set.update!(is_editable: false)
        path = "#{ROOT}/assignments/#{@assignment.id}"
        patch path, params: { expiry: '1w' }
        stored = @assignment.reload.expires_at

        assert_no_lock_refusal { patch path, params: { expiry: '1w' } }
        assert_nil flash[:alert]
        assert_equal stored, @assignment.reload.expires_at
      end

      test 'a locked set keeps Remove and the end-date control on the person page and the set page' do
        @set.update!(is_editable: false)

        get "#{ROOT}/people/#{@holder.id}"
        assert_response :ok
        assert_includes response.body, "/assignments/#{@assignment.id}/remove"
        assert_includes response.body, %(id="pf-exp-#{@assignment.id}")

        get "#{ROOT}/permission_sets/#{@set.id}", params: { tab: 'assignments' }
        assert_response :ok
        assert_includes response.body, "/assignments/#{@assignment.id}/remove"
        assert_includes response.body, 'pf-revoke-form'
      end

      test 'unlocked: removal, restore and membership work as before' do
        delete "#{ROOT}/assignments/#{@assignment.id}"
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment.id)

        post "#{ROOT}/assignments/restore", params: { permission_set_id: @set.id, user_id: @holder.id }
        assert PermissionForge::PermissionSetUser.exists?(user_id: @holder.id, permission_set_id: @set.id)

        post "#{ROOT}/groups/#{@group.id}/members", params: { user_id: @user.id }
        assert PermissionForge::PermissionSetGroupUser.exists?(user_id: @user.id, permission_set_group_id: @group.id)
      end
    end
  end
end
