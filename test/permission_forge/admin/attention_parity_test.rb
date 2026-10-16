# frozen_string_literal: true

require 'test_helper'
require_relative '../virtual_field_models'
require_relative '../rule_path_models'
require_relative '../secret_column_models'
require_relative '../../support/rule_problem_fixtures'

module PermissionForge
  module Admin
    # Home, Settings and `rake permission_forge:audit` tell one story (R1 #93:
    # Settings said "7 look good" while Home warned; R4 #81: the audit said
    # High while the admin was silent). Every SecurityAudit finding that can
    # be medium or worse is classified here, found by reading the checks'
    # `finding(…)` calls (a new one fails until it is classified):
    #
    # - HOME: about a record the admin can open — a Home card
    #   (AttentionItems) lists that record;
    # - SETTINGS: about a setting — the Settings page flags its row;
    # - OUTSIDE: neither a record nor a setting with a risk row (host code,
    #   the environment, a trade-off the docs explain);
    # - NOT_ON_HOME: about records Home leaves to the audit, with the reason.
    #
    # HOME and SETTINGS entries each have a fixture that raises the finding;
    # the test asserts the finding (medium or worse) and the card or the row
    # — the card as Home draws it (AttentionItems::CARDS: list => partial),
    # so a list dropped from the map or a card that no longer renders fails.
    class AttentionParityTest < ActionDispatch::IntegrationTest
      include RuleProblemFixtures

      CHECKS = Dir[File.expand_path('../../../lib/permission_forge/services/security_audit/*_check.rb', __dir__)].freeze
      FINDING_CALL = /\bfinding\(\s*([^,]+?),\s*:(\w+)\s*,/
      AT_LEAST_MEDIUM = /:(?:critical|high|medium)\b/

      HOME = {
        stale_assignments: :stale,
        unmasked_personal_data: :privacy_findings,
        implicit_virtual_personal_data: :privacy_findings,
        unmapped_personal_data: :privacy_findings,
        cross_set_unmasking: :privacy_findings,
        unenforced_rules: :unenforced_rules,
        missing_rule_columns: :broken_rules,
        unknown_rule_operators: :broken_rules,
        unusable_rule_values: :broken_rules,
        secret_rule_columns: :secret_rules,
        unknown_mask_strategies: :unknown_mask_strategies,
        incomplete_conditions: :broken_conditions,
        audit_off: :audit_findings,
        audit_table_missing: :audit_findings
      }.freeze

      SETTINGS = {
        admin_ui_exposed: 'http_basic_auth_enabled',
        unconfigured_fields_pass: 'unconfigured_field_strategy',
        write_protection_off: 'masked_write_protection',
        audit_trail_off: 'audit_trail_enabled',
        conditional_sets_lenient: 'conditional_sets_strict_mode',
        api_mutations_unguarded: 'api_require_authorization',
        tenantless_admin: 'admin_tenantless_access'
      }.freeze

      OUTSIDE = {
        process_local_cache: 'the cache store of a production deployment: not a record, and not a setting the admin reads',
        nested_parent_fallback: 'a trade-off of a setting the docs explain (Settings shows its value)',
        masked_nil_user_bypass: 'a trade-off of a setting the docs explain (Settings shows its value)',
        gdpr_defaults_off: 'a default for rows generated later, not about a record; Settings shows its value',
        detection_raises_in_production: 'a setting of the detection level the docs explain (Settings shows its value)',
        api_without_auth: 'the API answers 401 to every request: fails closed, Settings shows api_auth',
        audit_shared_basic_auth: 'how admin changes are attributed: a setting, explained on every event page',
        audit_anonymous_api: 'how API changes are attributed: a setting (api_actor_resolver)',
        audit_unknown_actors: 'events whose remedy is a setting or with_audit_actor; every such event page says so',
        audit_changes_unrecorded: 'audit_change_failure_strategy: a setting, Settings shows its value',
        unguarded_actions: 'host controller code (the guard is not installed there), not a record the admin edits',
        action_guard_missing: 'host controller code (the guard cannot be read), not a record the admin edits'
      }.freeze

      NOT_ON_HOME = {
        missing_users: 'the person no longer exists: there is no page to open for them',
        inactive_users: "judged by the host's user_active_check for every assigned person — a call per person the " \
                        "admin must not make on every page (the navigation counts Home's items)",
        audit_self_granted: 'the evidence is the assignment.granted event (the Audit log filters by it); the remedy ' \
                            'is a policy, admin_assignment_authorization',
        duplicate_fields: 'impossible under the unique index the install and upgrade create; the admin shows one ' \
                          'row per name, so the duplicate has no page of its own',
        duplicate_actions: 'impossible under the unique index; the admin shows one row per name',
        bypass_grants: 'a deliberate grant, not a defect: the Resources tab shows View All / Modify All on the row',
        temporary_sets: "a guess from the set's name; Home's tidy-up card lists the sets that are provably unused"
      }.freeze

      # code => true when some `finding(…)` call can give it medium or worse.
      def self.scanned_codes(sources)
        sources.each_with_object({}) do |source, codes|
          source.scan(FINDING_CALL).each do |severity, code|
            codes[code.to_sym] ||= false
            codes[code.to_sym] ||= severity.match?(AT_LEAST_MEDIUM)
          end
        end
      end

      def self.medium_codes
        scanned_codes(CHECKS.map { |file| File.read(file) }).select { |_, medium| medium }.keys
      end

      setup do
        @user = create_user(name: 'Ana')
        @set = create_permission_set(name: 'Sales')
        create_permission_set_user(user: @user, permission_set: @set)
        @restore = []
      end

      teardown do
        @restore.reverse_each(&:call)
      end

      test 'every finding that can be medium or worse is classified, once' do
        tables = [HOME, SETTINGS, OUTSIDE, NOT_ON_HOME].map(&:keys)

        assert_equal tables.flatten.size, tables.flatten.uniq.size, 'a code in two tables'
        assert_empty self.class.medium_codes - tables.flatten, 'a finding of medium or worse is not classified'
        assert_empty tables.flatten - self.class.medium_codes, 'a classified code no check raises at medium or worse'
        assert(OUTSIDE.merge(NOT_ON_HOME).values.all? { |reason| reason.to_s.strip.present? }, 'every exclusion says why')
      end

      test 'the scan finds a new finding and its severity (negative fixture)' do
        codes = self.class.scanned_codes(["finding(held ? :high : :low, :new_code, 'T', 'D')", "finding(:low, :minor, 'T', 'D')"])

        assert_equal({ new_code: true, minor: false }, codes)
        assert_includes self.class.medium_codes, :unknown_mask_strategies
      end

      HOME.each do |code, collection|
        test "#{code}: the audit's finding is on a Home card (#{collection})" do
          record = send(:"arrange_#{code}")
          finding = Services::SecurityAudit.call.findings.find { |candidate| candidate.code == code }

          assert finding, "the audit raises #{code}"
          assert_includes %i[critical high medium], finding.severity
          items = AttentionItems.new.public_send(collection)
          assert(items.any? { |item| about?(item, record) }, "Home's #{collection} lists #{record.inspect}")
          assert_home_card(collection)
        end
      end

      SETTINGS.each do |code, key|
        test "#{code}: the audit's finding is a flagged row on Settings (#{key})" do
          send(:"configure_#{code}")
          finding = Services::SecurityAudit.call.findings.find { |candidate| candidate.code == code }

          assert finding, "the audit raises #{code}"
          assert_includes %i[critical high medium], finding.severity
          assert_predicate SettingsCatalog.new.row(key), :warn?, "Settings flags #{key}"
        end
      end

      test 'every Home list has a card partial, and only those' do
        partials = Dir[File.expand_path('../../../app/views/permission_forge/home/_*_card.html.erb', __dir__)]
                   .map { |file| File.basename(file, '.html.erb').delete_prefix('_') }

        assert_equal partials.sort, AttentionItems::CARDS.values.sort
        assert_empty HOME.values.uniq - AttentionItems::CARDS.keys
      end

      private

      def config = PermissionForge.configuration

      # GET Home: the card of `collection` is drawn, titled by its heading.
      def assert_home_card(collection)
        get '/permission_forge/'
        assert_response :success
        id = "pf-card-#{AttentionItems::CARDS.fetch(collection).delete_suffix('_card').tr('_', '-')}"
        assert_select "section[aria-labelledby='#{id}'] ##{id}", 1, "Home draws the #{collection} card"
      end

      def about?(item, record)
        return item == record if record.is_a?(Symbol)

        [item, item.try(:rule), item.try(:field), item.try(:resource), item.try(:permission_set)].include?(record)
      end

      def readable_customer(set = @set)
        create_resource(permission_set: set, name: 'Customer', read_access: true)
      end

      def held_set(name, **)
        create_permission_set(name: name, **).tap { |set| create_permission_set_user(user: @user, permission_set: set) }
      end

      # --- Home ------------------------------------------------------------------------

      def arrange_stale_assignments
        create_permission_set_user(user: create_user, permission_set: @set).tap { |row| row.update_columns(created_at: 400.days.ago) }
      end

      def arrange_unmasked_personal_data
        create_resource_field(resource: readable_customer, name: 'email', read_access: true, mask_access: false)
      end

      def arrange_implicit_virtual_personal_data
        readable_customer
      end

      def arrange_unmapped_personal_data
        config.unconfigured_field_strategy = :pass_through
        readable_customer
      end

      def arrange_cross_set_unmasking
        masking = readable_customer(held_set('Support'))
        create_resource_field(resource: masking, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        create_resource_field(resource: readable_customer, name: 'email', read_access: true, mask_access: false)
      end

      def arrange_unenforced_rules
        config.auto_query_scoping = :off
        readable_customer.tap do |resource|
          create_permission_set_rule(permission_set: @set, resource: resource, field_name: 'name', field_value: 'x')
        end
      end

      def rule_of_kind(kind)
        resource = create_resource(permission_set: @set, name: fixture_model_name(kind), read_access: true)
        broken_rule(kind, permission_set: @set, resource: resource)
      end

      def arrange_missing_rule_columns = rule_of_kind(:missing_column)
      def arrange_unknown_rule_operators = rule_of_kind(:unknown_operator)
      def arrange_unusable_rule_values = rule_of_kind(:unusable_value)

      # A rule on a secret column, written before the model refused one.
      def arrange_secret_rule_columns
        resource = create_resource(permission_set: @set, name: 'PfSecretRecord', read_access: true)
        create_permission_set_rule(permission_set: @set, resource: resource, field_name: 'label', field_value: 'x')
          .tap { |rule| rule.update_columns(field_name: 'password_digest') }
      end

      def arrange_unknown_mask_strategies
        create_resource_field(resource: readable_customer, name: 'email', read_access: true, mask_access: true,
                              mask_strategy: 'email').tap { |field| field.update_columns(mask_strategy: 'rot13') }
      end

      def arrange_incomplete_conditions
        held_set('Office hours').tap do |set|
          set.update!(allowed_hours_start: 9, allowed_hours_end: 17)
          set.update_columns(allowed_hours_end: 9)
        end
      end

      def arrange_audit_off
        config.audit_events = false
        :off
      end

      def arrange_audit_table_missing
        replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { false }
        @restore << -> { PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?) }
        :missing_table
      end

      # --- Settings --------------------------------------------------------------------

      def configure_admin_ui_exposed
        config.http_basic_auth_enabled = false
        config.base_controller_class = '::ActionController::Base'
      end

      def configure_unconfigured_fields_pass
        config.unconfigured_field_strategy = :warn
      end

      def configure_write_protection_off
        config.masked_write_protection = :off
      end

      def configure_audit_trail_off
        config.audit_trail_enabled = false
      end

      def configure_conditional_sets_lenient
        config.conditional_sets_strict_mode = false
        @set.update!(requires_session_flag: 'mfa_verified')
      end

      def configure_api_mutations_unguarded
        config.api_enabled = true
        config.api_require_authorization = false
        config.api_action_authorization = nil
        config.api_assignment_authorization = nil
      end

      def configure_tenantless_admin
        config.admin_tenantless_access = :allow
      end
    end
  end
end
