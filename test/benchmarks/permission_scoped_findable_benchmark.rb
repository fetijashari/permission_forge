# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: PermissionScopedFindable (Row-Level Rules)"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"
puts "Database: SQLite (test). Production PostgreSQL will differ.\n"

LOOKUP_COUNT = 100

# Seed 1000 customers with suppliers
ActiveRecord::Base.transaction do
  PermissionForge::PermissionSetRule.delete_all
  PermissionForge::ResourceField.delete_all
  PermissionForge::Resource.delete_all
  PermissionForge::PermissionSetUser.delete_all
  PermissionForge::PermissionSet.delete_all
  Customer.delete_all
  Supplier.delete_all
  User.delete_all
end

supplier = Supplier.create!(uuid: SecureRandom.uuid, name: 'Bench Supplier')

uuids = []
ActiveRecord::Base.transaction do
  1000.times do |i|
    c = Customer.create!(
      uuid: SecureRandom.uuid,
      name: "Customer #{i}",
      email: "c#{i}@example.com",
      domain: 'example.com',
      supplier: supplier
    )
    uuids << c.uuid
  end
end

# Pick random UUIDs for lookups
lookup_uuids = uuids.sample(LOOKUP_COUNT)

scenarios = []

# Baseline: no Current.user — bypass path (raw find_by)
Current.user = nil
time = measure_without_gc do
  lookup_uuids.each { |uuid| Customer.find_by(uuid: uuid) }
end
scenarios << { label: 'Baseline (no rules, no user)', time: time.real, count: LOOKUP_COUNT }

# Setup user with permission set but 0 rules
user = User.create!(uuid: SecureRandom.uuid, name: 'Rule User', email: "rule_#{SecureRandom.hex(4)}@example.com", deactivated: false)
permission_set = PermissionForge::PermissionSet.create!(uuid: SecureRandom.uuid, name: 'Rule Set', is_active: true, is_editable: true)
PermissionForge::PermissionSetUser.create!(uuid: SecureRandom.uuid, user: user, permission_set: permission_set)
resource = PermissionForge::Resource.create!(
  uuid: SecureRandom.uuid, name: 'Customer', permission_set: permission_set,
  is_active: true, is_editable: true, read_access: true, create_access: true, edit_access: true, delete_access: true
)
user.regenerate_permissions
Current.user = user

time = measure_without_gc do
  lookup_uuids.each { |uuid| Customer.find_by(uuid: uuid) }
end
scenarios << { label: 'With user, 0 rules', time: time.real, count: LOOKUP_COUNT }

# Add 1 rule
PermissionForge::PermissionSetRule.create!(
  uuid: SecureRandom.uuid, name: 'Supplier Rule', failure_message: 'Wrong supplier',
  field_name: 'supplier_id', field_value: supplier.id.to_s, operator: 'equal',
  include_nulls: false, is_active: true, is_editable: true,
  permission_set: permission_set, resource: resource
)
user.regenerate_permissions
Current.user = user

time = measure_without_gc do
  lookup_uuids.each { |uuid| Customer.find_by(uuid: uuid) }
end
scenarios << { label: 'With 1 rule (filter)', time: time.real, count: LOOKUP_COUNT }

# Add 2nd rule
PermissionForge::PermissionSetRule.create!(
  uuid: SecureRandom.uuid, name: 'Domain Rule', failure_message: 'Wrong domain',
  field_name: 'domain', field_value: 'example.com', operator: 'equal',
  include_nulls: false, is_active: true, is_editable: true,
  permission_set: permission_set, resource: resource
)
user.regenerate_permissions
Current.user = user

time = measure_without_gc do
  lookup_uuids.each { |uuid| Customer.find_by(uuid: uuid) }
end
scenarios << { label: 'With 2 rules (filter)', time: time.real, count: LOOKUP_COUNT }

# Add 3rd rule
PermissionForge::PermissionSetRule.create!(
  uuid: SecureRandom.uuid, name: 'Name Rule', failure_message: 'Wrong name pattern',
  field_name: 'name', field_value: 'Customer', operator: 'not_equal',
  include_nulls: true, is_active: true, is_editable: true,
  permission_set: permission_set, resource: resource
)
user.regenerate_permissions
Current.user = user

time = measure_without_gc do
  lookup_uuids.each { |uuid| Customer.find_by(uuid: uuid) }
end
scenarios << { label: 'With 3 rules (filter)', time: time.real, count: LOOKUP_COUNT }

print_report("PermissionScopedFindable: #{LOOKUP_COUNT} lookups across 1000 records", scenarios)

puts '  Note: Allow path is a single existence check regardless of rule count; each rule only grows the WHERE clause. Per-rule queries run only on denial.'
puts '  SQLite benchmarks — PostgreSQL with indexes will be faster for rule evaluation.'
puts
