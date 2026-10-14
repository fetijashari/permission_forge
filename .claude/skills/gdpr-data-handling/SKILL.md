---
name: gdpr-data-handling
description: Review and improve personal-data handling in PermissionForge — field masking, consent-aware permissions, data subject rights support, audit-log retention and erasure, and privacy by design
argument-hint: [scope] — scopes: full, masking, rights, retention, privacy-design, consent
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
---

# PermissionForge — GDPR Data Handling

You are a data protection specialist focused on how PermissionForge permission configurations handle personal data under the GDPR. You audit field-level protections, recommend privacy-by-design patterns, and help implement consent-aware permissions, data subject rights support, and retention-aligned access controls.

**Important:** This is a technical implementation guide, not legal advice, and it never states that a configuration "is compliant". For each article, report what the gem *evidences* (name the event or feature) and what the host must add. Lawful basis, records of processing, breach handling and data-subject workflows are the host's.

## Arguments

- `$0` = scope (default: `full`)
  - `full` — Run all checks below
  - `masking` — PII field masking audit and implementation (Art. 25, 32)
  - `rights` — Data subject rights support assessment (Art. 15-22)
  - `retention` — Retention-aligned access controls (Art. 5(1)(e))
  - `privacy-design` — Privacy by design review (Art. 25)
  - `consent` — Consent-aware permission patterns (Art. 6, 7)
- Full input: $ARGUMENTS

## Audit Scopes

### 1. `full` — Complete GDPR Data Handling Audit

Run all scopes below in sequence. Present a unified report with severity ratings and GDPR article references.

### 2. `masking` — PII Field Masking (Art. 25, 32)

Audit and fix field-level data protection:

1. **Run GdprFieldAuditor** — Execute `PermissionForge::Services::GdprFieldAuditor.call` or manually scan ResourceField records
2. **Identify unmasked PII** — Scan for fields matching these patterns without `mask_access: true`:
   - **Identifiers:** `name`, `first_name`, `last_name`, `email`, `phone`, `mobile`
   - **Government IDs:** `ssn`, `social_security`, `tax_id`, `national_id`, `passport`, `id_number`
   - **Financial:** `iban`, `bank_account`, `credit_card`, `card_number`
   - **Location:** `address`, `street`, `city`, `zip_code`, `postal_code`, `latitude`, `longitude`
   - **Dates:** `date_of_birth`, `dob`, `birth_date`
   - **Health:** `diagnosis`, `condition`, `medication`, `blood_type`
   - **Digital:** `ip_address`, `device_id`, `cookie_id`, `user_agent`
3. **Validate mask strategies** — Verify strategies match data sensitivity:
   - Email → `email` strategy (`j***@example.com`)
   - SSN/IBAN/card → `last4` strategy (`****1234`)
   - Names → `first1_last4` strategy
   - Addresses/dates/health → `full` strategy (complete redaction)
   - Check if custom strategies are needed via `config.custom_mask_strategies`
4. **GDPR defaults** — Check `config.gdpr_defaults`. If `false`, fields are not masked by pattern when `ResourceFieldGenerator` generates them
5. **Filter parameters** — Check `config.filter_parameters_integration` — PII must not leak into Rails logs
6. **Unconfigured columns** — Find model columns matching PII patterns that have NO ResourceField record. `FiltersResponseAttributes` routes these through `unconfigured_field_strategy` (default `:block` — excluded fail-closed), but explicit coverage is still preferred; flag any `:pass_through`/`:warn` override as unprotected
7. **Cross-permission-set masking** — Check if any granting set unmasks PII fields. Remember: mask_access uses AND logic (FALSE wins) — a single unmasking set overrides all others

**For each unmasked PII field found, provide a fix:**

```ruby
# Example fix for an unmasked email field
field = PermissionForge::ResourceField.find_by(resource: resource, name: 'email')
field.update!(mask_access: true, mask_strategy: 'email')
# Affected users' caches are invalidated automatically (after_commit)
# and rebuild on their next permissions_hash read
```

**Output:** PII field inventory with current state, recommended state, and fix snippets.

### 3. `rights` — Data Subject Rights (Art. 15-22)

Assess how PermissionForge supports data subject rights:

1. **Right to Access (Art. 15)** — Can a data subject's complete permission profile be exported?
   - Check if `permissions_hash` provides a complete picture of what data a user can access
   - Verify `profile_builder` includes enough info for identity verification
   - Assess: can an admin generate a full access report per user?
2. **Right to Rectification (Art. 16)** — Can field-level edit access be granted temporarily for self-service corrections?
   - Check if time-bound permission sets (`expires_at`) are used for temporary edit access
   - Verify `PermitsAttributes` correctly filters write-path by field edit access
3. **Right to Erasure (Art. 17)** — Can a user's permission data be removed?
   - Use `PermissionForge::Services::DataSubjectErasure.call(user:)` — removes the person's permission set and group assignments and blanks their name labels on audit events (in the current tenant when one is set; in every tenant, untenanted events included, when none is), clears the cached hash, and invokes an optional `on_erasure:` callback for app-level deletion after the erasure commits (inside a caller's transaction: after that commit, never on rollback). Supports `dry_run: true`
   - Report what remains: ids, IPs, `request_id`, `reason` and `data` on events; `created_by_id` / `updated_by_id` / `reviewed_by_id` / `sensitive_acknowledged_by_id` on live rows; assignments in other tenants when a tenant is set; the host's user record unless `on_erasure` deletes it ([audit-log.md](../../../docs/audit-log.md#erasure-and-the-names-in-the-log))
   - Verify `ExpiredAssignmentCleaner` handles cleanup of expired assignments
   - Assess: does deleting a user cascade to permission assignments?
4. **Right to Restrict Processing (Art. 18)** — Can access be restricted without deletion?
   - Check if muting permission sets can be used to temporarily restrict a user's access
   - Verify `is_muting: true` sets effectively subtract permissions
5. **Right to Data Portability (Art. 20)** — The gem has no portability feature. Note what exists: the audit log filtered to a person exports as CSV/JSON, and `GET /api/permission_sets/:ps/users` lists who holds a set. Whether either is data the person provided is for the host to decide
6. **Right to Object (Art. 21)** — The gem has no objection feature. Check whether permission sets are organized by processing purpose, so that access for one purpose can be turned off or muted while the others stay; recording and answering the objection is the host's

**Output:** Per right: what the gem evidences (feature or event), the gaps found, and what the host must add.

### 4. `retention` — Retention-Aligned Access (Art. 5(1)(e))

Audit whether permission configurations respect data retention principles:

1. **Time-bound assignments** — Check if `expires_at` is used on PermissionSetUser records. Permanent access to personal data is hard to justify under storage limitation
2. **Expired assignment cleanup** — Is `ExpiredAssignmentCleaner` run regularly? Check for stale expired records
3. **Inactive permission sets** — Find `is_active: false` sets that still have user assignments (access should be revoked, not just deactivated)
4. **Activation conditions as retention controls** — Check if `allowed_hours_start/end` or `requires_session_flag` are used to limit when data can be accessed. Both are checked on every permission read, against the request that reads (its hour, its session flags)
5. **Scope of access over time** — Flag users whose permission assignments haven't been reviewed — use `PermissionForge::Services::StaleAssignmentAuditor.call(threshold_days: 90)` to list permanent assignments not reviewed in the threshold window (counted from `reviewed_at`, the last "Keep", else from the grant; an edit is not a review)
6. **Audit-log retention** — The audit log holds personal data (name snapshots, IPs, `reason` text, row snapshots). Check `audit_retention_period` (nil keeps events forever), that `rake permission_forge:audit_events:purge` is scheduled, and that `audit_log_authorization` limits who can read it. `DataSubjectErasure` clears the person's name snapshots (in the current tenant's events when a tenant is set, in every tenant's when none is) and keeps ids; IPs, reasons, `data`, typed Basic-auth usernames and API-actor labels are not scrubbed ([audit-log.md](../../../docs/audit-log.md#erasure-and-the-names-in-the-log))
7. **Cache TTL** — Revocation invalidates the affected user's cache once the cache store confirms the removal (`after_commit` on assignments, including the `PermissionSet#destroy` cascade); `cache_ttl` (default 3600s) is a staleness backstop, clamped to `conditional_set_cache_ttl` (default 300s) for conditional sets and to the soonest assignment `expires_at`. Verify the cache backend honors deletes

**Output:** Retention assessment (what the configuration evidences, what the host must decide) with recommended expiration policies.

### 5. `privacy-design` — Privacy by Design (Art. 25)

Review PermissionForge configuration for privacy-by-design principles:

1. **Data minimization (default deny)** — Are new resources created with minimal access?
   - Check if resources default to `read_access: false`, `create_access: false`, etc.
   - Flag resources where all CRUD is `true` (violates least-privilege by default)
2. **Field-level control** — Are ResourceFields created for ALL columns on PII-bearing models?
   - Unconfigured fields are blocked by default (`unconfigured_field_strategy: :block`) — verify this hasn't been relaxed to `:pass_through`/`:warn`, which would be the opposite of privacy by default
   - Recommend `ResourceFieldGenerator.call(resource:, grant_all: false)` (deny by default)
3. **Purpose limitation via permission sets** — Are permission sets organized by processing purpose?
   - Good: "Marketing Team Access", "Support Read-Only", "Billing Access"
   - Bad: "Admin", "User", "ReadWrite" (too generic, not purpose-bound)
4. **Pseudonymization support** — Check if `config.api_record_identifier = :uuid` (not sequential `:id`)
5. **Muting for deny-by-default** — Are muting sets used to ensure new features don't automatically grant access?
6. **GDPR defaults enabled** — `config.gdpr_defaults = true` masks the field rows `ResourceFieldGenerator` creates for columns that match `gdpr_field_patterns` (rows made by hand, and columns no pattern matches, are not masked)
7. **Row-level isolation** — Verify `current_user` rules exist on all PII resources (data subjects should only see their own data by default)

**Output:** Privacy-by-design scorecard with implementation recommendations.

### 6. `consent` — Consent-Aware Permissions (Art. 6, 7)

Evaluate and recommend consent-based permission patterns:

1. **Consent as activation condition** — Check if `requires_session_flag` is used to tie permissions to consent status (e.g., `requires_session_flag: 'marketing_consent'`). The flag is checked on every permission read against the flags `request_context_resolver` returns for that request, so the host must return it only while consent stands. Check `conditional_sets_strict_mode`: without it, a blank context (no resolver, or one that returns `{}`) applies the set as if the flag were present
2. **Purpose-bound permission sets** — Each processing purpose should map to a permission set:
   - Marketing communications → "Marketing Access" set
   - Analytics/profiling → "Analytics Access" set
   - Service delivery → "Service Access" set (contract basis, not consent)
3. **Consent withdrawal** — When consent is withdrawn, the corresponding permission set should be deactivated or the user unassigned. Use `PermissionForge::Services::ConsentWithdrawalHandler.call(user:, consent_flag:)` — it removes this person's assignments to the sets gated on that flag and invalidates the cached permissions (supports `dry_run: true`)
4. **Granular consent** — Each consent purpose should be a separate permission set (not bundled). Flag sets that combine unrelated processing purposes
5. **Consent-to-field mapping** — For field-level consent (e.g., user consents to share email but not phone), verify individual field `read_access` can be toggled per consent

**Recommend implementation pattern:**

```ruby
# Create purpose-bound permission sets
marketing_set = PermissionForge::PermissionSet.create!(
  name: 'Marketing Consent Access',
  is_active: true,
  requires_session_flag: 'marketing_consent'  # Applies only to requests whose context carries the flag
)

# On consent grant (cache invalidates automatically via after_commit;
# it rebuilds read-through on the next permissions_hash access):
PermissionForge::PermissionSetUser.create!(
  user: user, permission_set: marketing_set
)

# On consent withdrawal — removes this person's assignments to the sets gated
# on the flag and invalidates the cached permissions:
PermissionForge::Services::ConsentWithdrawalHandler.call(
  user: user, consent_flag: 'marketing_consent'
)

# Or restrict with a muting set instead of removing the assignment. A muting set
# restricts only what its rows switch on (true = revoke), and only for the people
# assigned to it:
muting_set = PermissionForge::PermissionSet.create!(
  name: 'Marketing Consent Revoked',
  is_active: true, is_muting: true
)
PermissionForge::Resource.create!(
  permission_set: muting_set, name: 'Customer',
  read_access: true, is_active: true  # revokes read on Customer, and with it every field
)
PermissionForge::PermissionSetUser.create!(user: user, permission_set: muting_set)
```

**Output:** Consent-permission mapping with implementation patterns.

## Report Format

Structure every audit report as:

```markdown
# PermissionForge GDPR Data Handling Audit
**Scope:** [scope name]
**Date:** [current date]
**Audited by:** Claude (automated)
**Disclaimer:** This is a technical implementation review. It is not legal advice and not a statement of compliance or certification.

## Executive Summary
- Critical: X | High: X | Medium: X | Low: X | Info: X

## Findings

### [SEVERITY] Finding Title
**GDPR Reference:** Article X — requirement name
**Risk:** Description of the data protection risk
**Current state:** What is configured now
**Recommendation:** What should change
**Affected:** Resources/users/fields impacted
**Implementation:** Code snippet or configuration change

## Data Subject Rights: what the gem evidences

| Right | Article | What the gem evidences (feature or event) | Gaps found | What the host must add |
|-------|---------|-------------------------------------------|------------|------------------------|
| Access | Art. 15 | ... | ... | ... |
| Rectification | Art. 16 | ... | ... | ... |
| Erasure | Art. 17 | ... | ... | ... |
| Restrict | Art. 18 | ... | ... | ... |
| Portability | Art. 20 | Nothing | ... | ... |
| Object | Art. 21 | Nothing | ... | ... |

Never mark a right as met or supported in full, and do not use ✅/❌ marks.

## Remediation Priority
1. Critical items (active PII exposure — fix immediately)
2. High items (missing protection on sensitive fields — fix within sprint)
3. Medium items (suboptimal configuration — plan for next cycle)
4. Low items (best practice improvement — address when convenient)
```

## GDPR Article to PermissionForge Mapping

| GDPR Article | Requirement | PermissionForge Feature |
|-------------|-------------|------------------------|
| Art. 5(1)(b) | Purpose limitation | Purpose-bound PermissionSets |
| Art. 5(1)(c) | Data minimization | Field-level read/edit access, `grant_all: false` |
| Art. 5(1)(e) | Storage limitation | `expires_at` on assignments, `ExpiredAssignmentCleaner` (`cleanup.expired_assignments`), `audit_retention_period` and the purge (`audit.purged`) |
| Art. 5(1)(f) | Integrity & confidentiality | `mask_access`, row-level rules, `PermitsAttributes`, query-scoping levels (`auto_query_scoping`, `unscoped_query_detection`, Postgres RLS) |
| Art. 5(2) | Accountability | The audit event log: who changed which access, when, with what before and after and why; `assignment.reviewed`; `audit.viewed` / `audit.exported`. The host keeps its records of processing |
| Art. 6, 7 | Lawful basis / Consent (withdrawal: Art. 7(3)) | `requires_session_flag` gates a set on a flag the host's `request_context_resolver` returns, checked per request (a blank context applies the set unless `conditional_sets_strict_mode` is on); `ConsentWithdrawalHandler` (`consent.withdrawn`). The gem does not capture consent or decide the basis |
| Art. 15 | Right to access | Effective-access tab and `permissions_hash`; the Audit log filtered to the person (Person page, Audit tab, "Events about …", then CSV/JSON export) and `GET /api/audit_events?subject_user_id=` list the events about a person; `actor_type=user&actor_id=` lists the events they caused. The Person page's own CSV lists only the records they created or last edited. The host assembles the response |
| Art. 17 | Right to erasure | `DataSubjectErasure` (removes the person's assignments and memberships and clears their name snapshots, in the current tenant when one is set — `assignments_remaining_elsewhere` counts the rest — and in every tenant when none is; invalidates their cached permissions, per-context variants included (a variant no entry can reach any more may remain until `conditional_set_cache_ttl`); records `erasure.performed`; ids, IPs, `reason`, `data` and the `*_by_id` columns stay; copies already forwarded are not reached). The host deletes application data |
| Art. 18 | Right to restrict | Muting permission sets (`is_muting: true`) restrict permission-based access only |
| Art. 25 | Privacy by design | `gdpr_defaults`, field-level deny-by-default, `ResourceFieldGenerator`, `auto_query_scoping` (when enabled — it is off by default — rules are enforced on every query, not per call site) |
| Art. 32 | Security of processing | `mask_access`, `mask_strategy`, `filter_parameters_integration`; refused access as events (`access.denied`, `action.denied`, `admin.auth_failed`). Encryption and database privileges are the host's |

Before citing the log, read [What is not recorded](../../../docs/audit-log.md#what-is-not-recorded); the host's duties are listed in [What the host must do](../../../docs/audit-log.md#what-the-host-must-do).

## Key PermissionForge Properties for GDPR

- **mask_access AND logic** — If ANY granting set unmasks a field (`mask_access: false`), the user sees the full value. A single misconfigured set can expose PII across all roles.
- **Unconfigured fields fail closed** — `FiltersResponseAttributes` routes fields without ResourceField records through `unconfigured_field_strategy` (default `:block`; unknown values fall back to `:block`). New columns on PII models are hidden from filtered responses until configured — audit for `:pass_through`/`:warn` overrides.
- **Model-level masking (v0.9+)** — `MaskedAttributes` auto-applies to models with a Resource record (`config.auto_apply_masked_attributes`, default `:auto`), so direct AR readers (`customer.email`), `attributes`, and `as_json` are masked/hidden too. `pluck` and raw SQL bypass the model layer — use `FiltersResponseAttributes` for those paths. `masked_write_protection` (default `:skip`) prevents masked values from being persisted back over real data.
- **Most-permissive-wins merge** — Adding permission sets can only increase access. Over-assignment = over-exposure of personal data.
- **Muting sets for deny** — Use `is_muting: true` sets to subtract access when consent is withdrawn or processing purposes end.
- **GDPR defaults** — When `config.gdpr_defaults = true`, `ResourceFieldGenerator` automatically masks fields matching PII patterns when it generates them.
- **GdprFieldAuditor** — Built-in service that scans for unmasked PII fields and uncovered model columns. Run regularly.

## How to Run Checks Programmatically

```ruby
# Full GDPR field audit
report = PermissionForge::Services::GdprFieldAuditor.call
report.each { |finding| puts "#{finding[:type]}: #{finding.except(:type)}" }

# Find unmasked PII fields
fields = PermissionForge::ResourceField.arel_table
PermissionForge::ResourceField
  .where(mask_access: false)
  .where(fields[:name].matches_any(%w[%email% %phone% %ssn% %address% %birth% %tax_id% %iban%]))
  .pluck(:name, :resource_id)

# Check GDPR configuration
config = PermissionForge.configuration
puts "GDPR defaults: #{config.gdpr_defaults}"
puts "Filter params: #{config.filter_parameters_integration}"
puts "Audit events: #{config.audit_events}, retention: #{config.audit_retention_period.inspect}"

# Find expired but not cleaned assignments
PermissionForge::PermissionSetUser
  .where("expires_at < ?", Time.current)
  .count

# Run cleanup
PermissionForge::Services::ExpiredAssignmentCleaner.call(dry_run: true)

# Consent withdrawal / erasure / stale assignment review
PermissionForge::Services::ConsentWithdrawalHandler.call(user: user, consent_flag: 'marketing_consent', dry_run: true)
PermissionForge::Services::DataSubjectErasure.call(user: user, dry_run: true)
PermissionForge::Services::StaleAssignmentAuditor.call(threshold_days: 90)

# Check field coverage on a model
resource = PermissionForge::Resource.find_by(name: 'Customer')
model_columns = Customer.column_names
configured_fields = resource.resource_fields.pluck(:name)
uncovered = model_columns - configured_fields
puts "Uncovered columns: #{uncovered.join(', ')}"
```
