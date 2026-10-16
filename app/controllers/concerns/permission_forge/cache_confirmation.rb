# frozen_string_literal: true

module PermissionForge
  # For admin actions that clear somebody's cached permissions: says what the
  # cache store confirmed, and when the store lives in this process only,
  # instead of announcing success whatever happened. One Cache::Outcome
  # (Cache::Report) is the datum, as in the rake tasks, the API and the
  # audit events.
  #
  # @api private
  module CacheConfirmation
    extend ActiveSupport::Concern

    private

    # Measures the invalidations made in the block (Cache::Report.of). The
    # gem's own failure bookkeeping is asked, not the value of
    # invalidate_permissions: host apps override that method.
    #
    # @return [PermissionForge::Cache::Outcome]
    def cache_outcome(&)
      PermissionForge::Cache::Report.of(&)
    end

    # The notice — or, when the cache store did not confirm that the cached
    # permissions are gone, the alert, which says the old ones may still be
    # served (a confirmation not known yet, inside a transaction of the
    # host's, is not a failure). `keys` names both, under
    # permission_forge.flash.<controller_name>: `{ notice: :erased, alert: :erased_cache_kept }`.
    # When the store lives in this process only (Outcome#process_local?) the
    # text ends with flash.cache_process_local: other processes kept theirs.
    #
    # @param outcome [PermissionForge::Cache::Outcome, Hash] an Outcome, or a service's `cache:`
    # @return [Hash] for redirect_to
    def cache_flash(outcome, keys, **)
      outcome = PermissionForge::Cache::Outcome.wrap(outcome)
      kind = outcome.flash_kind
      cache_scoped(outcome, kind => t("permission_forge.flash.#{controller_name}.#{keys.fetch(kind)}", **))
    end

    # The flash for a change whose message has no alert of its own (one
    # assignment, a batch of edits): `text` as the notice, or — when the
    # store did not confirm — as the alert, followed by
    # flash.cache_not_confirmed; flash.cache_process_local as in #cache_flash.
    #
    # @param outcome [PermissionForge::Cache::Outcome]
    # @param text [String] the translated notice
    # @return [Hash] for redirect_to / pf_redirect
    def cache_flash_text(outcome, text)
      kind = outcome.flash_kind
      text = "#{text} #{t('permission_forge.flash.cache_not_confirmed')}" if kind == :alert
      cache_scoped(outcome, kind => text)
    end

    # `flash` with flash.cache_process_local appended when the store lives
    # in this process only.
    def cache_scoped(outcome, flash)
      return flash unless outcome.process_local?

      flash.transform_values { |text| "#{text} #{t('permission_forge.flash.cache_process_local')}" }
    end
  end
end
