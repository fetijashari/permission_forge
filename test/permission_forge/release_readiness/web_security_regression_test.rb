# frozen_string_literal: true

require 'test_helper'
require_relative '../security/shipped_api_authorization'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module ReleaseReadiness
    # The pre-release review of 2026-10-12, web-security lane: the admin screens and the JSON API, attacked as an
    # authenticated caller would attack them. Every test is an HTTP request
    # to the engine; each failed on v0.13.0 unless named as a limit.
    # The API runs on the shipped api_require_authorization (true) with both
    # hooks allowing, the setup the docs ask hosts for.
    class WebSecurityRegressionTest < ActionDispatch::IntegrationTest
      include PermissionForge::Security::ShippedApiAuthorization
      include PermissionForge::Tenancy::TenancyTestHelper

      ROOT = '/permission_forge'
      API = "#{ROOT}/api".freeze

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
        ActsAsTenant.configuration.require_tenant = false
      end

      def locked_set_with_resource
        set = create_permission_set(name: 'Seeded admin', is_editable: false)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        [set, resource]
      end

      def permission_rows
        [PermissionForge::Resource.count, PermissionForge::ResourceField.count, PermissionForge::PermissionSetRule.count,
         PermissionForge::ResourceAction.count, PermissionForge::PermissionSetUser.count,
         PermissionForge::PermissionSetGroupUser.count]
      end

      # ---- MAJOR-1: the is_editable lock was per row in the API -------------------

      # A seeded set was locked to freeze its grants. An API caller tries to
      # widen it from below: new resources, fields, rules and actions, flags
      # on the existing resource, deleting it, regenerating its fields.
      test 'WEB-M1 a locked Permission Set cannot be extended from below through the API' do
        set, resource = locked_set_with_resource
        base = "#{API}/permission_sets/#{set.uuid}"
        attempts = [
          [:post, "#{base}/resources", { resource: { name: 'Supplier', read_access: true, view_all: true, modify_all: true } }],
          [:post, "#{base}/resources/#{resource.uuid}/fields", { resource_field: { name: 'email', read_access: true, edit_access: true } }],
          [:post, "#{base}/resources/#{resource.uuid}/rules",
           { permission_set_rule: { name: 'r', field_name: 'name', operator: 'equal', field_value: 'x' } }],
          [:post, "#{base}/resources/#{resource.uuid}/actions", { resource_action: { name: 'export', is_permitted: true } }],
          [:patch, "#{base}/resources/#{resource.uuid}", { resource: { view_all: true, modify_all: true } }],
          [:post, "#{base}/resources/#{resource.uuid}/generate_fields", { grant_all: 'true' }],
          [:delete, "#{base}/resources/#{resource.uuid}", {}]
        ]

        attempts.each do |verb, path, params|
          assert_no_changes -> { [permission_rows, resource.reload.view_all] } do
            public_send(verb, path, params: params)
          end
          assert_response :forbidden, "#{verb.upcase} #{path}"
        end
      end

      test 'WEB-M1 a locked Permission Set cannot be granted to anyone through the API or the admin undo' do
        set, = locked_set_with_resource
        user = create_user

        assert_no_difference -> { PermissionForge::PermissionSetUser.count } do
          post "#{API}/permission_sets/#{set.uuid}/users", params: { user_id: user.id }
          assert_response :forbidden
          post "#{API}/permission_sets/#{set.uuid}/users/bulk", params: { user_ids: [user.id], bulk_action: 'assign' }
          assert_response :forbidden
          post "#{ROOT}/assignments/restore", params: { permission_set_id: set.id, user_id: user.id }
          assert_response :redirect
        end
      end

      test 'WEB-M1 a locked Resource takes no field, rule or action, and a locked group no member or set' do
        set = create_permission_set(name: 'Open')
        resource = create_resource(permission_set: set, name: 'Customer', is_editable: false)
        base = "#{API}/permission_sets/#{set.uuid}/resources/#{resource.uuid}"
        group = create_permission_set_group(name: 'System', is_editable: false)
        user = create_user

        assert_no_changes -> { [permission_rows, set.reload.permission_set_group_id] } do
          post "#{base}/fields", params: { resource_field: { name: 'email', read_access: true, edit_access: true } }
          assert_response :forbidden
          post "#{base}/rules", params: { permission_set_rule: { name: 'r', field_name: 'name', operator: 'equal', field_value: 'x' } }
          assert_response :forbidden
          post "#{base}/actions", params: { resource_action: { name: 'export', is_permitted: true } }
          assert_response :forbidden
          post "#{API}/permission_set_groups/#{group.uuid}/users", params: { user_id: user.id }
          assert_response :forbidden
          patch "#{API}/permission_sets/#{set.uuid}", params: { permission_set: { permission_set_group_id: group.id } }
          assert_response :forbidden
        end
      end

      # Decision pinned (ws5-handoff, decision 1): the lock never blocks
      # narrowing access, so offboarding never needs an unlock.
      test 'WEB-M1 limit: holders can still be revoked from a locked Permission Set' do
        set, = locked_set_with_resource
        assignment = create_permission_set_user(user: create_user, permission_set: set)

        delete "#{API}/permission_sets/#{set.uuid}/users/#{assignment.uuid}"

        assert_response :no_content
        assert_not PermissionForge::PermissionSetUser.exists?(assignment.id)
      end

      # NIT pinned: locking is one way through the API.
      test 'WEB-NIT limit: a lock cannot be undone through the API' do
        set = create_permission_set(name: 'Open')
        patch "#{API}/permission_sets/#{set.uuid}", params: { permission_set: { is_editable: false } }
        assert_response :ok

        patch "#{API}/permission_sets/#{set.uuid}", params: { permission_set: { is_editable: true } }

        assert_response :forbidden
        assert_not set.reload.is_editable
      end

      # ---- MAJOR-2: multi-tenant admin ran tenant-less under the documented wiring ----

      # The host set tenant_model but its engine base controllers never set a
      # tenant (the documented wiring sets it in the host's own
      # ApplicationController). With no tenant acts_as_tenant scopes nothing:
      # one Basic-auth credential read and edited every tenant.
      test 'WEB-M2 tenant-less admin and API requests are refused when tenancy is configured' do
        tenant = Account.create!(name: 'Tenant A')
        set = within(tenant) { create_permission_set(name: 'Alphaset') }
        no_tenant!

        get "#{ROOT}/permission_sets"
        assert_response :forbidden
        assert_not_includes response.body, 'Alphaset'
        patch "#{ROOT}/permission_sets/#{set.id}/apply", params: { pf: { set: { name: 'Edited by nobody' } } }
        assert_response :forbidden
        assert_equal 'Alphaset', PermissionForge::PermissionSet.unscoped.find(set.id).name
        get "#{API}/permission_sets"
        assert_response :forbidden
        get "#{API}/permission_sets/#{set.uuid}"
        assert_response :forbidden

        ActsAsTenant.test_tenant = tenant
        get "#{ROOT}/permission_sets"
        assert_response :ok
        assert_includes response.body, 'Alphaset'
      end

      test 'WEB-M2 the default is :deny and the security audit flags a default base controller under tenancy' do
        assert_equal :deny, PermissionForge::Configuration.new.admin_tenantless_access

        configuration = PermissionForge::Configuration.new
        configuration.tenant_model = 'Account'
        codes = PermissionForge::Services::SecurityAudit.call(configuration: configuration).findings.map(&:code)

        assert_includes codes, :tenantless_admin
      end

      test 'WEB-M2 the opt-out serves tenant-less reads but still never stores a tenant-less record' do
        PermissionForge.configuration.admin_tenantless_access = :allow
        no_tenant!

        get "#{ROOT}/permission_sets"
        assert_response :ok
        assert_no_difference -> { PermissionForge::PermissionSet.unscoped.count } do
          post "#{API}/permission_sets", params: { permission_set: { name: 'Nobody' } }
        end
        assert_response :unprocessable_entity
      end

      # ---- MAJOR-3: api_require_authorization shipped false -------------------------

      # The host wired api_auth = ->(c) { c.current_user.present? } ("proves
      # identity", as the docs say). Every signed-in user of the app could
      # create a set with modify_all and assign it to themselves.
      test 'WEB-M3 identity alone cannot change permissions under the shipped default' do
        assert_equal true, PermissionForge::Configuration.new.api_require_authorization
        PermissionForge.configuration.api_action_authorization = nil
        PermissionForge.configuration.api_assignment_authorization = nil
        set = create_permission_set(name: 'Existing')
        me = create_user

        assert_no_changes -> { [PermissionForge::PermissionSet.count, permission_rows] } do
          post "#{API}/permission_sets", params: { permission_set: { name: 'Escalate' } }
          assert_response :forbidden
          post "#{API}/permission_sets/#{set.uuid}/resources",
               params: { resource: { name: 'Customer', read_access: true, edit_access: true, view_all: true, modify_all: true } }
          assert_response :forbidden
          post "#{API}/permission_sets/#{set.uuid}/users", params: { user_id: me.id }
          assert_response :forbidden
        end
        assert_audit_event('api.auth_failed', data: { 'hook' => 'api_require_authorization' })

        get "#{API}/permission_sets"
        assert_response :ok, 'reads are not affected'
      end

      # ---- MINOR-1: unhandled input turned into 500s --------------------------------

      # The dummy app raises (show_exceptions = :none); a host's error page
      # answers with the status Rails maps the exception to, so the test pins
      # that mapping too: BadRequest and ParameterMissing are 400s, while the
      # ArgumentError / NoMethodError of 0.13 were 500s.
      test 'WEB-m1 crafted admin input answers 4xx, never a 500' do
        set = create_permission_set(name: 'Target')
        resource = create_resource(permission_set: set, name: 'Customer')
        create_resource_field(resource: resource, name: 'name')
        user = create_user
        responses = ActionDispatch::ExceptionWrapper.rescue_responses
        assert_equal :bad_request, responses['ActionController::BadRequest']
        assert_equal :bad_request, responses['ActionController::ParameterMissing']
        # Rails maps by exact class name: the gem's subclass is registered too.
        assert_equal 400, ActionDispatch::ExceptionWrapper.status_code_for_exception('PermissionForge::ParamShapes::InvalidParam')

        assert_no_difference -> { PermissionForge::PermissionSetUser.count } do
          assert_raises(ActionController::BadRequest) do
            post "#{ROOT}/assignments/restore", params: { permission_set_id: set.id, user_id: user.id, expires_at: '25:99' }
          end
          post "#{ROOT}/assignments/undo", params: { ids: ['x', { a: 1 }] }
          assert_response :redirect
        end
        get "#{ROOT}/people", params: { page: '9' * 30 }
        assert_response :ok
        assert_raises(ActionController::ParameterMissing) do
          patch "#{ROOT}/permission_sets/#{set.id}/resources/Customer/fields/name", params: { field: 'x' }
        end
        patch "#{ROOT}/preferences", params: { theme: 'dark', return_to: '/\\evil.com' }
        assert_response :redirect
        assert_match(%r{\Ahttp://www\.example\.com/permission_forge}, response.location)
      end

      test 'WEB-m1 blank names are a 422 in the API, not a stored blank or a 500' do
        set = create_permission_set(name: 'Target')
        resource = create_resource(permission_set: set, name: 'Customer')

        assert_no_changes -> { [PermissionForge::PermissionSet.count, PermissionForge::PermissionSetGroup.count, permission_rows] } do
          post "#{API}/permission_sets", params: { permission_set: { name: '' } }
          assert_response :unprocessable_entity
          post "#{API}/permission_set_groups", params: { permission_set_group: { name: '' } }
          assert_response :unprocessable_entity
          post "#{API}/permission_sets/#{set.uuid}/resources/#{resource.uuid}/fields", params: { resource_field: { name: '' } }
          assert_response :unprocessable_entity
        end
        patch "#{ROOT}/permission_sets/#{set.id}/apply", params: { pf: { set: { name: '' } } }
        assert_response :redirect
        assert_equal 'Target', set.reload.name
      end

      # ---- MINOR-2 (and integrity M1): user_list_resolver was a list, not a boundary ----

      # The host narrows the people list to the tenant's users. A tenant-A
      # admin who knows Bob's id (Bob exists only in tenant B) must not be
      # able to open, assign, or erase him.
      test 'WEB-m2 a person outside user_list_resolver cannot be viewed, assigned or erased by id' do
        tenant_a = Account.create!(name: 'Tenant A')
        tenant_b = Account.create!(name: 'Tenant B')
        bob = create_user(name: 'Bob Only-In-B', email: 'bob@b.test', account_id: tenant_b.id)
        set_b = within(tenant_b) { create_permission_set(name: 'Bravoset') }
        assignment_b = within(tenant_b) { create_permission_set_user(user: bob, permission_set: set_b) }
        set_a = within(tenant_a) { create_permission_set(name: 'Alphaset') }
        PermissionForge.configuration.user_list_resolver = -> { User.where(account_id: ActsAsTenant.current_tenant&.id) }
        ActsAsTenant.test_tenant = tenant_a
        labelled = -> { PermissionForge::AuditEvent.unscoped.where(subject_user_id: bob.id.to_s).where.not(record_label: nil).count }
        labels_before = labelled.call

        assert_raises(ActionController::RoutingError) { get "#{ROOT}/people/#{bob.id}" }
        assert_no_difference -> { PermissionForge::PermissionSetUser.unscoped.count } do
          post "#{ROOT}/assignments", params: { user_id: bob.id, set_ids: [set_a.id], expiry: 'never' }
          post "#{API}/permission_sets/#{set_a.uuid}/users", params: { user_id: bob.id }
          # The same 422 as an id that names nobody (through 0.14.1 a 404).
          assert_response :unprocessable_entity
          assert_equal({ 'user_id' => [I18n.t('permission_forge.api.errors.user_not_found')] },
                       JSON.parse(response.body).dig('error', 'messages'))
        end
        assert_raises(ActionController::RoutingError) do
          post "#{ROOT}/people/#{bob.id}/erasure", params: { confirmation: 'Bob Only-In-B' }
        end
        assert_equal labels_before, labelled.call, "tenant B's audit labels are untouched"
        within(tenant_b) { assert PermissionForge::PermissionSetUser.exists?(assignment_b.id) }
      end

      # ---- MINOR-3: api_assignment_authorization got user_ids in three shapes ----

      # The documented self-assignment check `!user_ids.include?(current_user.id)`
      # silently passed on create, where the id arrived as a String.
      test 'WEB-m3 api_assignment_authorization receives Integer user ids on every endpoint' do
        set = create_permission_set(name: 'Target')
        me = create_user
        other = create_user
        seen = []
        PermissionForge.configuration.api_assignment_authorization = lambda { |_controller, _target, user_ids|
          seen << user_ids
          !user_ids.include?(me.id)
        }

        post "#{API}/permission_sets/#{set.uuid}/users", params: { user_id: me.id }
        assert_response :forbidden
        post "#{API}/permission_sets/#{set.uuid}/users/bulk", params: { user_ids: [me.id.to_s, other.id.to_s], bulk_action: 'assign' }
        assert_response :forbidden
        post "#{API}/permission_sets/#{set.uuid}/users", params: { user_id: other.id }
        assert_response :created
        delete "#{API}/permission_sets/#{set.uuid}/users/#{PermissionForge::PermissionSetUser.find_by!(user_id: other.id).uuid}"
        assert_response :no_content

        assert_equal [[me.id], [me.id, other.id], [other.id], [other.id]], seen
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: me.id)
      end

      # ---- MINOR-4: no CSP of its own; preference cookies lacked `secure` -------------

      # Pinned: the engine is compatible with a strict CSP (no inline styles,
      # scripts or handlers; it consumes the host's nonce) but sets none of
      # its own — the host's policy applies.
      test 'WEB-m4 limit: the admin sets no Content-Security-Policy of its own' do
        get "#{ROOT}/permission_sets"

        assert_response :ok
        assert_nil response.headers['Content-Security-Policy']
        assert_no_match(/<script(?![^>]*\bsrc=)|\sstyle="|\son\w+="/, response.body, 'nothing inline for a CSP to refuse')
      end

      test 'WEB-m4 the admin preference cookies are Secure over HTTPS' do
        https!
        patch "#{ROOT}/preferences", params: { theme: 'dark' }

        cookie = Array(response.headers['Set-Cookie']).flat_map { |line| line.split("\n") }.find { |line| line.start_with?('pf_theme=') }
        assert cookie
        assert_match(/;\s*secure/i, cookie)
        assert_match(/;\s*httponly/i, cookie)
      end

      # ==== Pre-release re-review, web-security lane ===================

      def locked_muting_set
        create_permission_set(name: 'Contractors - no PII', is_muting: true, is_editable: false)
      end

      def lock_refusals
        PermissionForge::AuditEvent.where(event: 'admin.lock_refused').count
      end

      # ---- N1: "narrowing is always allowed" was inverted for muting sets ----

      # A host seeds and locks a Muting Permission Set so the screens cannot
      # weaken it. Removing a holder gives them their access back: refused,
      # on every path; adding one takes access away: allowed.
      test 'WEB-N1 the holders of a locked Muting Permission Set cannot be removed through the admin' do
        grant = create_permission_set(name: 'Sales')
        create_resource(permission_set: grant, name: 'Customer', read_access: true, edit_access: true)
        mute = locked_muting_set
        create_resource(permission_set: mute, name: 'Customer', read_access: true, edit_access: true)
        user = create_user(name: 'Muted')
        create_permission_set_user(user: user, permission_set: grant)
        assignment = create_permission_set_user(user: user, permission_set: mute)
        assert_not User.find(user.id).can_read?('Customer')
        widening = I18n.t('permission_forge.flash.locked_widening_muting')

        assert_difference(-> { lock_refusals }, 5) do
          get "#{ROOT}/assignments/#{assignment.id}/remove"
          assert_equal widening, flash[:alert]
          delete "#{ROOT}/assignments/#{assignment.id}"
          assert_equal widening, flash[:alert]
          post "#{ROOT}/assignments/undo", params: { ids: [assignment.id] }
          get "#{ROOT}/permission_sets/#{mute.id}/bulk_assignment/revoke", params: { user_ids: [user.id] }
          delete "#{ROOT}/permission_sets/#{mute.id}/bulk_assignment/revoke", params: { user_ids: [user.id] }
        end
        assert PermissionForge::PermissionSetUser.exists?(assignment.id)

        delete "#{ROOT}/people/#{user.id}/remove_all"
        assert PermissionForge::PermissionSetUser.exists?(assignment.id), 'offboarding keeps the mute'
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: user.id, permission_set_id: grant.id)
        assert_not User.find(user.id).can_read?('Customer')
      end

      test 'WEB-N1 the confirmation of "Remove all access" names the locked mute it keeps' do
        mute = locked_muting_set
        user = create_user(name: 'Muted')
        create_permission_set_user(user: user, permission_set: mute)
        create_permission_set_user(user: user, permission_set: create_permission_set(name: 'Sales'))

        get "#{ROOT}/people/#{user.id}/remove_all"

        assert_response :ok
        assert_includes response.body, I18n.t('permission_forge.people.confirm_remove_all.confirm', count: 1)
        assert_includes response.body, ERB::Util.html_escape(
          I18n.t('permission_forge.people.confirm_remove_all.kept', sets: mute.name)
        )
      end

      test 'WEB-N1 a locked Muting Permission Set takes holders and longer end dates through the admin' do
        mute = locked_muting_set
        user = create_user(name: 'New contractor')
        other = create_user(name: 'Second contractor')

        assert_no_difference(-> { lock_refusals }) do
          post "#{ROOT}/assignments", params: { user_id: user.id, set_ids: [mute.id], expiry: 'never' }
          post "#{ROOT}/permission_sets/#{mute.id}/bulk_assignment", params: { user_ids: [other.id], expiry: 'never' }
        end
        assignment = PermissionForge::PermissionSetUser.find_by!(user_id: user.id, permission_set_id: mute.id)
        assert PermissionForge::PermissionSetUser.exists?(user_id: other.id, permission_set_id: mute.id)

        # Undo of an assign removes the new holder: on a muting set that widens.
        post "#{ROOT}/assignments/undo", params: { ids: [assignment.id] }
        assert PermissionForge::PermissionSetUser.exists?(assignment.id)

        get "#{ROOT}/permission_sets/#{mute.id}", params: { tab: 'assignments' }
        assert_includes response.body, "/permission_sets/#{mute.id}/bulk_assignment/new"
        get "#{ROOT}/assignments/new", params: { user_id: create_user(name: 'Picker').id }
        assert_includes response.body, %(value="#{mute.id}")
      end

      test 'WEB-N1 on a locked Muting Permission Set an end date can be cleared or moved later, never earlier' do
        mute = locked_muting_set
        assignment = create_permission_set_user(user: create_user, permission_set: mute, expires_at: 60.days.from_now)
        path = "#{ROOT}/assignments/#{assignment.id}"
        widening = I18n.t('permission_forge.flash.locked_widening_muting')

        assert_difference(-> { lock_refusals }, 1) { patch path, params: { expiry: '1w' } } # earlier: widens
        assert_equal widening, flash[:alert]
        assert_operator assignment.reload.expires_at, :>, 30.days.from_now

        assert_no_difference(-> { lock_refusals }) { patch path, params: { expiry: 'extend30' } } # later: narrows
        assert_operator assignment.reload.expires_at, :>, 80.days.from_now
        assert_no_difference(-> { lock_refusals }) { patch path, params: { expiry: 'never' } } # cleared: narrows
        assert_nil assignment.reload.expires_at
        assert_difference(-> { lock_refusals }, 1) { patch path, params: { expiry: '30d' } } # set where none: widens
        assert_nil assignment.reload.expires_at
      end

      test 'WEB-N1 restoring a removed holder of a locked Muting Permission Set is allowed (it narrows)' do
        mute = locked_muting_set
        user = create_user

        assert_no_difference(-> { lock_refusals }) do
          post "#{ROOT}/assignments/restore", params: { permission_set_id: mute.id, user_id: user.id }
        end
        assert PermissionForge::PermissionSetUser.exists?(user_id: user.id, permission_set_id: mute.id)
      end

      test 'WEB-N1 the API refuses removing holders of a locked Muting Permission Set and allows adding them' do
        mute = locked_muting_set
        base = "#{API}/permission_sets/#{mute.uuid}/users"
        held = create_user
        assignment = create_permission_set_user(user: held, permission_set: mute)

        delete "#{base}/#{assignment.uuid}"
        assert_response :forbidden
        post "#{base}/bulk", params: { bulk_action: 'revoke', user_ids: [held.id] }
        assert_response :forbidden
        assert PermissionForge::PermissionSetUser.exists?(assignment.id)

        post base, params: { user_id: create_user.id }
        assert_response :created
        post "#{base}/bulk", params: { bulk_action: 'assign', user_ids: [create_user.id] }
        assert_response :ok
        assert_equal 3, mute.permission_set_users.count
      end

      test 'WEB-N1 a locked granting set still loses holders and takes none through the API' do
        set, = locked_set_with_resource
        assignment = create_permission_set_user(user: create_user, permission_set: set)
        base = "#{API}/permission_sets/#{set.uuid}/users"

        post "#{base}/bulk", params: { bulk_action: 'revoke', user_ids: [assignment.user_id] }
        assert_response :ok
        post "#{base}/bulk", params: { bulk_action: 'assign', user_ids: [create_user.id] }
        assert_response :forbidden
        post "#{base}/bulk", params: { bulk_action: 'bogus', user_ids: [create_user.id] }
        assert_response :forbidden
        assert_equal 0, set.permission_set_users.count
      end

      # ---- N2: the group page moved a set out of a locked group ----

      test 'WEB-N2 the group page does not move a set out of a locked group' do
        locked = create_permission_set_group(name: 'Locked group', is_editable: false)
        open = create_permission_set_group(name: 'Open group')
        set = create_permission_set(name: 'In locked', permission_set_group: locked)

        assert_difference(-> { lock_refusals }, 1) do
          post "#{ROOT}/groups/#{open.id}/add_set", params: { permission_set_id: set.id }
        end
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert_equal locked.id, set.reload.permission_set_group_id

        free = create_permission_set(name: 'Ungrouped')
        post "#{ROOT}/groups/#{open.id}/add_set", params: { permission_set_id: free.id }
        assert_equal open.id, free.reload.permission_set_group_id
      end

      # ---- N3: the paths that take an assignment id ignored user_list_resolver ----

      # The host keeps staff out of the admin (user_list_resolver). Their
      # assignments are named by id on several paths: each must answer as
      # if the person did not exist.
      test 'WEB-N3 an assignment of somebody outside user_list_resolver is not found by its id' do
        set = create_permission_set(name: 'Sales')
        inside = create_user(name: 'Inside Person')
        outside = create_user(name: 'Outside Person')
        kept = create_permission_set_user(user: outside, permission_set: set, expires_at: 3.days.from_now)
        group = create_permission_set_group(name: 'Team')
        membership = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: group, user: outside)
        PermissionForge.configuration.user_list_resolver = -> { User.where(name: 'Inside Person') }
        before = kept.expires_at

        [-> { get "#{ROOT}/assignments/#{kept.id}/remove" },
         -> { patch "#{ROOT}/assignments/#{kept.id}", params: { expiry: 'never' } },
         -> { patch "#{ROOT}/assignments/#{kept.id}", params: { expiry: 'extend30' } },
         -> { post "#{ROOT}/assignments/#{kept.id}/keep" },
         -> { delete "#{ROOT}/assignments/#{kept.id}" },
         -> { post "#{ROOT}/assignments/undo", params: { ids: [kept.id] } },
         -> { delete "#{ROOT}/groups/#{group.id}/members/#{membership.id}" }].each do |request|
          assert_raises(ActionController::RoutingError, &request)
        end
        delete "#{API}/permission_sets/#{set.uuid}/users/#{kept.uuid}"
        assert_response :not_found
        delete "#{API}/permission_set_groups/#{group.uuid}/users/#{membership.uuid}"
        assert_response :not_found

        assert_equal before, kept.reload.expires_at
        assert_nil kept.reviewed_at
        assert PermissionForge::PermissionSetGroupUser.exists?(membership.id)

        inside_assignment = create_permission_set_user(user: inside, permission_set: set)
        patch "#{ROOT}/assignments/#{inside_assignment.id}", params: { expiry: '30d' }
        assert inside_assignment.reload.expires_at
      ensure
        PermissionForge.configuration.user_list_resolver = nil
      end

      # ---- N4: the Edit-off cascade changed the fields of a locked Resource ----

      test 'WEB-N4 saving a set leaves the fields of a locked Resource as they are' do
        set = create_permission_set(name: 'Cascade')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true, edit_access: false, is_editable: false)
        field = create_resource_field(resource: resource, name: 'email', read_access: true, edit_access: true)

        patch "#{ROOT}/permission_sets/#{set.id}/apply", params: { pf: { set: { description: 'touch' } } }

        assert_equal 'touch', set.reload.description
        assert field.reload.edit_access, 'the locked Resource kept its Editable field'
      end

      # ---- N6: an unusual Accept header on a failing admin form was a 500 ----

      test 'WEB-N6 a failing admin form answers HTML whatever the Accept header asks for' do
        user = create_user
        %w[application/json text/csv application/xml text/plain].each do |accept|
          headers = { 'ACCEPT' => accept }
          post "#{ROOT}/permission_sets", params: { name: '' }, headers: headers
          assert_response :unprocessable_entity
          assert_equal 'text/html', response.media_type, accept
          post "#{ROOT}/assignments", params: { user_id: user.id }, headers: headers
          assert_response :unprocessable_entity
          post "#{ROOT}/people/#{user.id}/erasure", params: { confirmation: 'wrong' }, headers: headers
          assert_response :unprocessable_entity
        end
      end
    end
  end
end
