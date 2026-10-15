# frozen_string_literal: true

# The pre-release review's host: a brand-new Rails application with
# PermissionForge installed by the real generator with default flags, run on
# the shipped defaults (default table prefix, :rails_cache, audit trail on,
# no tenancy), and checked for what the pre-release review found broken on
# such a host:
#   - the app boots (and eager-loads) when the database cannot be reached
#     (integrity B1 / performance MAJOR-3): it is booted against a PostgreSQL
#     URL on a closed port (nothing listens on port 1, so no database is
#     touched), then connected to its SQLite database for the other checks;
#   - no `Current` class exists (packaging M1): the generated resolver answers
#     nil instead of raising, and a masked model is saved, found and read;
#   - the users table has no uuid column and an admin who is signed in
#     assigns a set (integrity B2 / WS3-B1): the holder's permissions build;
#   - the API's CSRF posture with forgery protection on and a session-based
#     api_auth (claims #1): a forged POST is refused, the same request with
#     the page's token goes through;
#   - api_require_authorization defaults to true (web MAJOR-3): identity
#     alone cannot change permissions.
# Modelled on test/support/fresh_install_app.rb; one app, several checks.
#
# Run in a child process by
# test/permission_forge/release_readiness/shipped_defaults_regression_test.rb:
#   ruby test/support/shipped_defaults_app.rb <result.json>

ENV['RAILS_ENV'] = 'test'
ENV.delete('DATABASE_URL')

require 'json'
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'base64'
require 'rack/test'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'permission_forge'

RESULT_PATH = ARGV.fetch(0)
UNREACHABLE_DATABASE_URL = 'postgresql://pf:pf@127.0.0.1:1/permission_forge_unreachable'
APP_ROOT = Dir.mktmpdir('pf_shipped_defaults')
SQLITE_PATH = File.join(APP_ROOT, 'db/test.sqlite3')
LOG_PATH = File.join(APP_ROOT, 'log/test.log')
at_exit { FileUtils.remove_entry(APP_ROOT) if File.directory?(APP_ROOT) }

%w[app/models config/initializers db/migrate log tmp].each { |dir| FileUtils.mkdir_p(File.join(APP_ROOT, dir)) }
File.write(File.join(APP_ROOT, 'config/database.yml'), <<~YAML)
  test:
    adapter: sqlite3
    database: #{SQLITE_PATH}
YAML
File.write(File.join(APP_ROOT, 'config/routes.rb'), <<~ROUTES)
  Rails.application.routes.draw do
    mount PermissionForge::Engine, at: '/permissions'
  end
ROUTES
# What `rails new` writes into config/initializers/filter_parameter_logging.rb (cut down).
File.write(File.join(APP_ROOT, 'config/initializers/filter_parameter_logging.rb'), <<~RUBY)
  Rails.application.config.filter_parameters += [:passw, :secret]
RUBY
Dir.chdir(APP_ROOT)

class ShippedApp < Rails::Application
  config.root = APP_ROOT
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.secret_key_base = 'shipped-defaults-' * 4
  config.logger = Logger.new(LOG_PATH)
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :none
  config.active_support.deprecation = :silence
  # Production posture for the CSRF check (`rails new` switches it off in
  # test.rb; the review's probe ran with it on).
  config.action_controller.allow_forgery_protection = true
end

# No `Current` class anywhere in this app. The host's models are autoloaded
# from app/models, as in any Rails app: a class defined here, before the
# boot, would load ActiveRecord::Base before config/initializers (and so
# hide what the filter_attributes check looks at).
File.write(File.join(APP_ROOT, 'app/models/user.rb'), <<~RUBY)
  class User < ActiveRecord::Base
    include PermissionForge::Concerns::PermissionedUser
  end
RUBY
File.write(File.join(APP_ROOT, 'app/models/customer.rb'), <<~RUBY)
  class Customer < ActiveRecord::Base
    include PermissionForge::Concerns::PermissionScopedFindable
  end
RUBY

# --- filter_attributes (Q5) --------------------------------------------------

module FilterAttributesChecks
  module_function

  # Column names: personal data, and names that merely contain a GDPR stem.
  PROBE = %w[name email telephone zipcode phone_number capacity hotel_id telemetry_enabled title status].freeze

  # Rails copies config.filter_parameters into ActiveRecord::Base.filter_attributes
  # when ActiveRecord::Base loads; with the models autoloaded that is after
  # the initializers, so the host's entries and the gem's GDPR patterns reach
  # #inspect. The GDPR patterns match whole name segments: `telephone` and
  # `zipcode` yes, `hotel_id`, `capacity` and `telemetry_enabled` no.
  def checks
    filtered = ActiveSupport::ParameterFilter.new(ActiveRecord::Base.filter_attributes).filter(PROBE.to_h { |name| [name, 'v'] })
    { filter_attributes_from_host: ActiveRecord::Base.filter_attributes.include?(:passw),
      inspect_filtered_names: filtered.select { |_, value| value == '[FILTERED]' }.keys,
      customer_inspect: Customer.new(name: 'Jane Doe', email: 'jane@example.test').inspect,
      **gem_model_checks }
  end

  # The gem's rows hold configuration names (InspectionFilters): shown,
  # while the audit log's labels, which name people, stay filtered.
  def gem_model_checks
    { set_inspect: PermissionForge::PermissionSet.first&.inspect,
      field_inspect: PermissionForge::ResourceField.find_by(name: 'email')&.inspect,
      audit_event_inspect: PermissionForge::AuditEvent.new(actor_label: 'Dan', record_label: 'Eve').inspect }
  end
end

module ShippedDefaults
  module_function

  def run
    boot = boot_without_database_check
    connect_to_sqlite
    create_host_tables
    install_permission_forge
    seed
    Rails.application.executor.wrap { nil } # the first request or job after the boot
    boot.merge(generated_settings, FilterAttributesChecks.checks, no_current_checks, user_without_uuid_checks, csrf_checks,
               authorization_default_checks)
  end

  # --- boot without a reachable database (a Docker build, a failover) -------

  # Boots and eager-loads against a PostgreSQL URL on a closed port. The
  # engine's boot checks must skip their database work (one log line), not
  # abort the boot as 0.13 did on Rails 7.2+.
  def boot_without_database_check
    ENV['DATABASE_URL'] = UNREACHABLE_DATABASE_URL
    Rails.application.initialize!
    adapter = ActiveRecord::Base.connection_db_config.adapter
    Rails.application.eager_load!
    { boot_without_database: true, boot_without_database_adapter: adapter,
      boot_without_database_skipped_logged: File.read(LOG_PATH).scan('The database could not be reached at boot').size }
  rescue StandardError => e
    { boot_without_database: false, boot_without_database_error: "#{e.class}: #{e.message}" }
  end

  # The database the rest of the checks run against.
  def connect_to_sqlite
    ENV.delete('DATABASE_URL')
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: SQLITE_PATH)
  end

  # --- the host ---------------------------------------------------------------

  def create_host_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:users) do |t| # no uuid column, as most apps
      t.string :name
      t.string :email
      t.timestamps
    end
    connection.create_table(:customers) do |t|
      t.string :name
      t.string :email
      t.bigint :owner_id
      t.timestamps
    end
  end

  def install_permission_forge
    require 'rails/generators'
    require 'generators/permission_forge/install/install_generator'
    PermissionForge::Generators::InstallGenerator.start([], destination_root: APP_ROOT)

    load File.join(APP_ROOT, 'config/initializers/permission_forge.rb')
    load Dir[File.join(APP_ROOT, 'db/migrate/*_create_permission_forge_tables.rb')].fetch(0)
    ActiveRecord::Migration.suppress_messages { CreatePermissionForgeTables.migrate(:up) }
  end

  def seed
    @admin = User.create!(name: 'Dan', email: 'dan@example.test')
    @eve = User.create!(name: 'Eve', email: 'eve@example.test')
    @set = PermissionForge::PermissionSet.create!(name: 'Sales rep')
    resource = PermissionForge::Resource.create!(permission_set: @set, name: 'Customer', read_access: true)
    PermissionForge::ResourceField.create!(resource: resource, name: 'name', label: 'Name', read_access: true)
    PermissionForge::ResourceField.create!(resource: resource, name: 'email', label: 'Email', read_access: true,
                                           mask_access: true, mask_strategy: 'email')
  end

  # What the generated initializer set (an option this version does not have
  # reads as nil, so an older gem still reports the other checks).
  def generated_settings
    { table_prefix: PermissionForge.table_name_prefix, generated_preset: setting(:preset)&.to_s,
      generated_conditional_sets_strict_mode: setting(:conditional_sets_strict_mode),
      generated_api_require_authorization: setting(:api_require_authorization),
      generated_action_guard_nil_user_strategy: setting(:action_guard_nil_user_strategy)&.to_s,
      generated_admin_tenantless_access: setting(:admin_tenantless_access)&.to_s,
      generated_nested_attributes_parent_fallback: setting(:nested_attributes_parent_fallback),
      audit_trail_enabled: setting(:audit_trail_enabled) }
  end

  def setting(name)
    config = PermissionForge.configuration
    config.public_send(name) if config.respond_to?(name)
  end

  # --- no Current -------------------------------------------------------------

  def no_current_checks
    record = Customer.create!(name: 'walk-in', email: 'walk-in@example.test', owner_id: @eve.id)
    found = Customer.find_by(id: record.id)
    { no_current_defined: Object.const_defined?(:Current),
      no_current_resolver_answers: PermissionForge.current_user.inspect,
      no_current_masked_model_applied: PermissionForge::Concerns::MaskedAttributes.applied?(Customer),
      no_current_save_find_read: [found&.name, found&.email] }
  rescue StandardError => e
    { no_current_error: "#{e.class}: #{e.message}" }
  end

  # --- users without uuid, assignment stamped by a signed-in admin -------------

  # Dan is signed in (the app's own resolver, since there is no Current) and
  # assigns the set to Eve: created_by_id is stamped (audit trail on by
  # default), and Eve's permissions must build from it.
  def user_without_uuid_checks
    assignment = signed_in_as(@admin) { PermissionForge::PermissionSetUser.create!(permission_set: @set, user: @eve) }
    eve = User.find(@eve.id)
    { users_have_uuid_column: User.column_names.include?('uuid'),
      granted_by_admin_stamped: assignment.reload.created_by_id == @admin.id,
      granted_by_admin_can_read: eve.can_read?(:Customer),
      granted_by_admin_email_masked: eve.masked_field?(:Customer, :email),
      granted_by_admin_grantor: grantor_of(eve) }
  rescue StandardError => e
    { granted_by_admin_error: "#{e.class}: #{e.message}" }
  end

  # The app's own resolver (there is no Current): a thread variable.
  def signed_in_as(user)
    PermissionForge.configuration.current_user_resolver = -> { Thread.current[:shipped_defaults_user] }
    Thread.current[:shipped_defaults_user] = user
    yield
  ensure
    Thread.current[:shipped_defaults_user] = nil
  end

  def grantor_of(user)
    user.permissions_hash.dig(:permissions, :resources, :Customer, :source_permission_sets, 0, :permission_set_granted_by)
  end

  # --- CSRF posture of the API with a session-based api_auth ---------------------

  # The admin signs in to the admin screens (Basic auth), which stores the
  # locale in the session; api_auth trusts that session. A cross-site form
  # post from the admin's browser carries the cookie but no token.
  def csrf_checks
    with_session_api do
      browser, signed_in, token = admin_browser_session
      forged = browser.post('/permissions/api/permission_sets', { permission_set: { name: 'forged' } }).status
      with_token = browser.post('/permissions/api/permission_sets', { permission_set: { name: 'same origin' } },
                                { 'HTTP_X_CSRF_TOKEN' => token }).status
      { csrf_admin_session_established: signed_in,
        csrf_forged_post_status: forged, csrf_forged_post_created: PermissionForge::PermissionSet.exists?(name: 'forged'),
        csrf_post_with_token_status: with_token, csrf_post_with_token_created: PermissionForge::PermissionSet.exists?(name: 'same origin') }
    end
  rescue StandardError => e
    { csrf_error: "#{e.class}: #{e.message}" }
  end

  SESSION_API = {
    http_basic_auth_user: 'admin', http_basic_auth_password: 'shipped-defaults', api_enabled: true,
    api_auth: ->(controller) { controller.session[:permission_forge_locale] == 'sq' },
    api_action_authorization: ->(*) { true }, api_assignment_authorization: ->(*) { true }
  }.freeze

  # The API on, authenticated by the admin session, both authorization hooks
  # allowing (so a legitimate request is a 201, not a 403 for another reason).
  def with_session_api
    SESSION_API.each { |name, value| PermissionForge.configuration.public_send("#{name}=", value) }
    yield
  ensure
    %i[api_action_authorization api_assignment_authorization].each { |name| PermissionForge.configuration.public_send("#{name}=", nil) }
  end

  # A browser that signed in to the admin screens: its cookie jar holds the
  # session; the page carries the CSRF token.
  #
  # @return [Array(Rack::Test::Session, Integer, String)] the browser, the sign-in status, the token
  def admin_browser_session
    browser = Rack::Test::Session.new(Rails.application)
    basic = { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:shipped-defaults')}" }
    response = browser.get('/permissions/permission_sets', { locale: 'sq' }, basic)
    [browser, response.status, response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]]
  end

  # --- api_require_authorization defaults to true ------------------------------

  # The host wired an identity-only api_auth and no authorization hooks:
  # reads work, changes and assignments are refused.
  def authorization_default_checks
    PermissionForge.configuration.api_auth = ->(_controller) { true }
    client = Rack::Test::Session.new(Rails.application)
    { identity_only_read_status: client.get('/permissions/api/permission_sets').status,
      identity_only_create_status: json_post(client, '/permissions/api/permission_sets', permission_set: { name: 'Escalate' }),
      identity_only_widen_status: json_post(client, "/permissions/api/permission_sets/#{@set.uuid}/resources",
                                            resource: { name: 'Customer', read_access: true, view_all: true, modify_all: true }),
      identity_only_assign_status: json_post(client, "/permissions/api/permission_sets/#{@set.uuid}/users", user_id: @admin.id),
      identity_only_changed_anything: identity_only_changed_anything? }
  rescue StandardError => e
    { identity_only_error: "#{e.class}: #{e.message}" }
  end

  def json_post(client, path, body)
    client.post(path, JSON.generate(body), { 'CONTENT_TYPE' => 'application/json' }).status
  end

  def identity_only_changed_anything?
    PermissionForge::PermissionSet.exists?(name: 'Escalate') ||
      PermissionForge::Resource.where(permission_set: @set).count != 1 ||
      PermissionForge::PermissionSetUser.exists?(user_id: @admin.id)
  end
end

begin
  File.write(RESULT_PATH, JSON.generate(ShippedDefaults.run))
rescue Exception => e # rubocop:disable Lint/RescueException -- the parent test reads whatever stopped the run
  File.write(RESULT_PATH, JSON.generate(error: "#{e.class}: #{e.message}", backtrace: Array(e.backtrace).first(12)))
  exit 1
end
