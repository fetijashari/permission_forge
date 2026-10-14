module PermissionForge
  module Services
    # Copies one record as a new row. The copy is a new record in every sense:
    # its own uuid, and no author or editor carried over from the original —
    # HasAuditTrail credits whoever makes the copy, and the copy's create
    # event (RecordsAuditEvents) names the same person. A field's "This is
    # intended" acknowledgement is one person's attestation about one set, so
    # a copy starts unacknowledged.
    #
    # @api private
    module Clonable
      # Columns a copy never takes from its original (those the table has).
      RESET_ON_COPY = %w[uuid created_by_id updated_by_id sensitive_acknowledged_at sensitive_acknowledged_by_id].freeze

      private

      def duplicate_record(record, **attrs)
        cloned = record.dup
        cloned.assign_attributes(reset_on_copy(cloned).merge(attrs))
        cloned.save!
        cloned
      end

      def reset_on_copy(record)
        RESET_ON_COPY.select { |column| record.has_attribute?(column) }.index_with(nil)
      end
    end
  end
end
