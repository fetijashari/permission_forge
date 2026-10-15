# frozen_string_literal: true

module PermissionForge
  module Admin
    # The is_editable lock, walked up what a record belongs to: a record is
    # locked when it, its Resource, its Permission Set, or (for a membership)
    # its Permission Set Group has is_editable: false. The admin screens and
    # the JSON API ask this one walk before every change, so a locked
    # Permission Set gains and loses no resources, fields, rules, actions or
    # holders through either surface, and a locked Resource keeps its fields,
    # rules and actions.
    #
    # A set's group is not part of its chain: a locked group freezes its own
    # name, its members and its list of sets (see .locked_group_for_move),
    # not the content of the sets in it — as on the group page.
    #
    # The lock never blocks narrowing access, and always blocks widening it
    # (.widening_lock). Which way a change to the holders goes depends on
    # the set: a granting set gives its holders access, so removing a holder
    # or ending their assignment sooner narrows, and adding a holder,
    # restoring a removal, clearing or extending an end date widens. A
    # Muting Permission Set takes access away from its holders, so each of
    # those changes goes the other way: adding a holder or keeping them
    # longer narrows, removing one or ending their assignment sooner widens.
    #
    # @example
    #   EditableLock.locked_record(field)          # => the locked Resource or Permission Set, or nil
    #   EditableLock.chain(rule)                   # => [rule, resource, permission_set]
    #   EditableLock.widening_lock(set, :revoke)   # => the set when it is locked and muting, else nil
    module EditableLock
      # What each record belongs to, for the lock: the first that is present.
      PARENTS = {
        'PermissionForge::Resource' => %i[permission_set],
        'PermissionForge::ResourceField' => %i[resource],
        'PermissionForge::ResourceAction' => %i[resource],
        'PermissionForge::PermissionSetRule' => %i[resource permission_set],
        'PermissionForge::PermissionSetUser' => %i[permission_set],
        'PermissionForge::PermissionSetGroupUser' => %i[permission_set_group]
      }.freeze

      # What a record is listed in: deleting it changes that list, so a
      # locked container refuses the deletion (a set in a locked group).
      CONTAINERS = { 'PermissionForge::PermissionSet' => :permission_set_group }.freeze

      module_function

      # @param record [ActiveRecord::Base, nil]
      # @return [Array<ActiveRecord::Base>] the record, then what it belongs to
      def chain(record)
        records = []
        while record && records.none? { |seen| seen.equal?(record) }
          records << record
          record = parent_of(record)
        end
        records
      end

      # @param records [Array<ActiveRecord::Base, nil>]
      # @return [ActiveRecord::Base, nil] the first locked record in their chains
      def locked_record(*records)
        records.flatten.compact.each do |record|
          locked = chain(record).find { |link| locked?(link) }
          return locked if locked
        end
        nil
      end

      # @return [Boolean] whether the record itself is flagged is_editable: false
      def locked?(record)
        record.respond_to?(:is_editable) && record.is_editable == false
      end

      # Moving a set from one Permission Set Group to another changes both
      # groups' lists of sets: refused when either is locked (the group
      # page's add/remove set refuses the same).
      #
      # @param from [Integer, nil] the group id the set has
      # @param to [Integer, String, nil] the group id it would get
      # @return [PermissionForge::PermissionSetGroup, nil] the locked group, if any
      def locked_group_for_move(from:, to:)
        to = RecordId.cast(to)
        return nil if to == from

        PermissionForge::PermissionSetGroup.where(id: [from, to].compact).detect { |group| locked?(group) }
      end

      # The container whose list deleting `record` would change, or nil.
      #
      # @return [ActiveRecord::Base, nil] e.g. a set's Permission Set Group
      def container_of(record)
        association = CONTAINERS[record.class.name]
        association && record.public_send(association)
      end

      # How a change moves a person's holding of a set: +1 they hold it more
      # (added, or kept longer), -1 less (removed, or ended sooner), 0 not at
      # all (the same end date again).
      HOLDING = {
        grant: ->(**) { 1 },
        revoke: ->(**) { -1 },
        change_expiry: ->(from:, to:) { expiry_direction(from: from, to: to) }
      }.freeze

      # Whether a change to the holders of `permission_set` gives anybody
      # more access: holding a granting set more, or a Muting Permission Set
      # less.
      #
      # @param permission_set [PermissionForge::PermissionSet]
      # @param change [Symbol] :grant, :revoke, or :change_expiry (with from:/to:)
      # @param from [Time, nil] the end date the assignment has (:change_expiry)
      # @param to [Time, nil] the one it would get (:change_expiry)
      # @return [Boolean]
      def widens_access?(permission_set, change, **expiry)
        direction = HOLDING.fetch(change).call(**expiry)
        permission_set.is_muting ? direction.negative? : direction.positive?
      end

      # The locked record that refuses a change to the holders of
      # `permission_set`: the set itself when the change widens access
      # (.widens_access?) and the set is locked; nil when the change may go
      # ahead — a narrowing one always may.
      #
      # @return [PermissionForge::PermissionSet, nil]
      def widening_lock(permission_set, change, **expiry)
        return nil unless widens_access?(permission_set, change, **expiry)

        locked_record(permission_set)
      end

      # The end-date changes a "Change end date" menu (or Home's "Extend 30
      # days", ExpiryPresets::EXTEND_KEY) offers for `assignment`: those the
      # lock lets through (.widening_lock), so a locked set never offers a
      # choice that would be refused.
      #
      # @param assignment [PermissionForge::PermissionSetUser]
      # @param keys [Array<String>] the changes to choose from (ExpiryPresets.change_to keys)
      # @return [Array<String>]
      def expiry_choices(assignment, keys: ExpiryPresets::CHANGE_KEYS, today: Time.zone.today)
        set = assignment.permission_set
        return keys unless locked_record(set)

        keys.reject do |key|
          to = ExpiryPresets.change_to(key, from: assignment.expires_at, today: today)
          widening_lock(set, :change_expiry, from: assignment.expires_at, to: to)
        end
      end

      # +1 when the end date moves later or is cleared, -1 when it moves
      # earlier or is set where there was none, 0 when it stays. Compared at
      # the column's precision (microseconds): a preset computes its end with
      # nanoseconds (end_of_day), the stored value has none, and choosing the
      # same preset again is no change.
      #
      # @param from [Time, nil] the end date the assignment has
      # @param to [Time, nil] the one it would get
      # @return [Integer]
      def expiry_direction(from:, to:)
        return 0 if from.nil? && to.nil?
        return 1 if to.nil?
        return -1 if from.nil?

        to.floor(6) <=> from.floor(6)
      end

      def parent_of(record)
        PARENTS.fetch(record.class.name, []).each do |association|
          parent = record.public_send(association)
          return parent if parent
        end
        nil
      end
      private_class_method :parent_of
    end
  end
end
