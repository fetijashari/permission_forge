require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.pattern = 'test/**/*_test.rb'
  t.verbose = false
end

# Postgres-only RLS enforcement suite. Requires a reachable PostgreSQL server:
#   DB=postgres bundle exec rake test:rls
# (the task forces DB=postgres itself, so plain `rake test:rls` also works).
task 'test:rls:env' do
  ENV['DB'] = 'postgres'
end

Rake::TestTask.new('test:rls' => 'test:rls:env') do |t|
  t.libs << 'test'
  t.pattern = 'test/rls/**/*_test.rb'
  t.verbose = false
end

desc 'Run performance benchmarks (each script in its own process for isolation)'
task :benchmark do
  FileList['test/benchmarks/**/*_benchmark.rb'].sort.each do |script|
    ruby script do |ok, _status|
      abort "Benchmark failed: #{script}" unless ok
    end
  end
end

task default: :test

# docs:configuration — the Option reference of docs/configuration.md (gem development only)
load File.expand_path('lib/tasks/permission_forge_docs.rake', __dir__)

# Documentation floor for the public API: objects marked `@api private` are not counted, and the number of
# undocumented ones may not grow (lower a floor when you document something, never raise it).
#   bundle exec rake yard:check
#
# What `yard stats --hide-api private` may report as undocumented: every public module, class, method and
# attribute is documented; public constants are only floored.
YARD_UNDOCUMENTED_FLOOR = { 'Modules' => 0, 'Classes' => 0, 'Constants' => 76, 'Attributes' => 0, 'Methods' => 0 }.freeze

namespace :yard do
  desc 'Fail when the public API has more undocumented objects than the floor'
  task :check do
    require 'open3'
    out, status = Open3.capture2e('yard', 'stats', '--hide-api', 'private')
    abort("yard stats failed:\n#{out}") unless status.success?

    failures = YARD_UNDOCUMENTED_FLOOR.filter_map do |kind, floor|
      found = out[/^#{kind}:\s+\d+\s+\(\s*(\d+) undocumented\)/, 1] or abort("yard stats printed no #{kind} line:\n#{out}")
      "#{kind}: #{found} undocumented, floor #{floor}" if found.to_i > floor
    end
    abort("Undocumented public API grew (run `yard stats --list-undoc --hide-api private`):\n  #{failures.join("\n  ")}") if failures.any?

    puts out[/^\s*[\d.]+% documented/].to_s.strip
  end
end
