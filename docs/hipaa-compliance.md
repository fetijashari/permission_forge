# HIPAA Technical Safeguards Skill for PermissionForge

This guide explains how to use the built-in `/hipaa-compliance` Claude Code skill to review your PermissionForge configuration against the HIPAA Technical Safeguards (45 CFR § 164.312), and what the gem can and cannot evidence for each of them.

> **Scope of every claim here.** PermissionForge is an authorization library. It can *support evidence for* some safeguards, and says below which event or feature does so. It does not make an application HIPAA compliant, it is not certified by anyone, and it does not replace a risk analysis, a Business Associate Agreement or legal review. For each safeguard the last column lists what **you** must add.

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
/hipaa-compliance full
```

Claude will scan your PermissionForge configuration and produce a structured report mapping findings to HIPAA Technical Safeguard sections.

## Available Scopes

| Command | What it checks |
|---------|---------------|
| `/hipaa-compliance full` | Runs all checks below |
| `/hipaa-compliance access-controls` | Unique user ID, emergency access, automatic logoff, role-based access (§ 164.312(a)) |
| `/hipaa-compliance audit-trail` | The audit event log, actor attribution, retention, log access, filter parameters (§ 164.312(b), § 164.308(a)(1)(ii)(D)) |
| `/hipaa-compliance minimum-necessary` | ViewAll/ModifyAll usage, blanket CRUD, field granularity, row isolation (§ 164.502(b)) |
| `/hipaa-compliance ephi-fields` | ePHI field identification, masking coverage, strategy validation (supports § 164.312(a)(1) and § 164.502(b); masking is not encryption) |
| `/hipaa-compliance transmission` | API exposure: auth, record identifiers, pagination, clone endpoints (§ 164.312(a)(1), (d); transport encryption under § 164.312(e) is yours) |

If you omit the scope, it defaults to `full`.

## What Each Scope Checks

### Access Controls (`access-controls`)

Maps PermissionForge features to § 164.312(a) requirements:

- **Unique user identification** — Verifies `current_user` lambda returns authenticated users with unique identifiers (uuid preferred)
- **Emergency access procedure** — Checks for "break-glass" permission sets with activation conditions
- **Automatic logoff** — The gem has no sessions, so it cannot log anyone off; session timeout is the host's (§ 164.312(a)(2)(iii)). What it does limit is how long *access* lasts: it reviews `expires_at` on assignments and `allowed_hours_start/end` conditions (checked on every permission read, against the hour of that read). The cached permission hash's TTL is clamped to the soonest assignment `expires_at`, so an expired assignment cannot keep granting access from the shared cache; a user instance that memoized its hash before the expiry stops granting from it at that moment too (the memo is retired at the soonest `expires_at`)
- **Role-based access** — Flags ad-hoc user assignments (5+ individual sets suggest missing role structure)
- **Authentication context** — Reviews `request_context_resolver` for IP restrictions and MFA session flags (checked on every permission read, against the request that reads), and recommends `config.conditional_sets_strict_mode = true`. Without it (the default), a blank context — no resolver, or one that returns `{}` — applies every conditional set as if its conditions held. With it, a context without an IP or session flags (a job, the console) drops conditional granting sets and still applies conditional muting sets. See [activation-conditions.md](activation-conditions.md#strict-mode)

**When to run:** During initial HIPAA assessment, after restructuring permission sets, when onboarding new clinical roles.

### Audit Trail (`audit-trail`)

Evaluates the [audit log](audit-log.md) for § 164.312(b) (audit controls) and § 164.308(a)(1)(ii)(D) (information system activity review):

- Checks `config.audit_events` (High if it is `false`, High if the table is missing — `rake permission_forge:audit` reports both)
- Checks that events name a person: `audit_actor_resolver` is set (otherwise every admin shares one Basic-auth login, Medium), and recent change events with an `unknown` actor; with the API enabled, that `audit_actor_resolver` is set too (`audit_anonymous_api`, Medium)
- Checks `audit_change_failure_strategy` is `:raise`: a change made through the models (their callbacks) cannot commit without its record while auditing is on; writes that skip callbacks (`update_all`, `delete_all`, `insert_all`, raw SQL, another application) are never recorded
- Checks which runtime groups are stored (`audit_runtime_events`): the default stores denials only; reads of personal data are recorded only with `:field_read`
- Checks who may read the log (`audit_log_authorization`), the retention period, and that events are forwarded or protected at database level (host duties, see the [audit log guide](audit-log.md#what-the-host-must-do))
- Looks for access people granted to themselves (`assignment.granted` where actor and subject are the same person, High)
- Verifies revocation immediacy — `PermissionSetUser` invalidates the affected user's cached hash on create/update/destroy, so a revocation takes effect once the cache store confirms the removal (`cache_ttl` is the backstop)
- Reviews filter parameters integration to prevent ePHI in logs, and the `profile_builder` lambda for ePHI in cached permission hashes
- Notes that `config.audit_trail_enabled` (created-by / last-edited-by on the row) is *not* an audit control: it keeps one name per row and is overwritten by the next edit

**When to run:** Before production deployment, after upgrading PermissionForge, during audit preparation.

### Minimum Necessary (`minimum-necessary`)

Evaluates § 164.502(b) minimum necessary access:

- Flags `view_all`/`modify_all` (they bypass all row-level rules, so for ePHI each needs a reason you can state; § 164.502(b)(2)(i) leaves disclosures to or requests by a health care provider for treatment outside the minimum necessary standard, while staff uses inside your organisation remain subject to role-based access, § 164.514(d)(2); judge it per role)
- Lists resources with `delete_access: true` (should be extremely rare for patient data)
- Checks field-level granularity — resources with CRUD but no ResourceFields expose ALL columns
- Verifies `current_user` isolation rules exist on ePHI resources
- Flags multi-set escalation risk (most-permissive-wins merge)

**When to run:** Quarterly access reviews, after adding new resources, when restructuring roles.

### ePHI Fields (`ephi-fields`)

Audits field-level protection. Masking limits what a role *sees*; it is not encryption and does not satisfy § 164.312(a)(2)(iv) (see [masking limits](gdpr_masking_disclaimer.md)):

- Identifies ePHI fields by pattern matching (patient IDs, diagnoses, SSNs, medications, etc.)
- Checks masking coverage — recommends `mask_access: true` on ePHI for roles that do not need the full value (non-clinical roles, say)
- Validates mask strategies match data types (SSN → `last4`, email → `email`, diagnosis → `full`)
- Finds model columns with ePHI patterns that have no ResourceField record — these are excluded from filtered responses by default (`unconfigured_field_strategy: :block`), but explicit ResourceField coverage is still required for masking and edit control

**When to run:** After adding models with patient data, when onboarding new data types, before HIPAA audits.

### Transmission (`transmission`)

Reviews how the admin API is exposed. PermissionForge does not encrypt traffic: transmission security (§ 164.312(e)) is TLS at your proxy or load balancer. What it can show is who may call the API (§ 164.312(a)(1), (d)):

- Flags API enabled without `api_auth` (Medium: every request gets 401)
- Reviews record identifier — sequential `:id` enables enumeration of ePHI records
- Checks pagination handler — missing pagination enables bulk data extraction
- Verifies mutation and assignment authorization — `api_action_authorization` gates create/update/destroy/clone, `api_assignment_authorization` gates user assignment; `api_require_authorization` must stay `true` (the default since 0.14) so a missing lambda denies (403) instead of silently allowing
- Checks `api_redact_rule_field_values` — rule field values can contain sensitive identifiers (patient IDs, account numbers); enable redaction in API responses for HIPAA environments

**When to run:** Before exposing API externally, during penetration testing, before BAA review.

## Understanding the Report

Every audit produces a structured report:

```
# PermissionForge HIPAA Technical Safeguard Audit
Scope: full
Date: 2026-03-24
Disclaimer: Technical configuration review, not legal HIPAA compliance certification.

## Executive Summary
Critical: 1 | High: 2 | Medium: 3 | Low: 1 | Info: 2

## Findings

### [HIGH] Audit event log switched off
HIPAA Reference: § 164.312(b) — Audit controls
Risk: Nobody can later tell who granted, changed or revoked access to ePHI
Current state: config.audit_events = false
Recommendation: Set config.audit_events = :auto and run the upgrade migration

## What the configuration evidences, and what the host must add

| Safeguard | Reference | What the gem evidences | What the host must add |
|-----------|-----------|------------------------|------------------------|
| Unique User ID | § 164.312(a)(2)(i) | actor_id on events; audit_actor_resolver set | One login per person |
| Emergency Access | § 164.312(a)(2)(ii) | No break-glass set found | Procedure and approver |
| Automatic Logoff | § 164.312(a)(2)(iii) | Nothing (no sessions) | Session timeout |
| Audit Controls | § 164.312(b) | audit_events = false: nothing recorded | Turn recording on; protect the table |
```

### Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| **Critical** | Required safeguard completely missing, ePHI at risk | Fix immediately |
| **High** | Significant gap in a required safeguard | Fix within current sprint |
| **Medium** | Addressable safeguard specification not implemented | Plan for next cycle |
| **Low** | Best practice improvement | Address when convenient |
| **Info** | Observation, no action required | Informational only |

## What the gem evidences, and what you must add

"Evidences" means: this event or feature produces a record or a control an assessor can look at. It does not mean the safeguard is met. Every row cites the event name from the [audit log](audit-log.md).

| HIPAA reference | What the gem evidences | What the host must add |
|---|---|---|
| § 164.312(a)(1) Access control; § 164.502(b) Minimum necessary | Who may do what: Resource CRUD, field read/edit, row-level rules, muting sets. Every change made through the models is an event (not writes that skip callbacks: `update_all`, raw SQL, another application) (`permission_set.*`, `resource.*`, `resource_field.*`, `permission_set_rule.*`, `assignment.granted/changed/revoked`), with before and after. Refusals (`access.denied`, `action.denied`) raised by `find_by`/`find_by!` and by the controller action guard are stored by default; a `can?` that returns false in your code and rows filtered out of a query are not. | Deciding the roles. Reviewing them. Encrypting the data. |
| § 164.312(a)(2)(i) Unique user identification | An event whose actor is a signed-in user stores the host's `actor_id`; `audit_actor_resolver` names the signed-in person. Basic-auth, system, unknown and anonymous API actors have no `actor_id`. | A unique login per person. Under shared Basic auth the events name the shared username. |
| § 164.312(a)(2)(ii) Emergency access | Activation conditions and time-bound assignments (`expires_at`); a break-glass grant shows as `assignment.granted` with its expiry and `reason`. | The break-glass procedure and who approves it (`admin_assignment_authorization` can forbid self-grants). |
| § 164.312(a)(2)(iii) Automatic logoff | Nothing. Assignment expiry and allowed hours limit *access*, not a session. | Session timeout in your authentication. |
| § 164.312(a)(2)(iv) Encryption and decryption | Nothing. `mask_access` is display-level obfuscation. | `ActiveRecord::Encryption` or database encryption. |
| § 164.312(b) Audit controls | The [audit log](audit-log.md) (insert-only in Ruby only (`update_all`, `delete_all`, `AuditEvent.delete`, `insert_all` and database access still reach it: [protect it at database level](audit-log.md#protecting-the-table-at-database-level))): `audit_events` rows written in the transaction of each change to the 8 permission tables; refused sign-ins and authorizations (`admin.auth_failed`, `api.auth_failed`, `admin.lock_refused`); viewing effective access and the log itself (`admin.effective_access_viewed`, `audit.viewed`, `audit.exported`); who could read personal data when `field_read` is stored (`field.access`). | Recording activity *in your application* (who opened which patient record): the gem records permission changes and, optionally, field reads through its models, not your application's business events. Protecting the table at database level, forwarding, clock synchronisation, retention, alerting on audit failures, trusted proxies; the full list is [What the host must do](audit-log.md#what-the-host-must-do). |
| § 164.308(a)(1)(ii)(D) Information system activity review | The Audit log page, timelines, CSV/JSON exports, "who holds what" export, `GET /api/audit_events`; periodic review recorded as `assignment.reviewed`. | Doing the review, on a schedule, and keeping the evidence of it. |
| § 164.308(a)(3) Workforce security (incl. (ii)(C) termination procedures); § 164.308(a)(4) Information access management | Assignments with expiry, reason and reviewer; `admin_assignment_authorization` for segregation of duties; the stale-assignment report. | Authorization and termination procedures, approvals. |
| § 164.312(c)(1) Integrity | Write-path field filtering (`PermitsAttributes`) and masked write-back protection limit who can change a field; permission changes keep before/after. | A mechanism to authenticate ePHI itself (§ 164.312(c)(2)): checksums, versioning, signatures. The log holds permission configuration, not ePHI history. |
| § 164.312(d) Person or entity authentication | Failed Basic and API sign-ins are recorded (`admin.auth_failed`, `api.auth_failed`). A set can require a session flag (an MFA step-up), an IP range or hours; the conditions are checked on every permission read against the request that reads, so a flag-gated set takes effect only in the sessions whose `request_context_resolver` returns the flag. When the context is blank (no resolver, or one that returns `{}`), every conditional set applies as if its conditions held, unless `conditional_sets_strict_mode` is on. | The authentication itself (and MFA), returning the flag only after it succeeded, strict mode, and rate limiting of failed attempts. |
| § 164.312(e)(1) Transmission security | Nothing. API auth, `:uuid` identifiers and pagination reduce enumeration; they do not protect data in transit. | TLS everywhere. |
| § 164.316(b)(2)(i) Retention of documentation | `audit_retention_period`, purge with `audit.purged` kept. HIPAA sets no retention period for audit logs; § 164.316(b)(2)(i) (six years) covers policies and documentation of required actions. | If you keep audit events as such documentation, set `audit_retention_period` to at least that; schedule the purge; backups. |

Before citing the log, read [What is not recorded](audit-log.md#what-is-not-recorded).

## Running Checks Without Claude

Some HIPAA checks can be run directly in a Rails console:

```ruby
# ePHI field audit (reuses the GDPR auditor). The default gdpr_field_patterns have no clinical
# terms: add your own first, for example
#   config.gdpr_field_patterns = config.gdpr_field_patterns.merge(/diagnosis|\Amrn\z|medication/ => 'full')
report = PermissionForge::Services::GdprFieldAuditor.call
report.each { |finding| puts "#{finding[:type]}: #{finding.except(:type)}" }

# Check for access wider than minimum necessary
PermissionForge::Resource.where(view_all: true).pluck(:name)
PermissionForge::Resource.where(modify_all: true).pluck(:name)

# Find users with excessive permission sets
User.joins(:permission_set_users)
    .group(:id)
    .having("COUNT(*) >= 5")
    .pluck(:id, Arel.sql("COUNT(*)"))

# Is the audit log recording, and who acted lately?
PermissionForge::Audit.enabled?
PermissionForge::AuditEvent.newest_first.limit(10).pluck(:occurred_at, :event, :actor_label)

# Access people granted to themselves
events = PermissionForge::AuditEvent.arel_table
PermissionForge::AuditEvent.where(event: 'assignment.granted', actor_type: 'user')
  .where(events[:actor_id].eq(events[:subject_user_id])).count

# Find unmasked ePHI fields
PermissionForge::ResourceField.where(mask_access: false)
  .where("name LIKE '%ssn%' OR name LIKE '%diagnosis%' OR name LIKE '%medication%'")
  .pluck(:name)

# Check for expired assignments
PermissionForge::PermissionSetUser
  .where("expires_at < ?", Time.current)
  .count
```

## Running Audits in CI

```bash
claude --print "/hipaa-compliance full" > hipaa-audit-report.md
```

## Combining with Other Skills

- **`/security-audit full`** — Run the general security audit first, then `/hipaa-compliance` for HIPAA-specific checks
- **`/gdpr-data-handling masking`** — GDPR field masking overlaps with HIPAA ePHI field protection. Run both for comprehensive coverage
- **`/permission-forge add ModelName`** — Set up permissions on a new model, then `/hipaa-compliance ephi-fields` to verify ePHI protection

## Tips

- **Run `full` first.** Get the table of what the configuration evidences per safeguard, then drill into specific safeguards.
- **Focus on Critical/High.** These represent missing required safeguards — an addressable specification (Medium) must be assessed under § 164.306(d)(3): implement it if reasonable and appropriate, or document why not and implement an equivalent alternative measure if that is reasonable and appropriate.
- **Save reports.** Keep them with your risk-analysis records as a dated note of what was reviewed; they do not replace the analysis.
- **Re-audit after changes.** Run the relevant scope after modifying permission sets or adding resources with ePHI.
- **This is not certification.** A clean report means the checks the skill knows about found nothing. It is not an assessment of your application, and it does not replace a formal HIPAA risk analysis or legal review.
