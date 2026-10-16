# frozen_string_literal: true

module PermissionForge
  # What an admin save says when it saved nothing. One definition for every
  # form that saves a record (the field drawer, the action form, the rule
  # builder, the group page, the Conditions tab, an end date, the set and
  # Resource pages): a record whose save changed nothing an audit event
  # records (RecordsAuditEvents#saved_audited_changes?: a blank posted over
  # generated text is no change either, Admin::Prefill.posted), or a
  # batched edit with no change (Admin::ChangeSet), says
  # flash.no_changes — never the form's "Saved …", and with no cache note
  # (no cache work was done). Field test round 8 (B#70).
  #
  # @api private
  module SaveNotice
    extend ActiveSupport::Concern

    # @param saved [ActiveRecord::Base, Boolean] the record just saved, or
    #   whether a batched edit applied any change
    # @return [Boolean] whether the save changed anything
    def self.changed?(saved)
      return saved if [true, false].include?(saved)

      saved.saved_audited_changes?
    end

    private

    # The flash of a save: { notice: "No changes to save." } when it changed
    # nothing (SaveNotice.changed?), else what the block answers — a flash
    # Hash (CacheConfirmation#cache_flash_text), or a String, the notice.
    #
    # @param saved [ActiveRecord::Base, Boolean]
    # @return [Hash] for redirect_to
    def pf_save_flash(saved)
      return { notice: pf_no_changes_text } unless SaveNotice.changed?(saved)

      flash = yield
      flash.is_a?(Hash) ? flash : { notice: flash }
    end

    # "No changes to save." in the page's language.
    def pf_no_changes_text
      t('permission_forge.flash.no_changes')
    end
  end
end
