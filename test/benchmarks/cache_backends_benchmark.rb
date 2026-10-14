# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: Cache Backends Comparison"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"

ITERATIONS = 5_000

# Build a realistic permission hash (similar to what regenerate_permissions stores)
permission_data = {
  profile: { id: 1, uuid: 'abc-123', name: 'Test User', email: 'user@example.com' },
  preferences: {},
  permissions: {
    resources: {
      Customer: {
        permissions: { read_access: true, create_access: true, edit_access: true, delete_access: false },
        fields: {
          name: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          email: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' },
          phone: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'last4' },
          address: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          domain: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          tax_id: { read_access: false, edit_access: false, mask_access: true, mask_strategy: 'full' },
          city: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          state: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          zip_code: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
          country: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
          website: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          notes: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          status: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
          category: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
          reference_number: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' }
        },
        actions: { export: { is_permitted: true }, sync: { is_permitted: false } },
        permission_set_rules: [
          { name: 'Supplier Rule', field_name: 'supplier_id', field_value: '42', operator: 'equal', include_nulls: false }
        ],
        source_permission_sets: [{ id: 1, name: 'Sales Team' }]
      },
      Supplier: {
        permissions: { read_access: true, create_access: false, edit_access: false, delete_access: false },
        fields: {
          name: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' },
          email: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }
        },
        actions: {},
        permission_set_rules: [],
        source_permission_sets: [{ id: 1, name: 'Sales Team' }]
      }
    }
  }
}

# ============================================================
# Test each backend
# ============================================================

backends = {}

# 1. MemoryCache (mutex-guarded deep_dup on read and write)
backends['MemoryCache'] = PermissionForge::Cache::MemoryCache.new(prefix: 'bench')

# 2. RailsCache with memory_store
rails_memory_store = ActiveSupport::Cache::MemoryStore.new
backends['RailsCache (memory_store)'] = PermissionForge::Cache::RailsCache.new(prefix: 'bench', store: rails_memory_store)

# 3. RailsCache with file_store
tmpdir = Dir.mktmpdir('pf_bench')
rails_file_store = ActiveSupport::Cache::FileStore.new(tmpdir)
backends['RailsCache (file_store)'] = PermissionForge::Cache::RailsCache.new(prefix: 'bench', store: rails_file_store)

# 4. NullCache (no-op baseline)
backends['NullCache (no-op)'] = PermissionForge::Cache::NullCache.new(prefix: 'bench')

# ============================================================
# Write benchmarks
# ============================================================
puts "\n--- Write Performance (#{ITERATIONS} writes) ---\n"

write_results = []

backends.each do |name, cache|
  begin
    cache.clear
  rescue StandardError
    nil
  end
  time = measure_without_gc do
    ITERATIONS.times { |i| cache.write("user_#{i % 100}", permission_data) }
  end
  write_results << { label: name, time: time.real, count: ITERATIONS }
end

print_report("Cache Write: #{ITERATIONS} iterations", write_results)

# ============================================================
# Read benchmarks (pre-populate first)
# ============================================================
puts "--- Read Performance (#{ITERATIONS} reads) ---\n"

read_results = []

backends.each do |name, cache|
  # Pre-populate
  100.times { |i| cache.write("user_#{i}", permission_data) }

  time = measure_without_gc do
    ITERATIONS.times { |i| cache.read("user_#{i % 100}") }
  end
  read_results << { label: name, time: time.real, count: ITERATIONS }
end

print_report("Cache Read: #{ITERATIONS} iterations", read_results)

# Cleanup
FileUtils.rm_rf(tmpdir)

puts '  Backend notes:'
puts '  - MemoryCache: mutex-guarded deep_dup on read AND write (in-process, no network)'
puts '  - RailsCache: Uses Rails.cache and its own serializer. Redis, Memcached and Solid Cache'
puts '    go through it (cache_backend = :rails_cache, or a store instance).'
puts '  - NullCache: No-op (always returns nil). Useful for testing/disabling cache.'
puts
