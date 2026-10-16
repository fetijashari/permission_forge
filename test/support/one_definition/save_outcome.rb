# frozen_string_literal: true

# Field test round 8 (B#70) — "the save changed something" has one
# definition, RecordsAuditEvents#saved_audited_changes? (saved_changes minus
# the bookkeeping columns): it decides whether a change event is written and
# whether the admin says "No changes to save." (SaveNotice). A second
# reading of saved_changes would let the flash and the audit log disagree
# again (an unchanged action form said "Saved “Export”." and wrote no event).
module OneDefinition
  SAVE_OUTCOME = [
    { name: 'a save changed something (RecordsAuditEvents#saved_audited_changes?)',
      needle: /\b(?:saved_changes\b\??|previously_changed\?|changed_for_autosave\?)/,
      canonical: %w[lib/permission_forge/concerns/records_audit_events.rb],
      allowlist: [],
      fixture: 'notice = @rule.saved_changes.any? ? saved : unchanged' }
  ].freeze
end
