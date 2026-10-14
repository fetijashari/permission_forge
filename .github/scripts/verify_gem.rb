# frozen_string_literal: true

# Checks a built permission_forge .gem before it is published.
#
#   ruby .github/scripts/verify_gem.rb permission_forge-X.Y.Z.gem X.Y.Z
#
# Run from the repository root of the commit the gem was built from. Exits
# non-zero with every problem listed. Used by .github/workflows/release.yml.

require 'English'
require 'rubygems/package'

gem_path, version = ARGV
abort "usage: ruby #{$PROGRAM_NAME} GEM_FILE VERSION" unless gem_path && version

package = Gem::Package.new(gem_path)
package.verify # the checksums inside the .gem; raises when one does not match
spec = package.spec
problems = []

problems << "name is #{spec.name.inspect}, expected \"permission_forge\"" unless spec.name == 'permission_forge'
problems << "version is #{spec.version}, expected #{version}" unless spec.version.to_s == version
problems << 'metadata rubygems_mfa_required is not "true"' unless spec.metadata['rubygems_mfa_required'] == 'true'

entries = {}
package.gem.with_read_io do |io|
  Gem::Package::TarReader.new(io).seek('data.tar.gz') do |data|
    Zlib::GzipReader.wrap(data) do |gz|
      Gem::Package::TarReader.new(gz).each do |entry|
        problems << "#{entry.full_name} is not a regular file" unless entry.file?
        entries[entry.full_name] = entry.header.mode & 0o7777
      end
    end
  end
end

# Every file is world-readable and not executable (0644); an executable, should
# the gem ever ship one, is 0755.
executables = spec.executables.map { |name| File.join(spec.bindir, name) }
entries.each do |name, mode|
  expected = executables.include?(name) ? 0o755 : 0o644
  problems << format('%<name>s has mode %<mode>04o, expected %<expected>04o', name:, mode:, expected:) unless mode == expected
end

shipped = entries.keys.sort
tracked = `git ls-files -z`.split("\0")
problems << 'git ls-files failed' unless $CHILD_STATUS.success?

problems << 'the gem contains no files' if shipped.empty?
problems << 'lib/permission_forge.rb is missing' unless shipped.include?('lib/permission_forge.rb')
problems << 'the file list differs from the packaged gemspec' unless shipped == spec.files.sort

expected_files = Gem::Specification.load('permission_forge.gemspec').files.sort
unless shipped == expected_files
  problems << "files not in the gemspec's list: #{(shipped - expected_files).join(', ')}" if (shipped - expected_files).any?
  problems << "gemspec files missing: #{(expected_files - shipped).join(', ')}" if (expected_files - shipped).any?
end

untracked = shipped - tracked
problems << "files not tracked by git: #{untracked.join(', ')}" if untracked.any?
missing_code = tracked.grep(%r{\A(?:lib|app)/}) - shipped
problems << "tracked lib/ or app/ files left out: #{missing_code.join(', ')}" if missing_code.any?

if problems.any?
  warn "#{gem_path}:"
  problems.each { |problem| warn "  - #{problem}" }
  exit 1
end

puts "#{gem_path}: #{spec.full_name}, #{shipped.size} files, all modes as expected, file list = gemspec (git ls-files)"
