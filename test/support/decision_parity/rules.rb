# frozen_string_literal: true

require 'test_helper'
require 'permission_forge/sti_models'

module PermissionForge
  module ReleaseReadiness
    # G5 (d, e, h, j) and the round-6 items of WP-8b: two surfaces that
    # decide the same thing agree — the admin's rule builder with the model
    # and the API, the admin's "stale" / "ending soon" with Home and the
    # audit, the admin's model lookup with ModelLookup, the conditional
    # scopes with #conditional?. Loaded by decision_parity_rules_test.rb
    # (and by WP-8a's decision_parity_test.rb, which requires every file
    # under test/support/decision_parity/).
    class DecisionParityRulesTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true)
      end

      # --- (d) the rule builder, the model and the API ------------------------------

      test 'include_nulls has one default: off in code, through the API and in the builder' do
        in_code = PermissionForge::PermissionSetRule.new.include_nulls
        saved = PermissionForge::PermissionSetRule.create!(permission_set: @set, resource: @resource, name: 'Plain', field_name: 'name',
                                                           field_value: 'x', operator: 'equal')
        builder = Admin::RuleForm.new(resource: @resource).include_nulls
        api = Api::Serializers::PermissionSetRuleSerializer.new(saved).as_json

        assert_equal false, in_code
        assert_equal false, saved.reload.include_nulls, 'a rule created without the flag (as the API does) stores false'
        assert_equal in_code, builder
        assert_equal in_code, api.with_indifferent_access[:include_nulls]
        assert_equal false, Admin::RuleForm.new(resource: @resource, rule: saved).include_nulls, 'editing shows what is stored'
      end

      test 'a filter rule that carries a path stays a filter rule through the builder' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'name', field_value: 'x')
        rule.update_columns(field_accessor_path: 'supplier', join_type: nil)
        form = Admin::RuleForm.new(resource: @resource, rule: rule.reload)

        assert_not rule.join_rule?
        assert_empty form.path, 'the builder loads no path for a filter rule'
        assert_nil form.join_type
        assert_equal 'auto', form.join
        assert_nil form.attributes[:join_type], 'saved again, it is still a filter rule'
      end

      test 'the operator is kept as posted, refused when it is none (no rewrite to equal)' do
        form = Admin::RuleForm.new(resource: @resource, params: { name: 'x', field_name: 'name', operator: 'regex', value: 'a' })

        assert_equal 'regex', form.operator
        assert_not form.valid?
        assert_equal :operator, form.errors[:operator]
        assert_equal 'equal', Admin::RuleForm.new(resource: @resource, params: { name: 'x' }).operator, 'no operator posted: the first'
      end

      test 'the builder offers exactly the columns the model accepts, ignored_fields included and flagged' do
        form = Admin::RuleForm.new(resource: @resource)
        offered = form.field_options.map(&:name)

        assert_equal Operators::RuleColumn.names_for(Customer).sort, offered.sort
        assert_includes offered, 'id'
        assert form.ignored_field?(form.field_options.find { |column| column.name == 'id' }), 'id is flagged (config.ignored_fields)'
        assert_not form.ignored_field?(form.field_options.find { |column| column.name == 'name' })
        offered.each do |name|
          rule = PermissionForge::PermissionSetRule.new(permission_set: @set, resource: @resource, name: name, field_name: name,
                                                        operator: 'is_not_null', field_value: '')
          rule.valid?

          assert_empty rule.errors[:field_name], "#{name} is offered, so the model accepts it"
        end
        refused = PermissionForge::PermissionSetRule.new(permission_set: @set, resource: @resource, name: 'x', field_name: 'nope',
                                                         operator: 'is_not_null', field_value: '')

        assert_not refused.valid?
        assert_not_includes offered, 'nope'
      end

      test 'a rule on id (the docs example) can be built in the admin' do
        form = Admin::RuleForm.new(resource: @resource, params: { name: 'Own', field_name: 'id', operator: 'equal', current_user: '1' })

        assert form.valid?, form.errors.inspect
        assert_equal 'id', form.column.name
      end

      test 'the column-typo validation message names the stored value, like the path message' do
        rule = PermissionForge::PermissionSetRule.new(permission_set: @set, resource: @resource, name: 'x', field_name: 'stauts',
                                                      operator: 'equal', field_value: 'a')
        rule.valid?

        assert_equal ['names stauts, which is not a column of Customer'], rule.errors[:field_name]
        I18n.available_locales.each do |locale|
          message = I18n.t('permission_forge.validations.permission_set_rule.unknown_column', locale: locale, name: 'stauts', model: 'Customer')

          assert_includes message, 'stauts', locale.to_s
        end
      end

      test 'join_type_rules agrees with filter_join_type? on whitespace, for Home and the boot warning' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'name', field_value: 'x')
        rule.update_columns(join_type: ' ')

        assert PermissionForge::PermissionSetRule.filter_join_type?(' ')
        assert_not rule.reload.join_rule?
        assert_empty PermissionForge::PermissionSetRule.join_type_rules
        PermissionForge.configuration.auto_query_scoping = :filter_only

        assert_empty Admin::AttentionItems.new.unenforced_rules
      end

      # --- (e) the model a name stands for ------------------------------------------

      test 'ModelLookup.model_for and ModelCatalog#find agree on what is a model' do
        catalog = Admin::ModelCatalog.new
        %w[Customer Kernel Comparable PermissionForge NoSuch ApplicationRecord PfStiBugTicket].each do |name|
          assert_equal PermissionForge::ModelLookup.model_for(name).nil?, catalog.find(name).nil?, name
        end
      end

      # --- (h) stale and ending soon ----------------------------------------------------

      def helper_view
        ApplicationController.new.view_context.extend(PermissionForge::ApplicationHelper)
      end

      test 'stale: the People page, Home, the audit and the auditor agree with the setting nil and set' do
        assignment = create_permission_set_user(user: create_user, permission_set: @set)
        assignment.update_columns(created_at: 60.days.ago)
        view = helper_view

        # nil: the 90-day default (the People page used to read nil as 0 days and mark everything stale)
        { nil => false, 30 => true, 365 => false }.each do |setting, expected|
          PermissionForge.configuration.admin_stale_assignment_days = setting
          days = Admin::AttentionItems.stale_days

          assert_equal expected, view.pf_stale?(assignment), "pf_stale? with #{setting.inspect}"
          assert_equal expected, Admin::AttentionItems.new.stale.include?(assignment), "Home with #{setting.inspect}"
          assert_equal expected, Services::StaleAssignmentAuditor.call[:stale_count].positive?, "auditor with #{setting.inspect}"
          assert_equal days,
                       Services::SecurityAuditChecks::AssignmentCheck.new(configuration: PermissionForge.configuration,
                                                                          environment: 'test').send(:stale_days)
          assert_equal expected, assignment.stale?(days)
        end
      end

      test 'ending soon: the end-date cell, Home, the People filter and ending_within agree' do
        # At noon, so "in two hours" is still today whenever the suite runs.
        travel_to Time.current.change(hour: 12)
        soon = create_permission_set_user(user: create_user, permission_set: @set, expires_at: 7.days.from_now.end_of_day)
        later = create_permission_set_user(user: create_user, permission_set: @set, expires_at: 8.days.from_now.beginning_of_day)
        today = create_permission_set_user(user: create_user, permission_set: @set, expires_at: 2.hours.from_now)
        view = helper_view
        ends_in = I18n.t('permission_forge.ui.expiry.ends_in', count: 7, date: '')[0, 5]

        assert_equal [soon, today].sort_by(&:id), PermissionForge::PermissionSetUser.ending_within.order(:id).to_a
        assert_equal [today, soon], Admin::AttentionItems.new.ending_soon
        assert_equal [today, soon].map(&:user_id).sort, Admin::PeopleDirectory::FILTER_ASSIGNMENTS.fetch('ending').call.pluck(:user_id).sort
        assert soon.ending_soon?
        assert today.ending_soon?
        assert_not later.ending_soon?
        assert_includes view.pf_expiry(soon.expires_at).first, ends_in.strip
        assert_equal I18n.t('permission_forge.ui.expiry.today'), view.pf_expiry(today.expires_at).first
        assert_not_includes view.pf_expiry(later.expires_at).first, ends_in.strip
      end

      test 'ended: the cell and the model agree at the boundary' do
        travel_to Time.current.change(usec: 0) do
          now = Time.current
          assert_not PermissionForge::PermissionSetUser.ended?(now)
          assert PermissionForge::PermissionSetUser.ended?(now - 1)
          assert_equal I18n.t('permission_forge.ui.expiry.today'), helper_view.pf_expiry(now).first
        end
      end

      # --- (j) conditional sets: Ruby and SQL ------------------------------------------

      test 'conditional? and the conditional scope agree on blank, whitespace and newline values' do
        ['', '  ', "\n", nil].each do |value|
          set = create_permission_set(name: "C #{value.inspect}")
          set.update_columns(allowed_ips: value, requires_session_flag: value)

          assert_equal set.reload.conditional?, PermissionForge::PermissionSet.conditional.exists?(id: set.id), value.inspect
          assert_equal !set.conditional?, PermissionForge::PermissionSet.unconditional.exists?(id: set.id), value.inspect
        end
      end
    end
  end
end
