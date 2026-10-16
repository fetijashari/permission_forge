# frozen_string_literal: true

# The gem's own documentation generators, run from the gem's Rakefile
# (`bundle exec rake docs:configuration`, `docs:api`). They are defined only in a checkout
# of the gem (where docs/ is) and never inside a Rails application — not in a
# host's `rails -T` (the gem ships without docs/), not in the dummy app's.
docs_root = File.expand_path('../../docs', __dir__)
inside_rails = defined?(Rails) && Rails.respond_to?(:application) && Rails.application
if File.directory?(docs_root) && !inside_rails
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

    desc 'Regenerate the json sample blocks (sample=<name>) of docs/admin-api.md from Api::Schema and the serializers'
    task :api do
      lib = File.expand_path('../../lib', __dir__)
      $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
      require 'permission_forge'
      require 'permission_forge/docs/api_samples'
      # The one parser of the docs' fenced blocks (a checkout has test/).
      require File.expand_path('../../test/support/doc_blocks', __dir__)

      path = File.join(docs_root, 'admin-api.md')
      document = File.read(path)
      samples = PermissionForge::Docs::ApiSamples.new(document: document, blocks: DocBlocks.parse(document, file: 'docs/admin-api.md'))
      if samples.stale?
        File.write(path, samples.render)
        puts 'docs/admin-api.md: json samples regenerated'
      else
        puts 'docs/admin-api.md: json samples are up to date'
      end
    end
  end
end
