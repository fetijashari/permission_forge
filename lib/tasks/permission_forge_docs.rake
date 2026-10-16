# frozen_string_literal: true

# The gem's own documentation generators. They exist only in a checkout of the
# gem (where docs/ is), never in a host application's `rails -T`: the gem ships
# without docs/.
docs_root = File.expand_path('../../docs', __dir__)
if File.directory?(docs_root)
  namespace :docs do
    desc 'Regenerate the Option reference of docs/configuration.md from SettingsCatalog and Configuration.new'
    task :configuration do
      lib = File.expand_path('../../lib', __dir__)
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require 'permission_forge'
      require 'permission_forge/docs/configuration_reference'

      path = File.join(docs_root, 'configuration.md')
      reference = PermissionForge::Docs::ConfigurationReference.new(document: File.read(path))
      if reference.stale?
        File.write(path, reference.render)
        puts 'docs/configuration.md: Option reference regenerated'
      else
        puts 'docs/configuration.md: Option reference is up to date'
      end
    end
  end
end
