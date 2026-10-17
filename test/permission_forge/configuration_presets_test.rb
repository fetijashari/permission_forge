# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # config.preset: :compat (the library defaults) and :strict (every fail-open
  # default of the README's hardening checklist closed), applied as a layer
  # of defaults under the settings the host makes itself.
  class ConfigurationPresetsTest < ActiveSupport::TestCase
    Presets = Configuration::Presets

    README = File.expand_path('../../README.md', __dir__)

    # Checklist rows that need host code, which no preset can supply.
    HOST_SUPPLIED = %i[http_basic_auth_enabled admin_assignment_authorization audit_log_authorization
                       base_controller_class user_active_check].freeze

    def config = @config ||= Configuration.new

    # --- the layer -------------------------------------------------------------

    test 'without a preset a configuration has the library defaults, and they are the :compat values' do
      assert_equal :compat, config.preset
      Presets::COMPAT.each do |option, value|
        value.nil? ? assert_nil(config.public_send(option), option) : assert_equal(value, config.public_send(option), option)
      end
      assert_equal Presets::COMPAT.keys, Presets::STRICT.keys
    end

    test ':strict sets every value it decides' do
      config.preset = :strict

      assert_equal :strict, config.preset
      Presets::STRICT.each { |option, value| assert_equal value, config.public_send(option), option }
      assert_empty config.options_looser_than_strict
    end

    test 'an explicit setting wins over the preset whether it comes before or after it' do
      config.nil_user_strategy = :bypass
      config.preset = :strict
      config.cache_backend = :memory

      assert_equal :bypass, config.nil_user_strategy
      assert_equal :memory, config.cache_backend
      assert_equal :block, config.response_filter_nil_user_strategy, 'the options nobody set follow the preset'
      assert config.explicitly_set?(:nil_user_strategy)
      assert_not config.explicitly_set?(:response_filter_nil_user_strategy)
    end

    test 'an explicit setting equal to the library default is kept under :strict' do
      config.action_guard_nil_user_strategy = nil
      config.preset = 'strict'

      assert_nil config.action_guard_nil_user_strategy
    end

    test 'a later preset, or a second configure block, never clobbers an explicit setting' do
      config.preset = :strict
      config.unconfigured_action_strategy = :allow
      config.preset = :compat

      assert_equal :allow, config.unconfigured_action_strategy
      assert_equal :bypass, config.nil_user_strategy, 'back to the library default'

      config.preset = :strict
      assert_equal :allow, config.unconfigured_action_strategy
      assert_equal :deny, config.nil_user_strategy
    end

    test 'a preset given as a String is taken as its Symbol; anything else raises' do
      config.preset = 'strict'
      assert_equal :strict, config.preset

      [:loose, 'paranoid', nil, true, ''].each do |value|
        error = assert_raises(ConfigurationError) { config.preset = value }
        assert_match(/preset must be one of :compat, :strict/, error.message)
      end
      assert_equal :strict, config.preset, 'a refused preset changes nothing'
    end

    test 'a refused value does not count as set' do
      assert_raises(ConfigurationError) { config.nil_user_strategy = :nope }
      config.preset = :strict

      assert_not config.explicitly_set?(:nil_user_strategy)
      assert_equal :deny, config.nil_user_strategy
    end

    test 'values as closed as the :strict one are not reported as looser' do
      config.preset = :strict
      config.nil_user_strategy = :raise
      config.action_guard_nil_user_strategy = nil # follows nil_user_strategy
      config.mask_virtual_attributes = true
      config.cache_backend = ActiveSupport::Cache::MemoryStore.new

      assert_empty config.options_looser_than_strict

      config.cache_backend = :memory
      config.mask_virtual_attributes = ['Customer']
      assert_equal({ cache_backend: :memory, mask_virtual_attributes: ['Customer'] }, config.options_looser_than_strict)
    end

    test 'a strategy given as a String is not reported as looser than its Symbol' do
      config.preset = :strict
      config.unconfigured_field_strategy = 'block'
      config.response_filter_nil_user_strategy = 'block'

      assert_empty config.options_looser_than_strict
    end

    test 'a preset set outside configure rebuilds a cache store it changes, and only then' do
      assert_kind_of PermissionForge::Cache::MemoryCache, config.cache_store
      config.preset = :strict
      store = config.cache_store
      assert_kind_of PermissionForge::Cache::RailsCache, store

      config.preset = :strict
      assert_same store, config.cache_store, 'the backend did not change'
    end

    # The suite's configuration sets cache_backend itself: start from a new one
    # (the test helper puts the suite's back).
    test 'PermissionForge.configure applies a preset, and the cache store follows it' do
      PermissionForge.reset!
      PermissionForge.configure { |c| c.preset = :strict }

      assert_equal :deny, PermissionForge.configuration.nil_user_strategy
      assert_kind_of PermissionForge::Cache::RailsCache, PermissionForge.cache
    end

    # --- the README checklist ----------------------------------------------------

    # So the preset and the README's "Production hardening checklist" cannot
    # drift: :strict closes exactly the fail-open rows a setting can close,
    # with the value the README names, and keeps the "already closed" ones.
    test ':strict closes exactly the README hardening checklist' do
      rows = checklist_rows
      closed_by_strict = Presets::STRICT.reject { |option, value| Presets::COMPAT[option] == value }

      assert_equal (rows.keys - HOST_SUPPLIED - Presets::OPT_IN).sort, closed_by_strict.keys.sort
      closed_by_strict.each do |option, value|
        default, to_close = rows.fetch(option)
        assert_equal Presets::COMPAT[option].inspect, default, "README default of #{option}"
        assert_includes to_close, "`#{value.inspect}`", "README closing value of #{option}"
      end
    end

    # Masking with nobody signed in: :strict hides guarded attributes in web
    # requests with nobody signed in (:hide_in_requests) and keeps the stored
    # values for jobs and the console; :hide, which hides there too, is as
    # closed. The library default stays :bypass.
    test ':strict sets masking with nobody signed in to :hide_in_requests; :hide counts as closed' do
      assert_equal :bypass, config.masked_attributes_nil_user_strategy, 'library default'
      assert_includes checklist_rows.keys, :masked_attributes_nil_user_strategy
      assert_empty Presets::OPT_IN

      config.preset = :strict
      assert_equal :hide_in_requests, config.masked_attributes_nil_user_strategy
      config.masked_attributes_nil_user_strategy = :hide
      assert_empty config.options_looser_than_strict
      config.masked_attributes_nil_user_strategy = 'bypass'
      assert_equal({ masked_attributes_nil_user_strategy: :bypass }, config.options_looser_than_strict)
    end

    test ':strict keeps closed what the README says is closed by default' do
      already_closed = readme_section[/^Already closed by default.*?(?=\n\n)/m].scan(/`(\w+) = ([^`]+)`/).to_h
      kept = Presets::STRICT.select { |option, value| Presets::COMPAT[option] == value }

      # Turning the API on is a feature, not a weakening: no preset decides it.
      assert_equal already_closed.keys.map(&:to_sym).sort - %i[api_enabled], kept.keys.sort
      kept.each { |option, value| assert_equal value.inspect, already_closed.fetch(option.to_s), option }
    end

    # Issue #10: closed by default since 0.15, in every preset; :allow is the
    # host's opt-out, and :strict reports it as an override.
    test 'unmanaged controller actions are refused under every preset, and :allow is an explicit override' do
      assert_equal :block, config.unconfigured_action_strategy
      assert_equal :block, Presets::COMPAT.fetch(:unconfigured_action_strategy)
      assert_equal :block, Presets::STRICT.fetch(:unconfigured_action_strategy)

      config.preset = :strict
      config.unconfigured_action_strategy = :allow
      config.preset = :compat

      assert_equal :allow, config.unconfigured_action_strategy, 'an explicit :allow survives a preset'
      config.preset = :strict
      assert_equal({ unconfigured_action_strategy: :allow }, config.options_looser_than_strict)
    end

    # --- SecurityAudit -------------------------------------------------------------

    test 'the security audit reports the preset' do
      report = Services::SecurityAudit.call(configuration: config, environment: 'test')
      assert_equal :compat, report.preset
      assert_equal :compat, report.to_h[:preset]
      assert_match 'Preset: :compat', Services::SecurityAuditChecks::TextReport.new(report).to_s
      assert_not_includes report.findings.map(&:code), :strict_overrides

      config.preset = :strict
      report = Services::SecurityAudit.call(configuration: config, environment: 'test')
      assert_equal :strict, report.preset
      assert_match "Preset: :strict\n", Services::SecurityAuditChecks::TextReport.new(report).to_s
      assert_not_includes report.findings.map(&:code), :strict_overrides
    end

    test 'under :strict the security audit names every option set looser than the preset' do
      config.preset = :strict
      config.response_filter_nil_user_strategy = :bypass
      config.cache_backend = :memory
      finding = Services::SecurityAudit.call(configuration: config, environment: 'test')
                                       .findings.find { |f| f.code == :strict_overrides }

      assert_equal :low, finding.severity
      assert_equal ['response_filter_nil_user_strategy = :bypass (strict: :block)', 'cache_backend = :memory (strict: :rails_cache)'],
                   finding.items
      assert_match '2 options are set to a looser value', finding.detail
    end

    # --- Settings page -------------------------------------------------------------

    test 'the Settings page shows the preset' do
      PermissionForge.configuration.preset = :strict
      row = Admin::SettingsCatalog.new.row(:preset)

      assert_equal 'strict', row.value.to_s
      assert_equal 'compat', row.default.to_s
      assert_predicate row, :ok?
      assert_predicate row, :changed?
    end

    test 'the Settings page flags an explicit :allow for unmanaged controller actions' do
      assert_predicate Admin::SettingsCatalog.new.row(:unconfigured_action_strategy), :ok?

      PermissionForge.configuration.unconfigured_action_strategy = :allow
      row = Admin::SettingsCatalog.new.row(:unconfigured_action_strategy)

      assert_predicate row, :warn?
      assert_equal ':block', row.recommended
      assert_equal 'block', row.default.to_s
    end

    # --- the generated initializer ---------------------------------------------------

    # The safe subset is written explicitly; the preset is offered commented,
    # with what it costs.
    test 'a new install gets the safe subset explicitly and :strict offered, not active' do
      generated = install_template_configuration
      source = render_install_template('initializer.rb.tt')

      assert_equal :compat, generated.preset
      assert_equal :deny, generated.action_guard_nil_user_strategy
      assert_equal true, generated.conditional_sets_strict_mode
      assert_equal :rails_cache, generated.cache_backend
      assert_equal :bypass, generated.nil_user_strategy, 'library default'
      assert_equal :hide_in_requests, generated.masked_attributes_nil_user_strategy, 'set explicitly: hidden in web requests'
      assert generated.explicitly_set?(:masked_attributes_nil_user_strategy)
      assert_equal :block, generated.unconfigured_action_strategy, 'library default'
      assert_includes source.lines,
                      "  # So, by default, is any guarded action no Permission Set manages (opt out: config.unconfigured_action_strategy = :allow).\n"
      assert_match(/^  # config\.preset = :strict$/, source)
      assert_match(/belongs_to presence check/, source)
      assert_match(/Never include PermissionScopedFindable in the user model/, source)
    end

    test 'the generated initializer is short and links to the full reference' do
      source = render_install_template('initializer.rb.tt', tenant_model: 'Account')

      assert_operator source.lines.size, :<, 150
      assert_includes source, 'docs/configuration.md'
      assert_includes source, '#production-hardening-checklist'
    end

    private

    def readme_section
      File.read(README)[/^## Production hardening checklist\n(.*?)^## /m, 1] || flunk('no hardening checklist in README.md')
    end

    # option => [default as written, "To close it" cell]
    def checklist_rows
      readme_section.lines.grep(/\A\| `/).to_h do |row|
        cells = row.split('|').map(&:strip)
        option, default = cells[1].match(/\A`(\w+)(?: = ([^`]+))?`/).captures
        [option.to_sym, [default, cells[3]]]
      end
    end
  end
end
