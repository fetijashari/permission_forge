# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: MaskValue Strategies"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"
puts "Iterations: 100,000 per strategy\n"

iterations = 100_000

test_values = {
  full: 'Some Sensitive Value That Should Be Hidden',
  email: 'john.doe@example.com',
  last4: '+1-555-123-4567',
  first1_last4: 'Jonathan Smith'
}

scenarios = []

# Baseline: no-op string access
time = measure_without_gc do
  iterations.times do
    test_values.each_value(&:to_s)
  end
end
scenarios << { label: 'Baseline (to_s only)', time: time.real, count: iterations * test_values.size }

# Per-strategy benchmarks
%w[full email last4 first1_last4].each do |strategy|
  value = test_values[strategy.to_sym]
  time = measure_without_gc do
    iterations.times do
      PermissionForge::Services::MaskValue.call(value, strategy: strategy)
    end
  end
  scenarios << { label: "mask_#{strategy}", time: time.real, count: iterations }
end

# All strategies mixed
time = measure_without_gc do
  iterations.times do
    test_values.each do |strategy, value|
      PermissionForge::Services::MaskValue.call(value, strategy: strategy.to_s)
    end
  end
end
scenarios << { label: 'All strategies mixed', time: time.real, count: iterations * test_values.size }

print_report('MaskValue — String Masking Throughput', scenarios)
