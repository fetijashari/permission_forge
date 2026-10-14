module PermissionForge
  module Services
    # Gives a model's declared extra (virtual) fields their implicit entry when
    # nothing configured them: readable when the resource grants read,
    # editable when it grants edit, never masked.
    #
    # Strictly ADDITIVE: a name that already has an entry (a ResourceField row,
    # or a variant of one) is left untouched, so an extra field can never
    # unmask or grant edit on a field an admin configured. PermissionHashBuilder
    # calls this once per resource, after every granting set is merged, so a
    # row in ANY of the user's sets wins whatever order the sets are in, and
    # the resource flags it follows are the merged ones (edit from any set).
    #
    # Only names the model declares through extra_fields_method are read, and
    # only under extra_fields_default_access = :grant. Under :unconfigured
    # nothing is added: the field follows unconfigured_field_strategy, like a
    # column. Names the admin merely discovers never get an entry here.
    #
    # An error raised by the host's extra_fields_method is not rescued: a
    # broken method must fail the build of the hash, not quietly change it.
    #
    # @api private
    class ExtraFieldDefaults
      # The entry's mask part: an implicit entry is never masked.
      UNMASKED = { mask_access: false, mask_strategy: 'full' }.freeze

      # @param entry [Hash] the resource's entry in the hash being built:
      #   its :fields (written in place) and its merged :permissions
      # @return [Hash] the fields, with implicit entries added
      def self.call(entry:, resource_name:, configuration: PermissionForge.configuration)
        new(entry:, resource_name:, configuration:).call
      end

      # The implicit entry for a resource with the given merged permissions.
      # Only an exact `true` grants: the entry used to be read + edit for
      # everyone who could read the resource, so a read-only user could write
      # a declared virtual field (before 0.14).
      #
      # @param permissions [Hash] the resource's merged :permissions
      # @return [Hash] a new entry
      def self.implicit_entry(permissions)
        { read_access: permissions[:read_access] == true, edit_access: permissions[:edit_access] == true, **UNMASKED }
      end

      def initialize(entry:, resource_name:, configuration:)
        @fields = entry.fetch(:fields)
        @permissions = entry.fetch(:permissions)
        @resource_name = resource_name.to_s
        @configuration = configuration
      end

      # @return [Hash] the fields hash, with implicit entries added
      def call
        declared_names.each { |name| @fields[name] ||= self.class.implicit_entry(@permissions) }
        @fields
      end

      private

      # @fields is String-keyed until the cache symbolizes it. A Symbol name
      # would miss the collision check, sit beside the configured String key,
      # and replace it once both become Symbols — so VirtualFields.extra_names
      # returns Strings.
      def declared_names
        return [] unless @configuration.grant_extra_fields_by_default?

        PermissionForge::VirtualFields.extra_names(@resource_name.safe_constantize, @configuration)
      end
    end
  end
end
