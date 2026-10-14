require 'test_helper'

module PermissionForge
  module Security
    # The HTML admin UI must honor the is_editable lock the same way the API
    # does: records flagged is_editable: false cannot be changed or destroyed,
    # even when a crafted request bypasses the disabled controls.
    class HtmlEditableLockTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @permission_set = create_permission_set(name: 'Locked Set')
        @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @base = "/permission_forge/permission_sets/#{@permission_set.id}"
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      test 'batched edits of a locked permission set are blocked with an alert' do
        @permission_set.update_columns(is_editable: false)

        patch "#{@base}/apply", params: { pf: { set: { name: 'Renamed' } } }

        assert_redirected_to @base
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert_equal 'Locked Set', @permission_set.reload.name
      end

      test 'destroy of a locked permission set is blocked with an alert' do
        @permission_set.update_columns(is_editable: false)

        delete @base

        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert PermissionForge::PermissionSet.exists?(@permission_set.id)
      end

      test 'destroy of a locked resource is blocked with an alert' do
        @resource.update_columns(is_editable: false)

        delete "#{@base}/resources/Customer"

        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert PermissionForge::Resource.exists?(@resource.id)
      end

      test 'locked fields are not changed through the field drawer or batched edits' do
        @field.update_columns(is_editable: false)

        patch "#{@base}/resources/Customer/fields/email", params: { field: { level: 'hidden' } }
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]

        patch "#{@base}/resources/Customer/apply", params: { pf: { fields: { @field.id => { level: 'hidden' } } } }
        assert @field.reload.read_access
      end

      test 'locked groups cannot be renamed or deleted' do
        group = create_permission_set_group(name: 'System', is_editable: false)

        patch "/permission_forge/groups/#{group.id}", params: { group: { name: 'Mine' } }
        delete "/permission_forge/groups/#{group.id}"

        assert_equal 'System', group.reload.name
      end

      test 'editable records still update and destroy normally' do
        patch "#{@base}/apply", params: { pf: { set: { name: 'Renamed' } } }
        assert_equal 'Renamed', @permission_set.reload.name

        delete @base
        assert_not PermissionForge::PermissionSet.exists?(@permission_set.id)
      end
    end
  end
end
