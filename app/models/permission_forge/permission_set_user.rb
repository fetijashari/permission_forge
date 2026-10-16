module PermissionForge
  # The assignment of a Permission Set to a user (unique per user and set), optionally with an `expires_at`.
  #
  # @api public
  class PermissionSetUser < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_set_users"

    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::InvalidatesInBatch
    include PermissionForge::Concerns::RecordsAuditEvents

    # optional: is stated on every belongs_to: the host's
    # belongs_to_required_by_default decides nothing here. The parent is
    # optional, as declared since 0.13 (the foreign key holds); the user is
    # required.
    belongs_to :permission_set, class_name: 'PermissionForge::PermissionSet', optional: true
    belongs_to :user, class_name: PermissionForge.configuration.user_class, optional: false

    # Mirrors the DB unique index so a repeat assignment returns a 422 instead of
    # a RecordNotUnique 500 (and prevents silent duplicate rows on schemas that
    # predate the index). BulkPermissionSetAssignment already de-dupes; this
    # covers the single-assignment controller/API paths.
    validates :user_id, uniqueness: { scope: :permission_set_id,
                                      message: ->(*) { I18n.t('permission_forge.validations.permission_set_user.taken') } }

    # An integer user_id column would store a UUID or string user key as its
    # leading digits, handing this assignment to every user who shares them.
    before_validation { PermissionForge::Services::HostKeyGuard.verify! }

    # The reason of the change in progress (Audit::Context, e.g. a ticket
    # from the request) is kept on the row it changed.
    before_save :keep_audit_reason

    # A move to another user takes the set from the previous holder: noted
    # at every save, invalidated with the holder after the commit
    # (InvalidatesInBatch#note_previous_value).
    after_save { note_previous_value('user_id') }

    scope :active_assignments, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }
    scope :expired, -> { where.not(expires_at: nil).where(expires_at: ...Time.current) }

    # Permanent assignments last reviewed before `cutoff` — the access
    # review list and StaleAssignmentAuditor. Reviewed means a "Keep"
    # (reviewed_at), else the grant itself (created_at); a schema without
    # the review columns (upgrade migration not run) keeps measuring from
    # updated_at, as before.
    scope :stale_before, ->(cutoff) { where(expires_at: nil).where(last_reviewed_column.lt(cutoff)) }

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # The review columns exist (bin/rails generate permission_forge:upgrade).
    def self.review_supported?
      column_names.include?('reviewed_at')
    end

    # Arel for "when this assignment was last reviewed" (see stale_before).
    def self.last_reviewed_column
      table = arel_table
      return table[:updated_at] unless review_supported?

      Arel::Nodes::NamedFunction.new('COALESCE', [table[:reviewed_at], table[:created_at]])
    end

    # When this assignment was last reviewed (see stale_before).
    def last_reviewed_at
      return updated_at unless self.class.review_supported?

      reviewed_at || created_at
    end

    # Access review "Keep": records who reviewed the assignment and when,
    # through a normal update that writes one assignment.reviewed event
    # (with the decision; the reason comes from Audit::Context). Without the
    # review columns only updated_at moves, so the event is recorded itself.
    #
    # @param reviewer [Object, nil] the acting admin (its id is stored)
    # @param decision [String]
    # @return [self]
    def mark_reviewed!(reviewer:, decision: 'keep')
      data = { 'decision' => decision }
      if self.class.review_supported?
        attrs = { reviewed_at: Time.current }
        attrs[:reviewed_by_id] = reviewer&.id if has_attribute?(:reviewed_by_id)
        audit_as('assignment.reviewed', data: data) { update!(attrs) }
      else
        record_review_without_columns(data)
      end
      self
    end

    def deactivated?
      active_check = PermissionForge.configuration.user_active_check
      !active_check.call(user)
    end

    def expired?
      expires_at.present? && expires_at < Time.current
    end

    def active_assignment?
      !expired?
    end

    private

    def record_review_without_columns(data)
      transaction do
        update!(updated_at: Time.current)
        PermissionForge::Audit.record('assignment.reviewed', record: self, data: data)
      end
    end

    def keep_audit_reason
      reason = PermissionForge::Audit::Context[:reason]
      return if reason.blank? || !has_attribute?(:reason)
      return unless new_record? || changed?

      self.reason = PermissionForge::Audit::ColumnValues.value(reason.to_s)
    end

    # InvalidatesInBatch (after commit, on create/update/destroy).
    #
    # Assigning or revoking a set must take effect immediately: invalidate the
    # user's cached hash so the next read rebuilds it (read-through). This also
    # covers PermissionSet#destroy — dependent: :destroy removes each assignment
    # through callbacks, so every previously-assigned user is invalidated even
    # though the set's own after_commit can no longer find the deleted rows.
    def invalidate_committed_caches
      super
      invalidate_user_permissions
    end

    def invalidate_user_permissions
      holders = [user_id, *previous_values('user_id')]
      invalidate_assigned_users(holders, invalidation_batch, permission_record_tenant_id)
    end

    # RecordsAuditEvents: the event of a move names the previous holder too
    # (its subject is the new one; data["changes"]["user_id"] has both).
    def audit_update_details
      return {} unless saved_change_to_user_id?

      { 'previous_subject_user_id' => user_id_before_last_save&.to_s }
    end

    # The holder of this assignment is at hand when the assignment was built
    # with it (`create!(user: user)`): no query to load it again.
    def assigned_users(user_ids)
      holder = association(:user).target
      return [holder] if holder && user_ids == [holder.id]

      super
    end
  end
end
