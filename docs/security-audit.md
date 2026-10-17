# Security Audit for PermissionForge

## Without Claude: `rake permission_forge:audit`

The gem ships a read-only audit task. It changes no permission data (it writes one `report.generated` audit event), so it is safe to run in production:

```bash fragment
bin/rails permission_forge:audit                   # text report
FORMAT=json bin/rails permission_forge:audit       # machine-readable
FAIL_ON=high bin/rails permission_forge:audit      # exit 1 on any High or Critical finding (CI)
ACTOR="CI" REASON="release check" bin/rails permission_forge:audit   # who ran it and why, on its report.generated event

# On a Kamal deployment
kamal app exec -i "bin/rails permission_forge:audit"
```

`FAIL_ON` takes `critical`, `high`, `medium`, `low` or `info`, in any case (`FAIL_ON=HIGH` is `high`). When a finding of that severity or worse exists, the task prints `Failing: N finding(s) at or above <level>` on stderr (FORMAT=json output on stdout stays parseable) and exits 1. Any other value stops the task before the review runs, with the list of levels on stderr, and exit 2. The text report ends with "No permission data was changed", and says that the run is recorded in the audit log (`report.generated`) when the log records.

Findings are rated Critical / High / Medium / Low / Info and grouped by check:

| Check | Looks at |
|-------|----------|
| `config` | Admin UI reachable without authentication, process-local cache in production, fail-open flags (`unconfigured_field_strategy`, `masked_write_protection`, `nested_attributes_parent_fallback`, nil-user strategies), GDPR settings, `audit_trail_enabled` (created-by / updated-by stamps on the rows, not the audit event log), conditional sets without strict mode, unscoped-query detection raising in production, JSON API authorization, admin base controllers that set no tenant |
| `privilege` | View All / Modify All grants, active sets whose names look temporary (dev, debug, test…), sets that grant delete almost everywhere |
| `assignment` | Permanent access not reviewed within `admin_stale_assignment_days` (counted from the last review, else the grant), assignments for deleted or deactivated users (`user_active_check`), expired rows not cleaned up, people holding 3+ sets, turned-off sets that still have people |
| `user_model` | The user model against the nil-user strategies (see the findings below) |
| `rule` | Record rules the app's query scoping doesn't apply to every query, rules in effect whose field name is not a column of their table or whose association path cannot be joined (`missing_rule_columns` — High when people hold the set, otherwise Medium), rules in effect whose value their column cannot hold and which therefore match nothing (`unusable_rule_values` — Medium when people hold the set, otherwise Low; both list set, resource, field, operator and value), rules on a column that holds a secret (`secret_rule_columns`), rules ignored because of View All, text operators on id columns |
| `integrity` | Duplicate field rows, duplicate action rows, rows that skip a required permission (edit without read, …), resources naming models the app doesn't have, field rows naming nothing on their model |
| `conditions` | Activation conditions the validation refuses today, which nobody can judge (`incomplete_conditions`), and Resources holding a row and an explicit row for one of its variants (`variant_rows_conflict`) |
| `personal_data` | `GdprFieldAuditor` results: unmasked, virtual, cross-set and unmapped personal data (see the findings below) |
| `action` | Controller actions as permissions (see below) |
| `audit_trail` | The [audit event log](audit-log.md): is it recording, can its actors be trusted, are the failure settings strict (see below) |

The other checks report these findings (the id is the `code` of the finding; the last column is its severity). Where a finding has two severities, the higher one applies when people hold the set or the rule concerned.

Every finding that can be Medium or worse and is about a record the admin can open has a card on the admin's Home (`test/permission_forge/admin/attention_parity_test.rb` enumerates them); a finding about a setting flags its row on the Settings page.

| Check | Finding | Severity | Meaning |
|-------|---------|----------|---------|
| `config` | `admin_ui_exposed` | Critical | `http_basic_auth_enabled` is false and `base_controller_class` is `ActionController::Base`: anyone who can reach the mount path can change permissions. |
| `config` | `process_local_cache` | High | `cache_backend` is `:memory` in production: a revoked permission stays cached in other workers until the TTL ends. |
| `config` | `unconfigured_fields_pass` | High | `unconfigured_field_strategy` is `:pass_through` or `:warn`. |
| `config` | `write_protection_off` | High | `masked_write_protection` is `:off`. |
| `config` | `api_mutations_unguarded` | High | The API is on, `api_require_authorization` is set to `false` (it defaults to `true`) and `api_action_authorization` or `api_assignment_authorization` is unset: any authenticated API caller can change permissions. |
| `config` | `tenantless_admin` | High or Medium | `tenant_model` is set and `base_controller_class` (or, with the API on, `api_base_controller_class`) is still `ActionController::Base`, which sets no tenant. High with `admin_tenantless_access = :allow` (a tenant-less admin request reads and changes every tenant); Medium under the default `:deny` (every such request is refused unless middleware sets the tenant). |
| `config` | `masked_nil_user_bypass` | Medium | `masked_attributes_nil_user_strategy` is `:bypass`: with no current user a masked model's getters, `attributes` and `as_json` return the stored values, in a web request nobody is signed in to as well (each such read there is logged and published as `field.unmasked_without_user`). Recommends `:hide_in_requests` and states its trade-off: a page that reads a masked model before sign-in reads hidden values. |
| `config` | `masked_nil_user_outside_requests` | Info | `masked_attributes_nil_user_strategy` is `:hide_in_requests`: hidden in web requests with nobody signed in, but jobs, rake tasks, the runner, the console and Action Cable channel actions read the stored values. `:hide` closes that too, at the cost of hidden values in jobs and mailers. |
| `config` | `middleware_above_web_request` | Info | Under `:hide_in_requests` or `:bypass`: middlewares sit above `PermissionForge::WebRequest::Middleware` (inserted with `insert_before 0`, as rack-cors documents): a masked attribute read there is not hidden or recorded. Lists them; move one that reads masked models below it with `config.middleware.insert_after PermissionForge::WebRequest::Middleware, ...`. |
| `config` | `nested_parent_fallback` | Medium | `nested_attributes_parent_fallback` is true: a `<assoc>_attributes` payload for a model the user has no Resource entry for is filtered against the parent's fields, so a key editable on the parent admits the same key on a child the user was never granted. |
| `config` | `gdpr_defaults_off` | Medium | `gdpr_defaults` is false. |
| `config` | `audit_trail_off` | Medium | `audit_trail_enabled` is false, so records do not keep created-by / last-edited-by (not the audit event log). |
| `config` | `conditional_sets_lenient` | Medium | Active sets with activation conditions exist and `conditional_sets_strict_mode` is off: a blank request context (no resolver, or one that returns `{}`) applies every conditional set as if its conditions held. |
| `config` | `detection_raises_in_production` | Medium | `unscoped_query_detection` is `:raise` and `production` is among its environments. |
| `config` | `api_without_auth` | Medium | The API is on and `api_auth` is nil: every request gets 401. |
| `config` | `nil_user_bypass` | Low | `nil_user_strategy` or `response_filter_nil_user_strategy` is `:bypass`. |
| `config` | `strict_overrides` | Low | `config.preset` is `:strict`, but options are set looser than the preset; the finding lists each one (`:raise` for a nil-user strategy, `:null` or your own store for `cache_backend` are not looser). The report header, and `preset` in `FORMAT=json`, name the preset. |
| `config` | `log_filtering_off` | Low | `filter_parameters_integration` is false. |
| `config` | `api_sequential_ids` | Low | The API is on and `api_record_identifier` is `:id`. |
| `config` | `api_rule_values_exposed` | Low | The API is on and `api_redact_rule_field_values` is false. |
| `config` | `api_authorization_unset` | Info | The API is on and `api_auth` is set, but an authorization lambda it needs is not: `api_action_authorization` / `api_assignment_authorization` while `api_require_authorization` is `true` (the default), `api_stats_authorization` while `api_stats_require_admin` is `true` (the default). The API answers 403, naming the option, to everything that lambda guards (it fails closed); the finding lists each missing lambda and what it guards. The server's boot log says the same. |
| `privilege` | `bypass_grants` | Medium or Low | View All / Modify All grants in active granting sets. |
| `privilege` | `temporary_sets` | Medium or Low | Active sets whose names look temporary (dev, debug, test, tmp, sandbox, demo, "full access"). |
| `privilege` | `broad_delete` | Low | A set grants delete on at least 10 resources and at least 75% of its resources. |
| `assignment` | `stale_assignments` | Medium | Permanent access not reviewed within `admin_stale_assignment_days`. |
| `assignment` | `missing_users` | Medium | Assignments for user ids the user table no longer has. |
| `assignment` | `inactive_users` | Medium | `user_active_check` says the user is inactive but the assignment remains. |
| `assignment` | `expired_uncleaned` | Low | Expired assignments not cleaned up. |
| `assignment` | `many_sets` | Low | People holding 3 or more sets. |
| `assignment` | `inactive_sets_assigned` | Low | Turned-off sets that still have people. |
| `assignment` | `all_permanent` | Info | Every active assignment is permanent. |
| `user_model` | `user_model_scoped` | Low | The user model includes `PermissionScopedFindable` and `nil_user_strategy` is `:deny` or `:raise`: sign-in, session restore and password reset look the user up before anyone is signed in, and find nothing. |
| `user_model` | `user_model_unmasked_without_user` | Low | `masked_attributes_nil_user_strategy` is `:hide` or `:hide_in_requests` and a Resource row masks the user model: the user model is exempt so sign-in can read it, so with nobody signed in its columns (password digests, tokens) read as stored. Lists the Resource names. |
| `rule` | `unenforced_rules` | High or Medium | Rules the app's query scoping does not apply to every query (`auto_query_scoping` off, or join rules). |
| `rule` | `missing_rule_columns` | High or Medium | Rules in effect whose field name is not a column, table or association of theirs — a column their table does not have, a table this database does not have, a name that is not a name (an empty part, a control character), or an association path naming an association their model does not have or one no join can be built through (a typo, a renamed or dropped column or association, a polymorphic `belongs_to`): they match nothing, so everyone they apply to is denied every record of the resource. The admin's Home lists the same rules under "Rules that match nothing". |
| `rule` | `unknown_rule_operators` | High or Medium | Rules in effect with an operator or join type this version does not know (written by a newer version, another application or past the model): they match nothing. High while people hold the set. |
| `rule` | `foreign_table_filter_rules` | High or Medium | Filter rules whose field name is qualified with another model's table: a filter rule compares its own table, so they match nothing. Use a join rule. High while people hold the set. |
| `rule` | `foreign_table_names` | Info | Join rules whose field name is qualified with a table this database has that is none of the rule's: left to the database; where the query does not join that table the rule matches nothing. Name the relationship in `field_accessor_path` instead. |
| `rule` | `unusable_rule_values` | Medium or Low | Rules in effect whose value their column cannot hold (text on a number column, a word that is no boolean, an unknown enum label, a list or range with the wrong number of values): they match nothing. |
| `rule` | `encrypted_rule_columns` | High or Medium | Rules in effect that compare a value with an attribute the model declares with `encrypts` (Active Record encryption): the column holds its ciphertext, so they match nothing — only `is_null` / `is_not_null` can be asked of it. Typically a rule saved before the attribute was encrypted. High while people hold the set. Home lists the same rules under "Rules that match nothing". |
| `rule` | `non_text_pattern_rules` | Medium or Low | Rules in effect with `contains`, `not_contains`, `starts_with` or `ends_with` on a column no pattern can be matched against (on PostgreSQL every column that is not text; a `json` column everywhere): they match nothing. Reported as `unusable_rule_values` before 0.15. Home lists the same rules. |
| `rule` | `secret_rule_columns` | Medium | Record rules in effect that compare a column holding a secret (`config.rule_secret_column_patterns`, by name: password digests, tokens, `encrypted_*` columns, secrets; an attribute declared with `encrypts` is `encrypted_rule_columns`). They still apply; who can read which record tells the secret apart. The item names the rule and its column, not its value. A new rule on such a column is refused. Home lists the same rules. |
| `rule` | `bypassed_rules` | Low | Rules ignored because of View All / Modify All. |
| `rule` | `text_operator_on_ids` | Low | `contains`, `starts_with` or `ends_with` on an id column. |
| `rule` | `no_rules` | Info | No record rules are in use; when it fires, it is the only `rule` finding. Its advice follows `auto_query_scoping`: add rules, and enable the setting only while it is off. |
| `integrity` | `duplicate_fields` | High | Two field rows for one field of a resource (an unmasked duplicate unmasks the field). |
| `integrity` | `duplicate_actions` | Medium | Two action rows for one action of a resource. |
| `integrity` | `dependency_violations` | Low | Rows that skip a required permission (edit without read, delete without read, mask without read, Modify All without View All). |
| `integrity` | `unknown_models` | Low | Resources naming models the app does not have. |
| `integrity` | `unknown_mask_strategies` | High or Medium | Field rows in effect whose `mask_strategy` is none of the built-in ones nor of `config.custom_mask_strategies`: masked fully until fixed. High while people hold the set. |
| `conditions` | `incomplete_conditions` | Medium | Permission Sets whose stored activation condition the validation refuses today: an IP entry that is not an IP address or CIDR range, a list with no entry, the same start and end hour, one hour of the two, an hour outside 0–23. Nobody can judge such a condition, so a muting set applies to every request and a granting set never passes. Each item says what the set does now and how many people hold it. |
| `conditions` | `variant_rows_conflict` | Info | Resources in effect holding a row and an explicit row for one of its variants (`owner_id` → `owner_uuid`). Since 0.15 the explicit row decides that name; the item shows both levels. |
| `integrity` | `unknown_fields` | Low or Info | Field rows in effect whose name is nothing their model has — no column, attribute, alias, public method, declared or discovered virtual field, or configured variant (a typo such as `emial`). Low when a muting set holds one (it mutes nothing), otherwise Info (a granting row grants nothing on the model). Lists set, resource, field and people. Saving does not refuse such a name: a key only a serializer computes is filtered by a row of its name; declare it in `extra_fields_for_permissions` to say so. Skipped for a Resource whose model the app cannot load. |
| `personal_data` | `unmasked_personal_data` | Medium | Fields that look like personal data and are readable unmasked, minus fields marked *This is intended* in the admin privacy audit (this finding only). A field counts when its row shows it in the clear (active, read on, no mask — `ResourceField#exposes_in_clear?`); a Hidden row is never listed. Columns your `filter_parameters` name count as personal data while `filter_parameters_integration` is on. |
| `personal_data` | `implicit_virtual_personal_data` | Medium | Declared virtual fields that look like personal data, have no active field row and are granted by default (`extra_fields_default_access = :grant`). |
| `personal_data` | `cross_set_unmasking` | Medium | One set unmasks what another masks (masks combine with AND). Each item names the set that unmasks and, in parentheses, the sets that mask. |
| `personal_data` | `unmapped_personal_data` | High when `unconfigured_field_strategy` is `:pass_through` or `:warn`, otherwise Low | Model columns that look like personal data and have no active field row. |

The `action` check covers custom actions and the [controller action guard](controller-actions.md):

| Finding | Severity | Meaning |
|---------|----------|---------|
| `ungranted_actions` | Low | An action is *managed* (a row for it is in effect in some Permission Set) but no active granting set permits it, so `can?` and the guard refuse everyone. Permit it in a set, or remove its rows to stop managing it. Judged per tenant. |
| `unguarded_actions` | Medium | With `controller_action_discovery` on: an action is *managed*, but a controller action that maps to it runs in a controller that does not include `PermissionForge::Concerns::ControllerActionGuard`, or skips it for every action. Each item names the action and those `controller#action` endpoints. Through them everyone can still run the action, whatever the admin shows, unless your code checks `can?`. Reported per endpoint, so it also catches a rollout where only some controllers have the guard. |
| `invalid_action_keys` | Low | Action rows in effect whose name is not a valid action key (lowercase letters, digits and `_`, starting with a letter, at most 63 characters), such as `Export` or `archive ` with a trailing space. Such a row is not the key of the action it looks like (`Export` does not cover `export`), so that action stays unmanaged while the admin shows a row for it. The row only takes effect where your code calls `can?` with exactly that name, or where a controller action is literally called that. The admin and the JSON API refuse these names; rows written before that, by seeds or by another app can still carry them. Rename the row. |
| `unlinked_actions` | Info | With `controller_action_discovery` on: action rows whose key no controller action maps to. Expected for an action your code checks with `can?`; otherwise the key is misspelled or its route is gone. |
| `action_guard_missing` | Medium when action rows are in effect, otherwise Low | `controller_action_discovery` is on, but no listed controller includes `PermissionForge::Concerns::ControllerActionGuard`. The admin lists controller actions, yet permitting or blocking one changes nothing at runtime unless your code checks `can?`. Managed actions that map to a controller action are then also listed under `unguarded_actions`. |

The `audit_trail` check (`Services::SecurityAuditChecks::AuditTrailCheck`) reads the configuration and, where the table exists, the event log:

| Finding | Severity | Meaning |
|---------|----------|---------|
| `audit_table_missing` | High | `audit_events` is not `false`, but the table does not exist (the upgrade migration has not run): under `:auto` nothing is recorded; under `true` every permission change fails with the default `:raise` strategy (and goes through unrecorded under `:report` or `:log`). The detail prints the value as written. Not reported when the database could not be asked. |
| `audit_off` | High | `audit_events = false`: nobody can later tell who granted, changed or revoked access. |
| `audit_shared_basic_auth` | Medium | HTTP Basic auth is on (`http_basic_auth_enabled`, true by default) and `audit_actor_resolver` is not set. When `current_user_resolver` finds nobody in an admin request, the events name the shared username, not a person (when it does, they name that user). |
| `audit_anonymous_api` | Medium | The JSON API is enabled (`api_enabled`) and `audit_actor_resolver` is not set: when `current_user_resolver` finds nobody in an API request (a token or API key), events name an anonymous "API client", not the caller. |
| `audit_unknown_actors` | Medium | Change events in the last 30 days have `actor_type: unknown` (a console, job or script outside `with_audit_actor`, with no current user). Reports the count; refusals and other non-change events are not counted. |
| `audit_self_granted` | High | Assignments that are still active were granted by the person who holds them (the `assignment.granted` event names the same user as actor and subject). The title counts the people ("1 person holds …"). Lists up to 10 people; scans the newest 5,000 such events. |
| `audit_changes_unrecorded` | Medium | `audit_change_failure_strategy` is `:report` or `:log`: a change can succeed without its event. |
| `audit_hook_failures_logged` | Low | `audit_hook_failure_strategy` is `:log`: a failing subscriber or runtime-event store never reaches `Rails.error`. |
| `audit_runtime_default` | Info | Nothing but `:denied` is stored at runtime: reads of masked fields, bypasses and cache events leave no stored event. With `audit_runtime_events` empty the finding says that no runtime events are stored at all, denials included. |
| `audit_kept_forever` | Info | `audit_retention_period` is `nil`. |

**`FAIL_ON` consequences when you upgrade.** `FAIL_ON=<level>` exits 1 when a finding of that severity or worse exists.
- `FAIL_ON=high` now also fails on an app that has not run the upgrade migration (`audit_table_missing`), on `audit_off`, and on a self-granted assignment.
- `FAIL_ON=medium` or `low` now also fails on a default install that uses HTTP Basic auth without `audit_actor_resolver` (`audit_shared_basic_auth`) and on an app with the API enabled and no `audit_actor_resolver` (`audit_anonymous_api`), until you set it, and on any app that has `unknown`-actor change events in the last 30 days (`audit_unknown_actors`) and on `audit_changes_unrecorded`. `FAIL_ON=low` also fails on `audit_hook_failures_logged`.
- The two Info findings fail a build only under `FAIL_ON=info`. (Up to 0.14 a `FAIL_ON` value the task did not recognise, a typo or `HIGH` in capitals, counted as `info`; from 0.15 capitals are read as the level and anything else exits 2.) Both fire on a default install (`audit_runtime_events` is `[:denied]` and `audit_retention_period` is `nil`), so `FAIL_ON=info` always fails there until you store more groups and set a retention period.

In code: `PermissionForge::Services::SecurityAudit.call` returns a report with `#findings`, `#counts`, `#at_least(:high)` and `#to_h`. To add a check, pass `checks:` to `SecurityAudit.call`, or override `SecurityAudit.checks`.

## With Claude Code: the `/security-audit` skill

This guide explains how to use the built-in `/security-audit` Claude Code skill to review your PermissionForge configuration for security gaps and personal-data handling, with findings cross-referenced to ISO/IEC 27001:2022 Annex A controls.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- A project that uses the PermissionForge gem
- PermissionForge's `.claude/` directory present in your project (it ships with the gem)

## Quick Start

Open your terminal in your project directory and run Claude Code:

```bash fragment
claude
```

Then use the skill:

```
/security-audit full
```

That's it. Claude will scan your PermissionForge configuration and produce a structured report with findings rated by severity.

## Available Scopes

| Command | What it checks |
|---------|---------------|
| `/security-audit full` | Runs all checks below — use this for a comprehensive review |
| `/security-audit gdpr` | PII field masking, mask strategies, GDPR defaults |
| `/security-audit access-review` | Over-privileged access, ViewAll/ModifyAll usage, least-privilege |
| `/security-audit rules` | Row-level rule effectiveness, bypasses, operator misuse |
| `/security-audit api` | API auth configuration, record identifier enumeration, pagination |
| `/security-audit config` | Cache backend, current_user lambda, audit log, table prefix |

If you omit the scope, it defaults to `full`.

## What Each Scope Checks

### GDPR Audit (`gdpr`)

Focuses on data protection and field masking:

- Scans for PII fields (email, phone, SSN, address, etc.) that aren't masked
- Validates mask strategies match data types (e.g., email fields use `email` strategy)
- Checks if `config.gdpr_defaults = true`
- Finds model columns with PII that have no ResourceField row in effect (none at all, or only switched-off ones)

**When to run:** Before any GDPR compliance review, after adding new models, or when onboarding new data types.

### Access Review (`access-review`)

Focuses on least-privilege and over-assignment:

- Flags resources with `view_all` or `modify_all` enabled (these bypass all row-level rules)
- Lists resources with `delete_access: true` (should be rare)
- Finds permission sets granting full CRUD on every resource
- Identifies inactive permission sets that still have users assigned
- Highlights users with 3+ permission sets (more sets = more access due to most-permissive-wins merge)
- Detects orphaned resources (PermissionForge resource exists but model no longer includes `PermissionScopedFindable`)

**When to run:** During quarterly access reviews, after bulk user provisioning, or when restructuring permission sets.

### Rules Audit (`rules`)

Focuses on row-level rule effectiveness:

- Flags resources without `current_user` isolation rules (potential data leakage)
- Detects misused operators (e.g., `contains` on ID fields)
- Finds accidentally disabled rules (`is_active: false`)
- Checks if `ViewAll`/`ModifyAll` is silently bypassing existing rules
- Reviews `left_outer_joins` usage and `include_nulls` settings

**When to run:** After creating or modifying row-level rules, when investigating data access issues.

### API Audit (`api`)

Focuses on the Admin JSON API security:

- Checks if API is enabled without authentication
- Reviews the `api_auth` lambda for bypasses
- Flags sequential `:id` as record identifier (enumeration risk — prefer `:uuid`)
- Checks for missing pagination handler (DoS risk on large collections)
- Reviews mutation authorization — `api_action_authorization` gates create/update/destroy/clone/generate_fields and `api_assignment_authorization` gates user-assignment endpoints; `api_auth` proves identity only
- Checks that `api_require_authorization` stays `true` (the default since 0.14): a missing authorization lambda then denies (403); with `false`, any authenticated caller can self-grant permission sets

**When to run:** Before exposing the API externally, during penetration testing prep.

### Config Audit (`config`)

Focuses on initializer hardening:

- Flags `NullCache` in production (permissions rebuilt every request). The skill rates this Low to Medium by context; the rake task has no check for it (it checks only `:memory` in production, High: `process_local_cache`)
- Verifies `current_user` lambda is set correctly
- Checks if the `profile_builder` lambda exposes sensitive data in the cache
- Reviews the fail-closed settings: `unconfigured_field_strategy` (default `:block`), `nil_user_strategy`, `response_filter_nil_user_strategy`, `masked_attributes_nil_user_strategy` (default `:bypass`; `:hide_in_requests` from the generator and the strict preset), and `masked_write_protection` (default `:skip` — prevents masked values being written back over real data)
- Recommends `conditional_sets_strict_mode = true` when permission sets use activation conditions — without it (the default), an unwired `request_context_resolver` leaves IP, hours and session-flag restrictions unenforced. With it, a context without an IP or session flags (a job, the console) drops conditional granting sets and still applies conditional muting sets. Checks that the resolver is cheap, returns `{}` where there is no request, and does not read permissions: it runs on every permission read of a user with conditional sets (see [activation-conditions.md](activation-conditions.md#configuration))
- Reviews table name prefix for collision risks
- Checks the audit log: `config.audit_events` is on, the table exists, `audit_actor_resolver` names a person, `audit_change_failure_strategy` is `:raise` (the same as the `audit_trail` check of the rake task). `config.audit_trail_enabled` only keeps created-by / last-edited-by on the row

**When to run:** After initial setup, before production deployment, after upgrading PermissionForge.

## Understanding the Report

Every audit produces a structured report:

```
# PermissionForge Security Audit Report
Scope: full
Date: 2026-03-23

## Executive Summary
Critical: 1 | High: 2 | Medium: 3 | Low: 1 | Info: 2

## Findings

### [CRITICAL] The admin UI has no authentication
Risk: Anyone who can reach the mount path can change permissions
Current state: http_basic_auth_enabled = false, base_controller_class = ActionController::Base
Recommendation: Set base_controller_class to a controller that authenticates and authorizes admins, or turn HTTP Basic back on
ISO/IEC 27001:2022 Annex A: A.8.5 Secure authentication
```

### Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| **Critical** | Active security vulnerability, data exposure possible | Fix immediately |
| **High** | Significant risk that could lead to unauthorized access | Fix within current sprint |
| **Medium** | Suboptimal configuration that weakens security posture | Plan for next cycle |
| **Low** | Minor improvement opportunity | Address when convenient |
| **Info** | Observation, no action required | Informational only |

## ISO 27001 Annex A mapping

The skill's findings are cross-referenced to ISO/IEC 27001:2022 Annex A (the rake task's findings carry no control field; the 2013 numbering, such as A.9.x, was withdrawn and is not used). A cross-reference tells an assessor where to look; it does not mean the control is implemented, and PermissionForge is not assessed against the standard by anyone. For each control: what the gem evidences, and what you add.

| Annex A control | What the gem evidences | What the host must add |
|---|---|---|
| A.5.3 Segregation of duties | `audit_self_granted` finds assignments a person granted to themselves (`assignment.granted` with the same actor and subject); `admin_assignment_authorization` can refuse such grants. | Deciding which duties must be separate, and who approves a grant. |
| A.5.15 Access control | Resource CRUD permissions; changes made through the models while recording is on are events (`resource.*`, `permission_set.*`). | The access-control policy and who owns it. |
| A.5.18 Access rights | Assignments with expiry, reason, grantor and reviewer (`assignment.granted/changed/revoked/reviewed`); the stale-assignment report; `admin_assignment_authorization`; the "who holds what" export. | Provisioning and removal procedures; the review schedule. |
| A.5.28 Collection of evidence | CSV and JSON exports of the log with a metadata block (time, time zone, who exported, filters, row count); each export is itself an event (`audit.exported`). | Preserving the evidence, with its chain of custody, outside the application. |
| A.5.33 Protection of records | Events insert-only in Ruby (see A.8.15); the purge refuses to run unrecorded and keeps `audit.purged`; `audit_retention_period`. | Database privileges, backups, the retention decision. |
| A.5.34 Privacy and protection of PII | The `personal_data` check and `GdprFieldAuditor`; field masking; `DataSubjectErasure` (blanks name labels on events, ids stay). | The legal basis, the records of processing, and the copies outside the gem. |
| A.8.2 Privileged access rights | View All / Modify All and delete access are flagged (`privilege` check); granting them is an event. | Limiting who may be an administrator. |
| A.8.3 Information access restriction | Field-level read/edit and row-level rules; refusals raised by `find_by`/`find_by!` and by the controller action guard are stored by default; a `can?` that returns false in your code and rows filtered out of a query are not. (`access.denied`, `action.denied`) | Restrictions in the rest of your application. |
| A.8.5 Secure authentication | Flags an API or admin UI without authentication (`config` check); failed sign-ins at the gem's own gates (HTTP Basic, `api_auth`) are events (`admin.auth_failed`, `api.auth_failed`). | The authentication itself, MFA, rate limiting. |
| A.8.10 Information deletion | `DataSubjectErasure`, the expired-assignment cleaner and the audit purge (`erasure.performed`, `cleanup.expired_assignments`, `audit.purged`). | Deleting your application data, backups and copies already forwarded to a log platform. |
| A.8.11 Data masking | `mask_access`, `mask_strategy`: display-level masking (see the [disclaimer](gdpr_masking_disclaimer.md)). | Encryption and pseudonymisation where required. |
| A.8.15 Logging | The [audit log](audit-log.md) (insert-only in Ruby only (`update_all`, `delete_all`, `AuditEvent.delete`, `insert_all` and database access still reach it: [protect it at database level](audit-log.md#protecting-the-table-at-database-level))): actor, source, request id, IP, time, before and after; notifications and a log subscriber for forwarding. | Protecting the table (database privileges as in [Protecting the table](audit-log.md#protecting-the-table-at-database-level): INSERT/SELECT for the application, column `UPDATE (actor_label, record_label)` for erasure, `DELETE` only for the purge role), forwarding to a log platform, monitoring, alerting on audit failures (route `Rails.error` and `[PermissionForge] audit … failed` log lines to your monitoring), reviewing, trusted proxies for the IP, a retention policy. |
| A.8.16 Monitoring activities | Notifications (`"<event>.permission_forge"`) and the log subscriber that forward events; the `audit_trail` checks of `rake permission_forge:audit`. | The monitoring and alerting that consume them. |
| A.8.17 Clock synchronization | Nothing. `occurred_at` is the application server's clock. | Time synchronization of your servers. |

Before citing the log, read [What is not recorded](audit-log.md#what-is-not-recorded).

## Running Audits in CI

You can run the security audit as part of your CI pipeline using Claude Code's headless mode:

```bash fragment
claude --print "/security-audit full" > security-audit-report.md
```

This generates the report as a markdown file you can attach to pull requests or keep with your review records.

## Running Checks Without Claude

Some audit checks can be run directly in a Rails console:

```ruby run
# GDPR field audit
report = PermissionForge::Services::GdprFieldAuditor.call
report.each { |finding| puts "#{finding[:type]}: #{finding.except(:type)}" }

# Find users with 3+ permission sets
User.joins(:permission_set_users)
    .group(:id)
    .having("COUNT(*) >= 3")
    .pluck(:id, Arel.sql("COUNT(*)"))

# List all resources with delete_access
PermissionForge::Resource.where(delete_access: true).pluck(:name)

# Find inactive sets with assigned users
PermissionForge::PermissionSet
  .where(is_active: false)
  .joins(:permission_set_users)
  .distinct
  .pluck(:name)

# Check ViewAll/ModifyAll usage
PermissionForge::Resource.where(view_all: true).pluck(:name)
PermissionForge::Resource.where(modify_all: true).pluck(:name)
```

## Tips

- **Run `full` first.** Start with a full audit to get the complete picture, then drill into specific scopes for deeper analysis.
- **Audit after changes.** Run the relevant scope after modifying permission sets, adding resources, or changing the configuration.
- **Save reports.** Keep dated reports with your review records. They show what was checked and found on that day; they are not evidence of certification or compliance.
- **Combine with `/permission-forge`**. Use `/permission-forge add ModelName` to set up permissions, then `/security-audit access-review` to verify the setup follows least-privilege.
