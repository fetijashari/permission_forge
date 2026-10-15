require 'simplecov'
SimpleCov.start do
  skip '/test/'
  skip '/lib/generators/'
  # The coverage gate applies to the canonical SQLite run; the Postgres RLS
  # suite (DB=postgres rake test:rls) exercises a narrow slice by design.
  minimum_coverage ENV['DB'] == 'postgres' ? 0 : 85
  # The parallel workers (support/parallel_workers.rb) are forks: each
  # stores its own result, and this process merges them.
  respond_to?(:merge_subprocesses) ? merge_subprocesses(true) : enable_for_subprocesses(true)
end
# Each run reports its own coverage: without this, a run merged the results
# an earlier run (its workers, another entry point) left within
# merge_timeout. Only this process runs it; the workers fork later and still
# merge into this run's report.
FileUtils.rm_f(SimpleCov::ResultMerger.resultset_path)

ENV['RAILS_ENV'] = 'test'

require_relative 'dummy/config/environment'

# When DB=postgres or DB=mysql, create the test database on first run —
# rails/test_help's maintain_test_schema! connects immediately, before the
# schema load below.
if %w[postgres mysql].include?(ENV['DB'])
  begin
    ActiveRecord::Base.connection.execute('SELECT 1')
  rescue ActiveRecord::NoDatabaseError
    ActiveRecord::Tasks::DatabaseTasks.create_current
    ActiveRecord::Base.establish_connection(:test)
  end
end

require 'rails/test_help'

# Load schema
ActiveRecord::Schema.verbose = false
load File.expand_path('dummy/db/schema.rb', __dir__)

# Configure PermissionForge for tests: the suite's base configuration, which
# every test starts from (ConfigurationSnapshot below). Options not set here
# keep the library defaults.
PermissionForge.configure do |config|
  config.tenant_model = 'Account'
  config.user_class = 'User'
  config.current_user_resolver = -> { Current.user }
  config.user_active_check = lambda(&:active_for_authentication?)
  config.cache_backend = :memory
  config.table_name_prefix = ''
  config.audit_trail_enabled = false
  config.http_basic_auth_enabled = false
  config.gdpr_defaults = false
  config.api_enabled = true
  config.api_auth = ->(_controller) { true }
  # Not the shipped defaults (the child-process install tests cover those):
  config.api_require_authorization = false
  config.api_stats_require_admin = false
  config.unconfigured_field_strategy = :warn
  config.filter_parameters_integration = false
end

# Tenancy is on from here: scope the models already loaded (TestModels)
require_relative 'support/test_models'
PermissionForge::TestModels.apply_tenant_scoping!

require_relative 'support/install_templates'
require_relative 'support/method_stubs'
require_relative 'support/text_key_models'
require_relative 'support/local_redis'

# Set default test tenant (acts_as_tenant test_tenant persists across request threads)
DEFAULT_TEST_ACCOUNT = Account.find_or_create_by!(name: 'Default Test Account')
ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT

# Snapshot of the base configuration (with its cache store built) and the
# logger, restored after every test.
require_relative 'support/configuration_snapshot'
PermissionForge.cache
ConfigurationSnapshot.take!
SUITE_LOGGER = Rails.logger

require_relative 'support/parallel_workers'

module ActiveSupport
  class TestCase
    self.use_transactional_tests = true

    # Forked workers on SQLite with Rails >= 8.1 (support/parallel_workers.rb);
    # serial on PostgreSQL, MySQL and older Rails.
    if ParallelWorkers.enabled? && ActiveSupport.respond_to?(:parallelize_test_databases=)
      ActiveSupport.parallelize_test_databases = false
      parallelize(workers: ParallelWorkers::DEFAULT)
      parallelize_before_fork { ParallelWorkers.save_database }
      parallelize_setup { |_worker| ParallelWorkers.load_database }
      Minitest.after_run { ParallelWorkers.remove_database }
    end

    include InstallTemplates
    include MethodStubs

    # The suite's configuration and logger are put back before every test as
    # well as after it: a subclass teardown that raises stops the teardown
    # callbacks before the base restore runs. Then the state outside the
    # configuration that a test may leave behind is cleared, each line naming
    # what it forgets.
    setup do
      ConfigurationSnapshot.restore!
      Rails.logger = SUITE_LOGGER unless Rails.logger.equal?(SUITE_LOGGER)
      PermissionForge.cache.clear # cached hashes, stamps, the managed-actions index
      PermissionForge::Cache::Invalidation.reset! # invalidations owed to a store
      PermissionForge::Cache::WithheldNotice.reset! # the "rebuilt inside a transaction" notice
      PermissionForge::Audit.reset! # the audit table check, context and runtime memory
      PermissionForge::ExecutionState.reset! # every ExecutionState slot (without_permission_scope included)
      I18n.locale = I18n.default_locale
      Current.reset if defined?(Current)
      ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT if defined?(ActsAsTenant)
      ActsAsTenant.configuration.require_tenant = false if defined?(ActsAsTenant)
    end

    # The suite's configuration and logger, put back after every test
    # (support/configuration_snapshot.rb).
    teardown do
      ConfigurationSnapshot.restore!
      Rails.logger = SUITE_LOGGER unless Rails.logger.equal?(SUITE_LOGGER)
    end

    private

    # The last audit event named `event` whose columns match `attrs` (a
    # `data:` Hash matches when every given key matches). Fails with the
    # events of that name it did find.
    #
    #   assert_audit_event('assignment.revoked', subject_user_id: user.id.to_s, actor_label: 'Ada')
    def assert_audit_event(event, **attrs)
      events = PermissionForge::AuditEvent.where(event: event.to_s).order(:id).to_a
      match = events.reverse.find { |candidate| audit_event_matches?(candidate, attrs) }
      assert match, "no #{event} event matching #{attrs.inspect}; found: #{audit_events_summary(events, attrs)}"
      match
    end

    def audit_event_matches?(event, attrs)
      attrs.all? do |key, expected|
        actual = event.public_send(key)
        key == :data ? expected.as_json.all? { |name, value| actual[name] == value } : actual == expected
      end
    end

    def audit_events_summary(events, attrs)
      columns = ['id', *attrs.keys.map(&:to_s)]
      "#{events.size} #{events.map { |candidate| candidate.attributes.slice(*columns) }.inspect}"
    end

    # The events about a record (oldest first), or of an event name.
    def audit_events_for(subject)
      scope = PermissionForge::AuditEvent.order(:id)
      subject.is_a?(ActiveRecord::Base) ? scope.for_record(subject) : scope.where(event: subject.to_s)
    end

    # Helper to create records (replaces FactoryBot)
    def create_user(attrs = {})
      User.create!({
        uuid: SecureRandom.uuid,
        name: 'Test User',
        email: "user_#{SecureRandom.hex(4)}@example.com",
        deactivated: false
      }.merge(attrs))
    end

    def create_customer(attrs = {})
      Customer.create!({
        uuid: SecureRandom.uuid,
        name: 'Test Customer',
        email: "customer_#{SecureRandom.hex(4)}@example.com",
        domain: 'example.com'
      }.merge(attrs))
    end

    # Set names are unique per tenant: without a name, the first free
    # "Test Permission Set", "Test Permission Set 2", ...
    def create_permission_set(attrs = {})
      PermissionForge::PermissionSet.create!({
        uuid: SecureRandom.uuid,
        name: attrs.key?(:name) ? nil : PermissionForge::PermissionSet.unique_name('Test Permission Set'),
        description: 'A test permission set',
        is_active: true,
        is_editable: true
      }.merge(attrs))
    end

    def create_permission_set_group(attrs = {})
      PermissionForge::PermissionSetGroup.create!({
        uuid: SecureRandom.uuid,
        name: 'Test Group',
        description: 'A test group',
        is_active: true,
        is_editable: true
      }.merge(attrs))
    end

    def create_permission_set_user(user:, permission_set:, **attrs)
      PermissionForge::PermissionSetUser.create!({
        uuid: SecureRandom.uuid,
        user: user,
        permission_set: permission_set
      }.merge(attrs))
    end

    def create_resource(permission_set:, **attrs)
      PermissionForge::Resource.create!({
        uuid: SecureRandom.uuid,
        name: 'Customer',
        permission_set: permission_set,
        is_active: true,
        is_editable: true,
        read_access: true,
        create_access: false,
        edit_access: false,
        delete_access: false
      }.merge(attrs))
    end

    def create_resource_field(resource:, **attrs)
      PermissionForge::ResourceField.create!({
        uuid: SecureRandom.uuid,
        name: 'name',
        label: 'Name',
        resource: resource,
        is_active: true,
        is_editable: true,
        read_access: true,
        edit_access: false
      }.merge(attrs))
    end

    def create_supplier(attrs = {})
      Supplier.create!({
        uuid: SecureRandom.uuid,
        name: 'Test Supplier'
      }.merge(attrs))
    end

    def create_resource_action(resource:, **attrs)
      PermissionForge::ResourceAction.create!({
        uuid: SecureRandom.uuid,
        name: 'export',
        label: 'Export',
        is_permitted: false,
        is_active: true,
        resource: resource
      }.merge(attrs))
    end

    def create_permission_set_rule(permission_set:, resource:, **attrs)
      PermissionForge::PermissionSetRule.create!({
        uuid: SecureRandom.uuid,
        name: 'Test Rule',
        failure_message: 'Access denied by test rule',
        field_name: 'supplier_id',
        field_value: 'current_user',
        operator: 'equal',
        include_nulls: true,
        is_active: true,
        is_editable: true,
        permission_set: permission_set,
        resource: resource
      }.merge(attrs))
    end
  end
end
