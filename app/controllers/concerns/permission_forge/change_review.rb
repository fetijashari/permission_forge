# frozen_string_literal: true

module PermissionForge
  # For the "Review and save" step of a batched edit (Admin::ChangeSet): what
  # to say when there is nothing to save.
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
      return { notice: t('permission_forge.flash.permission_sets.no_changes') } if refused.empty?

      reasons = refused.map { |refusal| helpers.pf_refusal_description(refusal) }
      { alert: t('permission_forge.flash.permission_sets.nothing_applied', reasons: reasons.join('; ')) }
    end
  end
end
