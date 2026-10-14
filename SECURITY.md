# Security Policy

PermissionForge decides who can see and change data in the apps that embed it, so a flaw here is a flaw in every host app. Security reports are handled ahead of all other work.

## Supported versions

PermissionForge is pre-1.0. Security fixes go into the latest release only and are not backported to older versions.

The newest release is the first numbered version in [CHANGELOG.md](CHANGELOG.md). If you can, reproduce the problem on that version before reporting — it may already be fixed.

## Reporting a vulnerability

**Please do not open a public issue, pull request, or discussion for a security problem.**

Report it through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability** (<https://github.com/fetijashari/permission_forge/security/advisories/new>). Only the
maintainers see the report. If you cannot use GitHub, email **fetijashari@gmail.com** with
`PermissionForge security` in the subject line.

Include:

- the PermissionForge version (tag or commit), and your Ruby and Rails versions
- the relevant parts of `config/initializers/permission_forge.rb`, with secrets removed
- what you expected, what happened instead, and the impact — who gains access to what
- steps to reproduce, ideally a failing test or a short script

What happens next:

1. You get an acknowledgement within 5 business days.
2. We reproduce the issue and tell you whether we treat it as a vulnerability, and why.
3. The fix ships as a new release with an entry in [CHANGELOG.md](CHANGELOG.md).
4. You are credited in that entry, unless you would rather not be.

Please keep the details private until the fix is released.

## What counts as a vulnerability

Anything that lets someone see or do more than their Permission Sets allow, for example:

- reading or writing a resource, field, or row that the user's permissions deny
- a masked or hidden value reaching the user unmasked
- a row-level rule that can be bypassed or injected into (including SQL injection)
- access that survives after an assignment is revoked, expired, or muted
- data crossing tenants in a multi-tenant setup
- reaching the admin UI or the JSON API without passing the configured authentication or authorization
- XSS, CSRF, or similar flaws in the admin UI
- for the [audit log](docs/audit-log.md): a way to change or remove an audit event through the gem's routes, API or forms; a permission change made through the models that leaves no event; an event whose actor comes from a request parameter or header instead of the authenticated request; the log, its exports or `GET /api/audit_events` readable by someone `audit_log_authorization` refuses; an export cell that a spreadsheet would run as a formula

## What does not

These are worth a regular issue if the documentation is unclear, but they are not vulnerabilities in the gem:

- **Permissive settings chosen by the host app.** Several options fail open by design, such as `nil_user_strategy = :bypass`, and the admin UI and JSON API are only as protected as the authentication you configure. The [production hardening checklist](README.md#production-hardening-checklist) lists them, and `bin/rails permission_forge:audit` reports them — see [Security Audit](docs/security-audit.md).
- **Paths the documentation says are not covered.** `pluck` and raw SQL skip model-level masking, and `unscoped` / `find_by_sql` skip Ruby-level row scoping. See [Masked Attributes](docs/masked-attributes.md) and [Query Scoping](docs/query-scoping.md) for the defenses that do cover them.
- **Masking treated as anonymization.** See the [GDPR Masking Disclaimer](docs/gdpr_masking_disclaimer.md).
- **The audit log's documented limits.** It is evidence of what the application did, not a tamper-proof ledger: events are insert-only through the model, but `update_all`, `delete_all`, `AuditEvent.delete`, `insert_all`, `AuditEvent.create!` and direct database access still reach the table, so protect it [at database level](docs/audit-log.md#protecting-the-table-at-database-level) and keep a second copy outside the application. Writes that skip callbacks or come from another application are not recorded; the request id and IP are client-influenced unless trusted proxies are configured; a request Rails rejects before the engine runs cannot be recorded; and with `audit_change_failure_strategy` set to `:report` or `:log` a change can succeed without its event. The full list is in [What is not recorded](docs/audit-log.md#what-is-not-recorded).
- **Vulnerabilities in dependencies.** Report those to the project concerned (for Rails: <https://rubyonrails.org/security>). Do tell us if PermissionForge makes one exploitable.
