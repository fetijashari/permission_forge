# frozen_string_literal: true

module PermissionForge
  # For the "Review and save" step of a batched edit (Admin::ChangeSet): what
  # to say when there is nothing to save, and once the edit is applied.
  #
  # @api private
  module ChangeReview
    extend ActiveSupport::Concern

    private

    # A plain notice, or — when the request turned on flags their
    # dependencies keep off (ChangeSet#refused: Edit with Read off, ...) — an
    # alert that says which and why, instead of a bare "No changes to save."
    #
    # @return [Hash] for redirect_to
    def pf_nothing_to_save_flash(change_set)
      refused = change_set.refused
      return { notice: pf_no_changes_text } if refused.empty?

      reasons = refused.map { |refusal| helpers.pf_refusal_description(refusal) }
      { alert: t('permission_forge.flash.permission_sets.nothing_applied', reasons: reasons.join('; ')) }
    end

    # The flash of an applied batched edit: how many changes, for whom, and
    # what the cache store confirmed (CacheConfirmation) — or, when it
    # applied none, what the review step says (#pf_nothing_to_save_flash:
    # "No changes to save.", or why each requested change was refused).
    #
    # @param change_set [PermissionForge::Admin::ChangeSet] after #apply!
    # @param outcome [PermissionForge::Cache::Outcome]
    # @return [Hash] for redirect_to
    def pf_applied_flash(change_set, outcome)
      changes = change_set.changes
      return pf_nothing_to_save_flash(change_set) if changes.empty?

      people = helpers.pf_people_text(pf_people_count(@permission_set))
      cache_flash_text(outcome, t('permission_forge.flash.permission_sets.saved', count: changes.size, people: people))
    end
  end
end
