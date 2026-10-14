# frozen_string_literal: true

module PermissionForge
  # For admin actions that clear somebody's cached permissions: says what the
  # cache store confirmed, instead of announcing success whatever happened.
  #
  # @api private
  module CacheConfirmation
    extend ActiveSupport::Concern

    private

    # Whether the cache store confirmed every invalidation made in the block.
    # The gem's own failure bookkeeping is asked, not the value of
    # invalidate_permissions: host apps override that method.
    def cache_confirmed?(&)
      PermissionForge::Cache::Failure.none?(&)
    end

    # The notice — or, when the cache store did not confirm that the cached
    # permissions are gone, the alert, which says the old ones may still be
    # served. `keys` names both, under permission_forge.flash.people:
    # `{ notice: :erased, alert: :erased_cache_kept }`.
    #
    # @return [Hash] for redirect_to
    def cache_flash(confirmed, keys, **)
      kind = confirmed ? :notice : :alert
      key = keys.fetch(kind)
      { kind => t("permission_forge.flash.people.#{key}", default: key.to_s.humanize, **) }
    end
  end
end
