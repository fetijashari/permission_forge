# frozen_string_literal: true

# Field test round 8 (B#70) — "the save changed something" has one
# definition, RecordsAuditEvents#saved_audited_changes? (saved_changes minus
# the bookkeeping columns): it decides whether a change event is written and
# whether the admin says "No changes to save." (SaveNotice). A second
# reading of saved_changes would let the flash and the audit log disagree
# again (an unchanged action form said "Saved “Export”." and wrote no event).
# "Saving would change something" is its twin before the save,
# RecordsAuditEvents#audited_changes_pending? (changes_to_save minus the same
# columns): the admin saves a record only then (SaveNotice#pf_save_changed).
# The admin controllers' bare dirty-tracking reads are guarded in
# html/unchanged_save_flash_test.rb (models read changed? for their own
# validations and callbacks, so that needle cannot cover app/ and lib/).
module OneDefinition
  SAVE_OUTCOME = [
    { name: 'a save changed something (RecordsAuditEvents#saved_audited_changes?, #audited_changes_pending?)',
      needle: /\b(?:saved_changes\b\??|previously_changed\?|changed_for_autosave\?|changes_to_save\b|has_changes_to_save\?)/,
      canonical: %w[lib/permission_forge/concerns/records_audit_events.rb],
      allowlist: [],
      fixture: 'notice = @rule.saved_changes.any? ? saved : unchanged' }
  ].freeze
end
