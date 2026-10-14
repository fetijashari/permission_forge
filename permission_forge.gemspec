require_relative 'lib/permission_forge/version'

Gem::Specification.new do |spec|
  spec.name          = 'permission_forge'
  spec.version       = PermissionForge::VERSION
  spec.authors       = ['Feti Jashari']
  spec.email         = ['fetijashari@gmail.com']

  spec.summary       = 'Database-backed permissions for Rails: resource CRUD, field-level access and masking, ' \
                       'row-level rules'
  spec.description   = 'PermissionForge stores permissions as Permission Sets that admins edit at runtime: ' \
                       'per-model CRUD flags and custom actions, per-field read/edit access with masking, and ' \
                       'row-level query rules. It applies them in your models (find_by, permission_scoped, ' \
                       'attribute readers and serialization) and controllers, caches each user\'s permissions ' \
                       'in any Rails cache store, records every permission change in an audit log, and ships ' \
                       'an admin UI and an opt-in JSON admin API.'
  spec.homepage      = 'https://github.com/fetijashari/permission_forge'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri']   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['documentation_uri'] = "#{spec.homepage}/tree/main/docs"
  spec.metadata['bug_tracker_uri']   = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # The tracked files only, so nothing stray in the build directory ships;
  # outside a git checkout (an unpacked source tree), the same globs.
  shipped = %r{\A(?:(?:lib|app)/|config/routes\.rb\z|config/locales/[^/]+\.yml\z|(?:LICENSE\.txt|CHANGELOG\.md|README\.md)\z)}
  spec.files = Dir.chdir(__dir__) do
    tracked = `git ls-files -z 2>/dev/null`.split("\x0") if File.exist?('.git')
    if tracked.nil? || tracked.empty?
      Dir['{lib,app}/**/*', 'config/routes.rb', 'config/locales/*.yml', 'LICENSE.txt', 'CHANGELOG.md', 'README.md']
        .select { |path| File.file?(path) }
    else
      tracked.grep(shipped)
    end
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord',  '>= 7.1', '< 8.2'
  spec.add_dependency 'activesupport', '>= 7.1', '< 8.2'
  spec.add_dependency 'railties',      '>= 7.1', '< 8.2'
end
