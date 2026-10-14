# GDPR Data Handling Skill for PermissionForge

This guide explains how to use the built-in `/gdpr-data-handling` Claude Code skill to review and improve how your PermissionForge configuration handles personal data, and what the gem can and cannot evidence for each GDPR article it touches.

> **Scope of every claim here.** PermissionForge is an authorization library. It can *support evidence for* some of your obligations, and says below which event or feature does so. Using it does not make an application GDPR compliant, nothing here is legal advice, and lawful basis, records of processing, breach handling and data-subject workflows stay with you.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- A project that uses the PermissionForge gem
- PermissionForge's `.claude/` directory present in your project (it ships with the gem)

## Quick Start

Open your terminal in your project directory and run Claude Code:

```bash
claude
```

Then use the skill:

```
/gdpr-data-handling full
```

Claude will scan your PermissionForge configuration and produce a structured report with GDPR article references and actionable fixes.

## Available Scopes

| Command | What it checks |
|---------|---------------|
| `/gdpr-data-handling full` | Runs all checks below — comprehensive GDPR review |
| `/gdpr-data-handling masking` | PII field masking, mask strategies, GDPR defaults, uncovered columns (Art. 25, 32) |
| `/gdpr-data-handling rights` | Data subject rights support — access, erasure, restriction, portability (Art. 15-22) |
| `/gdpr-data-handling retention` | Time-bound assignments, expired cleanup, audit-log retention, storage limitation (Art. 5(1)(e)) |
| `/gdpr-data-handling privacy-design` | Privacy by design, data minimization, default deny (Art. 25) |
| `/gdpr-data-handling consent` | Consent-aware permission patterns, purpose-bound sets (Art. 6, 7) |

If you omit the scope, it defaults to `full`.

## What Each Scope Checks

### Masking (`masking`)

The most actionable scope — finds and fixes unprotected PII:

- **Runs `GdprFieldAuditor`** to identify unmasked PII fields, unmapped PII columns, `view_all`/`modify_all` bypasses on PII resources, and cross-set unmasking
- **Validates mask strategies** match data types (email → `email`, SSN → `last4`, etc.)
- **Checks `gdpr_defaults`** — when enabled, fields that look like personal data are masked when fields are generated (`ResourceFieldGenerator`)
- **Checks `filter_parameters_integration`** — prevents PII from leaking into Rails logs
- **Finds uncovered columns** — model columns with no ResourceField row in effect (none, or only switched-off ones) fall to `unconfigured_field_strategy` (default `:block` — omitted from responses); they leak only if you've relaxed it to `:pass_through`/`:warn`
- **Cross-set masking risk** — mask_access uses AND logic, so a single unmasking set exposes PII for all roles

**When to run:** After adding models with PII, before a data-protection review, when onboarding new data types.

### Rights (`rights`)

Assesses how well PermissionForge supports data subject rights:

- **Access (Art. 15)** — Can you generate a complete access report per user?
- **Rectification (Art. 16)** — Can you grant temporary edit access for self-service corrections?
- **Erasure (Art. 17)** — Can a user's permission data be removed? (`DataSubjectErasure` removes the person's assignments and group memberships, and blanks their name labels on audit events: in the current tenant when one is set, in every tenant when none is; ids, IPs, reasons, `data` and the `*_by_id` columns stay, see [what remains](audit-log.md#erasure-and-the-names-in-the-log))
- **Restriction (Art. 18)** — Can muting sets temporarily restrict access without deletion?
- **Portability (Art. 20) and objection (Art. 21)** — The gem has no feature for either. The audit log filtered to a person exports as CSV/JSON, and `GET /api/permission_sets/:ps/users` lists who holds a set; whether that is data the person provided is for you to decide. Purpose-bound sets can be turned off or muted to stop the access for one purpose, but taking in and answering the request is yours

**When to run:** Before a data-protection review, when building data subject request workflows.

### Retention (`retention`)

Audits whether permission configurations respect storage limitation:

- **Time-bound assignments** — Are `expires_at` values set on PermissionSetUser records?
- **Expired cleanup** — Is `ExpiredAssignmentCleaner` running regularly? (Each removal is an `assignment.revoked` event; the run writes a `cleanup.expired_assignments` event only when it removed something.)
- **Inactive but assigned** — Sets deactivated but still linked to users
- **Stale assignments** — Permanent assignments not reviewed in 90+ days. Review is counted from the last "Keep" (`reviewed_at`, recorded as `assignment.reviewed`), else from the grant; an edit is not a review
- **Audit-log retention** — Is `audit_retention_period` set to your policy, and is `rake permission_forge:audit_events:purge` scheduled? The log holds personal data too (see below)
- **Cache TTL** — Revoking an assignment invalidates the user's cache once the cache store confirms the removal (0.10.0+); `cache_ttl` (default 1 hour) is the staleness backstop for everything else

**When to run:** Quarterly access reviews, after bulk user provisioning, when implementing retention policies.

### Privacy Design (`privacy-design`)

Reviews your configuration against privacy-by-design principles:

- **Default deny** — Are new resources created with minimal access?
- **Field coverage** — Do ALL columns on PII models have ResourceField records?
- **Purpose-bound sets** — Are permission sets named by processing purpose (not generic "Admin"/"User")?
- **Pseudonymization** — Is `:uuid` used as the API record identifier?
- **GDPR defaults** — Is auto-masking enabled on field generation?
- **Row isolation** — Do PII resources have `current_user` rules?

**When to run:** During architecture reviews, when adding new models, before production deployment.

### Consent (`consent`)

Evaluates consent-aware permission patterns:

- **Session flag gating** — Are permission sets tied to consent flags via `requires_session_flag`? The flag is checked on every permission read, against the flags `request_context_resolver` returns for that request, so the set applies only to requests whose context carries the flag. Is `conditional_sets_strict_mode` on? Without it, a blank context (no resolver, or one that returns `{}`) applies the set as if the flag were present. See [activation-conditions.md](activation-conditions.md#strict-mode).
- **Purpose-bound sets** — Is each processing purpose a separate permission set?
- **Consent withdrawal** — Can revoking consent immediately disable the corresponding set? (`ConsentWithdrawalHandler` removes this person's assignments to the sets gated on a consent flag)
- **Granular consent** — Can individual fields be toggled per consent?

**When to run:** When implementing consent management, after cookie consent changes, before GDPR audits.

## Understanding the Report

Every audit produces a structured report:

```
# PermissionForge GDPR Data Handling Audit
Scope: masking
Date: 2026-03-24

## Executive Summary
Critical: 0 | High: 2 | Medium: 1 | Low: 0 | Info: 1

## Findings

### [HIGH] Unmasked email field on Customer resource
GDPR Reference: Article 25 — Data protection by design
Risk: PII exposed in API responses and permission hash without masking
Current state: Customer.email — mask_access: false, mask_strategy: nil
Recommendation: Set mask_access: true, mask_strategy: 'email'
Implementation:
  field = PermissionForge::ResourceField.find_by(resource: resource, name: 'email')
  field.update!(mask_access: true, mask_strategy: 'email')
```

### Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| **Critical** | Active PII exposure, no protection in place | Fix immediately |
| **High** | Missing protection on sensitive fields | Fix within current sprint |
| **Medium** | Suboptimal configuration, weakened privacy posture | Plan for next cycle |
| **Low** | Best practice improvement | Address when convenient |
| **Info** | Observation, no action required | Informational only |

## The audit log holds personal data

The [audit log](audit-log.md) is a record of who did what, so it contains personal data about your administrators and about the people whose access is managed: a name snapshot (`actor_label`, `record_label`), the user id, the IP address and request id, free-text `reason`s, and `data` snapshots of changed rows. Treat it like any other store of personal data:

- **Purpose and basis** are yours to document (accountability, security of processing). The gem does not decide them.
- **Who can read it** is `audit_log_authorization` (nil = anyone with admin access) plus the exports; reads of the log through the admin pages, the exports and the API are themselves recorded (`audit.viewed`, `audit.exported`).
- **Retention** is `audit_retention_period` (nil = forever) and the purge; the `audit.purged` record of each deletion is kept.
- **Erasure** (`DataSubjectErasure`) clears the person's *name snapshots* — in the current tenant's events when a tenant is set (the admin screens), in every tenant's and the untenanted events when none is set (the rake task) — and keeps ids, so the log still says what happened but no longer shows the name. IPs, `reason` text and `data` (row snapshots, which can hold the person's id) are not scrubbed, nor are `created_by_id` / `updated_by_id` / `reviewed_by_id` / `sensitive_acknowledged_by_id` on live rows, and neither are usernames typed at a failed HTTP Basic sign-in (`admin.auth_failed`) or the labels of API actors, which are not user records. Whether keeping the id satisfies Art. 17 for your data is a question for your legal advisor; the gem makes the choice visible (`erasure.performed` counts what was cleared).
- **Forwarding.** The log subscriber and your own notification subscribers send `data` and the IP onward; apply the receiving system's retention to them.

## What the gem evidences, and what you must add

"Evidences" means: this event or feature produces a record or a control an assessor can look at. It does not mean the obligation is met.

| GDPR | What the gem evidences | What the host must add |
|---|---|---|
| Art. 5(1)(b) Purpose limitation | Purpose-bound Permission Sets (a set per processing purpose) and `requires_session_flag` gating, checked per request; every change to them is an event. | Defining the purposes; returning the flag from `request_context_resolver` according to your consent record; `conditional_sets_strict_mode`. |
| Art. 5(1)(c) Data minimisation | Field-level read/edit, `grant_all: false`, fields without a setting hidden by default (`unconfigured_field_strategy: :block`). `field.access` (with `audit_runtime_events` including `:field_read`) lists, per record read, which fields were hidden or masked and which were read in the clear (`passed_fields`; under `unconfigured_field_strategy` `:pass_through` or `:warn` also the `unconfigured` ones, and with no user the `bypassed` ones). | Not storing what you do not need. |
| Art. 5(1)(e) Storage limitation | `expires_at` assignments, `ExpiredAssignmentCleaner` (`cleanup.expired_assignments`), `audit_retention_period` and the purge (`audit.purged`). | Retention periods for your own data and for the audit log; scheduling. |
| Art. 5(1)(f), Art. 32 Integrity and confidentiality | Masking, row-level rules, write filtering (`PermitsAttributes`), `filter_parameters_integration`; audit log (insert-only in Ruby only (`update_all`, `delete_all`, `AuditEvent.delete`, `insert_all` and database access still reach it: [protect it at database level](audit-log.md#protecting-the-table-at-database-level))) with refusal events (`access.denied`, `action.denied`, `admin.auth_failed`, `api.auth_failed`); Refusals raised by `find_by`/`find_by!` and by the controller action guard are stored by default; a `can?` that returns false in your code and rows filtered out of a query are not. | Encryption, transport security, database privileges on the audit table, forwarding, retention and the rest of [What the host must do](audit-log.md#what-the-host-must-do). Masking is display-level only, see the [masking disclaimer](gdpr_masking_disclaimer.md). |
| Art. 5(2) Accountability | Who changed which access, when, with what before and after, and why (`reason`); periodic review (`assignment.reviewed`); who viewed or exported the log. | Your records of processing and the decisions behind them. |
| Art. 6, Art. 7 (withdrawal: Art. 7(3)) Lawful basis, consent | `requires_session_flag` lets a set apply only to the requests whose context carries a flag your app returns (checked on every permission read; with a blank context the set applies unless `conditional_sets_strict_mode` is on); `ConsentWithdrawalHandler` removes this person's assignments to the sets gated on a flag and records `consent.withdrawn`. | Capturing and storing consent, returning the flag only while consent stands, enabling strict mode, deciding the lawful basis. |
| Art. 15 Access | The Audit log filtered to the person (Person page, Audit tab, "Events about …", then CSV/JSON export) and `GET /api/audit_events?subject_user_id=` list the events about a person; `actor_type=user&actor_id=` lists the events they caused. The Person page's own CSV lists only the records they created or last edited; the Effective-access tab lists their permissions. | Assembling the full response from all your systems, and checking the log's contents for others' data before you hand it over. |
| Art. 17 Erasure | `DataSubjectErasure`: removes the person's assignments and memberships and clears their name snapshots, in the current tenant when one is set (`assignments_remaining_elsewhere` counts the rest) and in every tenant when none is; invalidates their cached permissions (the per-context variants included: every slot of the person's cache keys, whatever base entry they were built for, without relying on a read of the store; a variant that a request still in flight writes after the erasure may remain, unreachable, until `conditional_set_cache_ttl`, 300 s by default); records `erasure.performed`. Ids, IPs, `reason`, `data` and the `*_by_id` columns stay ([what remains](audit-log.md#erasure-and-the-names-in-the-log)); copies already forwarded are not reached. | Deleting the person's application data and the user record (`on_erasure` runs after the erasure commits); any backup; log copies you forwarded. |
| Art. 18 Restriction | A muting Permission Set removes *permission-based* access without deleting data. | A restriction on your processing generally. |
| Art. 25 Privacy by design | `gdpr_defaults` masks matching fields when fields are generated; deny-by-default for unconfigured fields. | Choosing the patterns and reviewing them (`GdprFieldAuditor`). |
| Art. 30 Records of processing | Nothing. | Your register. |
| Art. 33 Breach notification | Nothing automatic; the log can show who changed access in a period. | Detection, assessment and notification. |

Before citing the log, read [What is not recorded](audit-log.md#what-is-not-recorded).

## Running Checks Without Claude

Some GDPR checks can be run directly in a Rails console:

```ruby
# Full GDPR field audit — findings are keyed by :type (:unmasked_field,
# :unmapped_column, :implicit_virtual_grant, :view_all_on_pii_resource,
# :cross_set_unmasking)
report = PermissionForge::Services::GdprFieldAuditor.call
report.each { |finding| puts "#{finding[:type]}: #{finding.except(:type)}" }

# Check GDPR configuration
config = PermissionForge.configuration
puts "GDPR defaults: #{config.gdpr_defaults}"
puts "Filter params: #{config.filter_parameters_integration}"

# Find unmasked PII fields
fields = PermissionForge::ResourceField.arel_table
PermissionForge::ResourceField
  .where(mask_access: false)
  .where(fields[:name].matches_any(%w[%email% %phone%]))
  .pluck(:name)

# Check field coverage on a model
resource = PermissionForge::Resource.find_by(name: 'Customer')
model_columns = Customer.column_names
configured = resource.resource_fields.pluck(:name)
uncovered = model_columns - configured
puts "Uncovered: #{uncovered.join(', ')}"

# Find expired assignments
PermissionForge::PermissionSetUser
  .where("expires_at < ?", Time.current)
  .count

# Cleanup expired
PermissionForge::Services::ExpiredAssignmentCleaner.call(dry_run: true)

# Preview consent withdrawal (Art. 7(3)) — removes this person's assignments to the sets gated on the flag
PermissionForge::Services::ConsentWithdrawalHandler.call(
  user: user, consent_flag: 'marketing_consent', dry_run: true
)

# Preview erasure of a user's permission data (Art. 17); a dry run writes no event
PermissionForge::Services::DataSubjectErasure.call(user: user, dry_run: true)

# What the audit log holds about a person
PermissionForge::AuditEvent.for_subject(user.id).count
PermissionForge::AuditEvent.where(actor_type: 'user', actor_id: user.id.to_s).count

# Count the audit events a purge would delete under the retention policy
PermissionForge::Services::AuditEventPurger.call(older_than: 2.years, dry_run: true)
```

## Running Audits in CI

```bash
claude --print "/gdpr-data-handling full" > gdpr-audit-report.md
```

## Combining with Other Skills

- **`/security-audit gdpr`** — The security-audit skill has a gdpr scope too. Use `/security-audit gdpr` for a quick pass and `/gdpr-data-handling full` for deeper analysis with implementation patterns
- **`/hipaa-compliance ephi-fields`** — If your app handles both EU data and US healthcare data, run both. The default `gdpr_field_patterns` cover contact, identity and financial columns but no clinical terms; add patterns such as `diagnosis`, `mrn` or `medication` yourself
- **`/permission-forge add ModelName --with-fields`** — Set up permissions with auto-generated fields, then `/gdpr-data-handling masking` to verify PII is masked

## Tips

- **Start with `masking`.** It's the most actionable scope — finds unprotected PII and provides fix snippets.
- **Run `privacy-design` during setup.** Before going to production, verify your configuration follows privacy-by-design principles.
- **Use `consent` when adding consent management.** It provides implementation patterns for consent-gated permission sets.
- **Save reports.** Art. 5(2) asks you to be able to demonstrate compliance. Dated reports are one input; they are not a demonstration on their own.
- **Re-audit regularly.** New models and fields can introduce unprotected PII. Run `/gdpr-data-handling masking` after schema changes.
