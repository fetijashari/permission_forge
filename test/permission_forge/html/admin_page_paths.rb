require_relative 'admin_test_case'
require_relative 'admin_paths'
require_relative '../secret_column_models'

module PermissionForge
  module Html
    # The admin screens a whole-UI test walks (AdminPaths, on the sample data
    # AdminTestCase sets up plus a muting set, a group, an action, a locked set
    # down to its field and rule, a rule whose column is misspelled, and a
    # record for every Home card), with controller-action discovery on.
    # Included by the tests that check every screen (rendering, CSP,
    # accessibility, layout) and every error state; #extra_screens adds the
    # POSTs answered with a page and the screens a setting changes (the audit
    # log off, the audit log refused).
    module AdminPagePaths
      extend ActiveSupport::Concern

      # [label, setting, verb, path, status]: screens drawn only under a
      # setting (AdminPaths is the same for the browser probe, which cannot
      # change one per request). `setting` names a method below.
      STATE_SCREENS = [
        %w[audit_off get / 200], %w[audit_off get /audit 200], %w[audit_off get /people/:ana?tab=audit 200],
        %w[audit_refused get /audit 403], %w[audit_refused get /people/:ana?tab=audit 403],
        %w[audit_refused get /permission_sets/:set?tab=audit 403]
      ].map { |setting, verb, path, status| [setting.to_sym, verb.to_sym, path, status.to_i] }.freeze

      included do
        setup do
          PermissionForge.configuration.controller_action_discovery = true
          seed_home_cards
          @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
          @action = create_resource_action(resource: @resource)
          @group = create_permission_set_group(name: 'Sales')
          @muting = create_permission_set(name: 'Contractors', is_muting: true)
          create_resource(permission_set: @muting, delete_access: true)
          @locked = create_permission_set(name: 'Managed by API', is_editable: false)
          locked_resource = create_resource(permission_set: @locked, is_editable: false)
          create_resource_field(resource: locked_resource, is_editable: false)
          create_permission_set_rule(permission_set: @locked, resource: locked_resource, is_editable: false)
          @broken = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Typo rule',
                                               field_name: 'name', field_value: 'active')
          @broken.update_columns(field_name: 'stauts')
        end
      end

      def paths = admin_paths.paths
      def error_states = admin_paths.error_states
      def flows = admin_paths.flows
      def posted_pages = admin_paths.posted_pages

      # ["POST /permission_sets/1/review", body] for every POST answered with
      # a page, then ["audit_off GET /audit", body] for every STATE_SCREENS
      # entry, each answered with its status (asserted), in `locale`.
      def extra_screens(locale: nil)
        localized = locale ? { locale: locale } : {}
        posted = posted_pages.map do |page|
          post pf(page.path), params: page.params.merge(localized)
          assert_response page.status, "POST #{page.path}"
          ["POST #{page.path}", response.body]
        end
        posted + STATE_SCREENS.map { |setting, verb, path, status| state_screen(setting, verb, path, status, localized) }
      end

      # ["POST /permission_sets", body] for every error state that renders a
      # page: the refused forms, re-rendered, for the walks that lint markup.
      def error_screens
        error_states.select(&:renders?).map do |state|
          send(state.verb, pf(state.path), params: state.params)
          ["#{state.verb.upcase} #{state.path}", response.body]
        end
      end

      # Built once per test: the audit fixtures (an update's before/after, a
      # destroy's snapshot) are recorded on the first use.
      def admin_paths
        @admin_paths ||= begin
          updated, destroyed = audit_fixtures
          AdminPaths.new(ana: @ana.id, assignment: @assignment.id, set: @set.id, resource: @resource.id, email: @email.id,
                         muting: @muting.id, locked: @locked.id,
                         group: @group.id, action: @action.id, rule: @rule.id, broken: @broken.id,
                         updated_event: updated.uuid, destroyed_event: destroyed.uuid)
        end
      end

      private

      def state_screen(setting, verb, path, status, params)
        path = path.sub(':ana', @ana.id.to_s).sub(':set', @set.id.to_s)
        config = PermissionForge.configuration
        previous = [config.audit_events, config.audit_log_authorization]
        send(:"configure_#{setting}")
        send(verb, pf(path), params: params)
        assert_response status, "#{setting} #{verb.upcase} #{path}"
        ["#{setting} #{verb.upcase} #{path}", response.body]
      ensure
        config.audit_events, config.audit_log_authorization = previous
      end

      def configure_audit_off = PermissionForge.configuration.audit_events = false
      def configure_audit_refused = PermissionForge.configuration.audit_log_authorization = ->(_controller) { false }

      # A record for every Home card (Admin::AttentionItems::CARDS) but the
      # audit log's, which a setting raises (STATE_SCREENS): an assignment
      # ending soon, one expired, one due for review, a set whose condition
      # nobody can judge, a field masked with an unknown strategy, a rule on
      # a secret column.
      def seed_home_cards
        ending = create_permission_set(name: 'Temporary access')
        create_permission_set_user(user: @bo, permission_set: ending, expires_at: 3.days.from_now)
        expired = create_permission_set(name: 'Old project')
        create_permission_set_user(user: @bo, permission_set: expired, expires_at: 1.day.from_now).update_columns(expires_at: 2.days.ago)
        create_permission_set_user(user: @bo, permission_set: @set).update_columns(created_at: 400.days.ago)
        hours = create_permission_set(name: 'Office hours', allowed_hours_start: 9, allowed_hours_end: 17)
        hours.update_columns(allowed_hours_end: 9)
        create_permission_set_user(user: @bo, permission_set: hours)
        create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: true, mask_strategy: 'email')
          .update_columns(mask_strategy: 'rot13')
        vault = create_permission_set(name: 'Vault')
        create_permission_set_user(user: @bo, permission_set: vault)
        secrets = create_resource(permission_set: vault, name: 'PfSecretRecord', read_access: true)
        create_permission_set_rule(permission_set: vault, resource: secrets, field_name: 'label', field_value: 'x')
          .update_columns(field_name: 'password_digest')
      end

      def audit_fixtures
        @email.update!(mask_strategy: 'last4')
        updated = PermissionForge::AuditEvent.where(event: 'resource_field.updated').last
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Gone').destroy!
        destroyed = PermissionForge::AuditEvent.where(event: 'permission_set_rule.destroyed').last
        [updated, destroyed]
      end
    end
  end
end
