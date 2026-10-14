# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Drops ControllerActions::ManagedIndex when a record that defines it
    # changes: a row that counts being created, destroyed or renamed, or a row
    # or Permission Set being switched on or off. Flag edits (CRUD toggles,
    # is_permitted) leave the index alone — they change who is granted, not
    # what is managed.
    #
    # The change is noted at each save and consumed at commit. after_commit on
    # its own sees only the LAST save of a transaction: a row created (or
    # switched on) and then saved again would look unchanged there, and the
    # guard would keep treating its action as unmanaged.
    #
    # A note is only ever consumed by a commit, never forgotten: a later save
    # rolled back to a savepoint must not take the note of an earlier save
    # with it. After a rollback the note stays, and the record's next commit
    # drops the index once more than needed — which costs one rebuild, where a
    # missed drop lets requests through for as long as the index lives.
    #
    # The note is also left in the transaction's InvalidationBatch: of two
    # instances of one row written in a transaction, Rails runs the commit
    # callbacks of one, which may not be the one that changed what is managed.
    #
    # The index is dropped after commit through InvalidatesInBatch: once per
    # transaction (and tenant), however many of its records changed what is
    # managed.
    #
    # @api private
    module InvalidatesManagedActions
      extend ActiveSupport::Concern
      include InvalidatesInBatch

      NOTE = :managed_actions

      included do
        after_save :note_managed_actions_change
      end

      private

      def note_managed_actions_change
        return unless managed_actions_changed?

        @pf_managed_actions_changed = true
        note_in_invalidation_batch(NOTE, permission_record_tenant_id)
      end

      # The index first, and each of the two even when the other raises.
      def invalidate_committed_caches
        invalidate_managed_actions
      ensure
        super
      end

      def invalidate_managed_actions
        batch = invalidation_batch
        tenant_ids = batch.noted(NOTE)
        tenant_ids |= [permission_record_tenant_id] if destroyed? ? is_active : @pf_managed_actions_changed

        tenant_ids.each do |tenant_id|
          batch.once([NOTE, tenant_id]) do
            PermissionForge::ControllerActions::ManagedIndex.invalidate!(tenant_id: tenant_id)
          end
        end
        @pf_managed_actions_changed = false
      end

      # Whether the save just made changed what is managed. For a Resource or
      # ResourceAction: a new row that counts, a row switched on or off, or a
      # rename of a row that counts. PermissionSet overrides this.
      def managed_actions_changed?
        return is_active if previously_new_record?

        saved_change_to_is_active? || (is_active && saved_change_to_name?)
      end
    end
  end
end
