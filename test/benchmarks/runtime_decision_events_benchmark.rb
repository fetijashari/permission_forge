# frozen_string_literal: true

# The hot paths that publish runtime decision events (access.denied,
# rule.bypassed, field.access, …), measured with NO subscriber and the default
# config.audit_runtime_events (%i[denied]): attribute reads under
# MaskedAttributes, `find_by` and `permission_scoped` with row-level rules,
# and a relation built under auto-scoping. Publishing must cost nothing
# measurable when nobody listens, so compare a run of this script on the
# commit before the events with a run after (same machine, same Ruby).
#
#   bundle exec ruby test/benchmarks/runtime_decision_events_benchmark.rb
#
# Each scenario runs ROUNDS times; the median ns per operation is reported.

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: runtime decision events, no subscriber"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"

ROUNDS = Integer(ENV.fetch('ROUNDS', 7))
READS = Integer(ENV.fetch('READS', 50_000))
LOOKUPS = Integer(ENV.fetch('LOOKUPS', 2_000))

ActiveRecord::Base.transaction do
  [PermissionForge::PermissionSetRule, PermissionForge::ResourceField, PermissionForge::Resource,
   PermissionForge::PermissionSetUser, PermissionForge::PermissionSet, Customer, Supplier, User].each(&:delete_all)
end

user, resource, permission_set = setup_user_with_permissions(
  resource_name: 'Customer',
  fields_config: [
    { name: 'name', read_access: true },
    { name: 'email', read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' },
    { name: 'domain', read_access: false, edit_access: false },
    { name: 'uuid', read_access: true },
    { name: 'supplier_id', read_access: true },
    { name: 'account_id', read_access: true },
    { name: 'created_at', read_access: true },
    { name: 'updated_at', read_access: true }
  ]
)
Customer.include(PermissionForge::Concerns::MaskedAttributes) unless PermissionForge::Concerns::MaskedAttributes.applied?(Customer)

PermissionForge::PermissionSetRule.create!(
  uuid: SecureRandom.uuid, name: 'Own customers', permission_set: permission_set, resource: resource,
  field_name: 'supplier_id', operator: 'equal', field_value: 'current_user', is_active: true,
  failure_message: 'Not your customer'
)
user.regenerate_permissions
Current.user = user

customers = Array.new(200) do |i|
  Customer.create!(uuid: SecureRandom.uuid, name: "Customer #{i}", email: "c#{i}@example.com",
                   domain: 'example.com', supplier_id: user.id)
end
record = Customer.find(customers.first.id)
uuids = customers.map(&:uuid)

raise 'a subscriber is listening: this benchmark measures the no-listener path' \
  if ActiveSupport::Notifications.notifier.listening?('field.access.permission_forge') &&
     PermissionForge::Audit::EventCatalog.registered?('field.access') &&
     !PermissionForge.configuration.on_field_filtered.nil?

def median_ns(count)
  times = Array.new(ROUNDS) do
    GC.start
    Benchmark.realtime { count.times { |i| yield i } }
  end
  times.sort[ROUNDS / 2] / count * 1e9
end

results = {}
results['getter, readable field'] = median_ns(READS) { record.name }
results['getter, masked field'] = median_ns(READS) { record.email }
results['getter, hidden field'] = median_ns(READS) { record.domain }
results['record[:email]'] = median_ns(READS) { record[:email] }
results['attributes (9 columns)'] = median_ns(READS / 10) { record.attributes }
results['as_json (9 columns)'] = median_ns(READS / 10) { record.as_json }
results['find_by, rule allows'] = median_ns(LOOKUPS) { |i| Customer.find_by(uuid: uuids[i % uuids.size]) }
results['permission_scoped.where.first'] = median_ns(LOOKUPS) { |i| Customer.permission_scoped.where(uuid: uuids[i % uuids.size]).first }

resource.update!(view_all: true)
user.regenerate_permissions
results['find_by, view_all bypass'] = median_ns(LOOKUPS) { |i| Customer.find_by(uuid: uuids[i % uuids.size]) }

PermissionForge.configuration.auto_query_scoping = :filter_only
results['auto-scope, view_all bypass'] = median_ns(LOOKUPS) { |i| Customer.where(uuid: uuids[i % uuids.size]).to_sql }
resource.update!(view_all: false)
user.regenerate_permissions
results['auto-scope, filter rule'] = median_ns(LOOKUPS) { |i| Customer.where(uuid: uuids[i % uuids.size]).to_sql }
PermissionForge.configuration.auto_query_scoping = :off

# The legacy hooks (on_field_filtered, on_rule_bypass) set, nothing else
# listening: they are called directly, as before the audit event log.
PermissionForge.configuration.on_field_filtered = ->(**) {}
PermissionForge.configuration.on_rule_bypass = ->(**) {}
results['hook set: getter, masked field'] = median_ns(READS) { record.email }
results['hook set: as_json (9 columns)'] = median_ns(READS / 10) { record.as_json }
resource.update!(view_all: true)
user.regenerate_permissions
results['hook set: find_by, view_all bypass'] = median_ns(LOOKUPS) { |i| Customer.find_by(uuid: uuids[i % uuids.size]) }
PermissionForge.configuration.on_field_filtered = nil
PermissionForge.configuration.on_rule_bypass = nil

puts format("\n  %-34s %12s", 'Scenario (median of rounds)', 'ns / op')
puts "  #{'-' * 48}"
results.each { |label, ns| puts format('  %-34s %12.0f', label, ns) }
puts
