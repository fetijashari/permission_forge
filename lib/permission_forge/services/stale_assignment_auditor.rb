module PermissionForge
  module Services
    # Audits permanent permission set assignments that haven't been reviewed
    # within a configurable threshold (default: 90 days). Reviewed means the
    # last access review "Keep" (reviewed_at), else the grant (created_at) —
    # PermissionSetUser.stale_before; editing an assignment is not a review.
    # Supports GDPR Art. 5(1)(e) — Storage Limitation.
    #
    # @example Find stale assignments
    #   result = StaleAssignmentAuditor.call
    #   # => { stale_count: 5, affected_user_ids: [1, 2], assignments: [...] }
    #
    # @example Custom threshold
    #   result = StaleAssignmentAuditor.call(threshold_days: 30)
    #
    # With a tenant ambient, that tenant's assignments; with none, every
    # tenant's — also under acts_as_tenant's require_tenant
    # (Concerns::AcrossTenants).
    #
    # @api public
    class StaleAssignmentAuditor
      include Concerns::AcrossTenants

      # @param threshold_days [Integer] how long a permanent assignment may go unreviewed
      # @return [Hash] see {#call}
      def self.call(...) = new(...).call

      def initialize(threshold_days: 90)
        @threshold_days = threshold_days
      end

      # @return [Hash] `{ stale_count:, affected_user_ids:, assignments: }`
      def call
        across_tenants do
          stale = stale_assignments
          {
            stale_count: stale.count,
            affected_user_ids: stale.distinct.pluck(:user_id),
            threshold_days: @threshold_days,
            assignments: stale.includes(:permission_set).map { |psu| row_for(psu) }
          }
        end
      end

      private

      def row_for(psu)
        last_reviewed = psu.last_reviewed_at
        {
          user_id: psu.user_id,
          permission_set: psu.permission_set&.name,
          last_updated: psu.updated_at,
          last_reviewed_at: last_reviewed,
          reviewed_by_id: psu.try(:reviewed_by_id),
          days_stale: ((Time.current - last_reviewed) / 1.day).round
        }
      end

      def stale_assignments
        PermissionForge::PermissionSetUser.stale_before(threshold_cutoff)
      end

      def threshold_cutoff
        @threshold_days.days.ago
      end
    end
  end
end
