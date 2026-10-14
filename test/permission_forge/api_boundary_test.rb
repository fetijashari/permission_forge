require 'test_helper'
require 'yard'

module PermissionForge
  # The public/internal boundary: every constant under PermissionForge:: is either part of the supported surface
  # (`@api public`: the configuration, the concerns hosts include, the documented services, the errors) or
  # internal (`@api private`, free to change in any release). A new class or module that says neither fails here,
  # so the decision is made when the code is written and not discovered by a host after an upgrade.
  #
  # A marker on a private namespace covers the constants nested in it (YARD reads it that way too); a public
  # namespace does not make what is nested in it public. Top-level constants always carry their own.
  class ApiBoundaryTest < ActiveSupport::TestCase
    ROOT = File.expand_path('../..', __dir__)
    MARKERS = %w[public private].freeze

    def self.registry
      @registry ||= begin
        YARD::Registry.clear
        YARD.parse(%w[lib/**/*.rb app/**/*.rb].map { |glob| File.join(ROOT, glob) }, [], YARD::Logger::ERROR)
        YARD::Registry
      end
    end

    # Every module and class reachable from PermissionForge by its own name (not an alias), after eager loading.
    def self.constants_under_root
      Rails.application.eager_load!
      found = []
      queue = [PermissionForge]
      until queue.empty?
        namespace = queue.shift
        nested_modules(namespace).each do |constant|
          found << constant
          queue << constant
        end
      end
      found.uniq
    end

    def self.nested_modules(namespace)
      namespace.constants(false).sort.filter_map do |name|
        next if namespace.autoload?(name)

        value = namespace.const_get(name, false)
        value if value.is_a?(Module) && value.name == "#{namespace.name}::#{name}"
      end
    end

    def object_for(path) = self.class.registry.at(path)

    # The marker written in a comment directly above one of the object's definitions. Read from the source:
    # YARD's `tags(:api)` also answers with the marker it inherited from an enclosing namespace, which would
    # make an unmarked class look marked.
    def own_marker(path)
      object_for(path)&.files.to_a.each do |file, line|
        lines = File.readlines(file)
        index = line - 2
        while index >= 0 && lines[index].match?(/\A\s*#/)
          marker = lines[index][/\A\s*#\s*@api\s+(\w+)/, 1]
          return marker if marker

          index -= 1
        end
      end
      nil
    end

    # The marker that applies to `path`: its own, else a private one on an enclosing namespace below the root.
    def marker_for(path)
      own = own_marker(path)
      return own if own

      parents = path.split('::')[1...-1]
      parents.size.downto(1) do |size|
        marker = own_marker((['PermissionForge'] + parents.first(size)).join('::'))
        return marker if marker == 'private'
      end
      nil
    end

    test 'every constant under PermissionForge is marked @api public or @api private' do
      unmarked = self.class.constants_under_root.filter_map do |constant|
        path = constant.name
        object = object_for(path)
        next if object.nil?

        path unless MARKERS.include?(marker_for(path))
      end

      assert_empty unmarked,
                   'These constants have no `@api public` or `@api private` in their source comment (README, ' \
                   '"Versioning and stability"; a private namespace covers what is nested in it):' \
                   "\n  " \
                   "#{unmarked.sort.join("\n  ")}"
    end

    test 'the walk sees the namespaces the boundary is about' do
      paths = self.class.constants_under_root.map(&:name)

      %w[PermissionForge::Configuration PermissionForge::Concerns::PermissionedUser PermissionForge::Admin
         PermissionForge::Services::MaskValue PermissionForge::OpenTransaction].each do |expected|
        assert_includes paths, expected
      end
    end

    test 'the documented surface is public and the machinery is private' do
      public_paths = %w[PermissionForge PermissionForge::Configuration PermissionForge::ConfigurationError
                        PermissionForge::Concerns::PermissionedUser PermissionForge::Concerns::MaskedAttributes
                        PermissionForge::Services::DataSubjectErasure PermissionForge::Audit]
      private_paths = %w[PermissionForge::Admin PermissionForge::OpenTransaction PermissionForge::InvalidationBatch
                         PermissionForge::Concerns::PermissionsMemo PermissionForge::Admin::AuditLog]

      public_paths.each { |path| assert_equal 'public', marker_for(path), path }
      private_paths.each { |path| assert_equal 'private', marker_for(path), path }
    end
  end
end
