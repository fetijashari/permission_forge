# frozen_string_literal: true

require_relative 'benchmark_helper'

include BenchmarkHelpers

puts "\nPermissionForge Benchmark: Audit.instrument on a hot path"
puts "Ruby #{RUBY_VERSION} | Rails #{Rails.version}"

ITERATIONS = 200_000

audit = PermissionForge::Audit
record = Object.new

def noop(_event, **_payload) = nil

# The hot path: a runtime event nobody listens to, of a group that is not
# stored. Target: indistinguishable from a no-op method call.
PermissionForge.configuration.audit_runtime_events = %i[denied]
raise 'field.access must not be stored for this benchmark' if PermissionForge.configuration.store_runtime_group?(:field_read)

scenarios = []

time = Benchmark.realtime { ITERATIONS.times { noop('field.access', record: record) } }
scenarios << { label: 'baseline: no-op method call', time: time, count: ITERATIONS }

time = Benchmark.realtime { ITERATIONS.times { audit.instrument('field.access', record: record) } }
scenarios << { label: 'instrument (eager payload)', time: time, count: ITERATIONS }

time = Benchmark.realtime { ITERATIONS.times { audit.instrument('field.access') { { record: record, data: { 'h' => 1 } } } } }
scenarios << { label: 'instrument (payload block)', time: time, count: ITERATIONS }

time = Benchmark.realtime { ITERATIONS.times { audit.instrument?('field.access') } }
scenarios << { label: 'instrument? only', time: time, count: ITERATIONS }

PermissionForge.configuration.audit_events = false
time = Benchmark.realtime { ITERATIONS.times { audit.instrument('access.denied', record: record) } }
scenarios << { label: 'stored group, audit_events=false', time: time, count: ITERATIONS }
PermissionForge.configuration.audit_events = :auto

print_report('Audit.instrument with no subscriber', scenarios)

per_call = scenarios[1][:time] / ITERATIONS
puts format('  instrument (eager payload): %.0f ns per call, %.1fx the no-op', per_call * 1e9, scenarios[1][:time] / scenarios[0][:time])
