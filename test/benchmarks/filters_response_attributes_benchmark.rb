# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: FiltersResponseAttributes (Read Path)"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"
puts "This is the PRIMARY benchmark — runs on every serialized record in API responses.\n"

RECORD_COUNT = 1000

# ============================================================
# Scenario A: Mixed access (60% readable, 20% masked, 20% hidden)
# ============================================================
fields_config = mixed_fields_config(15)
records = generate_attributes(RECORD_COUNT, field_count: 15)
user, = setup_user_with_permissions(resource_name: 'Customer', fields_config: fields_config)

scenarios_a = []

# Baseline: plain hash copy (same iteration pattern, no permission logic)
time = measure_without_gc do
  records.each do |attrs|
    attrs.each_with_object({}) { |(k, v), h| h[k] = v }
  end
end
scenarios_a << { label: 'Baseline (hash copy)', time: time.real, count: RECORD_COUNT }

# With PermissionForge
time = measure_without_gc do
  records.each do |attrs|
    PermissionForge::Services::FiltersResponseAttributes.call(
      attributes: attrs, resource_name: 'Customer', user: user
    )
  end
end
scenarios_a << { label: 'With filter + mask', time: time.real, count: RECORD_COUNT }

print_report("Scenario A: #{RECORD_COUNT} records, 15 fields, mixed access (60/20/20)", scenarios_a)

# ============================================================
# Scenario B: Filtering only (no masking)
# ============================================================
ActiveRecord::Base.transaction do
  PermissionForge::ResourceField.delete_all
  PermissionForge::Resource.delete_all
  PermissionForge::PermissionSetUser.delete_all
  PermissionForge::PermissionSet.delete_all
  User.delete_all
end

filter_only_config = field_names_for(15).map.with_index do |name, i|
  readable = i < 12
  { name: name, read_access: readable, edit_access: readable, mask_access: false }
end
records_b = generate_attributes(RECORD_COUNT, field_count: 15)
user_b, = setup_user_with_permissions(resource_name: 'Customer', fields_config: filter_only_config)

scenarios_b = []

time = measure_without_gc do
  records_b.each do |attrs|
    attrs.each_with_object({}) { |(k, v), h| h[k] = v }
  end
end
scenarios_b << { label: 'Baseline (hash copy)', time: time.real, count: RECORD_COUNT }

time = measure_without_gc do
  records_b.each do |attrs|
    PermissionForge::Services::FiltersResponseAttributes.call(
      attributes: attrs, resource_name: 'Customer', user: user_b
    )
  end
end
scenarios_b << { label: 'With filter only (no mask)', time: time.real, count: RECORD_COUNT }

print_report("Scenario B: #{RECORD_COUNT} records, 15 fields, filtering only (12 visible, 3 hidden)", scenarios_b)

# ============================================================
# Scenario C: Masking only (no filtering)
# ============================================================
ActiveRecord::Base.transaction do
  PermissionForge::ResourceField.delete_all
  PermissionForge::Resource.delete_all
  PermissionForge::PermissionSetUser.delete_all
  PermissionForge::PermissionSet.delete_all
  User.delete_all
end

mask_strategies = %w[email last4 first1_last4 full full]
mask_only_config = field_names_for(15).map.with_index do |name, i|
  if i < 5
    { name: name, read_access: true, edit_access: true, mask_access: true,
      mask_strategy: mask_strategies[i] }
  else
    { name: name, read_access: true, edit_access: true, mask_access: false }
  end
end
records_c = generate_attributes(RECORD_COUNT, field_count: 15)
user_c, = setup_user_with_permissions(resource_name: 'Customer', fields_config: mask_only_config)

scenarios_c = []

time = measure_without_gc do
  records_c.each do |attrs|
    attrs.each_with_object({}) { |(k, v), h| h[k] = v }
  end
end
scenarios_c << { label: 'Baseline (hash copy)', time: time.real, count: RECORD_COUNT }

time = measure_without_gc do
  records_c.each do |attrs|
    PermissionForge::Services::FiltersResponseAttributes.call(
      attributes: attrs, resource_name: 'Customer', user: user_c
    )
  end
end
scenarios_c << { label: 'With mask only (no filter)', time: time.real, count: RECORD_COUNT }

print_report("Scenario C: #{RECORD_COUNT} records, 15 fields, masking only (5 masked, 10 plain)", scenarios_c)

# ============================================================
# Scenario D: Scaling test — vary field count
# ============================================================
puts "\n#{'=' * 70}"
puts '  Scenario D: Scaling — field count vs overhead (100 records each)'
puts '=' * 70

scaling_counts = [5, 15, 30, 50]

scaling_counts.each do |fc|
  ActiveRecord::Base.transaction do
    PermissionForge::ResourceField.delete_all
    PermissionForge::Resource.delete_all
    PermissionForge::PermissionSetUser.delete_all
    PermissionForge::PermissionSet.delete_all
    User.delete_all
  end

  fc_config = mixed_fields_config(fc)
  fc_records = generate_attributes(100, field_count: fc)
  fc_user, = setup_user_with_permissions(resource_name: 'Customer', fields_config: fc_config)

  baseline_time = measure_without_gc do
    fc_records.each { |attrs| attrs.each_with_object({}) { |(k, v), h| h[k] = v } }
  end

  filtered_time = measure_without_gc do
    fc_records.each do |attrs|
      PermissionForge::Services::FiltersResponseAttributes.call(
        attributes: attrs, resource_name: 'Customer', user: fc_user
      )
    end
  end

  overhead = filtered_time.real - baseline_time.real
  per_record = (overhead / 100) * 1000

  puts format('  %2d fields: baseline=%.4fs  filtered=%.4fs  overhead=+%.4fms/record',
              fc, baseline_time.real, filtered_time.real, per_record)
end

puts
