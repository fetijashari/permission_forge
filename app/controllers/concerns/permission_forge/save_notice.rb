# frozen_string_literal: true

module PermissionForge
  # An admin save that changes nothing: not written, and said so. One
  # definition for every form that saves a record (the field drawer, the
  # action form, the rule builder, the group page, the Conditions tab, an
  # end date, the set and Resource pages):
  #
  # - a record is saved only when it holds a change an audit event records
  #   (#pf_save_changed, RecordsAuditEvents#audited_changes_pending?: a blank
  #   posted over generated text is no change either, Admin::Prefill.posted;
  #   a stamp of updated_by alone is none) — an unchanged record is not
  #   saved, so no commit callback invalidates its holders' cached
  #   permissions. A batched edit with no change (Admin::ChangeSet) saves
  #   nothing either;
  # - such a save says flash.no_changes (#pf_save_flash) — never the form's
  #   "Saved …", and with no cache note: no cache work was done.
  #
  # Field test round 8 (B#70).
  #
  # @api private
  module SaveNotice
    extend ActiveSupport::Concern

    # @param saved [ActiveRecord::Base, Boolean] the record just saved (or
    #   left unsaved by #pf_save_changed), or whether a batched edit applied
    #   any change
    # @return [Boolean] whether the save changed anything
    def self.saved_anything?(saved)
      return saved if [true, false].include?(saved)

      saved.saved_audited_changes?
    end

    private

    # Assigns `attrs` to `record`, then runs the block (the save: save,
    # save!) only when the record holds a change an audit event records.
    #
    # @param record [ActiveRecord::Base] one of the gem's models
    # @param attrs [Hash] the attributes the form posted
    # @yieldparam record [ActiveRecord::Base]
    # @return the block's value, or true when there was nothing to save
    def pf_save_changed(record, attrs = {})
      record.assign_attributes(attrs)
      return true unless record.audited_changes_pending?

      yield record
    end

    # The flash of a save: { notice: "No changes to save." } when it changed
    # nothing (SaveNotice.saved_anything?), else what the block answers — a
    # flash Hash (CacheConfirmation#cache_flash_text), or a String, the notice.
    #
    # @param saved [ActiveRecord::Base, Boolean]
    # @return [Hash] for redirect_to
    def pf_save_flash(saved)
      return { notice: pf_no_changes_text } unless SaveNotice.saved_anything?(saved)

      flash = yield
      flash.is_a?(Hash) ? flash : { notice: flash }
    end

    # "No changes to save." in the page's language.
    def pf_no_changes_text
      t('permission_forge.flash.no_changes')
    end
  end
end
