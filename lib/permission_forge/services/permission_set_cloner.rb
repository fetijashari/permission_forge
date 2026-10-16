module PermissionForge
  module Services
    # Deep-copies a Permission Set: its resources with their fields, actions
    # and rules — never its assignments. Every copied row is created by an
    # audited save credited to whoever makes the copy (Clonable), and the copy
    # records `permission_set.cloned` naming its source; all of it shares one
    # correlation id (an enclosing Audit.correlate block's, if any).
    #
    #   PermissionSetCloner.call(permission_set: set, attrs: { name: 'Copy' })
    #   PermissionSetCloner.call(permission_set: set, attrs: { name: 'Copy' }, unlock: true) # every row editable
    #
    # @api public
    class PermissionSetCloner
      include Clonable

      # @param permission_set [PermissionSet] the source
      # @param attrs [Hash] attributes of the copy of the set itself
      # @param unlock [Boolean] create every copied row editable
      #   (`is_editable: true`) instead of keeping the source's locks
      # @return [PermissionSet] the copy
      def self.call(permission_set:, attrs: {}, unlock: false)
        new(permission_set, attrs, unlock: unlock).call
      end

      # Without a name the copy is named "<name> (copy)", numbered when taken
      # (names are unique per tenant: PermissionSet.copy_name).
      def initialize(permission_set, attrs, unlock: false)
        @permission_set = permission_set
        @attrs = attrs.key?(:name) || attrs.key?('name') ? attrs : attrs.merge(name: PermissionForge::PermissionSet.copy_name(permission_set.name))
        @unlock = unlock
      end

      # @return [PermissionSet] the copy
      def call
        PermissionForge::Audit.correlate do
          @permission_set.class.transaction do
            cloned = copy(@permission_set, **@attrs)
            clone_resources(cloned)
            record_clone(cloned)
            cloned
          end
        end
      end

      private

      # The rows in the order the hash builder merges them
      # (PermissionHashBuilder.sort_rows, the one definition of row order).
      def clone_resources(target_set)
        @skipped = []
        @permission_set.resources.includes(:resource_fields, :resource_actions, :permission_set_rules).load
        PermissionForge::Services::PermissionHashBuilder.sort_rows(@permission_set)
        @permission_set.resources.each { |resource| clone_resource(target_set, resource) }
        log_skipped
      end

      # A field or action row with a blank name (written before the names
      # were checked) cannot be created again: the copy leaves it out —
      # such a row names no column and no action — and the log says so,
      # once per copy, instead of refusing the whole copy.
      def clone_resource(target_set, resource)
        cloned_resource = copy(resource, permission_set: target_set)

        copyable(resource.resource_fields).each { |field| copy(field, resource: cloned_resource) }
        clone_actions(resource, cloned_resource)
        resource.permission_set_rules.each { |rule| copy(rule, permission_set: target_set, resource: cloned_resource) }
      end

      # One copy per action name. Rows that share a name (possible only on a
      # table without the unique index) are OR-ed when permissions are built
      # (PermissionHashBuilder#merge_resource_actions: the active rows'
      # is_permitted, ||=), so the copy is the single row they amount to.
      def clone_actions(resource, cloned_resource)
        copyable(resource.resource_actions).group_by(&:name).each_value do |rows|
          copy(rows.first, resource: cloned_resource, **combined_action_flags(rows))
        end
      end

      def copyable(rows)
        kept, skipped = rows.partition { |row| !refused_for_blank_name?(row) }
        @skipped.concat(skipped)
        kept
      end

      def log_skipped
        return if @skipped.empty?

        kinds = @skipped.map { |row| row.class.name.demodulize }.tally.map { |kind, count| "#{count} #{kind}" }.join(', ')
        Rails.logger&.warn("[PermissionForge] copying #{@permission_set.name}: skipped #{@skipped.size} row(s) with a blank name (#{kinds})")
      end

      def combined_action_flags(rows)
        return {} if rows.one?

        active = rows.select(&:is_active)
        { is_active: active.any?, is_permitted: (active.presence || rows).any?(&:is_permitted) }
      end

      # The lock is set before the first save, so the row's create event
      # holds it: there is no second, unaudited write.
      def copy(record, **attrs)
        attrs = { is_editable: true }.merge(attrs) if @unlock && record.has_attribute?(:is_editable)
        duplicate_record(record, **attrs)
      end

      def record_clone(cloned)
        PermissionForge::Audit.record('permission_set.cloned', record: cloned,
                                                               data: { 'source_uuid' => @permission_set.uuid,
                                                                       'source_name' => @permission_set.name })
      end
    end
  end
end
