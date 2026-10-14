# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: PermissionHashBuilder (Cache Rebuild)"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}\n"

def setup_scenario(resource_count, fields_per_resource)
  ActiveRecord::Base.transaction do
    PermissionForge::ResourceField.delete_all
    PermissionForge::Resource.delete_all
    PermissionForge::PermissionSetUser.delete_all
    PermissionForge::PermissionSet.delete_all
    User.delete_all
  end

  user = User.create!(
    uuid: SecureRandom.uuid,
    name: 'Rebuild User',
    email: "rebuild_#{SecureRandom.hex(4)}@example.com",
    deactivated: false
  )

  permission_set = PermissionForge::PermissionSet.create!(
    uuid: SecureRandom.uuid,
    name: 'Rebuild Set',
    is_active: true,
    is_editable: true
  )

  PermissionForge::PermissionSetUser.create!(
    uuid: SecureRandom.uuid,
    user: user,
    permission_set: permission_set
  )

  resource_names = %w[Customer Supplier Article Quote OrderEntry Inquiry SalesOrder Project RFQ Contact]

  resource_count.times do |r|
    resource = PermissionForge::Resource.create!(
      uuid: SecureRandom.uuid,
      name: resource_names[r] || "Resource#{r}",
      permission_set: permission_set,
      is_active: true,
      is_editable: true,
      read_access: true,
      create_access: true,
      edit_access: true,
      delete_access: true
    )

    all_names = BenchmarkHelpers::FIELD_TEMPLATES.merge(BenchmarkHelpers::EXTRA_FIELDS).keys
    fields_per_resource.times do |f|
      field_name = all_names[f] || "field_#{f}"
      PermissionForge::ResourceField.create!(
        uuid: SecureRandom.uuid,
        name: field_name.to_s,
        label: field_name.to_s.titleize,
        resource: resource,
        is_active: true,
        is_editable: true,
        read_access: true,
        edit_access: f.even?,
        mask_access: (f % 5).zero?,
        mask_strategy: %w[full email last4 first1_last4][f % 4]
      )
    end
  end

  Current.user = user
  [user, permission_set]
end

scenarios = [
  { resources: 1, fields: 5, iterations: 100, label: 'Small (1 resource, 5 fields)' },
  { resources: 3, fields: 15, iterations: 100, label: 'Medium (3 resources, 15 fields)' },
  { resources: 5, fields: 30, iterations: 50, label: 'Large (5 resources, 30 fields)' },
  { resources: 9, fields: 30, iterations: 20, label: 'XL (9 resources, 30 fields)' }
]

results = []

scenarios.each do |s|
  user, = setup_scenario(s[:resources], s[:fields])

  time = measure_without_gc do
    s[:iterations].times { user.regenerate_permissions }
  end

  results << { label: s[:label], time: time.real, count: s[:iterations] }
end

print_report('PermissionHashBuilder — Cache Rebuild Cost', results)

puts '  Note: Each rebuild queries the DB for permission_sets, resources, fields, actions, and rules.'
puts '  Production cost depends on association count and DB latency.'
puts
