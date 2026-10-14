# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options for the write path: {PermissionForge::Services::PermitsAttributes},
    # which filters incoming params by field-level edit access.
    #
    # @api public
    module PermitsAttributesSettings
      # How PermitsAttributes treats a `<assoc>_attributes` payload when the
      # user's permission hash has no entry for the association's model:
      #   false — the payload is dropped (default, fail closed)
      #   true  — it is filtered against the PARENT resource's fields, as
      #           versions before 0.14 did (a key editable on the parent then
      #           admits the same key on a child the user was never granted)
      attr_accessor :nested_attributes_parent_fallback

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_permits_attributes_defaults
        @nested_attributes_parent_fallback = false
      end
    end
  end
end
