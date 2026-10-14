require 'test_helper'
require_relative '../support/boot_test_helpers'

module PermissionForge
  # Exercises the boot checks (BootChecks, MaskedModels) and the warning
  # paths that never fire under the test-environment defaults: the
  # engine's after_initialize hook body (production
  # MemoryCache warning, blank HTTP Basic Auth credentials warning), the GDPR
  # unmasked-field warning, the db_available? failure branch, the raising
  # request_context_resolver rescue, and candidate-model resolution branches.
  #
  # Complements engine_warnings_test.rb — that file simulates the boot warnings;
  # this file invokes the real engine code paths directly.
  class EngineBootPathsTest < ActiveSupport::TestCase
    include BootTestHelpers

    BASIC_AUTH_WARNING = /HTTP Basic Auth is enabled but credentials are not configured/

    test 'Engine.apply_masked_attributes_to_managed_models still works, deprecated' do
      calls = []
      original = MaskedModels.method(:apply)
      replace_singleton_method(MaskedModels, :apply) do |only: nil|
        calls << only
        true
      end

      Deprecation.reset! # it warns once per process
      result, warnings = collect_deprecations(PermissionForge.deprecator) do
        PermissionForge::Engine.apply_masked_attributes_to_managed_models(only: 'Customer')
      end
      assert_equal 1, warnings.size
      assert_match(/MaskedModels\.apply.*PermissionForge #{Regexp.escape(Deprecation::HORIZON)} removes it/, warnings.first)
      assert_match(/called from .*#{Regexp.escape(File.basename(__FILE__))}/, warnings.first, 'it names the caller, not the delegator')
      assert_equal true, result
      assert_equal ['Customer'], calls
    ensure
      replace_singleton_method(MaskedModels, :apply, original)
    end

    # --- the engine only wires hooks -----------------------------------------

    test 'the engine carries no boot, masking or warning logic, and nothing reaches into it' do
      domain = [BootChecks, MaskedModels, MaskingSync, QueryScopingWarnings]

      assert_empty PermissionForge::Engine.singleton_class.ancestors & domain
      # apply_masked_attributes_to_managed_models stays one minor version, as
      # a deprecated delegator (Q8; test below).
      %i[run_boot_checks apply_tenant_scoping_to_models permission_models].each do |name|
        assert_not PermissionForge::Engine.respond_to?(name, true), name
      end
      sources = Dir[PermissionForge::Engine.root.join('{app,lib}/**/*.{rb,rake}').to_s]
      assert_empty(sources.select { |path| File.read(path).match?(/Engine\.send\(/) })
    end

    # --- db_available? ------------------------------------------------------

    test 'db_available? returns true when the connection is established' do
      assert PermissionForge::BootChecks.send(:db_available?)
    end

    test 'db_available? returns false when the connection cannot be established' do
      pool = Object.new
      def pool.with_connection = raise(ActiveRecord::ConnectionNotEstablished, 'no pool')

      with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
        refute PermissionForge::BootChecks.send(:db_available?)
      end
    end

    # Rails 7.2+ hands out a connection that has not connected yet: only
    # verify! finds out that the database is not there.
    test 'db_available? returns false when the connection it is handed cannot verify' do
      lazy = Object.new
      def lazy.verify! = raise(ActiveRecord::DatabaseConnectionError, 'There is an issue connecting')
      pool = Object.new
      pool.define_singleton_method(:with_connection) { |&block| block.call(lazy) }

      with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
        refute PermissionForge::BootChecks.send(:db_available?)
      end
    end

    # --- BootChecks.run ---------------------------------------------------------

    test 'BootChecks.run skips every database step when the database cannot be reached' do
      log = with_singleton_method(PermissionForge::BootChecks, :db_available?, -> { false }) do
        with_singleton_method(PermissionForge::PermissionSet, :conditional, -> { flunk 'read the database' }) do
          capture_rails_log { PermissionForge::BootChecks.run(PermissionForge.configuration) }
        end
      end

      assert_equal 1, log.scan('The database could not be reached at boot').size, log
    end

    test 'a boot step that loses the database is skipped and the next steps still run' do
      create_resource(permission_set: create_permission_set, name: 'Supplier')
      applied = []
      lost = -> { raise ActiveRecord::DatabaseConnectionError, 'There is an issue connecting' }

      log = with_singleton_method(PermissionForge::PermissionSet, :conditional, lost) do
        with_singleton_method(PermissionForge::MaskedModels, :apply_concern, ->(name) { applied << name }) do
          capture_rails_log { PermissionForge::BootChecks.run(PermissionForge.configuration) }
        end
      end

      assert_match(/Boot check conditional_sets skipped: .*DatabaseConnectionError/, log)
      assert_includes applied, 'Supplier', 'the masking step after the failed one must still run'
    end

    test 'a configuration error still stops the boot' do
      error = Class.new(PermissionForge::ConfigurationError)
      raising = -> { raise error, 'misconfigured' }

      with_singleton_method(PermissionForge::QueryScopingWarnings, :warn_join_rules_not_auto_scoped, ->(_) { raising.call }) do
        assert_raises(error) { PermissionForge::BootChecks.run(PermissionForge.configuration) }
      end
    end

    # --- warn_conditional_sets_without_context ------------------------------

    test 'a raising request_context_resolver is treated as empty context and warns' do
      create_permission_set(requires_session_flag: 'marketing_consent')
      PermissionForge.configuration.request_context_resolver = -> { raise StandardError, 'resolver exploded' }

      log = capture_rails_log do
        PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)
      end

      assert_match(/activation conditions/, log)
      assert_match(/ALWAYS ACTIVE/, log)
    end

    # --- warn_unmasked_gdpr_fields ------------------------------------------

    test 'warn_unmasked_gdpr_fields warns only once even with multiple unmasked GDPR fields' do
      permission_set = create_permission_set
      resource = create_resource(permission_set: permission_set, name: 'Customer')
      create_resource_field(resource: resource, name: 'email', label: 'Email',
                            read_access: true, mask_access: false)
      create_resource_field(resource: resource, name: 'phone_number', label: 'Phone',
                            read_access: true, mask_access: false)

      log = capture_rails_log do
        PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration)
      end

      assert_match(/GDPR warning/, log)
      assert_match(/matches GDPR pattern but is not masked/, log)
      assert_equal 1, log.scan('GDPR warning').count, 'must break after the first warning to avoid flooding'
    end

    test 'warn_unmasked_gdpr_fields stays silent when unmasked fields match no GDPR pattern' do
      permission_set = create_permission_set
      resource = create_resource(permission_set: permission_set, name: 'Customer')
      create_resource_field(resource: resource, name: 'notes', label: 'Notes',
                            read_access: true, mask_access: false)

      log = capture_rails_log do
        PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration)
      end

      assert_no_match(/GDPR warning/, log)
    end

    test 'warn_unmasked_gdpr_fields reads names only: one query when nothing matches' do
      resource = create_resource(permission_set: create_permission_set, name: 'Customer')
      12.times do |i|
        create_resource_field(resource: resource, name: "notes_#{i}", label: 'Notes', read_access: true,
                              mask_access: false)
      end

      statements = count_sql do
        capture_rails_log { PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration) }
      end

      assert_equal 1, statements
    end

    test 'warn_unmasked_gdpr_fields is a no-op when gdpr_field_patterns is blank' do
      original_patterns = PermissionForge.configuration.gdpr_field_patterns
      PermissionForge.configuration.gdpr_field_patterns = {}

      permission_set = create_permission_set
      resource = create_resource(permission_set: permission_set, name: 'Customer')
      create_resource_field(resource: resource, name: 'email', label: 'Email',
                            read_access: true, mask_access: false)

      log = capture_rails_log do
        PermissionForge::BootChecks.warn_unmasked_gdpr_fields(PermissionForge.configuration)
      end

      assert_no_match(/GDPR warning/, log)
    ensure
      PermissionForge.configuration.gdpr_field_patterns = original_patterns
    end

    # --- MaskedModels.model_names / resource_names ---------------------------

    test 'model_names uses the explicit allowlist when no only: constraint is given' do
      names = PermissionForge::MaskedModels.send(:model_names, ['Supplier'], only: nil)
      assert_equal ['Supplier'], names
    end

    test 'MaskedModels.apply tolerates unknown names in an allowlist' do
      PermissionForge.configuration.auto_apply_masked_attributes = ['NoSuchModelXyz']
      assert_nothing_raised do
        PermissionForge::MaskedModels.apply
      end
    ensure
      PermissionForge.configuration.auto_apply_masked_attributes = :auto
    end

    test 'resource_names queries resources directly when tenant scoping is disabled' do
      permission_set = create_permission_set
      create_resource(permission_set: permission_set, name: 'Supplier')

      PermissionForge.configuration.tenant_model = nil
      names = PermissionForge::MaskedModels.send(:resource_names)

      assert_includes names, 'Supplier'
    ensure
      PermissionForge.configuration.tenant_model = 'Account'
    end

    # --- after_initialize hook body ------------------------------------------

    test 'after_initialize hook warns about MemoryCache in production and blank basic auth credentials' do
      hook = engine_after_initialize_hook
      original_env = Rails.env
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new('production'))
      PermissionForge.configuration.cache_backend = :memory
      PermissionForge.configuration.http_basic_auth_enabled = true
      PermissionForge.configuration.http_basic_auth_user = nil
      PermissionForge.configuration.http_basic_auth_password = nil

      log = capture_rails_log { hook.call(Rails.application) }

      assert_match(/MemoryCache in production/, log)
      assert_match(BASIC_AUTH_WARNING, log)
      assert_match(/config\.http_basic_auth_user and config\.http_basic_auth_password/, log)
    ensure
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new(original_env.to_s))
      PermissionForge.configuration.cache_backend = :memory
      PermissionForge.configuration.http_basic_auth_enabled = false
      PermissionForge.configuration.http_basic_auth_user = nil
      PermissionForge.configuration.http_basic_auth_password = nil
    end

    test 'after_initialize hook does not warn when basic auth credentials are configured' do
      hook = engine_after_initialize_hook
      PermissionForge.configuration.http_basic_auth_enabled = true
      PermissionForge.configuration.http_basic_auth_user = 'admin'
      PermissionForge.configuration.http_basic_auth_password = 'secret'

      log = capture_rails_log { hook.call(Rails.application) }

      assert_no_match(BASIC_AUTH_WARNING, log)
      assert_no_match(/MemoryCache in production/, log)
    ensure
      PermissionForge.configuration.http_basic_auth_enabled = false
      PermissionForge.configuration.http_basic_auth_user = nil
      PermissionForge.configuration.http_basic_auth_password = nil
    end

    private

    # The engine registers its post-boot checks via `config.after_initialize`,
    # which stores the block in ActiveSupport's lazy load hook registry. Fetch
    # that exact block so the real code path (not a simulation) is exercised.
    def engine_after_initialize_hook
      hooks = ActiveSupport.instance_variable_get(:@load_hooks)[:after_initialize]
      entry = hooks.find do |block, _options|
        block.source_location&.first&.end_with?('lib/permission_forge/engine.rb')
      end
      assert entry, 'engine after_initialize hook not found in the load hooks registry'
      entry.first
    end
  end
end
