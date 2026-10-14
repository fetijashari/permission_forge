# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: PermissionedUser Cache Lookups"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}\n"

ITERATIONS = 10_000

# Setup: user with 3 resources, 15 fields each
fields_config = mixed_fields_config(15)
user, = setup_user_with_permissions(resource_name: 'Customer', fields_config: fields_config)

scenarios = []

# can_read?
time = measure_without_gc do
  ITERATIONS.times { user.can_read?(:Customer) }
end
scenarios << { label: 'can_read?(:Customer)', time: time.real, count: ITERATIONS }

# can_edit?
time = measure_without_gc do
  ITERATIONS.times { user.can_edit?(:Customer) }
end
scenarios << { label: 'can_edit?(:Customer)', time: time.real, count: ITERATIONS }

# can?(:read, :Customer) — generic action check
time = measure_without_gc do
  ITERATIONS.times { user.can?(:read, :Customer) }
end
scenarios << { label: 'can?(:read, :Customer)', time: time.real, count: ITERATIONS }

# permissions_hash_for
time = measure_without_gc do
  ITERATIONS.times { user.permissions_hash_for(:Customer) }
end
scenarios << { label: 'permissions_hash_for(:Customer)', time: time.real, count: ITERATIONS }

# field_permissions
time = measure_without_gc do
  ITERATIONS.times { user.field_permissions(:Customer, :email) }
end
scenarios << { label: 'field_permissions(:Customer, :email)', time: time.real, count: ITERATIONS }

# masked_field?
time = measure_without_gc do
  ITERATIONS.times { user.masked_field?(:Customer, :email) }
end
scenarios << { label: 'masked_field?(:Customer, :email)', time: time.real, count: ITERATIONS }

# permissions_hash (full cache read)
time = measure_without_gc do
  ITERATIONS.times { user.permissions_hash }
end
scenarios << { label: 'permissions_hash (full)', time: time.real, count: ITERATIONS }

print_report("Cache Lookups: #{ITERATIONS} iterations each (memory cache)", scenarios)

puts '  Note: every timed call reads the hash the user instance memoized (no store read). The first'
puts '  read on a fresh instance pays one store read (MemoryCache: a mutex-guarded deep_dup + deep_symbolize).'
puts '  Run `ruby test/benchmarks/cache_backends_benchmark.rb` for backend comparisons.'
puts
