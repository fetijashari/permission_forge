module PermissionForge
  # The acting admin as a record whose id can be stored (reviewed_by_id,
  # sensitive_acknowledged_by_id, created_by_id), or nil — under HTTP Basic
  # or a resolver that returns something that is not a record. The audit
  # event's actor comes from the audit context either way.
  #
  # @api private
  module ActingAdmin
    private

    # @return [Object, nil] pf_current_admin when it has an id
    def pf_acting_admin_record
      admin = pf_current_admin
      admin.respond_to?(:id) ? admin : nil
    end
  end
end
