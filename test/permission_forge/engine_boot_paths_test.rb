require 'test_helper'
require_relative '../support/boot_test_helpers'

module PermissionForge
  # Exercises the boot checks (BootChecks, MaskedModels) and the warning
  # paths that never fire under the test-environment defaults: the
  # engine's after_initialize hook body (production
  # MemoryCache warning, blank HTTP Basic Auth credentials warning), the GDPR
  # unmasked-field warning, the DatabaseReach failure branches, the raising
  # request_context_resolver rescue, and candidate-model resolution branches.
  #
  # Complements engine_warnings_test.rb — that file simulates the boot warnings;
  # this file invokes the real engine code paths directly.
  class EngineBootPathsTest < ActiveSupport::TestCase
    include BootTestHelpers

    BASIC_AUTH_WARNING = /HTTP Basic Auth is enabled but credentials are not configured/

    # --- the engine only wires hooks -----------------------------------------

    test 'the engine carries no boot, masking or warning logic, and nothing reaches into it' do
      domain = [BootChecks, CacheWarnings, MaskedModels, MaskingSync, QueryScopingWarnings]

      assert_empty PermissionForge::Engine.singleton_class.ancestors & domain
      # apply_masked_attributes_to_managed_models was a deprecated delegator
      # to MaskedModels.apply through 0.14; 0.15 removed it.
      %i[run_boot_checks apply_tenant_scoping_to_models permission_models
         apply_masked_attributes_to_managed_models].each do |name|
        assert_not PermissionForge::Engine.respond_to?(name, true), name
      end
      sources = Dir[PermissionForge::Engine.root.join('{app,lib}/**/*.{rb,rake}').to_s]
      assert_empty(sources.select { |path| File.read(path).match?(/Engine\.send\(/) })
    end

    # --- DatabaseReach (the boot ping) ----------------------------------------

    test 'DatabaseReach.problem is nil when the database answers' do
      assert_nil PermissionForge::DatabaseReach.problem
    end

    test 'DatabaseReach.problem names what connecting raised when the connection cannot be established' do
      pool = Object.new
      def pool.with_connection = raise(ActiveRecord::ConnectionNotEstablished, 'no pool')

      with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
        assert_instance_of ActiveRecord::ConnectionNotEstablished, PermissionForge::DatabaseReach.problem
      end
    end

    # Rails 7.2+ hands out a connection that has not connected yet: only
    # verify! finds out that the database is not there.
    test 'DatabaseReach.problem names what connecting raised when the connection it is handed cannot verify' do
      lazy = Object.new
      def lazy.verify! = raise(ActiveRecord::DatabaseConnectionError, 'There is an issue connecting')
      pool = Object.new
      pool.define_singleton_method(:with_connection) { |&block| block.call(lazy) }

      with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
        assert_instance_of ActiveRecord::DatabaseConnectionError, PermissionForge::DatabaseReach.problem
      end
    end

    # Field test round 8 (E#7): the sqlite3 adapter refuses a configuration
    # without a database file with an ArgumentError (a `rails new
    # --skip-kamal` production database.yml), a database configuration
    # without an adapter is an AdapterNotSpecified. Each means "no database
    # here", none aborts a boot.
    test 'DatabaseReach.problem counts an adapter that refuses its configuration as no database' do
      refusals = [ArgumentError.new('No database file specified. Missing argument: database'),
                  ActiveRecord::AdapterNotSpecified.new('database configuration does not specify adapter'),
                  ActiveRecord::NoDatabaseError.new('database does not exist')]
      refusals.each do |refusal|
        pool = Object.new
        pool.define_singleton_method(:with_connection) { |&_block| raise refusal }

        with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
          assert_same refusal, PermissionForge::DatabaseReach.problem, refusal.class.name
        end
      end
    end

    test 'DatabaseReach.problem lets any other error through: it is a bug, not a missing database' do
      pool = Object.new
      def pool.with_connection = raise(NoMethodError, 'undefined method')

      with_singleton_method(PermissionForge::PermissionSet, :connection_pool, -> { pool }) do
        assert_raises(NoMethodError) { PermissionForge::DatabaseReach.problem }
      end
    end

    test 'DatabaseReach.table_exists? is false for a model whose database is not configured' do
      model = Class.new
      def model.table_exists? = raise(ArgumentError, 'No database file specified. Missing argument: database')

      assert_not PermissionForge::DatabaseReach.table_exists?(model)
      assert PermissionForge::DatabaseReach.table_exists?(PermissionForge::Resource)
    end

    # The read of the Resource rows on every request or job of a process
    # that has not synced (MaskingSync.check!): through 0.15.0-rc an
    # ArgumentError from connecting reached check!, which logged a SECURITY
    # warning on every run of a runner with no database configured.
    test 'MaskedModels.apply answers false, without raising, when the database is not configured' do
      unconfigured = -> { raise ArgumentError, 'No database file specified. Missing argument: database' }

      with_singleton_method(PermissionForge::Resource, :table_exists?, unconfigured) do
        assert_equal false, PermissionForge::MaskedModels.apply
      end
    end

    # Review of round 8: a fresh `rails new` app's production cache store is
    # Solid Cache, whose database is not configured either; reading the
    # masking token raised the same ArgumentError, logged as a SECURITY
    # store failure at every executor run of a production runner.
    test 'a process that has not synced and cannot use its database does not read the masking token' do
      PermissionForge::MaskingSync.reset!
      unconfigured = -> { raise ArgumentError, 'No database file specified. Missing argument: database' }

      log = with_singleton_method(PermissionForge::Resource, :table_exists?, unconfigured) do
        with_singleton_method(PermissionForge.cache, :read_fresh, ->(*) { flunk 'read the masking token' }) do
          capture_rails_log { PermissionForge::MaskingSync.check! }
        end
      end

      assert_not_includes log, '[PermissionForge]'
      assert_not PermissionForge::MaskingSync.synced?, 'tried again at the next request or job'
    end

    test 'a model whose table check raises is named with the error in the unmaskable warning' do
      klass = Class.new(ActiveRecord::Base) { self.table_name = 'customers' }
      Object.const_set(:PfUnreadableTableProbe, klass)
      PermissionForge::MaskedModels.reset_warnings!
      unconfigured = -> { raise ArgumentError, 'No database file specified. Missing argument: database' }

      log = with_singleton_method(klass, :table_exists?, unconfigured) do
        capture_rails_log { assert_equal false, PermissionForge::MaskedModels.apply_concern('PfUnreadableTableProbe') }
      end

      assert_match(/PfUnreadableTableProbe has a Resource row but its table cannot be read \(ArgumentError: No database file specified/, log)
    ensure
      Object.send(:remove_const, :PfUnreadableTableProbe) if Object.const_defined?(:PfUnreadableTableProbe, false)
    end

    # Audit.table_available? under audit_events :auto, on the record path: a
    # database that does not answer or does not exist is "unchecked"
    # (nothing recorded, one SECURITY warning), as it always was; a
    # configuration error of the check (an ArgumentError, AdapterNotFound)
    # raises, so under audit_change_failure_strategy :raise the change rolls
    # back instead of committing without its event (review of round 8).
    test 'a configuration error of the audit table check rolls the change back; a database gone is unchecked' do
      PermissionForge.configuration.audit_events = :auto
      PermissionForge.configuration.audit_change_failure_strategy = :raise
      [ArgumentError.new('No database file specified. Missing argument: database'),
       ActiveRecord::AdapterNotFound.new('no adapter')].each do |error|
        PermissionForge::Audit.reset!
        with_singleton_method(PermissionForge::AuditEvent, :table_exists?, -> { raise error }) do
          assert_no_difference -> { PermissionForge::PermissionSet.count }, error.class.name do
            assert_raises(error.class) { create_permission_set(name: "Probe #{error.class}") }
          end
        end
      end

      PermissionForge::Audit.reset!
      gone = -> { raise ActiveRecord::NoDatabaseError, 'database does not exist' }
      log = with_singleton_method(PermissionForge::AuditEvent, :table_exists?, gone) do
        capture_rails_log { assert_equal false, PermissionForge::Audit.enabled? }
      end
      assert_match(/cannot check for the audit table '.*' \(ActiveRecord::NoDatabaseError\)/, log)
    ensure
      PermissionForge::Audit.reset!
    end

    # --- asset_build? ---------------------------------------------------------

    test 'asset_build? is true only when every task Rake was asked for is an asset task' do
      require 'rake'
      application = Rake::Application.new
      with_singleton_method(Rake, :application, -> { application }) do
        { %w[assets:precompile] => true, %w[assets:clean assets:clobber] => true,
          ['assets:precompile[now]'] => true, %w[assets:precompile db:seed] => false,
          %w[db:migrate] => false, [] => false }.each do |tasks, expected|
          application.instance_variable_set(:@top_level_tasks, tasks)

          assert_equal expected, PermissionForge::BootChecks.asset_build?, tasks.inspect
        end
      end
    end

    test 'BootChecks.run runs the configuration checks of an asset build and never pings the database' do
      PermissionForge.configuration.http_basic_auth_enabled = true

      log = with_singleton_method(PermissionForge::BootChecks, :asset_build?, -> { true }) do
        with_singleton_method(PermissionForge::DatabaseReach, :problem, ->(*) { flunk 'pinged the database' }) do
          with_singleton_method(PermissionForge::MaskingSync, :boot!, -> { flunk 'synced masking' }) do
            capture_rails_log { PermissionForge::BootChecks.run(PermissionForge.configuration) }
          end
        end
      end

      assert_match BASIC_AUTH_WARNING, log
      assert_not_includes log, 'could not be reached'
      assert_not PermissionForge::MaskingSync.synced?, 'the first request or job applies masking'
    end

    # --- BootChecks.run ---------------------------------------------------------

    test 'BootChecks.run skips every database step when the database cannot be reached' do
      refused = ActiveRecord::ConnectionNotEstablished.new('connection refused')
      log = with_singleton_method(PermissionForge::BootChecks, :database_problem, -> { refused }) do
        with_singleton_method(PermissionForge::PermissionSet, :conditional, -> { flunk 'read the database' }) do
          capture_rails_log { PermissionForge::BootChecks.run(PermissionForge.configuration) }
        end
      end

      assert_equal 1, log.scan("The database could not be reached at boot, or the gem's models could not be loaded " \
                               '(ActiveRecord::ConnectionNotEstablished: connection refused)').size, log
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

    # Field test round 5 (a #120): the install generator's own boot logged
    # warnings about the defaults (cache_backend :memory, Basic Auth without
    # credentials) next to the initializer it had just written.
    test 'BootChecks.run checks and logs nothing while a generator boots the app' do
      PermissionForge.configuration.cache_backend = :memory
      PermissionForge.configuration.http_basic_auth_enabled = true
      create_resource(permission_set: create_permission_set, name: 'Supplier')

      log = with_singleton_method(PermissionForge::BootChecks, :generator_running?, -> { true }) do
        with_singleton_method(PermissionForge::BootChecks, :database_problem, -> { flunk 'pinged the database' }) do
          with_singleton_method(PermissionForge::MaskingSync, :boot!, -> { flunk 'synced masking' }) do
            capture_rails_log { PermissionForge::BootChecks.run(PermissionForge.configuration) }
          end
        end
      end

      assert_not_includes log, '[PermissionForge]'
      assert_not PermissionForge::MaskingSync.synced?, 'the first request or job applies masking'
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
      assert_match(/matches the GDPR pattern '[a-z_]+' but is not masked/, log)
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

      log = nil
      capture_io { log = capture_rails_log { hook.call(Rails.application) } } # production, no server: standard error too

      assert_match(/in-process permission cache in production/, log)
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
      assert_no_match(/in-process permission cache in production/, log)
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
