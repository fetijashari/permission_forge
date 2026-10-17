# frozen_string_literal: true

# Boots a brand-new Rails application in a temp directory and installs
# PermissionForge the way a new adopter does: the real install generator with
# default flags, the generated initializer, the generated migration. Nothing
# from test/dummy or test_helper is loaded, so this runs on the shipped
# defaults: the default table prefix, :rails_cache over the stock test
# NullStore, audit trail on, no tenancy.
#
# Run in a child process by test/permission_forge/install/fresh_install_test.rb:
#   ruby test/support/fresh_install_app.rb <scenario> <result.json>
# Scenarios:
#   default      integer user keys
#   string_keys  string user keys (the SQLite stand-in for UUID primary keys)
#   no_current   no `Current` class (an app without CurrentAttributes); its
#                users table has a uuid column
#
# The users table has no uuid column except in no_current: most apps have
# none, and the gem must not need one.

ENV['RAILS_ENV'] = 'test'
ENV.delete('DATABASE_URL')

require 'json'
require 'tmpdir'
require 'fileutils'
require 'logger'
require 'base64'
require 'rack/mock'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'permission_forge'

SCENARIO = ARGV.fetch(0, 'default')
RESULT_PATH = ARGV.fetch(1)
STRING_KEYS = SCENARIO == 'string_keys'
NO_CURRENT = SCENARIO == 'no_current'
APP_ROOT = Dir.mktmpdir('pf_fresh_install')
at_exit { FileUtils.remove_entry(APP_ROOT) if File.directory?(APP_ROOT) }

%w[config/initializers db/migrate log tmp].each { |dir| FileUtils.mkdir_p(File.join(APP_ROOT, dir)) }
File.write(File.join(APP_ROOT, 'config/database.yml'), <<~YAML)
  test:
    adapter: sqlite3
    database: #{File.join(APP_ROOT, 'db/test.sqlite3')}
YAML
File.write(File.join(APP_ROOT, 'config/routes.rb'), <<~ROUTES)
  Rails.application.routes.draw do
    mount PermissionForge::Engine, at: '/permissions'
    get '/walk_ins/:id', to: 'walk_ins#show'
  end
ROUTES
Dir.chdir(APP_ROOT)

class FreshApp < Rails::Application
  config.root = APP_ROOT
  config.load_defaults Rails::VERSION::STRING.to_f
  config.eager_load = false
  config.secret_key_base = 'fresh-install-' * 5
  config.logger = Logger.new(File.join(APP_ROOT, 'log/test.log'))
  # What `rails new` writes into config/environments/test.rb.
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :none
  config.active_support.deprecation = :silence
end

unless NO_CURRENT
  class Current < ActiveSupport::CurrentAttributes
    attribute :user
  end
end

class User < ActiveRecord::Base
  include PermissionForge::Concerns::PermissionedUser
end

class Customer < ActiveRecord::Base
  include PermissionForge::Concerns::PermissionScopedFindable
end

# A public page of the host: nobody signed in, a masked model read in a web
# request (the generated initializer's :hide_in_requests hides it there).
class WalkInsController < ActionController::Base
  def show
    customer = Customer.find_by(id: params[:id])
    render json: [customer.name, customer.email]
  end
end

# Two ids that an integer column would both truncate to 1, and ones it would
# truncate to 0.
IDS = if STRING_KEYS
        { ann: '1aaaaaaa-0000-4000-8000-000000000001', bob: '1bbbbbbb-0000-4000-8000-000000000002',
          cat: 'c0000000-0000-4000-8000-000000000003', dan: 'd0000000-0000-4000-8000-000000000004',
          eve: 'e0000000-0000-4000-8000-000000000005' }
      else
        { ann: nil, bob: nil, cat: nil, dan: nil, eve: nil }
      end

# The checks around who is signed in (extended into FreshInstall, so they
# share its instance variables).
module FreshInstallSignIn
  # How the app tells PermissionForge who is signed in: Current.user, which
  # the generated initializer reads. An app without Current wires its own
  # resolver; this one reads a thread variable.
  def sign_in(user)
    if NO_CURRENT
      PermissionForge.configuration.current_user_resolver = -> { Thread.current[:fresh_install_user] }
      Thread.current[:fresh_install_user] = user
    else
      Current.user = user
    end
  end

  # Nobody signed in, with the generated initializer unchanged: a model that
  # has a Resource row (so MaskedAttributes was applied) is saved, found and
  # read. In an app without Current the generated resolver must answer nil,
  # not raise NameError.
  def signed_out_checks
    record = Customer.create!(name: 'walk-in', email: 'walk-in@example.test', owner_id: @bob.id)
    @walk_in_id = record.id
    { signed_out_current_user: PermissionForge.current_user.inspect,
      signed_out_masked_attributes: PermissionForge::Concerns::MaskedAttributes.applied?(Customer) }.merge(signed_out_reads(record.id))
  rescue StandardError => e
    { signed_out_error: "#{e.class}: #{e.message}" }
  end

  # The stored values, find_by, and a read past the record rules.
  def signed_out_reads(id)
    found = Customer.find_by(id: id)
    unscoped = PermissionForge.without_permission_scope { Customer.find(id) }
    { signed_out_saved: Customer.unscoped.where(id: id).pick(:name, :email),
      signed_out_save_find_read: [found&.name, found&.email],
      signed_out_unscoped_read: [unscoped.name, unscoped.email] }
  end

  # An admin who is signed in assigns the set to Eve: the assignment is
  # stamped with the admin's id (audit_trail_enabled is on in the generated
  # initializer), and Eve's permissions are built from it. Runs last so the
  # set's holders above are Ann and Cat only.
  def granted_by_admin_checks
    sign_in(@dan)
    assignment = PermissionForge::PermissionSetUser.create!(permission_set: @set, user: @eve)
    sign_in(nil)
    { granted_by_admin_stamped: assignment.reload.created_by_id == @dan.id,
      granted_by_admin_can_read: outcome { User.find(@eve.id).can_read?(:Customer) } }
  ensure
    sign_in(nil)
  end

  def outcome
    yield
  rescue StandardError => e
    "#{e.class}: #{e.message}"
  end
end

# A second process (extended into FreshInstall). Two real processes share
# the database and a cache store (a file store: the stock test NullStore
# keeps nothing). A forked worker has not masked Invoice; this process
# commits the first Resource row for it; the worker's next executor run (a
# request or a job) must mask it.
module FreshInstallOtherProcess
  def other_process_checks
    PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(File.join(APP_ROOT, 'tmp/cache'))
    PermissionForge.configuration.reset_cache_store!
    Object.const_set(:Invoice, Class.new(ActiveRecord::Base) { self.table_name = 'customers' })
    PermissionForge::MaskingSync.boot!
    { other_process_masked: in_forked_worker { PermissionForge::Resource.create!(permission_set: @set, name: 'Invoice') } }
  end

  # Forks a worker that waits for the parent's change (the block), then
  # reports whether Invoice was masked before and after one executor run.
  def in_forked_worker
    go_read, go_write = IO.pipe
    result_read, result_write = IO.pipe
    pid = fork { worker(go_read, result_write, [go_write, result_read]) }
    [go_read, result_write].each(&:close)
    yield
    go_write.write('go')
    go_write.close
    JSON.parse(result_read.read).tap { Process.wait(pid) }
  end

  def worker(go_signal, result, unused)
    unused.each(&:close)
    go_signal.read(1)
    before = invoice_masked?
    Rails.application.executor.wrap { nil }
    result.write(JSON.generate([before, invoice_masked?]))
    result.close
    exit!(0)
  end

  def invoice_masked?
    PermissionForge::Concerns::MaskedAttributes.applied?(Invoice)
  end
end

# The user model with a Resource row (extended into FreshInstall). Under
# masked_attributes_nil_user_strategy :hide (an explicit opt-in) masked
# attributes read as hidden with nobody signed in, but authentication reads
# the user record before anyone is: the user model is exempt, every other
# masked model is not. Runs last: from here on User is masked and :hide set.
module FreshInstallUserModel
  def user_model_checks
    PermissionForge.configuration.masked_attributes_nil_user_strategy = :hide
    users = PermissionForge::Resource.create!(permission_set: @set, name: 'User', read_access: true)
    PermissionForge::ResourceField.create!(resource: users, name: 'email', label: 'Email', read_access: true,
                                           mask_access: true, mask_strategy: 'email')
    signing_in = User.find(@ann.id)
    customer = PermissionForge.without_permission_scope { Customer.find(@mine.id) }
    { user_model_masked: PermissionForge::Concerns::MaskedAttributes.applied?(User),
      user_model_signed_out_read: [signing_in.name, signing_in.email],
      other_model_signed_out_read: [customer.name, customer.email] }
  end
end

module FreshInstall
  extend FreshInstallSignIn
  extend FreshInstallOtherProcess
  extend FreshInstallUserModel

  module_function

  def run
    Rails.application.initialize!
    create_host_tables
    install_permission_forge
    seed_host_rows
    seed_permissions
    install_facts.merge(signed_out_checks, model_checks, signed_in_checks, http_checks, granted_by_admin_checks,
                        other_process_checks, user_model_checks)
  end

  def key_type
    STRING_KEYS ? :string : :bigint
  end

  def create_host_tables
    connection = ActiveRecord::Base.connection
    connection.create_table(:users, id: key_type) do |t|
      t.string :name
      t.string :email
      t.string :uuid if NO_CURRENT
      t.timestamps
    end
    connection.create_table(:customers) do |t|
      t.string :name
      t.string :email
      t.column :owner_id, key_type
      t.timestamps
    end
  end

  # `rails generate permission_forge:install` with no flags, then the files it
  # wrote: the initializer and the migration.
  def install_permission_forge
    require 'rails/generators'
    require 'generators/permission_forge/install/install_generator'
    PermissionForge::Generators::InstallGenerator.start([], destination_root: APP_ROOT)

    load File.join(APP_ROOT, 'config/initializers/permission_forge.rb')
    load Dir[File.join(APP_ROOT, 'db/migrate/*_create_permission_forge_tables.rb')].fetch(0)
    ActiveRecord::Migration.suppress_messages { CreatePermissionForgeTables.migrate(:up) }
  end

  def user(name)
    id = IDS.fetch(name.downcase.to_sym)
    attributes = { name: name, email: "#{name.downcase}@example.test" }
    attributes[:id] = id if id
    attributes[:uuid] = "uuid-of-#{name.downcase}" if NO_CURRENT
    User.create!(attributes)
  end

  def seed_host_rows
    @ann = user('Ann')
    @bob = user('Bob')
    @cat = user('Cat')
    @dan = user('Dan')
    @eve = user('Eve')
    @mine = Customer.create!(name: 'mine', email: 'mine@example.test', owner_id: @ann.id)
    @theirs = Customer.create!(name: 'theirs', email: 'theirs@example.test', owner_id: @bob.id)
  end

  # One row in each of the 8 tables: Ann holds a set that lets her read her
  # own customers, with the email masked.
  def seed_permissions
    @group = PermissionForge::PermissionSetGroup.create!(name: 'Sales')
    @set = PermissionForge::PermissionSet.create!(name: 'Sales rep', permission_set_group: @group)
    @resource = PermissionForge::Resource.create!(permission_set: @set, name: 'Customer', read_access: true)
    seed_resource_details
    @assignment = PermissionForge::PermissionSetUser.create!(permission_set: @set, user: @ann)
    PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @ann)
  end

  def seed_resource_details
    PermissionForge::ResourceField.create!(resource: @resource, name: 'name', label: 'Name', read_access: true)
    PermissionForge::ResourceField.create!(resource: @resource, name: 'email', label: 'Email', read_access: true,
                                           mask_access: true, mask_strategy: 'email')
    PermissionForge::ResourceAction.create!(resource: @resource, name: 'export', is_permitted: true)
    PermissionForge::PermissionSetRule.create!(permission_set: @set, resource: @resource, name: 'Own customers',
                                               field_name: 'owner_id', field_value: 'current_user',
                                               operator: 'equal', include_nulls: false)
  end

  def install_facts
    { scenario: SCENARIO, table_prefix: PermissionForge.table_name_prefix, preset: PermissionForge.configuration.preset.to_s,
      user_id_column_type: PermissionForge::PermissionSetUser.columns_hash['user_id'].type.to_s,
      cache_store: Rails.cache.class.name }
  end

  def model_checks
    models = [PermissionForge::PermissionSetGroup, PermissionForge::PermissionSet, PermissionForge::Resource,
              PermissionForge::ResourceField, PermissionForge::ResourceAction, PermissionForge::PermissionSetRule,
              PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroupUser]
    { models_with_rows: models.count(&:exists?),
      assignment_stores_the_full_user_id: @assignment.reload.user_id == @ann.id,
      audit_runs: PermissionForge::Services::SecurityAudit.call.findings.is_a?(Array) }
  end

  # Everything a request made by Ann would see.
  def signed_in_checks
    sign_in(@ann)
    access_checks.merge(row_rule_checks, isolation_checks)
  ensure
    sign_in(nil)
  end

  def access_checks
    hash = @ann.permissions_hash
    rules = hash.dig(:permissions, :resources, :Customer, :permission_set_rules)
    { ann_can_read: @ann.can_read?(:Customer), ann_can_delete: @ann.can_delete?(:Customer),
      ann_can_export: @ann.can?(:export, :Customer), ann_rule_count: rules.to_a.size,
      ann_email_masked: @ann.masked_field?(:Customer, :email),
      ann_profile: hash[:profile].transform_keys(&:to_s).slice('uuid', 'name', 'email') }
  end

  def row_rule_checks
    { find_by_own_row: find_by_outcome(@mine), find_by_other_row: find_by_outcome(@theirs),
      permission_scoped: Customer.permission_scoped.pluck(:name) }
  end

  def find_by_outcome(record)
    Customer.find_by(id: record.id) ? 'found' : 'missing'
  rescue PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
    'denied'
  end

  # Bob was never assigned; with string keys his id shares its leading digit
  # with Ann's. Cat is assigned in bulk, by id.
  def isolation_checks
    bulk = PermissionForge::Services::BulkPermissionSetAssignment.call(
      permission_set: @set, user_ids: [@cat.id.to_s], action: :assign
    )
    { lookalike_user_can_read: @bob.can_read?(:Customer), lookalike_user_sets: @bob.permission_sets.pluck(:name),
      bulk_assigned: bulk[:assigned], bulk_assigned_the_right_user: @cat.permission_sets.pluck(:name),
      set_users: @set.users.pluck(:name).sort }
  end

  def http_checks
    without_credentials = get('/permissions/')
    PermissionForge.configuration.http_basic_auth_user = 'admin'
    PermissionForge.configuration.http_basic_auth_password = 'fresh-install'
    basic = { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:fresh-install')}" }
    { admin_without_credentials: without_credentials,
      admin_home: get('/permissions/', basic),
      admin_permission_sets: get('/permissions/permission_sets', basic),
      admin_permission_set: get("/permissions/permission_sets/#{@set.id}", basic),
      admin_person: get("/permissions/people/#{@ann.id}", basic),
      api_when_disabled: get('/permissions/api/permission_sets'),
      signed_out_request_read: get_json("/walk_ins/#{@walk_in_id}") }
  end

  # Closes the body, as a server does: that ends the request's executor run.
  def get(path, headers = {})
    request(path, headers).first
  end

  def get_json(path)
    status, text = request(path, {})
    status == 200 ? JSON.parse(text) : status
  end

  def request(path, headers)
    status, _headers, body = Rails.application.call(Rack::MockRequest.env_for("http://localhost#{path}", headers))
    text = +''
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, text]
  end
end

begin
  File.write(RESULT_PATH, JSON.generate(FreshInstall.run))
rescue Exception => e # rubocop:disable Lint/RescueException
  File.write(RESULT_PATH, JSON.generate(error: "#{e.class}: #{e.message}", backtrace: Array(e.backtrace).first(12)))
  exit 1
end
