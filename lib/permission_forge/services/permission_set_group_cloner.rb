module PermissionForge
  module Services
    # Deep-copies a Permission Set Group with all its Permission Sets (each
    # through PermissionSetCloner) — never its members. The group's copy
    # records `permission_set_group.cloned`, each set's copy
    # `permission_set.cloned`; every event of the copy shares one correlation id.
    #
    # @api public
    class PermissionSetGroupCloner
      include Clonable

      # @param unlock [Boolean] copy the group's sets (and their rows)
      #   editable (`is_editable: true`) instead of keeping their locks
      def self.call(permission_set_group:, attrs: {}, unlock: false)
        new(permission_set_group, attrs, unlock: unlock).call
      end

      def initialize(permission_set_group, attrs, unlock: false)
        @group = permission_set_group
        @attrs = attrs
        @unlock = unlock
      end

      # @return [PermissionSetGroup] the copy
      def call
        PermissionForge::Audit.correlate do
          @group.class.transaction do
            cloned = duplicate_record(@group, **@attrs)
            clone_permission_sets(cloned)
            record_clone(cloned)
            cloned
          end
        end
      end

      private

      def clone_permission_sets(cloned_group)
        @group.permission_sets.each do |ps|
          # Names are unique per tenant: each copy is "<name> (copy)", numbered when taken.
          attrs = { name: PermissionForge::PermissionSet.copy_name(ps.name), permission_set_group: cloned_group }
          attrs[:is_editable] = true if @unlock
          PermissionSetCloner.call(permission_set: ps, attrs: attrs, unlock: @unlock)
        end
      end

      def record_clone(cloned)
        PermissionForge::Audit.record('permission_set_group.cloned', record: cloned,
                                                                     data: { 'source_uuid' => @group.uuid, 'source_name' => @group.name })
      end
    end
  end
end
