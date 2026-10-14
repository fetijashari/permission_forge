# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: PermitsAttributes (Write Path)"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}\n"

RECORD_COUNT = 1000

# Setup: 15 fields, 9 editable, 6 not editable
fields_config = field_names_for(15).map.with_index do |name, i|
  { name: name, read_access: true, edit_access: i < 9, mask_access: false }
end

setup_user_with_permissions(resource_name: 'Customer', fields_config: fields_config)

# Create a Customer record for the service (it reads resource_name from record.class.name)
customer = Customer.create!(uuid: SecureRandom.uuid, name: 'Bench Customer', email: 'c@example.com', domain: 'example.com')

# Pre-generate param hashes
editable_keys = Set.new(field_names_for(9))
param_template = field_names_for(15).to_h { |k| [k, "value_for_#{k}"] }
params_list = RECORD_COUNT.times.map { param_template.dup }

scenarios = []

# Baseline: filter by Set inclusion (simulates what the gem does, minus cache/permissions)
time = measure_without_gc do
  params_list.each do |params|
    p = params.dup
    p.each_key { |k| p.delete(k) unless editable_keys.include?(k) }
  end
end
scenarios << { label: 'Baseline (Set filter)', time: time.real, count: RECORD_COUNT }

# With PermissionForge
# Need to regenerate params_list since baseline mutated copies
params_list = RECORD_COUNT.times.map { param_template.dup }

time = measure_without_gc do
  params_list.each do |params|
    PermissionForge::Services::PermitsAttributes.call(
      resource: customer, permitted_params: params.dup
    )
  end
end
scenarios << { label: 'With PermitsAttributes', time: time.real, count: RECORD_COUNT }

print_report("PermitsAttributes: #{RECORD_COUNT} param hashes, 15 fields (9 editable)", scenarios)
