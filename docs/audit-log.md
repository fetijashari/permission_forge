# The Audit Log

PermissionForge records who changed access, to whom, when, from where and what it was before. The record is an insert-only table (`audit_events`) that the gem writes inside the same transaction as the change, plus a read-only admin page, exports and a JSON endpoint to look at it.

This page says what the log records, what it does **not** record, and what you must add around it. It does not claim that using the gem makes you compliant with anything: the log **supports evidence for** access-control and accountability requirements ([HIPAA](hipaa-compliance.md), [GDPR](gdpr-data-handling.md), [ISO 27001 Annex A](security-audit.md#iso-27001-annex-a-mapping)). Whether it is enough is for your assessor to decide.

- [What you get](#what-you-get)
- [What is recorded](#what-is-recorded)
- [What is not recorded](#what-is-not-recorded)
- [Who did it: actor resolution](#who-did-it-actor-resolution)
- [Request context: request id and IP](#request-context-request-id-and-ip)
- [Reason and correlation](#reason-and-correlation)
- [Configuration](#configuration)
- [When an event cannot be written](#when-an-event-cannot-be-written)
- [Runtime groups and their cost](#runtime-groups-and-their-cost)
- [Notifications, the log subscriber and legacy hooks](#notifications-the-log-subscriber-and-legacy-hooks)
- [The Audit log page](#the-audit-log-page)
- [Exports](#exports)
- [The API endpoint](#the-api-endpoint)
- [Retention and purge](#retention-and-purge)
- [Erasure and the names in the log](#erasure-and-the-names-in-the-log)
- [Protecting the table at database level](#protecting-the-table-at-database-level)
- [Forwarding to a log platform](#forwarding-to-a-log-platform)
- [What the host must do](#what-the-host-must-do)
- [Upgrading](#upgrading)
- [Recording your own events](#recording-your-own-events)

## What you get

- **Every change to the eight permission tables made through the models is an event**, written in the transaction of the change (`after_create`, `after_update`, `after_destroy`). With the default `audit_change_failure_strategy = :raise`, a change whose event cannot be written rolls back: there is no change without its record.
- **Insert-only in Ruby.** A persisted `PermissionForge::AuditEvent` is read-only: `save`, `update`, `update_column(s)`, `touch`, `destroy`, `delete`, `upsert`, `upsert_all` and `update_counters` raise `ActiveRecord::ReadOnlyRecord` (`app/models/permission_forge/audit_event.rb`). No route, form or API parameter writes an event. See [Protecting the table at database level](#protecting-the-table-at-database-level) for what Ruby cannot stop.
- **One emitter.** The gem's own code writes events only through `PermissionForge::Audit.record` (change, admin and system events) and `PermissionForge::Audit.instrument` (runtime events), with one exception: while `audit_events = false`, `audit.settings_observed` is stored directly (`Audit::SettingsObserver`), so a period with auditing off stays visible. An event name that is not in the catalogue raises in those two, so a typo cannot silently record nothing; `AuditEvent.create!` in your own code does not go through them (see [below](#protecting-the-table-at-database-level)).
- **Who, where, why.** Actor (type, id, name at the time), source (`admin_ui`, `api`, `rake`, `job`, `console`, `service`, `runtime`), request id, IP, an optional reason, and a correlation id that groups the events of one action.
- **Notifications.** Every event is published as `"<event>.permission_forge"` through `ActiveSupport::Notifications`, so you can forward it.
- **A way to read it.** The admin Audit log page, CSV and JSON exports, timelines on the Permission Set and Person pages, a "who holds what" export, and `GET /api/audit_events`.

The event store, the table and every option below are active as soon as the migration has run. With `audit_events = :auto` (the default) a missing table is not an error: changes keep working, nothing is recorded, and the gem warns at boot and in the security audit.

## What is recorded

Generated from `PermissionForge::Audit::EventCatalog` (the registry that every `Audit.record` / `Audit.instrument` call is checked against). Every row also carries the columns listed after the tables.

### Change events (28)

Written by `Audit.record` inside the transaction of the change itself.

| Event | What it carries |
|---|---|
| `permission_set.created` | the new row: `data.snapshot` (every attribute) |
| `permission_set.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `permission_set.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `resource.created` | the new row: `data.snapshot` (every attribute) |
| `resource.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `resource.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `resource_field.created` | the new row: `data.snapshot` (every attribute) |
| `resource_field.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `resource_field.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `resource_action.created` | the new row: `data.snapshot` (every attribute) |
| `resource_action.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `resource_action.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `permission_set_rule.created` | the new row: `data.snapshot` (every attribute) |
| `permission_set_rule.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `permission_set_rule.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `permission_set_group.created` | the new row: `data.snapshot` (every attribute) |
| `permission_set_group.updated` | what changed: `data.changes` as `{attribute: [from, to]}`, leaving out `created_at`, `updated_at`, `created_by_id`, `updated_by_id`; a save that changes nothing else writes no event |
| `permission_set_group.destroyed` | the deleted row: `data.snapshot` (every attribute) |
| `permission_set.cloned` | the copy is the record; `data.source_uuid`, `data.source_name`. The copy also has its own `permission_set.created` and the events of its rows, under one correlation id |
| `permission_set_group.cloned` | the copy is the record; `data.source_uuid`, `data.source_name`. Each copied set also writes `permission_set.cloned` |
| `assignment.granted` | the person (`subject_user_id`, `record_label`), the set, and `data.snapshot` including `expires_at` and `reason` |
| `assignment.changed` | `data.changes`, for example `expires_at: [from, to]`. An assignment moved to another person also carries `data.previous_subject_user_id`: the event's `subject_user_id` is the new holder, so filtering the log by the previous holder does not find it (search `data`, or the record's events) |
| `assignment.revoked` | `data.snapshot` of the removed assignment, including `expires_at` |
| `assignment.reviewed` | "Keep" in the admin: `data.changes` (`reviewed_at`, `reviewed_by_id`) and `data.decision` (`keep`); written instead of `assignment.changed` |
| `group_membership.added` | the person (`subject_user_id`) and `data.snapshot` |
| `group_membership.changed` | the person and `data.changes` (for example the `reason`) |
| `group_membership.removed` | the person and `data.snapshot` |
| `field.sensitive_acknowledged` | "This is intended": `data.changes` (`sensitive_acknowledged_at`, `sensitive_acknowledged_by_id`); written instead of `resource_field.updated` |

### System events (7)

Housekeeping and the log's own upkeep. Written by `Audit.record`.

| Event | What it carries |
|---|---|
| `erasure.performed` | `subject_user_id`; `data`: `operation`, `set_uuids`, `set_names`, `group_uuids`, `group_names`, `assignments_removed`, `group_assignments_removed`, `assignments_remaining_elsewhere`, `group_assignments_remaining_elsewhere`, `events_scrubbed`, `actor_labels_cleared`, `record_labels_cleared`, `callback_invoked` (an `on_erasure` callback was given), `dry_run`, and the cache scope: `cache_confirmed` (`nil` here: the event is written in the operation's transaction, before the cache work), `process_local` (the store lives in each process — `cache_backend = :memory`, or `Rails.cache` a `:memory_store`), `in_request` (`true` when the operation ran inside a request the admin or the API served), `unconfirmed` (users the store did not confirm; `nil` when not known yet). The sentence then ends with "The cached permissions were cleared in this server process only (an in-memory store): the other web workers and the job processes kept theirs." (`in_request: true`) or "…in its own process only…: the web and job processes kept theirs." (`in_request: false`, and events stored before 0.15 without the key). Written on every real run, also with zero counts. A run with no tenant set (`rake permission_forge:erasure`) writes one `erasure.performed` without a tenant, which tenant auditors do not see; each removed assignment's `assignment.revoked` is recorded in its own tenant |
| `consent.withdrawn` | `subject_user_id`; `data`: `consent_flag`, `set_uuids`, `set_names`, `revoked`, and the cache scope as for `erasure.performed` (`cache_confirmed` `nil`, `process_local`, `in_request`, `unconfirmed`). Written on every real run, in one transaction with the revocations. With no tenant set while tenancy is on: one per tenant that lost assignments (in that tenant, with that tenant's counts and sets), plus one without a tenant with the totals and `tenants`, each with `across_tenants: true` |
| `cleanup.expired_assignments` | `data`: `removed`, `invalidated` (users whose cache invalidation the store confirmed), `affected_user_count`, `affected_user_ids` (at most 100), `affected_user_ids_truncated` (there were more), `set_uuids`, `set_names`, and the cache scope: `cache_confirmed` (`true` / `false`, what the store confirmed), `process_local`, `in_request`, `unconfirmed` (as for `erasure.performed`). Each removed assignment has its own `assignment.revoked` naming its person. Written only when something was removed; the run's events carry the reason `expired` unless a reason is given. With no tenant set while tenancy is on: one per tenant that lost assignments (in that tenant, with that tenant's counts and sets), plus one without a tenant with the totals and `tenants`, each with `across_tenants: true` |
| `cache.cleared` | `data`: `operation` (`cache_clear`), `strategy` (`pattern` or `enumerated`), `users` (user visits invalidated; `nil` under `pattern`, with `counted: false`), `tenants`, and the cache scope: `cache_confirmed` (`true` / `false`, what the store confirmed), `process_local` (the store lives in each process — `cache_backend = :memory`, or `Rails.cache` a `:memory_store`), `in_request`, `unconfirmed` (users the store did not confirm); the sentence ends as for `erasure.performed`. Written by `rake permission_forge:cache:clear` / `PermissionCacheClearer`: one per tenant, in that tenant with that tenant's counts, plus one without a tenant with the totals and `across_tenants: true` |
| `audit.purged` | `data`: `operation`, `count`, `batch`, `cutoff`, `period_seconds`, `dry_run`, and `across_tenants: true` when the purge ran with no tenant set while tenancy is on. One per deleted batch, in the batch's own transaction; in that across-tenants case one per tenant whose events the batch deleted (in that tenant, with that tenant's `count`) plus one without a tenant when the batch deleted untenanted events. Never purged itself |
| `audit.settings_observed` | `data.settings`: the ten audit options as they stood at boot (a lambda reads `set` or `unset`, never its code) |
| `report.generated` | `data.task` and `data.counts` of a read-only rake task (`audit`, `audit_masks`, `stale_assignments`, `expired_assignments`) |

### Admin events (6)

Viewing, exporting and refused requests. Written by `Audit.record`.

| Event | What it carries |
|---|---|
| `admin.effective_access_viewed` | the person (`subject_user_id`) whose effective access was opened (Person page, Effective tab, or the field drawer's "Explain for a person") |
| `audit.viewed` | `data.scope` (`log`, `event`, `person`, `permission_set`, `api`) and the filters used; the 2xx response only |
| `audit.exported` | `data.scope` (`log`, `holdings`, `person`, `permission_set`), `data.format`, the filters |
| `admin.auth_failed` | `data.reason` (`invalid_credentials`, `basic_auth_not_configured`, `assignment_not_authorized`, `audit_log_not_authorized`, `tenant_missing`), `method`, `path`, `endpoint`; for a Basic sign-in the typed username as actor label, never the password. An assignment refusal adds `hook`, `action`, `user_ids` (at most 100) and `user_count`. `tenant_missing`: tenancy is on, the request has no current tenant and `admin_tenantless_access` is not `:allow` |
| `api.auth_failed` | `data.reason` (`api_auth_not_configured`, `api_auth_denied`, `action_not_authorized`, `assignment_not_authorized`, `audit_log_not_authorized`, `stats_not_authorized`, `tenant_missing`), `hook` (the option that refused), `method`, `path`, `endpoint`; `status` for the two `api_auth` reasons; `action` for an action refusal; `user_ids` (at most 100) and `user_count` for an assignment refusal |
| `admin.lock_refused` | a change refused because a record is locked (`is_editable: false`), from the admin screens or the API: `method`, `path`, `endpoint`; the event's record is the locked one, which may be the changed record itself or what holds it (its Resource, its Permission Set, or a membership's Permission Set Group). A change to a locked set's holders is refused only when it widens access: adding holders or extending/clearing end dates on a granting set, removing holders or ending them sooner on a Muting Permission Set |

### Runtime (access) events (9)

Published always, stored only for the groups in `config.audit_runtime_events`. Written by `Audit.instrument`.

| Event | Group | What it carries |
|---|---|---|
| `access.denied` | `denied` | `data.model`, `data.reason` (`rule`, `nil_user`), `data.via` (`find_by`, `permission_scoped`, `auto_scope`); `subject_user_id` is the user denied |
| `action.denied` | `denied` | `data.model`, `data.reason` (the Authorizer reason), `data.action`, `controller`, `action_name`, `via: action_guard` |
| `rule.bypassed` | `bypass` | `data.model`, `data.via`, `data.reason`: `view_all`, `modify_all`, `nil_user`, `scope_suspended`, `auto_scope_opt_out`, `no_rules`, `guard_bypass` |
| `query.unscoped` | `bypass` | `data.model`, `data.table`, `data.mode`, `data.call_site`; never the SQL |
| `field.access` | `field_read` | one per record read: `data.model`, `hidden[]`, `masked[]`, `unconfigured[]`, `bypassed[]` (field names), `passed` (a count) and `passed_fields[]` (the names read in the clear; under `unconfigured_field_strategy` `:pass_through` or `:warn` the `unconfigured[]` ones are returned unfiltered too, and reads with no user are under `bypassed[]`); never a value |
| `params.filtered` | `params_filtered` | `data.model`, `data.reason` (`field_access`, `nil_user`), `data.dropped` (parameter paths, never values) |
| `write.masked_skipped` | `params_filtered` | the record, `data.attribute`, `data.protection`, `data.detected_by` |
| `permissions.rebuilt` | `cache` | `subject_user_id`; `data.read_through`, `data.withheld` |
| `permissions.invalidated` | `cache` | `subject_user_id`; `data.tenant_id`, `data.confirmed` |

### Columns of every event

| Column | Meaning |
|---|---|
| `uuid`, `occurred_at` | Identity and time of the event (UTC, microseconds). `occurred_at` is `Time.current` of the application server (see [clock synchronisation](#what-the-host-must-do)). |
| `event`, `category` | Name from the catalogue; `change`, `admin`, `system` or `access`. |
| `actor_type`, `actor_id`, `actor_label` | `user`, `api`, `basic_auth`, `system` or `unknown`; the id as text (bigint and UUID keys both fit); the name at the time of the event. |
| `source` | `admin_ui`, `api`, `rake`, `job`, `console`, `service` or `runtime`. |
| `record_type`, `record_id`, `record_uuid`, `record_label` | What the event is about. No foreign keys: events outlive the row. For a host record only type, id and (when the table has a `uuid` column) uuid are filled, never a label. |
| `permission_set_id`, `permission_set_uuid` | The Permission Set concerned, when there is one. |
| `subject_user_id` | The person an assignment, membership, denial or view names. Changes to a Permission Set, its resources, fields, actions or rules, or a set joining a group, change every holder's access but name none of them. To reconstruct one person's access, combine their events with the timelines of the sets they held. |
| `data` | JSON (`changes`, `snapshot` and event-specific keys). |
| `reason`, `request_id`, `ip`, `correlation_id` | See below. |
| tenant column | Present when tenancy is configured; follows the record the event is about, else the ambient tenant. |
| `created_at` | No `updated_at`: rows are never updated. |

Every text column is cleaned once, before it is stored (`Audit::ColumnValues`): valid UTF-8, line breaks and tabs become a space, other control characters are removed, at most 255 characters. `data` is stored as given.

## What is not recorded

Read this list before you tell an assessor what the log proves. Each item is a limit of the code, not an oversight in this page.

**Writes that run no callbacks.** `update_all`, `delete_all`, `update_column(s)`, `touch`, `delete`, `insert_all`, `upsert_all`, raw SQL, `collection.delete_all(:delete_all)` or `(:nullify)` with an explicit strategy, a narrowed relation such as `collection.where(...).delete_all`, and a database console change a permission row without an event (`Concerns::RecordsAuditEvents` hooks `after_create`, `after_update` and `after_destroy`). The gem's own code does not use them on the eight models (the one exception is the one-time de-duplication migration `add_resource_fields_unique_index`, which runs a raw `DELETE FROM`); **your** code and other applications that write to the same tables with their own models can. The association writers Rails generates for the gem's own collections are recorded: `user.permission_sets.delete`, `set.user_ids = []`, `group.permission_sets = []`, `clear` and `delete_all` without an argument remove assignments, memberships and set links record by record, through callbacks (`PermissionForge::Concerns::AuditedCollection`), each with its event and cache invalidation, and never destroy the other side. The de-duplication migration prints the kept row and the deleted ids of each duplicate group ("not in the audit log") in its output. A save that changes nothing besides bookkeeping columns writes nothing, and a `destroy` whose DELETE hit no row writes nothing (the event was written when the row went).

**Reads.**
- Reads of record data are not recorded unless you store the `field_read` group, and then only reads that go through the model's attribute readers or the response filters. `pluck`, raw SQL (including `select("email AS contact")`) and direct database access bypass both masking and the event.
- Reads in the admin screens and the API are not recorded except the ones listed above: viewing someone's effective access, the audit tabs, the audit log, its exports and the "who holds what" export. Opening a Permission Set, a Resource or the People list leaves no event.
- With the default `audit_runtime_events = %i[denied]`, bypasses (`rule.bypassed`), `query.unscoped`, `field.access`, `params.filtered`, `write.masked_skipped` and the cache events are published but **not stored**. A runtime event published inside an open transaction is stored when the outermost transaction ends, committed or rolled back. The exception is an outermost `transaction(joinable: false)` (the same limit as for refusals, below): the gem does not count it as open, so a runtime event noticed inside it is lost if it rolls back.
- Some runtime events are reported once per request (a `rule.bypassed` under auto-scoping for one model, reason and user; `query.unscoped` once per table), not once per query. `scope_suspended` and `auto_scope_opt_out` bypasses carry no `subject_user_id`.

**Settings.** `audit.settings_observed` covers only the ten audit options listed in the [catalogue](#system-events-7). The configuration that decides access is not recorded: `nil_user_strategy`, `unconfigured_action_strategy`, `unconfigured_field_strategy`, `action_guard_bypass`, `api_auth`, `api_action_authorization` and `api_assignment_authorization`, `current_user_resolver`, the HTTP Basic credentials, auto-scoping, `masked_write_protection`, `extra_fields_default_access` and the host's `permission_forge_actions` mappings. Track changes to the initializer and to the deployed code in your own change management. `audit.settings_observed` is written at boot when the audit settings differ from the last one recorded (not in the `test` environment). A setting changed at run time after boot (`PermissionForge.configuration.audit_events = false` in a console, say) is not observed until the next boot. A period with `audit_events = false` shows only as a gap, and as the `audit.settings_observed` event at the next boot.

**Failures.**
- With `audit_events = false`, or with `:auto` and no table, changes go through unrecorded. With `true` and no table, every change fails under the default `:raise` strategy (and goes through unrecorded under `:report` or `:log`). `:auto` looks for a missing table again every 60 seconds, so a worker started before the migration records once it has run.
- With `audit_change_failure_strategy = :report` or `:log`, a change whose event cannot be written goes through without it (the failure is logged and, under `:report`, handed to `Rails.error`).
- A refusal (`admin.auth_failed`, `api.auth_failed`, `admin.lock_refused`) is written after the surrounding transaction ends, whether it commits or rolls back. The exception is a **non-joinable** transaction (`transaction(joinable: false)`, as Rails test fixtures and some wrappers use): the gem does not count it as open, so a refusal noticed inside it is lost if it rolls back.
- A browser's first Basic-auth challenge (no credentials sent) is not an event. Credentials that were sent and rejected are (`admin.auth_failed`). Successful admin and API sign-ins, and sessions, are not recorded at all; record sign-ins in your authentication layer.
- A host that lets Rails' request logger evaluate `request.remote_ip` before the engine runs: when the `Client-IP` and `X-Forwarded-For` headers contradict each other, Rails raises `ActionDispatch::RemoteIp::IpSpoofAttackError` in the host's middleware (`Rails::Rack::Logger`, at info log level), the request ends in a 500 before routing, and **no event is possible**. The engine itself handles the error (`Audit::RequestContext.remote_ip` falls back to the peer address and flags `ip_spoof_suspected` on refusals). Configure trusted proxies, strip `Client-IP` at the proxy, or decide `config.action_dispatch.ip_spoofing_check` in the host. Observed manually on Rails 7.1.6 and 8.1.4; not covered by the test suite.

**Database policies.** `rake permission_forge:rls:sync` and `rls:remove` (and the RLS generator's migration) write no audit event, by design: they only install, replace or remove PostgreSQL policies derived from rules whose changes are already recorded. `rls:remove` switches row-level security off without a trace in the log; record these runs in your change management.

**Decisions that allow.** Only denials are recorded (`access.denied`, `action.denied`), and bypasses when their group is stored. An allowed controller action and the rows a rule allowed leave no event. Rows a row-level rule filters out are not denials either: `permission_scoped`, auto-scoping and `find` (which raises `RecordNotFound`) publish no event for them; only `find_by` and `find_by!` attribute a rule denial to the user. `user.can?` and `can_*?`, `Authorizer.allowed?` (the checks behind buttons in a view) and conditional-set activation (IP, hours, session flag) are not instrumented.

**Expiry.** An assignment whose `expires_at` has passed leaves no event at the moment access lapses; only the later removal by the expired-assignment cleaner is an event (`assignment.revoked`, `cleanup.expired_assignments`). Derive the lapse from `expires_at` in the grant's snapshot.

**Your own records.** Changes to and reads of your own application's models are not recorded (outside the `field_read` group, which records field decisions on models with `MaskedAttributes`). Audit your own application records where your regime requires it.

**Dry runs and empty runs.** `DataSubjectErasure`, `ConsentWithdrawalHandler` and `AuditEventPurger` with `dry_run: true` write no event. `ExpiredAssignmentCleaner` writes `cleanup.expired_assignments` only when it removed something; a purge that finds nothing records nothing.

**Tenants.** With a tenant set (the admin screens), the erasure service removes the person's assignments and memberships in that tenant only (`assignments_remaining_elsewhere` counts the rest) and clears name labels in that tenant's events only; with none set (the rake task), it removes them and clears labels in every tenant, untenanted events included. A request with no tenant set sees the events of every tenant, as every other endpoint of the gem does for its own tables; with tenancy on, the admin screens and the API refuse such a request unless `admin_tenantless_access = :allow` (`tenant_missing`).

**Free text.** `reason` and host-supplied `data` are stored as given. Erasure clears name labels, not free text. `params.filtered` stores the **names** of dropped parameters (their paths, never values); with a free-form permitted hash (`permit(meta: {})`) those are keys chosen by whoever sent the request.

**Copies and personal data outside the table.** Erasure does not reach copies outside it: events already forwarded to notification subscribers or a log platform, downloaded exports and database backups. The usernames typed at a failed HTTP Basic sign-in (`admin.auth_failed`) and the labels of API actors are not scrubbed, because they are not user records.

## Who did it: actor resolution

The actor of an event is the first of these that names someone (`Audit::Actor.current`, `Audit::ActorResolver`):

1. An explicit block: `PermissionForge.with_audit_actor(...)` or `Audit::Context.with(actor: ...)`. A host that wraps requests in its own around-action wins over the request's resolution.
2. The request (admin UI): `config.audit_actor_resolver`, called with the controller; then `config.current_user_resolver`; then, under HTTP Basic auth, the username that was checked (`actor_type: basic_auth`, no id).
3. The request (API): `audit_actor_resolver`; then the current user; otherwise an anonymous `api` actor labelled "API client" (`api_auth` answers yes or no, so it cannot name a principal). On the default `api_base_controller_class` your app's sign-in does not run, so `Current.user` is not set there and changes read "API client" even from a signed-in browser: see [naming the API caller](admin-api.md#who-the-audit-log-names-for-an-api-change).
4. Outside a request: `PermissionForge.current_user`; otherwise `unknown`.

The actor is never taken from parameters or headers. A resolver that raises, or answers with something that is not an actor, gives `unknown` and is reported through `audit_hook_failure_strategy`.

```ruby fragment
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  # Under HTTP Basic auth your app's sign-in does not run in the admin: name the
  # person signed in to your app, not the shared Basic-auth login.
  # Rails 8's authentication generator:
  config.audit_actor_resolver = ->(controller) {
    Session.find_by(id: controller.request.cookie_jar.signed[:session_id])&.user
  }
  # Devise: ->(controller) { controller.request.env['warden']&.user(:user) }
  # Behind your own admin controller (base_controller_class) leave it nil:
  # current_user_resolver already names the signed-in user.

  # A token API: name the client yourself.
  # config.audit_actor_resolver = ->(controller) {
  #   { type: 'api', id: controller.api_key.id, label: controller.api_key.name }
  # }
end
```

Outside a request, name the actor explicitly:

```ruby fragment
PermissionForge.with_audit_actor(user: admin, source: 'job', reason: 'TCK-12') do
  PermissionForge::Services::ExpiredAssignmentCleaner.call
end

PermissionForge.with_audit_actor(label: 'nightly import', source: 'service') { import! }
```

`source` is one of `admin_ui api rake job console service runtime`. Without one, the gem says `console` in a Rails console, `rake` while a rake task runs, and `service` otherwise; a job performed through Active Job says `job`.

**Under HTTP Basic auth every admin shares one login**, so events name that username, not a person. `rake permission_forge:audit` reports it (`audit_shared_basic_auth`, Medium) and the engine logs a warning at boot until `audit_actor_resolver` is set.

`created_by_id` / `updated_by_id` on the rows themselves (`config.audit_trail_enabled`) are stamped only from an actor of type `user` that is an instance of `config.audit_user_class`; a Basic-auth, API-client or system actor stamps nothing, and an edit by nobody no longer blanks `updated_by_id`. They are a convenience on the live row; the events are the record.

## Request context: request id and IP

Each event carries `request_id` and `ip` from `request.request_id` and `request.remote_ip`, capped at 255 characters. Both are **client-influenced**:

- `remote_ip` is only as trustworthy as your proxy setup. Configure `config.action_dispatch.trusted_proxies` (or the proxy that sets the header) so that `X-Forwarded-For` from the internet is not believed.
- `request_id` may come from the client's `X-Request-Id` header (Rails sanitises it, it does not authenticate it).

Override either with a lambda; a key you return replaces the default (a key returned as `nil` stores nothing):

```ruby fragment
config.audit_request_context = ->(controller) {
  { request_id: controller.request.headers['X-Correlation-Id'], ip: controller.request.headers['CF-Connecting-IP'] }
}
```

A lambda that raises is reported and the defaults are used.

## Reason and correlation

**Reason.** A free-text reason (a ticket number, "left the team") is stored on the event as `reason`:
- every admin UI form that changes permission data has an optional "Add a reason" field (`name="reason"`, 255 characters; a group's Duplicate sends the reason of the header form); the API reads a `reason` parameter or JSON key; only requests that can change something (not GET or HEAD) are read, and only a String is accepted;
- rake tasks read `REASON=`, services take `reason:`, `with_audit_actor` takes `reason:`.

On an assignment or a group membership the reason is also kept on the row (`reason` column), so the row shows the reason of the **last change that had one**, not of its creation. A change without a reason keeps the row's old value.

**Correlation.** Events of one action share a `correlation_id`: one id per mutating admin or API request, one per outermost transaction otherwise, one per standalone event when neither applies. `Audit.correlate { ... }` makes a block share one id (an outer block's id wins).

```ruby fragment
PermissionForge::Audit.correlate { change_set.apply! }
```

## Configuration

All ten options live in `PermissionForge::Configuration::AuditSettings`; the Settings page of the admin lists them (all but `admin_assignment_authorization` under "Audit log"). The older `audit_trail_enabled`, `audit_user_class`, `on_rule_bypass` and `on_field_filtered` still work (see [legacy hooks](#notifications-the-log-subscriber-and-legacy-hooks)).

| Option | Default | Values and effect |
|---|---|---|
| `audit_events` | `:auto` | `:auto` records when the table exists; `true` always (a missing table then fails every change); `false` never (notifications are still published). Anything else raises `ConfigurationError`. |
| `audit_actor_resolver` | `nil` | `lambda(controller)` returning a user, an `Audit::Actor` or `{ type:, id:, label: }`. |
| `audit_request_context` | `nil` | `lambda(controller)` returning `{ request_id:, ip: }`. |
| `audit_change_failure_strategy` | `:raise` | `:raise`, `:report`, `:log`. See [below](#when-an-event-cannot-be-written). |
| `audit_hook_failure_strategy` | `:report` | `:report`, `:log`, `:raise`. Subscribers, legacy hooks, runtime-event stores, resolvers. |
| `audit_runtime_events` | `%i[denied]` | Any of `denied bypass field_read params_filtered cache`; strings accepted, `nil` means none. The array is frozen: assign a new one, `<<` raises. |
| `audit_log_subscriber` | `false` | `true` writes every event as one JSON line to `Rails.logger`. |
| `audit_retention_period` | `nil` | `nil` keeps events forever; a Duration (`2.years`) or a number of seconds; zero, negative or anything else raises `ConfigurationError`. |
| `audit_log_authorization` | `nil` | `lambda(controller)`; the audit pages, exports and API endpoint are shown only when it returns exactly `true`. `nil`: anyone who can reach the admin. |
| `admin_assignment_authorization` | `nil` | `lambda(controller, target, user_ids, action)`; see [configuration.md](configuration.md#admin_assignment_authorization). |

```ruby fragment
PermissionForge.configure do |config|
  config.audit_events = :auto
  config.audit_runtime_events = %i[denied bypass]
  config.audit_retention_period = 2.years
  # PermissionForge.current_user: current_user_resolver's user (set behind your base_controller_class)
  config.audit_log_authorization = ->(_controller) { PermissionForge.current_user&.auditor? == true }
end
```

## When an event cannot be written

| Where | Strategy | When the write fails |
|---|---|---|
| Every event written with `Audit.record`: change events, and also views, exports, refusals and housekeeping summaries | `audit_change_failure_strategy` | `:raise` (default): `Audit::EventNotRecordedError`; the change rolls back. A caller that rescues the error inside its own transaction still cannot commit: the transaction fails at commit. `:report` / `:log`: the operation goes through without its event. |
| Runtime events, notification subscribers, legacy hooks, actor and request-context lambdas | `audit_hook_failure_strategy` | `:report` (default): logged and handed to `Rails.error`, the request goes on. `:log`: logged only. `:raise`: the error propagates and **replaces** the decision's own outcome (the read, the query, or the error the guard raises). |

What follows:
- **Views and exports fail closed.** Viewing the audit log, opening someone's effective access and exporting write their event with `Audit.record`; under `:raise` a view whose event cannot be written answers 500 and shows no data. A refused request becomes a 500 instead of a 401/403: still refused.
- **The purge always fails closed.** Each batch of deleted events and its `audit.purged` event commit together; a batch whose event cannot be written is not deleted, under every strategy. With auditing off (or the table missing) a real purge raises `ConfigurationError`.
- **Consent withdrawal is one transaction.** The revocations and `consent.withdrawn` commit together; under `:raise`, if the summary cannot be written nothing is revoked. The cache is invalidated after the commit.
- **Erasure under `:report` or `:log` completes without `erasure.performed`.** The right to erasure is not blocked by the audit write; the failure is reported. Under `:raise` nothing changes if the summary cannot be written.
- **Each stored event costs a savepoint** (`SAVEPOINT` + insert + `RELEASE`), because on PostgreSQL a failed INSERT would otherwise abort the caller's transaction.
- **Denials cost one extra query** (the id of the denied row) on the denial path only.

## Runtime groups and their cost

Runtime events are published always (if somebody listens) and stored only for the groups in `audit_runtime_events`. With nobody listening and the group not stored, `Audit.instrument` returns before building anything.

| Group | Events | Volume to expect |
|---|---|---|
| `denied` (default) | `access.denied`, `action.denied` | One per denial. Small. |
| `bypass` | `rule.bypassed`, `query.unscoped` | Admin requests run with record rules suspended, so under auto-scoping each request reports one `scope_suspended` per protected model it reads. Moderate. |
| `field_read` | `field.access` | **One event per record read**, whether or not any field was hidden. High: switch it on for the models and the period where you must show who could read personal data, and plan retention for it. |
| `params_filtered` | `params.filtered`, `write.masked_skipped` | One per write that dropped parameters or refused a masked write-back. |
| `cache` | `permissions.rebuilt`, `permissions.invalidated` | One per permission-hash rebuild or invalidation. High on a busy system. |

**What `field_read` costs.** Each stored `field.access` is an INSERT in its own transaction: three statements per record read. On the 0.14 release candidate (Ruby 3.4.5, Rails 8.1.4, Apple M5 Max, in-memory SQLite, measured by the pre-release performance review) a masked getter took about 355 µs with `field_read` stored instead of about 2.5–2.9 µs, and serializing 1,000 records with `as_json` took about 400 ms and 1,000 transactions instead of about 40 ms. On a networked database each read adds its round trips. **A subscriber to a pattern** that matches every PermissionForge event (`ActiveSupport::Notifications.subscribe(/permission_forge/)`, as some log shippers do) opens every runtime gate even when nothing is stored: the same getter then took about 50 µs. A forwarder that needs every event (see [Forwarding to a log platform](#forwarding-to-a-log-platform)) pays that; anything else should subscribe to the event names it needs.

`field.access` lists field **names** (`hidden`, `masked`, `unconfigured`, `bypassed`, and `passed_fields` for the ones read in the clear) and a count of the ones that passed. It never stores a value. To answer "who read `email` unmasked", filter `field.access` for the model and check that `email` is in `data.passed_fields`, or in `data.unconfigured` when `unconfigured_field_strategy` is `:pass_through` or `:warn` (those fields are returned unfiltered); reads with no user are under `bypassed` (a field absent from `masked` and `hidden` may simply not have been part of the read). A virtual reader that is hidden and dropped from `as_json(methods:)` is listed under `hidden`. The names are collected only when the event will be built, so the no-listener path is unchanged. The sentence reads "*actor* read *record*.", or "… with these fields hidden or masked: …" when any were.

## Notifications, the log subscriber and legacy hooks

Every event is published after the transaction that wrote it commits (at once outside a transaction, never after a rollback). Runtime events are published at once. The payload has every column as a symbol key, plus `tenant_id`, `stored` (was a row written), `deferred` (it will be written when the open transaction ends), `audit_event` (the row or `nil`) and, for in-process subscribers only, `objects`.

```ruby fragment
ActiveSupport::Notifications.subscribe(/\.permission_forge\z/) do |event|
  Rails.logger.info("#{event.name} #{event.payload[:actor_label]}")
end

ActiveSupport::Notifications.subscribe('assignment.revoked.permission_forge') do |event|
  SecurityMailer.revoked(event.payload[:subject_user_id]).deliver_later
end
```

**Publishing happens even when storage is off** (`audit_events = false`, table missing): `stored: false`, `audit_event: nil`. That is the channel for sending events elsewhere.

**The log subscriber.** `config.audit_log_subscriber = true` writes one line per event at info level:

```
[PermissionForge] audit {"uuid":"3f2a...","event":"assignment.revoked","category":"change","actor_type":"user","actor_id":"7","source":"admin_ui","record_type":"PermissionForge::PermissionSetUser",...,"data":{"snapshot":{...}},"correlation_id":"...","occurred_at":"...","stored":true,"deferred":false}
```

It leaves out `actor_label` and `record_label` (names) and empty columns, but it **forwards the whole `data`**: change events carry `changes` and `snapshot`, and a snapshot of a rule includes its `field_value`. It also carries `ip`, `request_id` and `reason`. Treat wherever those logs go as holding that data.

**Legacy hooks.** `config.on_rule_bypass` and `config.on_field_filtered` keep their signatures. They are now subscribers of `rule.bypassed` and `field.access`, silenced while the hook is `nil`. Differences from before: their errors are no longer swallowed, they follow `audit_hook_failure_strategy`; and `on_field_filtered` is called once per field decision, in the same order with the same arguments: as the decision is made when it is the only listener and `field_read` is not stored (as before), otherwise when the read returns.

`on_field_filtered` is also called per field for `record.attributes` when there is no current user (as it is for getters and `as_json`), when someone listens or `field_read` is stored.

**What the legacy hooks cost.** With a hook set, reads cost more than before. Measured in 0.13, when the hooks were added, against the commit before them (`test/benchmarks/runtime_decision_events_benchmark.rb`, results in [benchmarks.md](benchmarks.md#audit-events-attribute-reads-and-row-lookups)): a masked getter with `on_field_filtered` set took about 1.24 times as long, and `find_by` with a `view_all` bypass and `on_rule_bypass` set about 1.08 times; a 0.14 run of the same script gives the same picture (about 1.3x and 1.1x). With no hook set and nobody listening, reads were not slower. These are single-machine numbers.

## The Audit log page

Mounted at `<mount path>/audit` (sidebar entry "Audit log"). It is read-only: nothing on it writes an event except its own `audit.viewed`.

- **List.** Newest first, 50 per page with First / Previous / "Page n of m" / Next / Last links, no cap on how far back it goes.
- **Filters** (GET form, no JavaScript needed): from, to, event (grouped by category), category, actor type, actor, person, Permission Set, correlation id; `record_type` / `record_id` / `record_uuid` appear when given. Invalid input answers 422 with one line per field.
- **Days are days in the application's time zone** (`Time.zone`); the page says which zone. The API and a timestamp with an offset are read as UTC or as written.
- **Views of the log (`audit.viewed`) are hidden** from the list and the timelines unless you tick "Include views of the log" or filter by event or category. Exports always include them.
- **One event** (`/audit/<uuid>`): a sentence, when and from where, the actor, the record, the Permission Set, the person, the before/after table of `data.changes`, the snapshot of a created or deleted row, any other data key, the reason, and links to all events of the same actor, record, set, person or correlation id. An unknown id, an id with a NUL byte and an id longer than 255 characters all answer 404.
- **Timelines.** The Permission Set's Audit tab and the Person's Audit tab show the same events with paging (20 per page) and links into the log.
- **Review labels.** Assignments read "Reviewed by *person* on *date*", "Reviewed on *date*" (reviewer is not a record, e.g. Basic auth) or "Never reviewed". Staleness is counted from the last review (`reviewed_at`), else from the grant (`created_at`).
- **"Last edited by"** in a record's footer comes from the latest change event while auditing records, and says "History" with a link into the log; with auditing off it falls back to `updated_by_id` / `updated_at`.
- **"Created by"** (footers, the Assignments tab, "Assigned by", the audit tabs and their CSV) comes from the record's creation event (`<model>.created`, `assignment.granted`, `group_membership.added`) while the log has one, so an HTTP Basic login or an API client is named as in the log rather than as "System"; without one it falls back to `created_by_id`, which stays a user id (nothing is stamped for an actor that is not a record of `audit_user_class`).
- **Names as of the event.** A sentence names a Permission Set or group as it was when the event happened (the label of the record's latest event at or before it; failing that the earliest later event's previous name, then the live name, then `#id`) and a person by the label stored on the assignment or membership. A revocation of an assignment whose `expires_at` had passed reads "… after it expired on *date*".
- **Home** shows a card when auditing is switched off, when the table is missing, or when `audit_events = true` has no table and every change fails; the log and timelines carry a note with the same three texts.
- **Gating.** `audit_log_authorization` guards the page, the event page, the exports, the holdings export, the audit tabs of the Person and Permission Set pages and their CSV. A refusal answers 403 (a page, banner or empty body) and records `admin.auth_failed` with reason `audit_log_not_authorized`, once per request; the other tabs stay reachable. A lambda that raises counts as a refusal. Names taken from the log also appear outside the gate: the "Created by" and "Last edited by" footers, "by …" in a Permission Set's Assignments tab, and "Assigned by" on a person's Access tab and in the Home stale-assignments card.

## Exports

Every export is of the **current filter**, has **no row cap**, and is itself recorded as `audit.exported`.

**Audit log export** (`/audit.csv`, `/audit.json`): all columns of the API serializer (`id uuid occurred_at event category actor_type actor_id actor_label source record_type record_id record_uuid record_label permission_set_id permission_set_uuid subject_user_id data reason request_id ip correlation_id created_at`), oldest first, times in ISO 8601 UTC. `data` is JSON.

CSV layout: a metadata block of `key,value` lines, an empty line, the column names, then the rows (CRLF line ends, RFC 4180 quoting):

```
export,audit_events
exported_at,2026-10-05T09:30:00Z
time_zone,Europe/Berlin
exported_by,Ada Admin
exported_by_type,user
exported_by_id,7
filters,"{""from"":""2026-07-01"",""to"":""2026-09-30"",""include_views"":true}"
row_count,1234

id,uuid,occurred_at,event,...
```

JSON layout: `{ "meta": { ... }, "columns": [ ... ], "data": [ { ... } ] }` with the same metadata keys. `include_views: true` is always in the filters: an export is evidence, so views of the log are in it.

**Who holds what** (`/audit/holdings.csv`, `.json`, linked from the log page and the People page): every assignment as it stands, with columns `assignment_id assignment_uuid person_id person permission_set_id permission_set_uuid permission_set muting set_active granted_at granted_by_type granted_by_id granted_by expires_at expired reviewed_at reviewed_by_id reviewed_by reason`. `granted_by` is the actor of the assignment's `assignment.granted` event, else its `created_by`. A blank `reviewed_at` means never reviewed. Expired rows are listed with `expired` true; group memberships are not included.

**Person and Permission Set CSVs** (the Audit tabs) list the *records* the person created or last edited (or the set's records), taken from `created_by` / `updated_by` and the latest change event (`/permission_sets/:id.csv` is always this CSV, gated like the audit tab), with no per-type limit (the tab itself shows the latest 100 per type and says so). They are not the events: to export the events about a person use the Audit log filtered to them (Person page, Audit tab, "Events about …", then CSV/JSON), or `GET /api/audit_events?subject_user_id=`.

How they are delivered:
- Both exports are streamed in batches, so neither is built in memory: the events export in batches of 1000 (`find_each`), the "who holds what" export in batches of 500 assignments (`find_in_batches`). Each counts its rows with one `COUNT` query when it starts, for `row_count`. Events are insert-only, so the events export fixes its rows at the newest id then and `row_count` is the number of rows that follow. Assignments are changed and removed, so the "who holds what" `row_count` is the count when the export started: an assignment removed while the file is written is missing (`row_count` can exceed the rows) and each row shows its assignment as it was when its batch was read. The body is written after the request's own wrappers have ended; the export carries the action's tenant and suspended record rules into it, so a host that sets the tenant in its own `around_action` needs nothing more. A host middleware that buffers response bodies would hold the file in memory; a database error mid-stream truncates the file, and `row_count` in the header tells you how many rows to expect.
- The rows are fixed when the export starts (events up to the newest at that moment), so `row_count` equals the rows that follow; the export's own `audit.exported` is written after and is not in it.
- Headers of the audit log and "who holds what" exports: `Cache-Control: no-store`, `X-Accel-Buffering: no`, a download filename `permission-forge-<kind>-<UTC timestamp>.csv|json`. The Person and Permission Set CSVs are plain CSV files with `Cache-Control: no-store` and without the metadata block and with their own filenames (`permission-forge-changes-<person id>.csv`, `permission-forge-<set name>-audit.csv`).
- CSV injection: a cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return (also after leading spaces) is written with a leading apostrophe (`Admin::Csv`).

## The API endpoint

Read-only, under the engine's API (`config.api_enabled = true`, authenticated like every API endpoint, then `audit_log_authorization`). A refused call answers 403 and records `api.auth_failed` (`audit_log_not_authorized`). Reads are recorded as `audit.viewed` (`scope: api`).

```
GET /permissions/api/audit_events?event=assignment.revoked&from=2026-07-01&to=2026-09-30&page=1&per_page=100
GET /permissions/api/audit_events/<uuid>          # or the id, per config.api_record_identifier
```

Filters (all optional; an invalid value answers `422 {"error":{"status":422,"messages":{"from":["is invalid"]}}}`):

| Parameter | Meaning |
|---|---|
| `from`, `to` | ISO 8601 timestamp or `YYYY-MM-DD`. Without an offset: UTC. A bare `to` date means the end of that day, inclusive. |
| `event` | One name, an array, or a comma list; every name must be in the catalogue. |
| `category`, `actor_type` | Must be a known value. |
| `actor_id`, `subject_user_id`, `correlation_id` | Exact match. |
| `record_type` + `record_id` or `record_uuid` | `record_id` matches the `record_id` column only, `record_uuid` the `record_uuid` column only; either requires `record_type`. |
| `permission_set` | A uuid, or a numeric id. |

Newest first (`occurred_at desc, id desc`). Pagination follows `config.api_default_per_page` (15) and `config.api_max_per_page` (100); a `page` beyond 2,147,483,647 is clamped. Each row has every column except the tenant column; `data` is an object and times are ISO 8601 UTC with microseconds. Unknown parameters are ignored. Only `GET` routes exist. See [admin-api.md](admin-api.md#audit-events-read-only).

## Retention and purge

`audit_retention_period` defaults to `nil`: events are kept forever (the security audit reports this as `audit_kept_forever`, Info). Set it to your policy:

```ruby fragment
config.audit_retention_period = 2.years
```

Nothing deletes events on its own. Run the purge from cron, a job or a rake task:

```bash run
DRY_RUN=1 bin/rails permission_forge:audit_events:purge                    # counts only (a dry run)
bin/rails permission_forge:audit_events:purge                              # deletes
ACTOR="Ops nightly" REASON="TCK-88" bin/rails permission_forge:audit_events:purge
```

```ruby run
PermissionForge::Services::AuditEventPurger.call(dry_run: true)
PermissionForge::Services::AuditEventPurger.call(actor: 'nightly job', reason: 'policy 7.2')
```

- `DRY_RUN` decides whether the task deletes: unset (or empty), `false`, `0` or `no` deletes, so a scheduled purge keeps running; any other value (`1`, `true`, `yes`, `TRUE`) only counts. `rake permission_forge:erasure` reads `DRY_RUN` the same way but is a dry run when it is unset. `ACTOR=` and `REASON=` name who ran it and why on its `audit.purged` events.
- Only events with `occurred_at` strictly before `now - period` are deleted. A Duration is subtracted by the calendar (`30.days` across a daylight-saving change, `1.year`); a number is seconds.
- Deleted in id batches of 1000, each batch in one transaction with its own `audit.purged` event (`count`, `batch`, `cutoff`, `period_seconds`). A purge with no tenant set while tenancy is on writes one `audit.purged` per tenant whose events the batch deleted, in that tenant and with that tenant's `count` (`across_tenants: true`), plus one without a tenant for untenanted events, so each tenant's auditors see that their log was purged.
- **`audit.purged` events are never purged.** The record of what was deleted outlives it.
- In a tenant context only that tenant's events are purged; with none, all of them.
- There is deliberately no route, controller action or API for the purge: it is reachable from Ruby and rake only. Rake without `ACTOR=` records the actor as `rake permission_forge:audit_events:purge` and prints a warning on stderr.
- With no period set, nothing is deleted and the task says so.

The purge uses `relation.delete_all`. If you revoke `DELETE` from the application's database role (recommended), run the purge with a separate role; see below.

## Erasure and the names in the log

`DataSubjectErasure` removes a person's assignments and group memberships through callbacks (each writes `assignment.revoked` or `group_membership.removed`), then clears the **name labels** the log holds about them and writes `erasure.performed`, all in one transaction:

- `actor_label` of events where the person was the actor (`actor_type: user` only; an API key or Basic login that happens to share the id is somebody else),
- `record_label` of events whose `subject_user_id` is the person,
- with a tenant set (the admin screens), in that tenant's events only; with none set (the rake task), in every tenant's events and in events without a tenant.

This is the one sanctioned mutation of events (`update_all`, recorded by `erasure.performed` counts `actor_labels_cleared` and `record_labels_cleared`). A person erasing themselves has their name dropped from the erasure's own events too.

**What remains after an erasure**, so the log still says what happened:

- on every event: the ids (`actor_id`, `subject_user_id`, `record_id`), `ip`, `request_id`, `reason` and `data` (snapshots of the removed rows included); free text is not scrubbed;
- on live permission rows: `created_by_id`, `updated_by_id`, `reviewed_by_id` and `sensitive_acknowledged_by_id` that name the person;
- with a tenant set: the person's assignments and memberships in other tenants (counted in `assignments_remaining_elsewhere` and `group_assignments_remaining_elsewhere`) and the labels in other tenants' events;
- the person's user record and application data in your app, unless your `on_erasure` callback deletes them;
- copies outside the table (see [What is not recorded](#what-is-not-recorded)).

**The admin's Audit log page still shows the person's name** while their user record exists. The page names people from your user table, looked up by id when it renders, not from the stored labels, so it reads "Carol Support" on her events although the labels were cleared (the CSV export and `GET /api/audit_events` show the stored, now empty, labels). Once your `on_erasure` callback deletes or anonymises the user record, the page shows the id only.

**`on_erasure:`** runs after the erasure commits. Called outside a transaction, it runs right after the erasure; an error it raises propagates (the erasure stands and is recorded) and the result's `callback_invoked` is `true`. Called inside your own transaction, it runs after your transaction commits, never if it rolls back; the result's `callback_invoked` is then `nil`, and an error it raises is reported through `Rails.error` and the log rather than raised (raising from the commit would skip other after-commit work). Events it writes keep the labels they are given.

## Protecting the table at database level

The insert-only guard is Ruby. These still reach the table from Ruby: `AuditEvent.where(...).update_all`, `.delete_all`, `AuditEvent.delete(id)` (the gem itself uses only two of these: `update_all` for the erasure scrub and `delete_all` for the purge), `insert_all`, `AuditEvent.create!` with any values (a back-dated `occurred_at`, a forged actor, an event name outside the catalogue), `touch_all`, `delete_by`, and anything that bypasses ActiveRecord. A database account with `UPDATE` or `DELETE` on the table can alter the log. The real protection is the database:

```sql
-- PostgreSQL: the application role may add and read events, and clear name labels (erasure)
REVOKE ALL ON permission_forge_audit_events FROM app_user;
GRANT SELECT, INSERT ON permission_forge_audit_events TO app_user;
GRANT UPDATE (actor_label, record_label) ON permission_forge_audit_events TO app_user;
GRANT USAGE, SELECT ON SEQUENCE permission_forge_audit_events_id_seq TO app_user;

-- a separate role for the purge: deletes, and records audit.purged in the same transaction
GRANT SELECT, INSERT, DELETE ON permission_forge_audit_events TO audit_maintenance;
GRANT USAGE, SELECT ON SEQUENCE permission_forge_audit_events_id_seq TO audit_maintenance;
```

(Use your table prefix.) These statements were checked in `psql` on PostgreSQL 17: the application role can insert and select, can null the two label columns, and gets `permission denied` on any other `UPDATE`, on `DELETE` and on `TRUNCATE`. The gem's purge and erasure have not been run end to end under such roles, so try them in staging. Consequences you need to plan for:
- **The erasure scrub needs `UPDATE (actor_label, record_label)`** (`DataSubjectErasure` runs `update_all(actor_label: nil)` and `update_all(record_label: nil)`, nothing else). With a plain `REVOKE UPDATE`, an erasure from the admin or rake fails with a permission error, and the whole erasure rolls back (the scrub is inside its transaction).
- **The purge needs `DELETE`**, and also `INSERT` and the sequence, because each batch writes `audit.purged` in the same transaction. Run it under the separate role (a second database configuration, or a job that connects with it). `delete_all` is the only deleting statement it runs on the table.
- The owner of the table and database superusers are not stopped by `REVOKE`; do not run the application as the owner. Create the table with a different role (or `ALTER TABLE … OWNER TO`).
- `REVOKE` does not remove privileges granted to `PUBLIC` or to a role `app_user` is a member of.
- The application role can still set the two label columns to any value, not only NULL, and can insert events; ids, times and `data` it cannot change. A second copy outside its reach is the protection against both.
- On MySQL the application account must not hold `UPDATE` or `DELETE` at database level (`db.*`): grants add up across levels.
- On MySQL the equivalent is `GRANT SELECT, INSERT, UPDATE (actor_label, record_label) ON db.permission_forge_audit_events TO 'app'@'%'`. PermissionForge has not been run against MySQL with these grants.
- Back up the table, and test restoring it. The gem does not.

## Forwarding to a log platform

Events in your own table are as trustworthy as your database access controls. To keep a second copy outside the application's reach:

1. Subscribe to `/\.permission_forge\z/` and send `event.payload.except(:audit_event, :objects)` to your platform (Datadog, Splunk, S3 with object lock, a syslog server). `objects` holds live objects such as the user and the record read: never serialise it. Skip names that are not audit events (`PermissionForge::Audit::EventCatalog.registered?(event.name.delete_suffix('.permission_forge'))`; `cache_failure.permission_forge` also matches the pattern). Or
2. set `audit_log_subscriber = true` and ship `Rails.logger` with the agent you already run (filter on the `[PermissionForge] audit ` prefix).

Either path forwards `data` (snapshots included) and the IP; the log subscriber leaves out the name labels, a subscriber of your own receives everything in the payload. Apply the retention and access rules of the platform to it. Forwarding is the host's job: the gem does not retry a failed delivery, it reports it (`audit_hook_failure_strategy`).

## What the host must do

The gem produces events; these remain yours:

- **Name the person.** Set `audit_actor_resolver` unless every admin really has their own login.
- **Trusted proxies** so that `ip` means the client.
- **Database privileges** as above, and not running the application as the table owner.
- **Clock synchronisation.** `occurred_at` is the application server's `Time.current`. Keep servers on NTP (or an equivalent) so that times from different hosts and from your log platform can be ordered.
- **A retention policy.** Decide how long events are kept, set `audit_retention_period`, and schedule the purge.
- **Run the purge** (and the cleaner) on a schedule, from an identified actor.
- **Alert on audit failures.** Route `Rails.error` (source `permission_forge.audit`) and the `[PermissionForge] audit … failed` log lines to your monitoring. Under `:report` / `:log`, failures of runtime-event stores and subscribers are otherwise silent.
- **Name the actor outside requests.** Wrap jobs, consoles and scripts in `PermissionForge.with_audit_actor`, otherwise their events say `unknown`.
- **Rate limiting** of failed sign-ins. Each rejected Basic or API credential writes an event; a brute-force attempt grows the table, it does not stop.
- **Who may read the log.** `audit_log_authorization` and who can reach the admin at all.
- **Review.** A log nobody reads is not a control. Use the Stale and Needs-attention cards, the "who holds what" export and `assignment.reviewed` for periodic access reviews.
- **A second copy** if your assessor needs tamper evidence beyond database privileges.
- **Other writers.** An application that changes the same tables with its own models must emit the same events or be retired.
- **Change management for configuration.** Changes to the initializer that decide access (see [What is not recorded](#what-is-not-recorded)) are not events; track initializer and deploy changes yourself.
- **Sign-ins.** Successful admin and API sign-ins and sessions are not recorded; record them in your authentication layer.
- **Your own application's records.** Audit changes to and reads of your own models where your regime requires it.
- **Copies of the log.** Erasure does not reach forwarded copies, downloaded exports or backups; apply your retention and erasure rules to them.

## Upgrading

From 0.13 to 0.14 no migration is needed. The deploy step `bin/rails permission_forge:cache:clear ACTOR=... REASON=...` is recorded as `cache.cleared` (see the [migration guide](migration-guide.md)).

From a version without the audit log (before 0.13):

```bash fragment
bin/rails generate permission_forge:upgrade --skip   # up to three migrations; reads your table prefix
bin/rails db:migrate
```

- The generator adds the migrations you do not have yet: the resource-field unique index, the admin-UI columns and the audit log. `--skip` leaves earlier migrations alone; without it an earlier `add_resource_fields_unique_index` migration that is not byte-identical stops the generator with a conflict. The unique-index migration is guarded and runs on installs that already have the index (every install from 0.11 on).
- The audit migration creates `<prefix>audit_events` with its indexes, and adds the nullable columns `permission_set_users.reviewed_at`, `reviewed_by_id`, `reason`, `permission_set_group_users.reason` and `resource_fields.sensitive_acknowledged_by_id`. Every step is guarded: running it on an install that already has them changes nothing.
- **Tenancy.** The upgrade generator takes `--tenant-column=<column>` (default: the configured tenant column, if any) for the audit table; a fresh `install` takes `--tenant=Model`. `--table-prefix` overrides the prefix for both.
- **Irreversible.** `down` raises `ActiveRecord::IrreversibleMigration`: the audit log is evidence and a rollback must not drop it. Remove the table by hand if you mean to.
- `reviewed_by_id` and `sensitive_acknowledged_by_id` take the SQL type of your existing `permission_set_users.user_id` column, and the audit table's tenant column the type of your tenant column (`bigint` when there is none to copy). A fresh `install` types them from your user and tenant models (`--user-id-type`, `--tenant-id-type`). If your `user_id` column is a `bigint` holding UUID or string keys, repair it first ([UUID or string keys](migration-guide.md#uuid-or-string-keys)).
- Existing assignments are not backfilled: `reviewed_at` is blank (never reviewed) and staleness counts from `created_at`, so rows once "kept" appear stale again.
- Until the migration has run, `audit_events = :auto` keeps everything working and unrecorded; `rake permission_forge:audit` reports `audit_table_missing` (High).

Behaviour changes are listed in the [migration guide](migration-guide.md#upgrading-to-013-the-audit-log).

## Recording your own events

Adding an event is one catalogue entry; recording it is one call.

```ruby fragment
# config/initializers/permission_forge.rb (after configure)
PermissionForge::Audit::EventCatalog.register('host.export_requested', category: 'admin')

# anywhere
PermissionForge::Audit.record('host.export_requested', data: { 'report' => 'quarterly' }, reason: 'TCK-4')
```

`record` takes `record:`, `record_label:`, `data:`, `reason:`, `actor:`, `source:`, `subject_user_id:`, `permission_set:`, `occurred_at:` and the column overrides (`Audit::Recorder::OPTIONS`); anything else raises. An access event (`category: 'access'`) needs a `runtime_group:` and is published with `Audit.instrument`. The admin reads an event with a sentence from the locale key `permission_forge.audit_log.sentences.<event>`; without one it reads "Actor: event.name". The gem's own events have a sentence in English, Albanian and Macedonian.
