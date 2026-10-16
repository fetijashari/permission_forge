# frozen_string_literal: true

# Serves the admin for a browser: boots test/dummy in development on a
# throwaway SQLite file with the sample data of the whole-UI tests
# (AdminTestCase + AdminPagePaths, plus a person with a long name and a long
# email), prints the screens to walk (AdminPaths: paths, error states, flows)
# as one JSON line, then serves the app with Puma until stopped.
#
#   bundle exec ruby test/support/preview_app.rb [--port 4017]
#   PREVIEW:{"base":"http://127.0.0.1:4017/permission_forge","paths":[…],"error_states":[…],"flows":[…]}
#
# test/browser/layout_probe.js reads that line (the `browser` CI job); a
# person can open the base URL as well. Forgery protection stays on: the
# probe posts with the page's CSRF token, as the browser would.
require 'json'
require 'fileutils'
require 'optparse'
require 'securerandom'

port = 4017
OptionParser.new { |opts| opts.on('--port PORT', Integer, 'TCP port (default 4017)') { |value| port = value } }.parse!(ARGV)

root = File.expand_path('../..', __dir__)
db = File.join(root, 'tmp', "pf-preview-#{port}.sqlite3")
FileUtils.mkdir_p(File.dirname(db))
FileUtils.rm_f(db)
ENV['RAILS_ENV'] = 'development'
ENV['DATABASE_URL'] = "sqlite3:#{db}"

require File.join(root, 'test/dummy/config/environment')
require_relative '../permission_forge/html/admin_paths'

ActiveRecord::Schema.verbose = false
load File.join(root, 'test/dummy/db/schema.rb')

# The suite's base configuration (test_helper.rb) without tenancy: acts_as_tenant
# wants a current tenant per request, which a browser does not send.
PermissionForge.configure do |config|
  config.user_class = 'User'
  config.current_user_resolver = -> { Current.user }
  config.cache_backend = :memory
  config.table_name_prefix = ''
  config.audit_trail_enabled = true
  config.http_basic_auth_enabled = false
  config.gdpr_defaults = false
  config.api_enabled = true
  config.api_auth = ->(_controller) { true }
  config.unconfigured_field_strategy = :block
  config.filter_parameters_integration = false
end
PermissionForge::Audit.reset! # the table check ran at boot, before the schema was loaded

# The factories of test_helper.rb (same defaults), for a process that is no test.
module Seeds
  module_function

  def uuid = SecureRandom.uuid

  def user(name, email) = User.create!(uuid: uuid, name: name, email: email, deactivated: false)

  def permission_set(name, **attrs)
    PermissionForge::PermissionSet.create!({ uuid: uuid, name: name, description: 'A test permission set', is_active: true,
                                             is_editable: true }.merge(attrs))
  end

  def resource(set, **attrs)
    PermissionForge::Resource.create!({ uuid: uuid, name: 'Customer', permission_set: set, is_active: true, is_editable: true,
                                        read_access: true, create_access: false, edit_access: false, delete_access: false }.merge(attrs))
  end

  def field(resource, **attrs)
    PermissionForge::ResourceField.create!({ uuid: uuid, name: 'name', label: 'Name', resource: resource, is_active: true,
                                             is_editable: true, read_access: true, edit_access: false }.merge(attrs))
  end

  def rule(set, resource, **attrs)
    PermissionForge::PermissionSetRule.create!({ uuid: uuid, name: 'Test Rule', failure_message: 'Access denied by test rule',
                                                 field_name: 'supplier_id', field_value: 'current_user', operator: 'equal',
                                                 include_nulls: true, is_active: true, is_editable: true, permission_set: set,
                                                 resource: resource }.merge(attrs))
  end

  def action(resource)
    PermissionForge::ResourceAction.create!(uuid: uuid, name: 'export', label: 'Export', is_permitted: false, is_active: true,
                                            resource: resource)
  end

  def assignment(user, set) = PermissionForge::PermissionSetUser.create!(uuid: uuid, user: user, permission_set: set)

  def group(name)
    PermissionForge::PermissionSetGroup.create!(uuid: uuid, name: name, description: 'A test group', is_active: true, is_editable: true)
  end
end

# AdminTestCase
ana = Seeds.user('Ana Krasniqi', 'ana@acme.test')
Seeds.user('Bo Berisha', 'bo@acme.test')
set = Seeds.permission_set('Sales rep')
resource = Seeds.resource(set, read_access: true, edit_access: true)
email = Seeds.field(resource, name: 'email', label: 'Email', read_access: true, mask_access: true, mask_strategy: 'email')
assignment = Seeds.assignment(ana, set)
# AdminPagePaths
rule = Seeds.rule(set, resource)
action = Seeds.action(resource)
group = Seeds.group('Sales')
muting = Seeds.permission_set('Contractors', is_muting: true)
Seeds.resource(muting, delete_access: true)
locked = Seeds.permission_set('Managed by API', is_editable: false)
locked_resource = Seeds.resource(locked, is_editable: false)
Seeds.field(locked_resource, is_editable: false)
Seeds.rule(locked, locked_resource, is_editable: false)
broken = Seeds.rule(set, resource, name: 'Typo rule', field_name: 'name', field_value: 'active')
broken.update_columns(field_name: 'stauts')
email.update!(mask_strategy: 'last4')
updated = PermissionForge::AuditEvent.where(event: 'resource_field.updated').last
Seeds.rule(set, resource, name: 'Gone').destroy!
destroyed = PermissionForge::AuditEvent.where(event: 'permission_set_rule.destroyed').last
# Long host data: a name and an email that must wrap, never widen a page.
long = Seeds.user('Aleksandra-Katarina Mitrevska-Dimitrievska', 'aleksandra.katarina.mitrevska@very-long-company-domain.example')
Seeds.assignment(long, set)

screens = PermissionForge::Html::AdminPaths.new(ana: ana.id, assignment: assignment.id, set: set.id, muting: muting.id,
                                                locked: locked.id, group: group.id, action: action.id, rule: rule.id,
                                                broken: broken.id, updated_event: updated&.uuid, destroyed_event: destroyed&.uuid)
puts "PREVIEW:#{{ base: "http://127.0.0.1:#{port}/permission_forge", paths: screens.paths,
                  error_states: screens.error_states.map(&:to_h), flows: screens.flows.map(&:to_h) }.to_json}"
$stdout.flush

require 'rackup'
require 'puma'
Rackup::Handler.get('puma').run(Rails.application, Port: port, Host: '127.0.0.1', Silent: true)
