# frozen_string_literal: true

# The audit table taken away for a test: an install whose upgrade migration
# has not run. The model is pointed at a table name that does not exist; no
# table is renamed or dropped (DDL commits the test's transaction on MySQL,
# and what the test writes afterwards then fails).
#
#   include HiddenAuditTable
#   without_audit_table { get '/permission_forge/audit' }
#
# hide_audit_table! / restore_audit_table! are the two halves, for a test
# that restores in its own reset (restore is a no-op when nothing is hidden).
module HiddenAuditTable
  MISSING_NAME = 'audit_events_not_migrated'

  def without_audit_table
    hide_audit_table!
    yield
  ensure
    restore_audit_table!
  end

  def hide_audit_table!
    return if @audit_table_name

    @audit_table_name = PermissionForge::AuditEvent.method(:table_name)
    replace_singleton_method(PermissionForge::AuditEvent, :table_name) { MISSING_NAME }
    forget_audit_table
  end

  def restore_audit_table!
    return unless @audit_table_name

    original = @audit_table_name
    replace_singleton_method(PermissionForge::AuditEvent, :table_name) { original.call }
    @audit_table_name = nil
    forget_audit_table
  end

  private

  # What Rails and the gem remember about the table.
  def forget_audit_table
    PermissionForge::AuditEvent.connection.schema_cache.clear!
    PermissionForge::AuditEvent.reset_column_information
    PermissionForge::Audit.reset!
  end
end
