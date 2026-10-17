# frozen_string_literal: true

module PermissionForge
  module Audit
    # The reasons the gem records on an event itself, stored as codes (never
    # English): the admin renders a code from the locale
    # (`permission_forge.audit_log.reason_codes.<code>`, helper
    # `pf_audit_reason`) and any other reason as it was typed. The CSV export
    # and the API keep the stored value.
    #
    # @api private
    module ReasonCodes
      # ExpiredAssignmentCleaner's reason when nobody gave one (rake, the admin's Clean up).
      EXPIRED = 'expired'
      # Every code.
      ALL = [EXPIRED].freeze

      # @param reason [String, nil] an event's (or a row's) stored reason
      # @return [Boolean] whether it is one of the gem's codes
      def self.code?(reason)
        ALL.include?(reason.to_s.strip)
      end
    end
  end
end
