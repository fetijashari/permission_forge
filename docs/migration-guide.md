# Migration Guide

## Upgrading to 0.15

1. **No generator to run from 0.14:** 0.15 adds no table and no column, and `bin/rails generate permission_forge:upgrade` is for installs older than 0.13 (its migrations — the resource-field unique index, the admin-UI columns, the audit log — are all in a 0.13 or 0.14 install). Coming from 0.13: [From 0.13](#from-013) (a revocation made on 0.15 does not reach 0.13's cache: two paths).
2. **Before the deploy, run `bin/rails permission_forge:audit`** and fix what it lists ([below](#before-the-deploy-run-the-audit)), the guarded controller actions it lists as `unmanaged_actions_refused` included: 0.15 refuses them (403) unless you set `config.unconfigured_action_strategy = :allow`.
3. **After the deploy, re-sync RLS** if you use PostgreSQL row-level security: `bin/rails permission_forge:rls:sync` ([below](#after-the-deploy-rls-postgresql)).

Then read the [behaviour changes](#behaviour-changes): each says how to opt out, or why there is no opt-out. The [CHANGELOG](../CHANGELOG.md) has every change.

### From 0.13

0.13 and 0.15 cache permissions under different keys, so during a rolling deploy a permission change made on one version does not reach what the other has cached — in both directions:

- **0.13 → 0.15:** a change made by a 0.13 process removes 0.13's own bare keys (`user_<id>`, `tenant_<t>_user_<id>`); it does not reach the entries 0.15 caches under `pf:v2:` (`Cache::UserKeys`), so a 0.15 process can serve the old permissions until `cache_ttl`.
- **0.15 → 0.13:** a change made by a 0.15 process removes the `pf:v2:` entries only — `Cache::UserKeys::PREVIOUS_ENTRY_NAMESPACES` is empty since 0.15 — so 0.13's bare keys stay, and a 0.13 process keeps serving a revoked grant until `cache_ttl`.

Take one of two paths. Either way, go through [Upgrading from 0.13 to 0.14](#upgrading-from-013-to-014) first — its stricter defaults apply to you too — then the checklist above.

1. **Through 0.14** (no window for a revocation made on the new version): deploy 0.14, including its [cache clear](#after-the-deploy-clear-the-permission-cache-once) once the last 0.13 process is gone, then deploy 0.15. 0.14 still removes 0.13's bare keys on every invalidation, so a revocation made on 0.14 reaches the 0.13 processes still running; 0.14 and 0.15 share the `pf:v2:` entries.
2. **Straight to 0.15:** deploy 0.15 and accept up to `cache_ttl` of stale grants while both versions run (lower `cache_ttl` before the deploy, or keep the rollout short, to shorten it). Once **the last 0.13 process is gone**, run `bin/rails permission_forge:cache:clear`: it ends the 0.13 → 0.15 gap (running it earlier does not help: an invalidation a 0.13 process makes afterwards misses the new entries again); the 0.15 → 0.13 gap ends with the 0.13 processes. 0.13's own entries are never read again and expire with `cache_ttl`.

```bash fragment
ACTOR="ops: deploy" REASON="deploy 0.15" bin/rails permission_forge:cache:clear
```

### Before the deploy: run the audit

Run the 0.15 security audit against your data before production runs 0.15 — from a branch with the new gem against a copy of the data, or on a staging deploy: the 0.14 audit does not know most of these findings. It changes no permission data (it records one `report.generated` event):

```bash fragment
bin/rails permission_forge:audit
```

It lists the rows 0.15 reads differently. Fix them before production sees the new behaviour:

| Finding | What 0.15 does with such a row |
|---------|--------------------------------|
| `unmanaged_actions_refused` | A controller action that maps to a Resource, in a controller that includes `ControllerActionGuard`, and that no Permission Set manages is refused with 403 (`unconfigured_action_strategy` is `:block` by default; 0.14 let it through). With tenancy, each item names the tenants that do not manage it (an action managed in one tenant is still refused in the others). Manage it in the Permission Sets that should run it, or set `config.unconfigured_action_strategy = :allow`. Read from your routes whether or not `controller_action_discovery` is on; an action a controller exempts with `skip_before_action :pf_authorize_action!, only: …` is listed although it runs, and `actions_not_checked` names what the audit could not judge (fix it, then run the audit again). A CI step running the audit with `FAIL_ON=low` fails on this finding. |
| `missing_rule_columns` | A rule naming a column, table or association path that is not there matches nothing (its holders are denied every record), and is refused when created or changed. |
| `unknown_rule_operators` | A rule with an operator or join type this version does not know matches nothing. |
| `unusable_rule_values` | A rule whose value its column cannot hold matches nothing, and a new or changed one is refused. On PostgreSQL this now includes `uuid` / `inet` / `cidr` / native enum values PostgreSQL could not read (they raised before), date or time text PostgreSQL cannot read, and every rule on a `json` / `jsonb` / array column under an operator other than `is_null` / `is_not_null`. |
| `non_text_pattern_rules` | A LIKE operator (`contains`, `starts_with`, ...) on a column no pattern can be matched against (on PostgreSQL every column that is not text; a `json` column everywhere) matches nothing, and a new or changed one is refused on `operator`. |
| `encrypted_rule_columns` | A rule comparing a value with an attribute declared with `encrypts` (its column holds ciphertext) matches nothing — also the rows `support_unencrypted_data` still holds in plaintext, which it used to match — and a new one, or a change of its column, is refused. |
| `secret_rule_columns` | A rule comparing a password digest, a token, an `encrypted_*` column or a secret keeps applying, but a new one, or a change of its column, is refused. |
| `incomplete_conditions` | An activation condition the validation refuses (a bad IP entry, one hour of the two, the same hour twice) is unjudgeable: a Muting Permission Set applies to every request, a granting set never passes. |
| `variant_rows_conflict` | An explicit field row for a variant name (`owner_uuid` next to `owner_id`) now decides that name, whichever row is older. |
| `dependency_violations` | A row that skips a required permission (edit without read, Modify All without View All), written past the validation, no longer grants the dependent permission. |
| `unknown_mask_strategies` | A field masked with a strategy this app does not know is masked fully. |

### Behaviour changes

Each with its opt-out, or why there is none. The [CHANGELOG](../CHANGELOG.md) has the full list.

1. **A mapped controller action no Permission Set manages is refused** (403, `ActionNotAuthorizedError` with reason `resource_not_managed_blocked` or `action_not_managed_blocked`): `unconfigured_action_strategy` defaults to `:block` (it was `:allow`). Only controllers that include `ControllerActionGuard` are concerned, and only actions that map to a Resource; `bin/rails permission_forge:audit` lists them (`unmanaged_actions_refused`). Every refused request stores an `action.denied` audit event (the denied group is stored by default). If you copied `config.unconfigured_action_strategy = :allow` from the 0.14 reference block of `docs/configuration.md`, remove it to get the new default. **Opt out:** `config.unconfigured_action_strategy = :allow` lets every signed-in user run them, as before (the audit reports it as `unconfigured_actions_allowed`, medium, and lists what it opens). See [`unconfigured_action_strategy`](controller-actions.md#unconfigured_action_strategy).
2. **`include_nulls` defaults to `false`** for a rule made in code, through the API and in the admin's builder (before, the column default `true` let the NULL rows of a rule created in code or through the API through). Stored rules keep their value. **Opt out:** pass `include_nulls: true` (code, API) or tick "Also show records where … is empty" in the builder, per rule. See [The `include_nulls` Flag](row-level-rules.md#the-include_nulls-flag).
3. **Rules on a column that holds a secret are refused** when created or when their column, path, join type or resource changes. **Opt out:** `config.rule_secret_column_patterns = []`, or a narrower list.
4. **A rule value its column cannot hold is refused on save** (`field_value`: "is not a value Customer.owner_id can hold"; 422 in the API). **No opt-out:** such a rule could only deny every record; stored ones keep matching nothing and are listed by `unusable_rule_values`. See [A value the column cannot hold](row-level-rules.md#a-value-the-column-cannot-hold).
5. **PostgreSQL types rule values more closely:** date or time text in another notation than ISO 8601 and column types without a caster that PostgreSQL can compare (`money`, `interval`, `macaddr`, ...) are asked of PostgreSQL once per process — what it cannot read matches nothing and is refused on save (it raised for every holder); a type it cannot compare (`xml`, `point`, `hstore`) takes no value; a LIKE operator matches text columns only; a uuid in braces, after `urn:uuid:` or without hyphens is read as the uuid it holds. **No opt-out:** such a rule never matched a row; a custom operator still gets the value as written. See [How Values Are Compared](row-level-rules.md#how-values-are-compared).
6. **A rule on a `json`, `jsonb` or array column matches nothing** under every built-in operator but `is_null` / `is_not_null`. **Opt out:** register a custom operator (`operator_registry:`), which receives the value as written.
7. **The field generator writes fewer rows.** `ResourceFieldGenerator.call(resource:)` (also the API's `generate_fields` without `grant_all`) creates the personal-data columns Hidden like the others, with their recommended mask strategy on the row (they were readable and masked), and on a Muting Permission Set writes no row at all. `grant_all: true` gives every field full access, unmasked. Rows already written are not changed. **Opt out:** add the personal-data columns Read-only in the admin (under `gdpr_defaults` they start Masked), or generate with `grant_all: true` and mask what `rake permission_forge:audit_masks` lists.
8. **Generated rows give `created_at` / `updated_at` a row** (at most read-only on a granting set); right after the upgrade the admin lists them as not configured on every existing Resource until you sync its fields. **Opt out:** `config.ignored_fields += %w[created_at updated_at]`.
9. **An explicit field row for a variant name decides that name**, and **a broken activation condition is unjudgeable** (see the table above). **No opt-out:** the explicit row is what the admin wrote; a lockdown that never locked was the defect.
10. **An unrescued denial answers 403** (`NotAuthorizedError`, `ActionNotAuthorizedError`), not 500; in production an HTML request gets an empty page until you add `public/403.html`. **Opt out:** rescue the errors yourself, or set another status in `config.action_dispatch.rescue_responses`. See [Handling Denials](row-level-rules.md#handling-denials).
11. **API answers.** A refusing `api_auth` is 401 (was 403); every 422 is `{"error": {"status": 422, "messages": {"<field>": ["…"]}}}`, keyed by the request parameter or `base`; an `expires_at` given as a date means the end of that day, and one that is not after now is a 422; unrouted paths, `OPTIONS`, `TRACE` and extensions other than `.json` answer the JSON 404 envelope; `null` for a NOT NULL attribute is a 422 keyed by it; `DELETE …/permission_sets/:uuid/users/:uuid` answers 200 with the removed assignment and `meta.cache` (was 204), `POST …/users` adds `meta.cache`. **No opt-out:** see the CHANGELOG for each answer and what a client reads instead.
12. **Permission Set names are unique within a tenant** (ignoring case and surrounding spaces) for a new set or a rename; two sets that already share a name stay valid until one is renamed. **No opt-out:** give duplicates distinct names.
13. **A filter rule compares its own table:** one qualified with another model's table (`suppliers.name` on `Customer`) matches nothing and is refused on save (it raised for every holder); `rake permission_forge:audit` lists stored ones as `foreign_table_filter_rules`. **Opt out:** use a join rule (`join_type` + `field_accessor_path`) for a column of another table. See [Using the wrong field name](row-level-rules.md#using-the-wrong-field-name).
14. **API: `allowed_ips` with no entry** (`[]`, `[""]`) is a 422; send `null` to clear the condition.
15. **New option `config.no_read_access_strategy`**: the default `:rules_only` changes nothing; under `config.preset = :strict` it is `:deny`, and a signed-in user whose Permission Sets do not grant Read on a model finds none of its records (`find_by` raises `NotAuthorizedError`, `permission_scoped` and auto-scoping are empty). The generated RLS policies follow it too — re-sync them after switching it ([below](#after-the-deploy-rls-postgresql)). **Opt out:** `config.no_read_access_strategy = :rules_only`. See [Rules only, not the CRUD flags](row-level-rules.md#rules-only-not-the-crud-flags).
16. **More boot warnings are `SECURITY warning:`** (a model loaded with another `tenant_model`, masking that could not be synced, a per-process cache or unannounced masking in production, row-level security on an adapter that is not PostgreSQL), and the production cache and masking warnings lost their `WARNING:` prefix. **No opt-out:** update a log alert that matched the old text; each warning names the setting that removes its condition.
17. **A rule on an attribute declared with `encrypts` can only ask whether it is empty.** Its column holds ciphertext, so every built-in operator that takes a value matches nothing — the plaintext rows `support_unencrypted_data` keeps included, which such a rule used to match — and a new rule, or a change of its column or of its operator off `is_null` / `is_not_null`, is refused on `field_name` (422 in the API); `encrypted_rule_columns` lists stored ones. **Opt out:** compare a deterministically encrypted attribute through a custom operator whose strategy uses `query.where(attribute => value)`. See [How Values Are Compared](row-level-rules.md#how-values-are-compared).
18. **A LIKE operator on a column that is not text is refused on `operator`**, naming the column's type (it was refused on `field_value` as "is not a value … can hold"); the audit lists stored ones as `non_text_pattern_rules` instead of `unusable_rule_values`. **No opt-out:** such a rule still matches nothing; a client that maps the 422 reads `operator`, and an alert on the audit finding's name uses the new one.
19. **Field and action rows the gem creates are labelled with their name** (`billing_email`, `export_csv`), never with English made up from it ("Billing email"); a field label an admin blanks is stored as the name. Rows already stored keep their label. **Opt out:** write a label of your own (admin or API), or translate the column in your locale files (`activerecord.attributes.<model>.<column>`).
20. **A Permission Set, a group or a rule created without a name — or renamed to a blank one — is refused, and a rule created without a blocked message stores none** — through the API (422 on `name`) and in code alike; a name of only spaces counts as none (0.14 saved one for a rule); they used to store the install migration's English column defaults ("Untitled Permission Set", "Untitled Rule", "You do not have permission to perform this action."). A rule whose stored message is that English default denies with the locale's sentence (`permission_forge.denials.rule_default`). **Opt out:** send a name, and a `failure_message` of your own. See [The name and blocked message columns](#the-name-and-blocked-message-columns).
21. **The audit log's own words are codes.** The reason the expired-assignment cleanup records (`expired`) is shown in the page's language, and an API change nobody names is stored with the actor label `api_client` (was "API client") and shown as "API client" in the page's language; the CSV export and the API return the stored values. **Opt out:** set `config.audit_actor_resolver`, so API changes name their client.
22. **API: a value of the wrong shape for its attribute is a 422 keyed by it** — a list or an object for a scalar (it was dropped: `{"is_active": [false]}` answered 200 with nothing changed), `true` or a number for text (a name became `"t"`), a word that is not a boolean (`"nope"` was `true`), a copy `name` that is not text, a `user_ids` element that is no id. A boolean takes `true`/`false`/`1`/`0` and the words `true`, `false`, `t`, `f`, `on`, `off` in any case; a rule's `field_value` takes a JSON number or boolean (stored as its text) and, under `in` / `not_in` / `between`, a list (stored joined with commas). The admin goes back with a message for a flag it cannot read. **No opt-out:** send each attribute in its shape ([Attribute shapes](admin-api.md#attribute-shapes)); a dropped or miscast value was a silent no-op or an inverted flag.
23. **The admin and API boot warnings stay in the log outside a server process.** HTTP Basic auth without credentials, a shared Basic-auth login without `audit_actor_resolver`, an API-only host missing the admin's middlewares, tenantless admin access and the API without its authorization lambdas are no longer printed by `bin/rails runner`, rake tasks, consoles or job workers (the log still has them); a server process prints them as before. Unicorn, Passenger, Falcon and Pitchfork now count as servers, so in production their processes write the warnings to the log only, as Puma's do. **No opt-out:** the log keeps every warning; see [Where warnings appear](configuration.md#where-warnings-appear).
24. **A label the gem generated is shown as no label.** A field or action row labelled with its own name, the name in English ("Created at", what the generator stored through 0.14) or "Untitled Field", and a column with no row at all, read the host's translation, else — on an English page — Rails' English for the name (`human_attribute_name`: "Created at", as before), else the name in `<code>` (`created_at` on an Albanian or Macedonian page); a label an admin wrote still wins, and the field drawer and the action form no longer pre-fill a generated one. A Permission Set, group or rule stored under the install migration's English name ("Untitled Rule") is named in the page's language, and the admin does not pre-fill it as the name. Saving a form with such a field left blank keeps the stored text (no change, no audit event); type a new label or name to replace it. **Opt out:** write a label or name of your own, or translate the column (`activerecord.attributes.<model>.<column>`). See [i18n.md](i18n.md#your-models-and-columns-in-the-admin).
25. **The rule builder's preview says what the save would say.** It runs the save's checks in memory and shows the first refusal ("Enter both ends of the range.") before the rule's sentence; the builder no longer offers a column declared with `encrypts` (only the one a stored rule names), and a stored rule on a secret column is flagged on its edit page, in the preview and on the Rules tab. The builder's checkboxes (`current_user`, `include_nulls`, `is_active`) are read as every admin flag is (`true`, `on`, `1`, ...; a value that is no boolean goes back with a message). **No opt-out:** wording and the same refusals the save already made.
26. **Dry runs say "would" and did no cache work.** `rake permission_forge:audit_events:purge DRY_RUN=1` prints "Audit events that would be deleted" (it printed "Audit events deleted"); the dry runs of `ConsentWithdrawalHandler`, `DataSubjectErasure` and `ExpiredAssignmentCleaner` answer `cache: { confirmed: nil, ..., work: false }` (the consent dry run answered `confirmed: true`; the other two had no `cache`). **No opt-out:** a script that read `cache[:confirmed]` of a dry run reads `work` instead.
27. **A Permission Set holding two Resources of one single-table-inheritance chain is named with the Resource** on the field drawer's "Across all Permission Sets" and a person's effective access ("Sales rep · VipCustomer"). **No opt-out:** wording.

### If you override the gem's locale keys

The gem's own locales are complete. Only a host whose locale files override one of these keys (all under `permission_forge.`) renames it:

| 0.14 key | 0.15 key |
|----------|----------|
| `ui.levels.*` | `ui.states.field_level.*` |
| `ui.states.granted`, `ui.states.blocked`, `ui.states.none` | `ui.states.effective.granted`, `.blocked`, `.none` |
| `people.effective_tab.hidden_by_muting` | `ui.states.effective.hidden_by_muting` |
| `audit_log.actor_types.*` | `ui.states.actor.*` |
| `ui.badges.locked` | `ui.states.lock.locked` |
| `shared.crud_cell.needs_read` | `ui.needs_read_first` |
| `settings.row.default`, `settings.row.docs` | `settings.row.default_html`, `settings.row.docs_html` |
| `permission_set_rules.builder.message_placeholder` | `permission_set_rules.builder.message_help` (a hint under the field, not a placeholder) |
| `home.index.search_placeholder` (the long sentence) | `home.index.search_placeholder` is now "Name or email"; the sentence moved to `home.index.search_help` |
| `home.conditions_card.granting`, `home.conditions_card.muting` | `ui.conditions.effect.granting`, `.muting` (Home's card and the Conditions tab's banner say the same) |

Removed without a replacement: `ui.levels.muted`, `ui.badges.not_configured`, `ui.audit.system`, `people.effective_tab.legend_muted`, `people.effective_tab.legend_none`, `shared.across_sets.muted_hidden`. See [i18n.md](i18n.md#overriding-translations).

### Removed and deprecated

Removed in 0.15:

- `PermissionForge::Engine.apply_masked_attributes_to_managed_models` — call `PermissionForge::MaskedModels.apply(only:)`.
- The 0.13 cache keys (`user_<id>`, `tenant_<t>_user_<id>`) are no longer removed by an invalidation. An app still on 0.13: [From 0.13](#from-013).

Deprecated in 0.15, removed in 0.16 (each warns through `PermissionForge.deprecator`):

- An `api_auth` that sets `@admin` on the controller to open `GET /api/stats` — set `config.api_stats_authorization`.
- The `pf_time_ago` helper — use `pf_relative`.
- `PermissionForge::Admin::SensitiveColumns` — use `PermissionForge::SensitiveColumns`.

### After the deploy: RLS (PostgreSQL)

`RlsPolicyGenerator::GENERATOR_VERSION` is 7, so `bin/rails permission_forge:rls:status` reports every table as `STALE — run permission_forge:rls:sync` (and exits 1) until you sync. The old policies stay in force until then — wider than the application layer for a set with only an end hour. Run once the new code is live:

```bash fragment
bin/rails permission_forge:rls:sync
```

See [what version 7 changes](query-scoping.md#level-3--database-postgres-row-level-security).

**Strict users (`no_read_access_strategy = :deny`, the `:strict` preset):** the policies now follow that option. Under `:deny` a session user without read access to a table's Resource chain sees no row of it in PostgreSQL either; the policies of 0.14 applied the rules alone, so they show such a user every row the rules allow until you sync. The option is part of the policy digest: whenever you switch it (or the preset), `rls:status` reports every protected table as `STALE` until you run `bin/rails permission_forge:rls:sync` again. Sync with eager loading (`config.rake_eager_load = true`), so the policy knows every STI subclass. See [Read access in a policy](query-scoping.md#read-access-in-a-policy).

### The name and blocked message columns

A 0.15 install creates the `name` columns of the Permission Set, group and rule tables and the rule's `failure_message` column without a default; a 0.14 install keeps the English defaults ('Untitled Permission Set', 'Untitled Permission Set Group', 'Untitled Rule', 'You do not have permission to perform this action.'). Nothing needs to change: the models declare no default (`attribute :name, default: nil`, `attribute :failure_message, default: nil`), so a row created through the model — code, API, admin — gets none, and the gem reads a stored install default as nothing an admin wrote (`PermissionForge::GeneratedText`). Only a row inserted with SQL, past the model, takes the column default. To align the columns anyway, a migration of your own (use your table prefix):

```ruby fragment
class DropPermissionForgeEnglishDefaults < ActiveRecord::Migration[7.1]
  def change
    change_column_default :permission_forge_permission_sets, :name, from: 'Untitled Permission Set', to: nil
    change_column_default :permission_forge_permission_set_groups, :name, from: 'Untitled Permission Set Group', to: nil
    change_column_default :permission_forge_permission_set_rules, :name, from: 'Untitled Rule', to: nil
    change_column_default :permission_forge_permission_set_rules, :failure_message,
                          from: 'You do not have permission to perform this action.', to: nil
  end
end
```

### The `include_nulls` column

A 0.15 install creates `include_nulls` with the default `false`; a 0.14 install keeps the column default `true`. Nothing needs to change: the model declares the default (`false`), so every rule created through the model — code, API, admin — gets `false`; only a row inserted with SQL, past the model, takes the column default. To align the column anyway, a migration of your own (use your table prefix):

```ruby fragment
class ChangePermissionForgeIncludeNullsDefault < ActiveRecord::Migration[7.1]
  def change
    change_column_default :permission_forge_permission_set_rules, :include_nulls, from: true, to: false
  end
end
```

## Upgrading from 0.13 to 0.14

No migration is needed: 0.14 adds no table or column. Several defaults are stricter; go through these steps before you deploy.

1. **`api_require_authorization` is now `true`.** With the API on, every change and assignment is refused (403, `api.auth_failed`) until both `config.api_action_authorization` and `config.api_assignment_authorization` are set. Set them, or opt out with `config.api_require_authorization = false` (not recommended: the boot warning and `rake permission_forge:audit` flag it). See [admin-api.md](admin-api.md#security-considerations).
2. **With `tenant_model` set, the admin and the API need a current tenant.** A request without one is refused (403, reason `tenant_missing`). Point `config.base_controller_class` and `config.api_base_controller_class` at a controller that sets the tenant (or set it in middleware), or set `config.admin_tenantless_access = :allow` to serve tenant-less requests across every tenant. See [multi-tenancy.md](multi-tenancy.md).
3. **`nested_attributes_parent_fallback` is `false`.** A `<assoc>_attributes` payload for a child model the user has no Resource entry for is now dropped by `PermitsAttributes`, instead of being filtered against the parent's fields. Add a Resource for the child model to the user's sets, or set the option to `true` (not recommended; reported by `rake permission_forge:audit`).
4. **`NotAuthorizedError#message` is always a String** (the rule failure messages joined by `', '`). Code that read the Array or Hash from `message` must use `#details`, which keeps the value the error was raised with.
5. **RLS users: re-sync the policies** with `rake permission_forge:rls:sync` (`RlsPolicyGenerator::GENERATOR_VERSION` is 5; boot warns about the drift until you do). The `view_all` bypass now requires an active resource row in the row's tenant.
6. **Consider `config.action_guard_nil_user_strategy = :deny`.** New installs get it; existing installs keep following `nil_user_strategy` (default `:bypass`, which lets a request with no user through the controller action guard).
7. **`PermissionForge::Cache::RedisCache` is removed.** It was never loaded. Use `config.cache_backend = :rails_cache` with `redis_cache_store`, or pass an `ActiveSupport::Cache::RedisCacheStore` instance.
8. **Blank names are refused** for Permission Sets, Permission Set Groups, fields and actions when they are created or renamed (422 in the API). Rows whose name is already blank stay editable in their other attributes; rename them.
9. **`user_list_resolver` is now the boundary of the people the admin and the API reach by id.** A person it leaves out is not found (404) on the person page, on assignment (also by assignment id: change of end date, Keep, Remove, Undo), erasure, group membership (also removal by membership id), and on the API's assignment and membership endpoints (`DELETE …/users/:uuid` included). Lists — a set's holders tab, `GET …/users` — still show every holder. The default resolver lists everyone, as before; if yours narrows the list (active users only, say), the people it leaves out can no longer be managed from the admin.
10. **The API's forgery check runs first.** A mutating request without a valid CSRF token reaches `api_auth` with an empty session and cookie jar. Same-origin JavaScript that calls the API with the session must send the `X-CSRF-Token` header; token or API-key clients are unaffected. See [CSRF Posture](admin-api.md#csrf-posture).
11. **Auto-applied masking reaches other processes through the cache store.** When a `Resource` row names a new model, every process masks it at its next request or job, through a token in the cache store. Use a shared store (`:rails_cache` over Redis, Memcached or Solid Cache); under `:memory` or `:null` other processes still pick the model up only at their next boot.

12. **Conditional Permission Sets are evaluated per request.** `request_context_resolver` now runs on every permission read of a user who holds a conditional set: keep it cheap, make it return `{}` where there is no request, and do not read permissions inside it (that raises `ConfigurationError`). In strict mode, conditional muting sets now apply without a request context. See [activation-conditions.md](activation-conditions.md).

### After the deploy: clear the permission cache once

0.14 keeps its entries under a new key namespace (`pf:v2:user_<id>`, `pf:v2:tenant_<t>_user_<id>`, and per-context variants). A 0.14 invalidation also removes the 0.13 keys, but a 0.13 process cannot reach a 0.14 entry: during a rolling deploy, a permission change made by a 0.13 process can stay cached in 0.14 until `cache_ttl`. Once **the last 0.13 process is gone**, run:

```bash run
ACTOR="ops: deploy" REASON="deploy 0.14" bin/rails permission_forge:cache:clear
```

- It removes every user's cached permissions in every tenant (both versions' keys and the variants). Where the store can delete by pattern (Redis, memory and file stores) it does so in one call per namespace, after checking with canary keys that the pattern reaches the store's keys; otherwise (Memcached, Solid Cache, or a pattern that did not reach the keys) it invalidates every user of the user model, per tenant when tenancy is on.
- Running it before the last 0.13 process stops does not help: an invalidation that process makes afterwards misses the new entries again.
- The cache is cold afterwards: each user rebuilds once, on their next request. Expect that load right after.
- It is recorded as `cache.cleared` (one event per tenant plus one without a tenant; see [audit-log.md](audit-log.md)).
- 0.15 no longer removes the 0.13 keys on invalidation: an app still on 0.13 follows [From 0.13](#from-013).

## Upgrading to 0.13: the audit log

Version 0.13 adds the [audit event log](audit-log.md): an `audit_events` table that is insert-only through the model (save, update and destroy raise; `update_all`, `delete_all` and `AuditEvent.delete` still work from Ruby — protect it [at database level](audit-log.md#protecting-the-table-at-database-level)), written in the transaction of every change made through the models, plus an admin page, exports and an API endpoint to read it. See [what is not recorded](audit-log.md#what-is-not-recorded).

### Steps

```bash fragment
bin/rails generate permission_forge:upgrade --skip   # reads your table prefix; add --tenant-column=<col> if your tables are tenant-scoped
bin/rails db:migrate
```

1. The generator adds the migrations you do not have yet (the resource-field unique index, the admin-UI columns, the audit log). `--skip` leaves earlier migrations alone: without it, an earlier `add_resource_fields_unique_index` migration that is not byte-identical stops the generator with a conflict. The unique-index migration is guarded, so the upgrade also runs on installs that already have that index (every install from 0.11 on).
2. The audit migration creates `audit_events` and adds `permission_set_users.reviewed_at`, `reviewed_by_id`, `reason`, `permission_set_group_users.reason` and `resource_fields.sensitive_acknowledged_by_id`. It is guarded and can be re-run. It is **irreversible**: `down` raises `ActiveRecord::IrreversibleMigration`, because the audit log is evidence.
3. A fresh `install` takes `--tenant=Model`; the upgrade takes `--tenant-column=<column>` (default: the configured tenant column).
4. `reviewed_by_id` and `sensitive_acknowledged_by_id` take the type of your existing `permission_set_users.user_id` column, and the audit table's tenant column the type of your tenant column, so UUID and string keys need no edit (repair a `bigint` `user_id` first: see [UUID or string keys](#uuid-or-string-keys)).
5. Set `config.audit_actor_resolver` so events name a person (see [Who did it](audit-log.md#who-did-it-actor-resolution)).
6. Protect the table at database level, set `audit_retention_period` and schedule the purge ([audit-log.md](audit-log.md#what-the-host-must-do)).

Until the migration has run, `audit_events = :auto` (the default) keeps everything working without recording, logs a warning at boot, and `rake permission_forge:audit` reports `audit_table_missing`. A worker started before the migration starts recording within 60 seconds of it.

### Behaviour changes

- **Every change is an event, and a change fails if its event cannot be written** (`audit_change_failure_strategy = :raise`). To keep the old behaviour of "the change always succeeds" choose `:report` or `:log`; the security audit then reports `audit_changes_unrecorded`.
- **Views and exports fail closed too.** Viewing someone's effective access, the audit tabs and the log are recorded with the same strategy; under `:raise` a view whose event cannot be written answers 500 and shows nothing.
- **`updated_by` is no longer blanked.** An edit by nobody (a console, a job), by an HTTP Basic login or by an API client used to set `updated_by_id` to `nil`; it now keeps the previous editor. `created_by_id` is stamped on create and `updated_by_id` on create and on each update, only from an actor that is a record of `audit_user_class`. "Last edited by" in the admin now comes from the latest change event (the row can pair an older editor with a newer `updated_at`).
- **Staleness is counted from the last review, not from `updated_at`.** "Keep" now sets `reviewed_at` and `reviewed_by_id`; editing an assignment no longer counts as a review. Existing rows are not backfilled, so after the upgrade every permanent assignment is stale-eligible from its grant date. `StaleAssignmentAuditor` rows gain `last_reviewed_at` and `reviewed_by_id`; `days_stale` follows the review; `last_updated` is kept.
- **`NotAuthorizedError` has readers.** `#user`, `#record` and `#record_id` (the record is `nil` when the gem raises: the denied row is not loaded). `ActionNotAuthorizedError` gains `#user` and `#record`. Existing `new(details)` calls keep working.
- **`config.audit_runtime_events` is frozen.** `config.audit_runtime_events << :bypass` raises `FrozenError`; assign a new array: `config.audit_runtime_events = %i[denied bypass]`.
- **`on_rule_bypass` and `on_field_filtered` keep their signatures but are now subscribers** of `rule.bypassed` and `field.access`. Their errors are no longer swallowed: they follow `audit_hook_failure_strategy` (default `:report`: logged and handed to `Rails.error`). Under `:raise` a hook error propagates out of the read or the query that triggered it and replaces the decision's own outcome. `on_field_filtered` is called once per field decision, in the same order with the same arguments: as the decision is made when it is the only listener and `field_read` is not stored (as before), otherwise when the read returns.
- **Cloning and group deletion.** A copy of a Permission Set or group credits the person making it (fresh uuid, `created_by` / `updated_by` reset) and is created unlocked rather than unlocked afterwards. Deleting a group detaches its sets through saves (one `permission_set.updated` each) instead of `dependent: :nullify`.
- **Association writers run callbacks.** `user.permission_sets.delete(set)`, `set.user_ids = []`, `group.permission_sets = []`, `clear` and `delete_all` without an argument on the gem's collections now remove assignments, memberships and set links record by record, each with an event and a cache invalidation (they used to be one SQL statement with neither). Passing the strategy explicitly (`delete_all(:delete_all)`) or narrowing the relation (`where(...).delete_all`) is still plain SQL and is not recorded. Destroying a user, set or group never destroys the other side.
- **Consent withdrawal is one transaction** with its revocations and its `consent.withdrawn` summary: if the summary cannot be written under `:raise`, nothing is revoked.
- **`on_field_filtered` is called for `record.attributes` with no current user**, as it already was for getters and `as_json`.
- **Field sync, Review-and-save and `generate_fields` are all-or-nothing** and share one correlation id.
- **Rake tasks** that change data take `ACTOR=` and `REASON=` (a warning is printed without `ACTOR`); report tasks record `report.generated`. New: `rake permission_forge:audit_events:purge`.
- **CSV exports of a person or Permission Set are no longer capped** at 500 rows per type.
- **`admin_assignment_authorization`** is new: `->(controller, target, user_ids, action)`. Refusals of it, and of `audit_log_authorization`, are recorded.
- **Boot warnings**: audit switched off, a shared Basic-auth login without `audit_actor_resolver`, and a missing table.

### `rake permission_forge:audit` and `FAIL_ON`

The audit gains an `audit_trail` check ([security-audit.md](security-audit.md)). A CI step that gated on a level may now fail on an upgrade:

- `FAIL_ON=high`: an app that has not run the migration (`audit_table_missing`, High), or has `audit_events = false` (`audit_off`), or holds self-granted access (`audit_self_granted`).
- `FAIL_ON=medium` or `low`: also a default install using HTTP Basic auth without `audit_actor_resolver` (`audit_shared_basic_auth`, Medium) or with the API enabled and no resolver (`audit_anonymous_api`, Medium) until you set the resolver, any app with `unknown`-actor change events in the last 30 days (`audit_unknown_actors`, Medium), and `audit_change_failure_strategy` other than `:raise` (`audit_changes_unrecorded`, Medium).
- `FAIL_ON=low`: also `audit_hook_failure_strategy = :log` (`audit_hook_failures_logged`, Low).
- The Info findings fail a build only under `FAIL_ON=info` or (up to 0.14) an unrecognised `FAIL_ON` value, which counted as `info`. From 0.15 `FAIL_ON` is read in any case and an unrecognised value exits 2.

## UUID or string keys

Columns that store one of *your* primary keys — `user_id`, the audit columns `created_by_id` / `updated_by_id`, and the tenant column added by `--tenant` — must have the type of that key. The install generator reads the key type from your user model (and tenant model) and types the columns to match:

```bash fragment
bin/rails generate permission_forge:install                       # detected from User
bin/rails generate permission_forge:install --user-id-type=uuid   # explicit: bigint, integer, uuid or string
bin/rails generate permission_forge:install --tenant=Account --tenant-id-type=uuid
```

Run the generator after your users table exists so detection can work; when it cannot read the key type it assumes `bigint` and says so.

**Why it matters.** An integer column silently truncates a UUID to its leading digits (`1aaaaaaa-…` and `1bbbbbbb-…` both become `1`), so users who share those digits would share permission sets. Versions up to 0.12.2 always created `bigint` columns. From 0.13.0 the gem refuses to work on such a schema: reading permissions or writing an assignment raises `PermissionForge::ConfigurationError` naming each column. It is raised at the point of use, not at boot, so `db:migrate` can still run to repair it.

**Repairing an affected install.** The stored ids are truncated and cannot be mapped back to users, so the assignments have to be re-created after the columns are retyped:

```ruby fragment
class RetypePermissionForgeUserKeys < ActiveRecord::Migration[7.1]
  PREFIX = 'permission_forge_'
  ASSIGNMENTS = { permission_set_users: %i[permission_set_id idx_pf_pset_users_unique],
                  permission_set_group_users: %i[permission_set_group_id idx_pf_pset_group_users_unique] }.freeze
  TABLES = %w[permission_set_groups permission_sets resources resource_fields resource_actions
              permission_set_rules permission_set_users permission_set_group_users].freeze

  def up
    ASSIGNMENTS.each do |name, (parent_key, unique_index)|
      table = :"#{PREFIX}#{name}"
      execute "DELETE FROM #{table}"
      remove_index table, name: unique_index.to_s
      remove_column table, :user_id
      add_column table, :user_id, :uuid, null: false
      add_index table, :user_id
      add_index table, [parent_key, :user_id], unique: true, name: unique_index.to_s
    end

    TABLES.each do |name|
      %i[created_by_id updated_by_id].each do |column|
        remove_column :"#{PREFIX}#{name}", column
        add_column :"#{PREFIX}#{name}", column, :uuid
      end
    end
  end
end
```

Use `:string` instead of `:uuid` for string keys, and your own prefix. If you have already run the 0.13 upgrade, retype `permission_set_users.reviewed_by_id` and `resource_fields.sensitive_acknowledged_by_id` the same way. Then assign people to their permission sets again.

## Upgrading an Existing Install to 0.10.0+

Version 0.10.0 added schema hardening that new installs now get automatically from the install migration: unique indexes on `resource_fields (resource_id, name)`, `permission_set_users (permission_set_id, user_id)`, and `permission_set_group_users (permission_set_group_id, user_id)`, plus matching model uniqueness validations.

If you installed with an earlier version, run the upgrade generator:

```bash fragment
bin/rails generate permission_forge:upgrade
```

This creates a migration that de-duplicates any existing `(resource_id, name)` collisions in `resource_fields` — keeping the most-restrictive row (masked over unmasked, then no-edit over edit) — and adds the unique index that new installs get by default. Duplicate field rows are a security issue: a duplicate with `mask_access: false` could silently unmask the field via the mask AND-merge logic.

The generator reads your app's configured `config.table_name_prefix` (the initializer is loaded by `rails generate`), so the migrations target your real tables — including unprefixed ones — without extra flags. To override, pass `--table-prefix`:

```bash fragment
bin/rails generate permission_forge:upgrade --table-prefix=""
```

> Before 0.12.1 the default was always `permission_forge_`; apps on another prefix had to pass the flag or the migration failed with `relation "permission_forge_resource_fields" does not exist`. If you generated with the wrong prefix, delete the unapplied migration files and run the generator again.

This also applies if you migrated from an embedded implementation with `--skip-migration` (below) — your legacy tables likely lack these indexes.

## Migrating from an Embedded Implementation

If you already have permission tables in your database (e.g., `permission_sets`, `resources`, etc.):

1. Install without migration:
   ```bash fragment
   rails generate permission_forge:install --skip-migration --table-prefix=""
   ```

2. Update your configuration to use empty prefix:
   ```ruby fragment
   config.table_name_prefix = ''
   ```

3. Replace concern includes:
   ```ruby fragment
   # Before
   include PermissionsGenerator
   include PermissionsHelpers

   # After
   include PermissionForge::Concerns::PermissionedUser
   ```

4. Replace model references:
   ```ruby fragment
   # Before                              # After
   Users::PermissionSet           =>     PermissionForge::PermissionSet
   Users::Resource                =>     PermissionForge::Resource
   Users::ResourceField           =>     PermissionForge::ResourceField
   Users::PermissionSetRule       =>     PermissionForge::PermissionSetRule
   Users::PermissionSetUser       =>     PermissionForge::PermissionSetUser
   Users::PermissionSetGroup      =>     PermissionForge::PermissionSetGroup
   Users::PermissionSetGroupUser  =>     PermissionForge::PermissionSetGroupUser
   ```

5. Run your test suite to verify everything works.
