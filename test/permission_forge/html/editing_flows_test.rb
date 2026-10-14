require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Editing Permission Sets, resources, fields, actions, rules and groups.
    class EditingFlowsTest < AdminTestCase
      test 'create a granting set, refuse duplicate names, create a muting copy' do
        post pf('/permission_sets'), params: { type: 'granting', name: 'Finance' }
        finance = PermissionForge::PermissionSet.find_by(name: 'Finance')
        assert_redirected_to pf("/permission_sets/#{finance.id}")

        post pf('/permission_sets'), params: { type: 'granting', name: 'finance' }
        assert_response :unprocessable_entity

        post pf('/permission_sets'), params: { type: 'granting', name: 'Sales EU', start_from_granting: @set.id }
        copy = PermissionForge::PermissionSet.find_by(name: 'Sales EU')
        assert_equal ['Customer'], copy.resources.map(&:name)
        assert_equal 0, copy.permission_set_users.count

        post pf('/permission_sets'), params: { type: 'muting', name: 'Contractors' }
        assert PermissionForge::PermissionSet.find_by(name: 'Contractors').is_muting
      end

      test 'duplicate makes an unlocked deep copy' do
        @set.update_columns(is_editable: false)
        @resource.update_columns(is_editable: false)

        post pf("/permission_sets/#{@set.id}/duplicate")

        copy = PermissionForge::PermissionSet.find_by(name: 'Sales rep (copy)')
        assert copy.is_editable
        assert copy.resources.first.is_editable
      end

      test 'review lists changes, apply saves them, nothing-to-do redirects' do
        params = { pf: { resources: { @resource.id => { read_access: '1', create_access: '1', edit_access: '1', delete_access: '0' } } } }

        post pf("/permission_sets/#{@set.id}/review"), params: params
        assert_response :success
        assert_match 'Customer', response.body

        patch pf("/permission_sets/#{@set.id}/apply"), params: params
        assert @resource.reload.create_access

        post pf("/permission_sets/#{@set.id}/review"), params: params
        assert_redirected_to pf("/permission_sets/#{@set.id}")
      end

      test 'locked sets reject edits' do
        @set.update_columns(is_editable: false)

        patch pf("/permission_sets/#{@set.id}/apply"), params: { pf: { set: { name: 'Hacked' } } }
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]

        delete pf("/permission_sets/#{@set.id}")
        assert PermissionForge::PermissionSet.exists?(@set.id)
        assert_equal 'Sales rep', @set.reload.name
      end

      test 'switch mode and delete' do
        patch pf("/permission_sets/#{@set.id}/switch_mode")
        assert @set.reload.is_muting

        delete pf("/permission_sets/#{@set.id}")
        assert_not PermissionForge::PermissionSet.exists?(@set.id)
      end

      test 'conditions validate IPs and save hours and flags' do
        patch pf("/permission_sets/#{@set.id}/conditions"), params: { allowed_ips: "10.0.0.0/8\n10.0.0.300" }
        assert_response :unprocessable_entity
        assert_match '10.0.0.300', response.body

        patch pf("/permission_sets/#{@set.id}/conditions"),
              params: { allowed_ips: "10.0.0.0/8\n2001:db8::/32", hours_enabled: '1', allowed_hours_start: '22',
                        allowed_hours_end: '6', requires_session_flag: '', requires_session_flag_custom: 'mfa_verified' }
        @set.reload
        assert_equal '10.0.0.0/8,2001:db8::/32', @set.allowed_ips
        assert_equal [22, 6], [@set.allowed_hours_start, @set.allowed_hours_end]
        assert_equal 'mfa_verified', @set.requires_session_flag
      end

      test 'add a resource with privacy defaults, sync and remove it' do
        PermissionForge.configuration.gdpr_defaults = true
        post pf("/permission_sets/#{@set.id}/resources"), params: { model_name: 'Supplier', preset: 'read' }
        supplier = @set.resources.find_by(name: 'Supplier')
        assert supplier.read_access
        assert_equal 'masked', PermissionForge::Admin::FieldLevel.level_of(supplier.resource_fields.find_by(name: 'name'), muting: false)

        post pf("/permission_sets/#{@set.id}/resources"), params: { model_name: 'Supplier', preset: 'read' }
        assert_response :unprocessable_entity

        supplier.resource_fields.find_by(name: 'owner_id').destroy
        supplier.resource_fields.create!(name: 'gone_column', label: 'Gone')
        post pf("/permission_sets/#{@set.id}/resources/Supplier/sync"), params: { op: 'add_new', level: 'hidden' }
        assert supplier.resource_fields.exists?(name: 'owner_id')
        post pf("/permission_sets/#{@set.id}/resources/Supplier/sync"), params: { op: 'remove_missing' }
        assert_not supplier.resource_fields.exists?(name: 'gone_column')

        delete pf("/permission_sets/#{@set.id}/resources/Supplier")
        assert_not @set.resources.exists?(name: 'Supplier')
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'resource review and apply covers fields, bulk and actions' do
        action = create_resource_action(resource: @resource, is_permitted: false)
        params = { pf: { fields: { @email.id => { level: 'read' } },
                         bulk: { resource_id: @resource.id, keys: ['domain'], level: 'hidden' },
                         actions: { action.id => { is_permitted: '1' } } } }

        post pf("/permission_sets/#{@set.id}/resources/Customer/review"), params: params
        assert_response :success
        patch pf("/permission_sets/#{@set.id}/resources/Customer/apply"), params: params

        assert_not @email.reload.mask_access
        assert @resource.resource_fields.exists?(name: 'domain', read_access: false)
        assert action.reload.is_permitted
      end

      test 'field drawer saves, applies recommendation and acknowledges' do
        patch pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"),
              params: { field: { level: 'read', label: 'Work email' } }
        assert_equal 'Work email', @email.reload.label
        assert_not @email.mask_access

        post pf("/permission_sets/#{@set.id}/resources/Customer/fields/email/apply_recommendation")
        assert @email.reload.mask_access

        post pf("/permission_sets/#{@set.id}/resources/Customer/fields/email/acknowledge")
        assert @email.reload.sensitive_acknowledged_at

        patch pf("/permission_sets/#{@set.id}/resources/Customer/fields/domain"), params: { field: { level: 'masked' } }
        assert @resource.resource_fields.find_by(name: 'domain').mask_access
      end

      # Enter in a text input submits through the form's first submit button in
      # document order. In the field drawer that has to be the plain Save: with
      # "Apply recommendation" first, Enter in the Label box would change the
      # level at once, with no review, and drop what was typed.
      test "the field drawer's default button is a plain Save" do
        @email.update!(mask_access: false)
        path = pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")
        get path

        submits = css_select("form[action='#{path}'] button[type=submit]")

        assert_out_of_sight_but_rendered submits.first
        %w[name formaction formmethod].each { |attribute| assert_nil submits.first[attribute], attribute }
        assert_match %r{/apply_recommendation\z}, submits[1]['formaction'], 'the recommendation comes right after it'
      end

      test 'a locked field drawer has no button that saves, shown or not' do
        @email.update!(mask_access: false, is_editable: false)
        path = pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")
        get path

        assert_response :success
        assert_empty css_select("form[action='#{path}'] button[type=submit]:not([formmethod=get])")
      end

      test 'actions can be added, edited and removed' do
        post pf("/permission_sets/#{@set.id}/resources/Customer/actions"), params: { resource_action: { name: 'Bad Key!' } }
        assert_response :unprocessable_entity

        post pf("/permission_sets/#{@set.id}/resources/Customer/actions"),
             params: { resource_action: { name: 'export', label: 'Export', is_permitted: '1', is_active: '1' } }
        action = @resource.resource_actions.find_by(name: 'export')
        assert action.is_permitted

        patch pf("/permission_sets/#{@set.id}/resources/Customer/actions/#{action.id}"),
              params: { resource_action: { label: 'Export CSV', is_permitted: '0' } }
        assert_equal 'Export CSV', action.reload.label

        delete pf("/permission_sets/#{@set.id}/resources/Customer/actions/#{action.id}")
        assert_not PermissionForge::ResourceAction.exists?(action.id)
      end

      test 'rules: build, refresh, edit, toggle and remove' do
        base = "/permission_sets/#{@set.id}/resources/Customer/rules"
        post pf(base), params: { rule: { name: '', field_name: 'name', operator: 'equal', value: 'x' } }
        assert_response :unprocessable_entity

        post pf("#{base}/refresh"), params: { rule: { name: 'Mine', path: ['supplier'], field_name: '', operator: 'equal' } }
        assert_match 'owner_id', response.body

        post pf(base), params: { rule: { name: 'Own', path: ['supplier'], field_name: 'owner_id', operator: 'equal', current_user: '1' } }
        rule = @resource.permission_set_rules.find_by(name: 'Own')
        assert_equal %w[supplier joins current_user], [rule.field_accessor_path, rule.join_type, rule.field_value]

        patch pf("#{base}/#{rule.id}"), params: { rule: { name: 'Own', field_name: 'name', operator: 'in', values_text: 'a,b' } }
        assert_equal ['in', 'a,b', nil], [rule.reload.operator, rule.field_value, rule.join_type]

        patch pf("#{base}/#{rule.id}/toggle")
        assert_not rule.reload.is_active

        delete pf("#{base}/#{rule.id}")
        assert_not PermissionForge::PermissionSetRule.exists?(rule.id)
      end

      # The builder carries a hidden "refresh" button for its shape-changing
      # selects. As the form's first submit button it was the default: Enter in
      # the Name box re-rendered the builder on its own page and saved nothing.
      test "the rule builder's default button is a plain Save" do
        base = pf("/permission_sets/#{@set.id}/resources/Customer/rules")
        get "#{base}/new"

        submits = css_select("form[action='#{base}'] button[type=submit]")

        assert_out_of_sight_but_rendered submits.first
        %w[name formaction formmethod].each { |attribute| assert_nil submits.first[attribute], attribute }
        assert submits[1].key?('data-pf-refresh-button'), 'the refresh button comes right after it'
      end

      test 'groups: create, rename, move sets, members, duplicate, delete' do
        post pf('/groups'), params: { name: '' }
        assert_response :unprocessable_entity

        post pf('/groups'), params: { name: 'Sales' }
        group = PermissionForge::PermissionSetGroup.find_by(name: 'Sales')

        patch pf("/groups/#{group.id}"), params: { group: { name: 'Sales team', description: 'Front line' } }
        assert_equal 'Sales team', group.reload.name

        post pf("/groups/#{group.id}/add_set"), params: { permission_set_id: @set.id }
        assert_equal group.id, @set.reload.permission_set_group_id

        locked = create_permission_set(name: 'System', is_editable: false)
        post pf("/groups/#{group.id}/add_set"), params: { permission_set_id: locked.id }
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert_nil locked.reload.permission_set_group_id

        post pf("/groups/#{group.id}/members"), params: { user_id: @bo.id }
        membership = group.permission_set_group_users.first
        assert_not PermissionForge::PermissionSetUser.exists?(user: @bo, permission_set: @set)

        delete pf("/groups/#{group.id}/members/#{membership.id}")
        assert_empty group.permission_set_group_users.reload

        post pf("/groups/#{group.id}/duplicate")
        assert PermissionForge::PermissionSetGroup.exists?(name: 'Sales team (copy)')

        delete pf("/groups/#{group.id}/remove_set"), params: { permission_set_id: @set.id }
        assert_nil @set.reload.permission_set_group_id

        delete pf("/groups/#{group.id}")
        assert_not PermissionForge::PermissionSetGroup.exists?(group.id)
      end

      test 'preferences set theme and dismissed helpers on the mount path only' do
        patch pf('/preferences'), params: { theme: 'dark', dismiss_help: 'permission_sets', return_to: pf('/permission_sets') }

        assert_redirected_to pf('/permission_sets')
        assert_match %r{pf_theme=dark; path=/permission_forge}i, Array(response.headers['Set-Cookie']).join("\n")
        get pf('/permission_sets')
        assert_match 'data-theme="dark"', response.body
        assert_no_match "#{I18n.t('permission_forge.permission_sets.index.help_term')}:", response.body
      end

      test 'return_to never redirects off-site' do
        patch pf('/preferences'), params: { theme: 'light', return_to: '//evil.example' }

        assert_redirected_to pf('/')
      end
    end
  end
end
