# frozen_string_literal: true

require 'test_helper'
require 'yaml'

module PermissionForge
  class AuditSettingsTest < ActiveSupport::TestCase
    AUDIT_KEYS = %w[audit_events audit_actor_resolver audit_request_context audit_change_failure_strategy
                    audit_hook_failure_strategy audit_runtime_events audit_log_subscriber audit_retention_period
                    audit_log_authorization admin_assignment_authorization].freeze

    def fresh = PermissionForge::Configuration.new

    test 'defaults follow the design contract' do
      config = fresh
      assert_equal :auto, config.audit_events
      assert_nil config.audit_actor_resolver
      assert_nil config.audit_request_context
      assert_equal :raise, config.audit_change_failure_strategy
      assert_equal :report, config.audit_hook_failure_strategy
      assert_equal %i[denied], config.audit_runtime_events
      assert_equal false, config.audit_log_subscriber
      assert_nil config.audit_retention_period
      assert_nil config.audit_log_authorization
      assert_nil config.admin_assignment_authorization
    end

    test 'the existing audit options are untouched' do
      config = fresh
      assert_equal true, config.audit_trail_enabled
      assert_equal 'User', config.audit_user_class
      assert_nil config.on_rule_bypass
      assert_nil config.on_field_filtered
    end

    test 'audit_events accepts :auto, true and false only' do
      config = fresh
      [:auto, true, false].each { |value| assert_equal value, (config.audit_events = value) }
      assert_raises(PermissionForge::ConfigurationError) { config.audit_events = 'auto' }
      assert_raises(PermissionForge::ConfigurationError) { config.audit_events = nil }
    end

    test 'the failure strategies are validated' do
      config = fresh
      %i[raise report log].each { |value| config.audit_change_failure_strategy = value }
      %i[report log raise].each { |value| config.audit_hook_failure_strategy = value }
      assert_raises(PermissionForge::ConfigurationError) { config.audit_change_failure_strategy = :ignore }
      assert_raises(PermissionForge::ConfigurationError) { config.audit_hook_failure_strategy = 'report' }
    end

    test 'audit_runtime_events takes known groups as symbols or strings and normalizes them' do
      config = fresh
      config.audit_runtime_events = %w[denied field_read]
      assert_equal %i[denied field_read], config.audit_runtime_events
      config.audit_runtime_events = []
      assert_equal [], config.audit_runtime_events
      config.audit_runtime_events = nil
      assert_equal [], config.audit_runtime_events
      assert_raises(PermissionForge::ConfigurationError) { config.audit_runtime_events = %i[denied everything] }
    end

    test 'store_runtime_group? asks the configured list' do
      config = fresh
      assert config.store_runtime_group?(:denied)
      assert_not config.store_runtime_group?(:bypass)
      config.audit_runtime_events = %i[bypass]
      assert config.store_runtime_group?(:bypass)
      assert_not config.store_runtime_group?(nil)
    end

    test 'audit_retention_period takes a duration, a number of seconds or nil' do
      config = fresh
      config.audit_retention_period = 90.days
      assert_equal 90.days, config.audit_retention_period
      config.audit_retention_period = 3600
      assert_equal 3600, config.audit_retention_period
      config.audit_retention_period = nil
      assert_nil config.audit_retention_period
      assert_raises(PermissionForge::ConfigurationError) { config.audit_retention_period = '90 days' }
      assert_raises(PermissionForge::ConfigurationError) { config.audit_retention_period = -1 }
    end

    test 'every audit option is on the Settings page with a label in each locale' do
      catalog = PermissionForge::Admin::SettingsCatalog.new
      AUDIT_KEYS.each do |key|
        row = catalog.row(key)
        assert_not_nil row, "#{key} is missing from the settings catalog"
        %i[en sq mk].each do |locale|
          I18n.with_locale(locale) do
            %w[name desc].each do |part|
              text = I18n.t("permission_forge.settings.items.#{key}.#{part}", default: nil)
              assert text.present?, "#{locale}: settings.items.#{key}.#{part} is missing"
            end
          end
        end
      end
    end

    test 'the settings page renders the audit rows with their current values' do
      PermissionForge.configuration.audit_retention_period = 90.days
      PermissionForge.configuration.audit_runtime_events = %i[denied bypass]
      catalog = PermissionForge::Admin::SettingsCatalog.new
      assert_equal 'auto', catalog.row('audit_events').value
      assert_equal %w[denied bypass], catalog.row('audit_runtime_events').value
      assert_equal 7_776_000, catalog.row('audit_retention_period').value
      assert_equal '90.days', catalog.snippet_value(catalog.row('audit_retention_period'))
      assert_equal '%i[denied bypass]', catalog.snippet_value(catalog.row('audit_runtime_events'))
      assert_equal :default, catalog.row('audit_actor_resolver').hook_state
      assert_equal :none, catalog.row('admin_assignment_authorization').hook_state
    end

    test 'audit_events is flagged as a risk when off and as secure when recording' do
      catalog = PermissionForge::Admin::SettingsCatalog.new
      assert catalog.row('audit_events').ok?
      PermissionForge.configuration.audit_events = false
      row = PermissionForge::Admin::SettingsCatalog.new.row('audit_events')
      assert row.warn?
      assert_equal ':auto', row.recommended
      %i[en sq mk].each do |locale|
        I18n.with_locale(locale) do
          assert I18n.t('permission_forge.settings.risks.audit_events', default: nil).present?, "#{locale} risk text"
          assert I18n.t('permission_forge.settings.oks.audit_events', default: nil).present?, "#{locale} ok text"
        end
      end
    end

    test 'the generated initializer documents every audit option' do
      template = File.read(File.expand_path('../../../lib/generators/permission_forge/install/templates/initializer.rb.tt', __dir__))
      AUDIT_KEYS.each { |key| assert_includes template, "config.#{key}", "initializer template lacks #{key}" }
    end
  end
end
