# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). PermissionForge is pre-1.0: a minor version may change
defaults, and every such change is listed under **Changed** with its opt-out.

## [Unreleased]

## [0.15.0] - 2026-10-16

Before upgrading, run `bin/rails permission_forge:audit`: it lists the stored rows this release reads differently (rules
that match nothing, broken activation conditions, variant rows, unknown mask strategies). The
[migration guide](docs/migration-guide.md#upgrading-to-015) has the steps, the behaviour changes with their opt-outs
and the RLS re-sync.

### Added

- **`rake permission_forge:audit` reports every kind of rule that matches nothing.** `Operators::RuleProblem::KINDS`
  is the one taxonomy, and each kind lands in exactly one finding: `missing_rule_columns` ("Rules naming a column,
  table or association that does not exist": High while people hold the set, otherwise Medium; set, resource, field,
  operator, value, rule and people per item) lists a rule whose field name is not a column of its table, one whose
  name is qualified with a table this database does not have, one whose field name is not a name (a trailing or
  doubled dot), and a join rule whose `field_accessor_path` names an association its model does not have (`ownr`) or
  one no join can be built through (a polymorphic `belongs_to`, a scope that takes the record, a `:through` or
  `inverse_of` naming nothing, a class that cannot be loaded); the new `unknown_rule_operators` (High while held,
  otherwise Medium) lists rules with an operator or join type this version does not know (written by a newer version
  in a rolling deploy, by another application on the shared tables, or past the model); the new
  `foreign_table_names` (Info) lists rules qualified with a real table of another model, which are left to the
  database. Run it before upgrading.
  <!-- pin: test/permission_forge/services/security_audit_test.rb#a rule naming a column its table does not have is a high finding while people hold the set -->
  <!-- pin: test/permission_forge/services/security_audit_test.rb#a rule whose association path cannot be followed is a high finding while people hold the set -->
  <!-- pin: test/permission_forge/services/security_audit_rule_check_test.rb#each kind lands in exactly one finding -->
- **Home lists the rules that match nothing.** A "Rules that match nothing" card on the admin's Home lists every active
  rule in effect that the audit lists under `missing_rule_columns`, `unknown_rule_operators` or `unusable_rule_values`
  (`AttentionItems#broken_rules`, by `Operators::RuleProblem`) — a missing column, table or relationship, a condition
  or a way of joining this version does not know, a value the field cannot hold — with why, the name as stored
  ("Matches nothing: `stauts` is not a column of Customer"), how many people hold the set, and **Fix rule** (the
  rule's edit page; for a locked set the Locked badge and **Open rules**). The Rules tab, the rule's edit page and a
  person's effective access say the same, in every locale.
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#Home lists each rule in effect that matches nothing, with why, linking to the rule -->
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#Home, the Rules tab and the edit page say why, for every kind, in every locale -->
- **`rake permission_forge:audit` reports fields naming nothing on their model** (`integrity/unknown_fields`). A
  `ResourceField` named `zzz` (or `emial`) on a `Customer` Resource was saved — 201 through the API — and configured
  nothing, so a typo went unnoticed. The audit now lists the rows in effect whose name is none of: a column of the
  model's table (read again before it is listed), an attribute or `alias_attribute`, a declared or discovered virtual
  field, a public reader or writer, or a configured variant (`field_variant_mappings`) of one of those or of another
  row of the Resource — on the model or on a loaded single-table-inheritance subclass of it. Low when a muting set
  holds one (it mutes nothing it was meant to), otherwise Info; set, resource, field and people per row; Resources
  whose model the app cannot load are skipped. Saving still accepts such a name: `FiltersResponseAttributes` filters
  any key of a hash, so a key only a serializer computes is configured by a row of its name — declare it in
  `extra_fields_for_permissions` to say it is meant.
  <!-- pin: test/permission_forge/services/security_audit_unknown_fields_test.rb#a row naming nothing on its model still saves, and the audit lists it (info for a granting set) -->
  <!-- pin: test/permission_forge/services/security_audit_unknown_fields_test.rb#a muting set holding one makes it low: it mutes nothing -->
- **`rake permission_forge:audit` reports fields masked with a strategy this app does not know**
  (`integrity/unknown_mask_strategies`: High while people hold the set, otherwise Medium — a row written past the
  model, a blank, or a custom strategy since removed from `config.custom_mask_strategies`). Such a field is masked
  fully until the row or the configuration is fixed.
  <!-- pin: test/permission_forge/services/security_audit_integrity_check_test.rb#a field in effect with a mask strategy this app does not know is reported, high while people hold the set -->
- **`rake permission_forge:audit` reports `secret_rule_columns`** (Medium): record rules in effect that compare a
  password digest, a token, an encrypted value or a secret (`config.rule_secret_column_patterns`). The item leaves the
  rule value out.
  <!-- pin: test/permission_forge/admin/attention_parity_test.rb#secret_rule_columns: the audit's finding is on a Home card (secret_rules) -->
- **`rake permission_forge:audit` has a `conditions` check**: `incomplete_conditions` (Medium — stored activation
  conditions nobody can judge: an IP entry that is not an address, a list with no entry, the same start and end hour,
  one hour of the two, an hour outside 0–23 — with what each set does now) and `variant_rows_conflict` (Info — a row
  next to an explicit row for one of its variants; the explicit row decides).
  <!-- pin: test/permission_forge/services/security_audit_conditions_check_test.rb#incomplete_conditions lists every stored row the validation would refuse, saying what each does now -->
- **Three more Home cards for what the security audit reports**: fields masked with a strategy this app does not
  know (`unknown_mask_strategies`, with a link to the field drawer), Permission Sets whose activation conditions nobody
  can judge (`incomplete_conditions`, with a link to the Conditions tab) and record rules that compare a secret column
  (`secret_rule_columns`). Home and the audit read the same rows (`ResourceField.with_unknown_mask_strategy`,
  `PermissionSet.with_broken_conditions`, `AttentionItems#secret_rules`).
  <!-- pin: test/permission_forge/admin/attention_parity_test.rb#unknown_mask_strategies: the audit's finding is on a Home card (unknown_mask_strategies) -->
- **`config.rule_secret_column_patterns`** — the column names a record rule may not compare
  (`PermissionForge::SecretColumns`, matched against the column name in lower case; default
  `[/\Apassword_digest\z/, /_digest\z/, /token/, /\Aencrypted_/, /_secret/]`). Listed on the Settings page (Record
  rules) and in the configuration reference. See **Changed** for what it refuses.
  <!-- pin: test/permission_forge/models/permission_set_rule_secret_columns_test.rb#rule_secret_column_patterns takes a list of regular expressions -->
- **`NotAuthorizedError#failure_messages`.** The `failure_message` of each row-level rule that denied the record, as
  the admin wrote it, in rule order and without repeats (`[]` when no rule denied), so a host can render a friendly 403
  without parsing `message` (`[Forbidden by Rule: <name>] with message: <failure_message>`). Only the rules that deny
  the record on their own are named (each rule is checked against the record on the denial path, one query per rule;
  should no single rule deny — a custom operator that is not a plain filter — the cumulative attribution is kept, so a
  denial never names no rule). A rule whose `failure_message` is blank gives `permission_forge.denials.rule_default`
  in the current locale ("You do not have permission to perform this action."). `message`, `details` and the
  `access.denied` event's `messages` use the same list of rules. See
  [Handling Denials](docs/row-level-rules.md#handling-denials).
  <!-- pin: test/permission_forge/concerns/permission_scoped_findable_test.rb#NotAuthorizedError#failure_messages are the denying rules' own messages, without parsing -->
  <!-- pin: test/permission_forge/concerns/permission_scoped_findable_test.rb#a denial names only the rules that deny the record on their own, in rule order -->
  <!-- pin: test/permission_forge/concerns/permission_scoped_findable_test.rb#a denial no single rule explains falls back to the cumulative attribution, never to no rule -->
  <!-- pin: test/permission_forge/services/rule_blame_property_test.rb#a denial blames exactly the rules that exclude the record on their own, in rule order -->
- **The install generator prints the next steps.** After the files it lists `bin/rails db:migrate` (not with
  `--skip-migration`), the mount line, where the admin credentials go (`PF_ADMIN_USER` / `PF_ADMIN_PASSWORD`, or your
  own admin controller), `bin/rails permission_forge:audit` and a link to the Quick Start, plus the line that makes
  `can_*?` work: `include PermissionForge::Concerns::PermissionedUser` in your User model. `rails destroy` prints none.
  <!-- pin: test/permission_forge/generators/install_generator_next_steps_test.rb#an install prints the next steps after the files -->
  <!-- pin: test/permission_forge/generators/install_generator_next_steps_test.rb#rails destroy prints no next steps -->
- **A boot warning in development when the permission cache is per process.** Rails 8.0+ generates
  `config.cache_store = :memory_store` for development (7.1/7.2: after `bin/rails dev:cache`) and the generated
  initializer caches through `Rails.cache`, so a permission change made from a console, `bin/rails runner`, a rake
  task or `db:seed` invalidated only that process's cache: a running server kept the permissions it had cached until
  `cache_ttl` (an hour) or a restart, and the change looked lost. The development boot now says so, with the two
  remedies (`config.cache_store = :file_store, "tmp/cache/store"` in `config/environments/development.rb`, or
  `cache_backend = :null` in development), when `cache_backend` is `:memory` or the store is a `MemoryStore`; file,
  Redis, Solid Cache, Memcached and null stores are not warned about. The generated initializer's comment above
  `cache_backend` and [Cache Consistency](docs/configuration.md#cache-consistency) say so.
  <!-- pin: test/permission_forge/cache_warnings_test.rb#development with Rails.cache as a :memory_store warns, naming what happens and both remedies -->
  <!-- pin: test/permission_forge/cache_warnings_test.rb#the development warning reads right in any process, not only a server -->
  <!-- pin: test/permission_forge/cache_warnings_test.rb#development with a shared or a null store does not warn -->
- **A boot warning for an API-only application that mounts the engine** (`config.api_only = true`): it names the
  middlewares its admin screens need (`ActionDispatch::Cookies`, `ActionDispatch::Session::CookieStore`,
  `ActionDispatch::Flash`) and the lines to add — without them every admin page that renders a form is a 500; the
  JSON API works without them.
  <!-- pin: test/permission_forge/boot_checks_api_only_test.rb#the warning goes through the emitter and names the middlewares and the lines to add -->
- **One cache outcome for every operation that clears cached permissions.** `PermissionForge::Cache::Outcome`
  (`confirmed`, `process_local`, `in_request`, `unconfirmed`), measured by `Cache::Report`, is what the terminal, the
  admin flash, the API body and the summary audit event report: `PermissionCacheClearer`, `DataSubjectErasure`,
  `ExpiredAssignmentCleaner`, `ConsentWithdrawalHandler` and `BulkPermissionSetAssignment` answer it under `cache:`;
  `cache.cleared`, `erasure.performed`, `cleanup.expired_assignments` and `consent.withdrawn` record it in their data;
  the admin's flashes and `POST /api/permission_sets/:id/users/bulk` (`cache: {…}`) say when the store lives in one
  process. `process_local` is `PermissionForge.cache.process_local?` (`cache_backend = :memory`, or `Rails.cache` a
  `:memory_store`): there a clear from rake reaches the rake process only, which the terminal said and the audit log
  did not.
  <!-- pin: test/permission_forge/audit/cache_scope_events_test.rb#erasure.performed on the suite's memory store says process-local in the event and the result, in every locale -->
  <!-- pin: test/permission_forge/services/permission_cache_clearer_test.rb#every event says whether the clear reached only this process (a memory store) or a shared store -->
  <!-- pin: test/permission_forge/audit/cache_scope_events_test.rb#cleanup.expired_assignments on a shared store says process_local false and reads without a suffix -->
- **The audit log says which processes kept their cached permissions.** One suffix per locale for an event whose
  data says `process_local: true`, chosen by where the operation ran: from an admin or API request, "The cached
  permissions were cleared in this server process only (an in-memory store): the other web workers and the job
  processes kept theirs."; from a rake task, runner, console or job, "…in its own process only…: the web and job
  processes kept theirs." (`audit_log.cache_scope.server_process` / `own_process`, en/sq/mk). On a shared store the
  sentence reads as before.
  <!-- pin: test/permission_forge/html/audit_sentences_test.rb#a clear made from an admin request names the other workers, not the server itself -->
  <!-- pin: test/permission_forge/html/audit_sentences_test.rb#a cache clear that reached only its own in-memory store says so; one on a shared store reads as before -->
- **`PermissionForge::RakeOutput`: one presenter for what the rake tasks print.** `rake permission_forge:erasure`,
  `cleanup_expired_assignments`, `cache:clear` and `audit_events:purge` print one line per key of the result their
  summary event records (the cache outcome included: "Cached permissions removed", "Cache scope", "Ran in"), name
  people as the admin does (`Admin::PersonLabel`; "id 7 (not in the people list)" for someone outside
  `user_list_resolver`) instead of `User 7` / `User IDs: 1, 2`, and say "would" on a dry run; `expired_assignments`
  and `stale_assignments` name people the same way. The erasure prints how many audit-log name labels it would clear
  (dry run) or cleared, as actor and as subject, as `erasure.performed` records them;
  `Services::DataSubjectErasure` returns them (`actor_labels_to_clear` / `record_labels_to_clear` in a dry run,
  `actor_labels_cleared` / `record_labels_cleared` otherwise).
  <!-- pin: test/permission_forge/tasks/rake_output_contract_test.rb#permission_forge:erasure prints every key its summary event records, on the memory store with the process-local note -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#the erasure says how many audit-log name labels it cleared -->
  <!-- pin: test/permission_forge/services/data_subject_erasure_test.rb#a dry run counts the name labels to clear, the run returns the ones it cleared -->
- **`rake -T permission_forge` shows every description whole.** Every task's first sentence is at most 100
  characters, ends on a word (the erasure task's stopped at "(supports GDPR Art"; it now says "Article 17") and the
  description names every environment variable the task reads (`ACTOR=`, `REASON=`, `USER_ID=`, `DRY_RUN=`,
  `FAIL_ON=`, `FORMAT=`, `THRESHOLD_DAYS=`).
  <!-- pin: test/permission_forge/tasks/rake_descriptions_test.rb#permission_forge:erasure: the first sentence shows whole in rake -T -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#the erasure task description is not cut at an abbreviation -->
- **`config.api_stats_authorization`.** A lambda called with the controller that decides who may read
  `GET /api/stats` while `api_stats_require_admin` is on (the default); a truthy answer allows. It replaces an
  `api_auth` that set `@admin = true` on the controller (see Deprecated). A refusal answers 403 with a body (it had
  none) and is recorded as `api.auth_failed` with reason `stats_not_authorized`; while the lambda is unset the 403
  names it. See [Dashboard Stats](docs/admin-api.md#dashboard-stats).
  <!-- pin: test/permission_forge/api/dashboard_controller_test.rb#api_stats_authorization decides who reads the stats -->
  <!-- pin: test/permission_forge/api/dashboard_controller_test.rb#GET /api/stats with api_stats_require_admin true and no api_stats_authorization is a 403 that names it -->
- **`PermitsAttributes.call(..., report: true)` says what was dropped.** It answers a `PermitsAttributes::Result`:
  `params` (the filtered Hash, as before), `dropped` (the paths of the dropped keys, never values), `dropped?` and
  `dropped_fields` (the top-level keys), so a controller can say "Not saved: status, notes" instead of a silent
  success. The paths are collected whether or not `params.filtered` is heard; with no model (`resource: nil`) every
  key is reported as dropped. Without `report:` the return value is the Hash, unchanged. See
  [Telling the user what was not saved](docs/field-filtering.md#telling-the-user-what-was-not-saved).
  <!-- pin: test/permission_forge/services/permits_attributes_test.rb#report: true answers the same filtered hash plus the dropped paths -->
  <!-- pin: test/permission_forge/services/permits_attributes_test.rb#report: true with no model to filter for lists every key, with or without a user -->
- **Bulk assignment reports the ids it skipped.** `POST …/users/bulk` answers `skipped` next to `assigned`, `revoked`
  and `invalidated`: the requested ids that name nobody `user_list_resolver` lists (`[99]`; `[]` when none), so a typo
  in an automated list no longer goes unnoticed. An id outside the resolver and an unknown one read the same.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#POST bulk reports the ids it skipped: nobody, or outside user_list_resolver -->
- **`permission_set_group_id` takes the group's uuid.** The API answers with uuids (`api_record_identifier = :uuid`),
  but `PATCH`/`POST …/permission_sets` read `permission_set_group_id` only as a numeric id: the group's uuid was a 422.
  Under `:uuid` it now takes the uuid or the id; under `:id`, the id. The value is looked up in the current tenant
  like every identifier (see Fixed for a uuid that starts with digits).
  <!-- pin: test/permission_forge/api/record_identifier_test.rb#under :uuid permission_set_group_id takes the group uuid, or its id -->
  <!-- pin: test/permission_forge/api/record_identifier_test.rb#under :id permission_set_group_id takes the id only -->
- **API `GET /api/permission_sets/:id` answers `allowed_ip_list`** (the entries as the engine reads them) beside
  `allowed_ips`.
  <!-- pin: test/permission_forge/api/permission_set_conditions_api_test.rb#the serializer shows the entries as the engine reads them -->
- **Cross-set unmasking findings name the masking sets too.** `GdprFieldAuditor`'s `:cross_set_unmasking` finding
  gains `masked_in` (the names of the granting Permission Sets that mask the field), `rake permission_forge:audit_masks`
  prints them ("masked in Permission Set Support") and `rake permission_forge:audit` lists them in parentheses after
  the set that unmasks. The other keys are unchanged.
  <!-- pin: test/permission_forge/services/gdpr_field_auditor_test.rb#a cross-set finding names the sets that mask the field -->
  <!-- pin: test/permission_forge/services/security_audit_test.rb#cross-set unmasking names the set that unmasks and the sets that mask -->
- **`MaskValue.call!`** (strict: raises for a strategy this app does not know — the admin preview, the validation),
  **`MaskValue.known?`**, and the **`mask_strategy_unknown.permission_forge`** notification (payload `strategy`,
  `fallback`), published once per process per name together with a warning.
  <!-- pin: test/permission_forge/services/mask_value_test.rb#call reports a strategy it does not know once per process per name: a warning and a notification -->
- **`PermissionForge::ModelLookup.model_for(name)`** — the one definition of "this name is a model with a table"
  (an ActiveRecord class, not abstract, whose table exists; nil for `Kernel`, `String`, an abstract model, a model
  without its table, a constant whose file raises as it loads).
  <!-- pin: test/permission_forge/model_lookup_test.rb#anything that is not a model with a table is nil -->
- **The JSON API's `POST …/resources/:id/generate_fields` answers 422** `{ "name": ["names no model this app can
  load"] }` for a Resource named after a constant that is no model (`Kernel`), instead of a 500 or the generic
  message.
  <!-- pin: test/permission_forge/api/resources_controller_test.rb#POST generate_fields on a Resource naming no model this app can load is a 422 on name -->
- **`PermissionForge::ActivationConditions`**: the one reading of a Permission Set's `allowed_ips`
  (`#allowed_ip_list`, `#allowed_ip_ranges`, `#invalid_ip_entries`) and hour window (`#hours_window`: `set?`,
  `wraps?`, `broken?`, `include?`), with `#conditions_broken?` / `#condition_problems`; included in `PermissionSet` and
  `ConditionalSets::Member`, read by the evaluator, the admin Conditions form, the sentences, the API serializer and
  the audit.
  <!-- pin: test/permission_forge/models/permission_set_condition_rows_test.rb#hours_window: none, a window, an overnight window, and the broken shapes -->
- **`PermissionHashBuilder.granted_flags(resource)`**: the one definition of what a granting Resource row grants after
  its dependencies; **`FieldPermissionMerger.targets_of(rows, variants)`**: the one definition of which names a
  resource's rows write and in what order.
  <!-- pin: test/permission_forge/services/field_permission_merger_test.rb#targets_of lists own names first, then the variants no row of the resource names -->
- **`PermissionForge::SensitiveColumns`** — the one definition of "this column looks like personal data, with this
  mask": `config.gdpr_field_patterns` first, then the host's `filter_parameters` (strategy `full`) while
  `filter_parameters_integration` is on. `match(name)` answers a `Match` (`pattern`: the alternative that matched or
  `filter_parameters`; `strategy`; `source`). The admin's presets, Sync, Fields tab and Home, the field generator,
  `GdprFieldAuditor` and the boot warning all ask it.
  <!-- pin: test/permission_forge/sensitive_columns_test.rb#matches gdpr patterns with the alternative that matched, its strategy and the source -->
- **One row builder for generated field rows** — `ResourceFieldGenerator.build(resource:, column:, level:)` /
  `.rows(resource)` (`ResourceFieldGenerator::RowBuilder`, reading the level tables of `PermissionForge::FieldLevel`,
  moved from `Admin::FieldLevel`, which stays as an alias): the flags of the level, the privacy default (under
  `gdpr_defaults`, on a granting set, a sensitive column granted Read-only starts Masked; Editable masks nothing;
  Hidden stays Hidden), Rails' timestamps at most read-only, the recommended mask strategy on every row, the label,
  and no row for a level that is none (Unchanged on a muting set). The admin's presets and "Sync fields"
  (`Admin::ColumnFields`), the Fields tab's bulk add (`Admin::ChangeSet`) and the generator (the API's
  `generate_fields`, `Resource.grant_full_access!`, the console) write the same row for the same level.
  <!-- pin: test/support/decision_parity/fields.rb#(a) Customer, muting=false, gdpr_defaults=true, read: presets, bulk and the generator write the same rows -->
  <!-- pin: test/permission_forge/services/resource_field_generator_gdpr_test.rb#build: the privacy default masks a sensitive column granted Read-only, and only that -->
- **`ResourceField#exposes_in_clear?`** and the scope **`ResourceField.exposing_in_clear`** — the one definition of
  "readable in the clear" (active, read on, no mask) that the GDPR audit, the security audit's `personal_data`
  check, Home's privacy card and the boot warning ask.
  <!-- pin: test/permission_forge/models/resource_field_in_clear_test.rb#the predicate and the scope agree on every combination of active, read and mask -->
- **`Admin::EditableLock.locked?(record)` walks the chain and `EditableLock.permits?(record, action)` is the one
  table of what the admin may offer on a locked record** (`:edit`, `:add`, `:toggle`, `:delete` — also the container,
  a set in a locked group —, `:grant` / `:revoke` / `:change_expiry` by direction, `:duplicate` and `:review` always).
  Every view asks it (`pf_locked?`, `pf_lock_badge(record)`); `html/locked_pages_test.rb` renders every page for a
  locked set, resource, field, rule, group and Muting Permission Set and checks every enabled control against it.
  <!-- pin: test/permission_forge/html/locked_pages_test.rb#a locked Permission Set offers no change to what it holds, only duplicate, review and narrowing -->
- **`PermissionSetUser.ending_within(days)` / `#ending_soon?` / `#stale?(days)` / `.ended?(time)`** and
  **`Admin::AttentionItems.stale_days`** — the one window of "ending soon" (`ENDING_SOON_DAYS`, 7) and the one review
  threshold, read by Home, the People page, the end-date cell, the audit's `stale_assignments` and
  `StaleAssignmentAuditor`.
  <!-- pin: test/support/decision_parity/rules.rb#ending soon: the end-date cell, Home, the People filter and ending_within agree -->
- **`PermissionSet.in_hash_order`** (the order sets merge in), **`Operators::RuleColumn.names_for(model)`** (the
  columns a rule may compare), **`FiltersResponseAttributes.unconfigured_strategy`** (one lookup for the response
  filter and the attribute guard).
  <!-- pin: test/permission_forge/release_readiness/one_definition_guard_test.rb#one definition: the order sets merge in (PermissionSet.in_hash_order) -->
- **`PermissionForge::SchemaRead`, the one reader of a model's columns** (`@api private`). A read that answers "no"
  (not a column, no such table) reads the schema again once first — one metadata query, and `reset_column_information`
  only when the database's columns differ from what Rails holds; a name confirmed missing costs nothing afterwards
  until the table is read again, and a column that is there costs no query. Lists that build rows or reports, and the
  save of a rule, compare with the database (`verify: true`). `SchemaRead.rereads` counts the re-reads.
  <!-- pin: test/permission_forge/schema_freshness_test.rb#a name confirmed missing is not read again until the table is -->
- **Rule values are typed for PostgreSQL's `uuid`, `inet`, `cidr` and native enum columns, and for `json` / `jsonb`
  / array columns on every database** (`Operators::ValueCasters::PostgresqlTypes`, `ValueCasters::OPAQUE`). A `uuid`
  column takes the text of a UUID in either case and in each notation PostgreSQL reads (RFC 4122 8-4-4-4-12, in
  braces, after `urn:uuid:`, or the 32 digits without hyphens), normalised to RFC 4122 text; `inet` an IPv4 or IPv6
  address IPAddr reads, with an optional prefix length (no netmask, no zone); `cidr` the same with no bits set right
  of the prefix; a native enum (`CREATE TYPE … AS ENUM`) one of the type's labels exactly as the database has it, read
  from `pg_enum` once per process and type and read again once before a label is called missing
  (`SchemaRead.enum_label?`: a label `ALTER TYPE … ADD VALUE` added while the process runs); a model `enum` over a
  native enum column maps its label first. A `json`, `jsonb` or array column takes no value under any built-in
  operator but the null checks. `current_user` on a `uuid` column is the id where user ids are uuids. What this
  changes for existing rules is under **Changed**.
  <!-- pin: test/permission_forge/operators/value_typing_test.rb#a uuid column takes the text of a uuid, in any case and in each notation PostgreSQL reads, and nothing else -->
- **One schema per API answer.** `PermissionForge::Api::Schema` (`@api private`) declares the success envelopes
  (`single`, `collection` with `meta.pagination`, `list`), the error envelope `{error: {status, messages}}` (field →
  messages for 422, one sentence for 400, 401, 403, 404), the answers without a body, every serializer's keys and
  types, and what each endpoint answers (`Schema::ENDPOINTS`). The numeric ids of other PermissionForge records are
  marked `:foreign_identifier`; their value is unchanged.
  <!-- pin: test/permission_forge/api/envelope_schema_test.rb#every serializer's keys are its Api::Schema payload, and every payload has its serializer -->
- **Every API route, in its success and every error class, is asserted against the schema**
  (`api/envelope_schema_test.rb`, one test per verb and path, the catch-all included: 401 refused or unset, 404 API
  off or unknown record, 403 tenant, lambdas or lock, 400, 422), under the pseudo-locale `xx`.
  <!-- pin: test/permission_forge/api/envelope_schema_test.rb#every API route has an Endpoint, and every Endpoint a route -->
  <!-- pin: test/permission_forge/api/envelope_schema_test.rb#~answers the schema in its success and in every error class -->
- **The JSON samples of docs/admin-api.md are generated** by `bundle exec rake docs:api`
  (`PermissionForge::Docs::ApiSamples`) from the schema and the serializers; `docs/api_samples_test.rb` fails while
  the document is stale. The success samples show every key a permission set, a group and an audit event answer.
  <!-- pin: test/permission_forge/docs/api_samples_test.rb#the json samples of docs/admin-api.md are what the schema and the serializers render -->
- **Rule builder: the preview is the saved rule's sentence, from the server.** A new `GET …/rules/preview` renders the
  rule being built with the helper the Rules tab draws a saved rule with (`SentencesHelper#pf_rule_sentence`);
  `pf_admin.js` fetches it as the value, "the current user", the list, the range or "or empty" change, instead of
  rebuilding a value token in JavaScript (ticking "the current user" left the preview at "Only show Customers where
  Owner is …." until the rule was saved). Without JavaScript the preview changes on the builder's refresh, and the
  URL is a page of its own.
  <!-- pin: test/permission_forge/html/rule_builder_explanations_test.rb#the preview is the sentence the saved rule shows, one string from one helper -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#the rule preview names the current user once it is ticked, without a doubled period -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#pf_admin.js fetches the preview sentence as the value inputs change -->
- **`Operators::RuleProblem::REMEDIES` / `#remedy`** — what the admin changes to correct a rule that matches nothing,
  by kind (`:join`, `:path`, `:operator`, `:field`, `:value`); the taxonomy guard fails for a kind without one.
  <!-- pin: test/permission_forge/html/rule_builder_explanations_test.rb#the banner names the fix for each kind of problem, in every locale -->
  <!-- pin: test/permission_forge/operators/rule_problem_taxonomy_test.rb#every kind has a remedy, and every remedy is a kind with a fix sentence in every locale -->
- **Labels of stored names have one definition.** `Admin::FieldLabel` (a column, field or association name),
  `Admin::ModelLabel` (a model or Resource, and its plural) and `Admin::ActionLabel` (an action key) answer the host's
  own translation when it has one (`activerecord.attributes.*` / `activerecord.models.*`, through
  `human_attribute_name` / `model_name.human` with a sentinel default — Rails' humanized English fallback is not a
  translation), else the row's label, else the name verbatim, which the admin draws in `<code>`.
  `Admin::ErrorSentence` says a validation sentence from the gem's keys (`permission_forge.validations.attributes.*`,
  `full_message`), `Admin::Prefill` what a new-record form shows. Helpers `pf_field_label`, `pf_field_label_text`,
  `pf_action_label_text`; `pf_resource_label` / `pf_resource_plural` read `ModelLabel`.
  <!-- pin: test/permission_forge/admin/labels_test.rb#a field is labelled by the host translation, else the row label, else the name verbatim -->
- **`Admin::StateLabel`** (the one registry of the admin's state words and glyphs, `ui.states.<kind>.<state>`) and
  **`Admin::ActorLabel`** (how the admin names who made a change): internal.
  <!-- pin: test/permission_forge/html/state_rendering_test.rb#the Effective access legend words the states as its cells do -->
- **`PermissionForge::ParamShapes#pf_integer_param(key, default:, range:)`** — the one reader of a whole-number
  request parameter (a page, a page size, a count): the number when the value is one inside the range (digits or a
  JSON number), the default for every other shape (text, `2abc`, fractions, lists, objects, blanks, 0 and negatives
  below the range). The API's pagination reads `page` and `per_page` through it (see **Changed**).
  <!-- pin: test/permission_forge/controllers/param_shapes_test.rb#anything else is the default: 0 and negatives below the range, text, fractions, lists, objects, blanks -->
- **Every code sample in README.md and docs/ says what it is**: its fence carries `run` (a console sample the
  documentation app executes, `# => literal` asserted), `file=<path>` (a complete file written into that app) or
  `fragment`. A ruby block that rescues a denial error is held to the handler that works in a Rails 8 Turbo app.
  <!-- pin: test/permission_forge/docs/doc_blocks_test.rb#every ruby, erb and bash block in README.md and docs/ carries a marker and follows the rules -->
- **The documentation names only what exists** (`docs/references_test.rb`): links and anchors, `config.<name>`
  options, `permission_forge:<task>` names (every task documented with the environment variables it reads),
  `PermissionForge::…` constants, and the defaults a sentence states.
  <!-- pin: test/permission_forge/docs/references_test.rb#every defined rake task is documented, with the environment variables it reads -->
- **`bundle exec rake docs:configuration`** regenerates the Option reference of `docs/configuration.md` from the code
  (the Settings catalog's sections and order, `Configuration.new`'s defaults, `StrategyValues`' values; every public
  option has an entry); the suite fails while it is stale. Gem development only.
  <!-- pin: test/permission_forge/docs/configuration_reference_test.rb#the Option reference in docs/configuration.md is what the code generates -->
- **The admin's layout is measured in a browser**: `test/browser/layout_probe.js` renders every page, error state and
  flow of `test/support/preview_app.rb` at phone and desktop widths in en, sq and mk under Chrome (the `browser` CI
  job, non-required until green for a release); without a browser, `html/layout_lint_test.rb` checks placeholders,
  wide grids and scroll containers, and `html/admin_page_paths_test.rb` keeps the screen list complete (every GET
  route, every `422` render site).
  <!-- pin: test/permission_forge/html/admin_page_paths_test.rb#every GET route of the admin is reached by a screen -->
- **Scroll frames** (`pf_scroll_frame`, `.pf-scroll-x`) are regions a keyboard reaches (`tabindex="0"`, named for
  assistive technology) with shadows at the edges that show when there is more to the side.
  <!-- pin: test/permission_forge/html/layout_lint_test.rb#every wide grid is in a scroll frame that is reachable and named, on every screen -->
- **The suite proves the gem owns every key it renders.** The dummy app runs without `rails-i18n`, and
  `html/locale_leak_test.rb` renders every screen, re-rendered form, toast, CSV export and API error class under a
  pseudo-locale (`test/support/pseudo_locale.rb`): a word that is neither a translation nor host data fails.
  <!-- pin: test/permission_forge/html/locale_leak_test.rb#every screen shows only translated words and host data -->
- **Static lints for the admin's words.** `release_readiness/inflection_guard_test.rb`: no English inflection
  (`humanize`, `pluralize`, `to_sentence`, `full_messages`, `time_ago_in_words`, ...) and no Rails-core key family in
  `app/` or `lib/permission_forge/admin/`; `i18n_test.rb`: a sq/mk value identical to English needs a reason, one pair
  of quotation marks per locale, one label per state; `release_readiness/column_default_prefill_test.rb`: no form
  pre-fills a string column default; `AdminPagesTest` lints every re-rendered form as it does every screen.
  <!-- pin: test/permission_forge/release_readiness/inflection_guard_test.rb#nothing in app/ or lib/permission_forge/admin inflects English -->
  <!-- pin: test/permission_forge/release_readiness/column_default_prefill_test.rb#no new-record screen or re-rendered form pre-fills a text default -->
  <!-- pin: test/permission_forge/html/admin_pages_test.rb#markup is CSP-safe and namespaced, on every screen and every re-rendered form -->
- **Release-readiness guards.** `stored_data_fail_closed_test.rb` poisons every interpreted column of the eight models
  past validation (nothing raises or widens, the audit names the row); `one_definition_guard_test.rb` (G4) fails a
  re-derivation of a one-definition rule (`test/support/one_definition/*.rb`); `decision_parity_test.rb` (G5) checks
  that two surfaces answering one question agree; `schema_freshness_test.rb` (G6) alters a table while the suite runs;
  `services/rule_blame_property_test.rb` (G7) checks a denial's blame on generated cases; `changelog_pins_test.rb`
  ties every CHANGELOG bullet to its test.
  <!-- pin: test/permission_forge/release_readiness/stored_data_fail_closed_test.rb#PermissionSet: every interpreted column, poisoned past validation, never raises or widens -->
  <!-- pin: test/permission_forge/release_readiness/one_definition_guard_test.rb#a re-derivation is a hit (negative fixture) -->
  <!-- pin: test/permission_forge/schema_freshness_test.rb#every reader sees a column a migration added after the schema was read, without a reset -->
  <!-- pin: test/permission_forge/release_readiness/changelog_pins_test.rb#the guard reports what it should, on a fixture -->
- **Host model shapes, Rails' reader surface and hostile parameters are covered end to end.** `host_shapes_test.rb`
  runs every enforcement path on a namespaced model with a uuid primary key (`Billing::Invoice`) and one with
  `encrypts` and an `enum` (`PfEncryptedNote`); `concerns/masked_reader_surface_test.rb` calls every attribute-method
  pattern of the Rails in use on a hidden column (one that hands out the stored value must be a raw path
  `docs/masked-attributes.md` lists); `security/route_fuzz_test.rb` says what each hostile parameter must be read as
  and plays the uniqueness race; a canary watches the `default:` option of `human_attribute_name` / `ModelName#human`.
  <!-- pin: test/permission_forge/host_shapes_test.rb#Billing::Invoice: permission_scoped lists the rows the rule allows and no other -->
  <!-- pin: test/permission_forge/concerns/masked_reader_surface_test.rb#every pattern that returns the stored value of a hidden column is a documented raw path, and every documented raw path still does -->
  <!-- pin: test/permission_forge/security/route_fuzz_test.rb#~reads every shape of -->
  <!-- pin: test/permission_forge/rails_internals_canary_test.rb#human_attribute_name / ModelName#human: the default: option is answered when the host has no translation, the host's translation when it has one -->
- **`test/rls/rls_rule_parity_test.rb` has a case for every `Operators::RuleProblem` kind**: each compiles to `FALSE`,
  selects nothing in the app layer and hides every row under a real policy; the matrix covers `uuid`, `inet`, `cidr`,
  native enum, `jsonb` and `text[]` columns.
  <!-- pin: test/rls/rls_rule_parity_test.rb#every kind of rule the app layer matches nothing for has a parity case -->

### Changed

- **A rule whose field name is not a column of its model does not save.** `PermissionSetRule` adds "names
  `onwer_id`, which is not a column of Customer" on `field_name` (en, sq, mk; it names the stored value, like the path
  message) when the Resource's model loads and the name is no column of its table — along `field_accessor_path` for a
  join rule — so the JSON API answers its field-keyed 422 instead of 201, and the admin shows the message. Checked for
  a new rule and when the field name, path, join type or resource changes, so an existing row stays editable in its
  other attributes (a stored `'filter'` join type and the admin's nil are one); saving compares the table's columns
  with the database (`RuleColumn.for_rule(rule, verify: true)`, one metadata query per model along the path), so a
  column a migration just added is accepted; skipped when the model cannot be loaded, its table does not exist or the
  path cannot be followed. Copying a Permission Set (or a group) copies such a rule as it is: leaving it out would
  widen the copy. **No opt-out:** the rule could only ever raise (and now matches nothing); write it past the model if
  you must.
  <!-- pin: test/permission_forge/models/permission_set_rule_column_test.rb#a field name that is no column of the model is refused on field_name -->
  <!-- pin: test/permission_forge/api/permission_set_rules_controller_test.rb#POST create answers 422 on field_name for a column the model does not have -->
  <!-- pin: test/permission_forge/models/permission_set_rule_column_test.rb#an existing row is checked only when what it names changes -->
  <!-- pin: test/permission_forge/models/permission_set_rule_column_test.rb#a column the process confirmed missing before a migration added it is accepted at save -->
  <!-- pin: test/support/decision_parity/rules.rb#the column-typo validation message names the stored value, like the path message -->
- **A join rule whose association path cannot be joined does not save.** `PermissionSetRule` adds "names ownr, which
  is not an association of Customer" on `field_accessor_path`, or why no join can be built through it (a polymorphic
  association, a class that cannot be loaded, a scope that takes the record — also along a `:through` —, a `:through`
  / `:source` / `inverse_of` naming nothing, an empty step in `parent..owner`; en, sq, mk;
  `Operators::RuleProblem#cause` / `#key`), so the JSON API answers its field-keyed 422 instead of 201. Checked for a
  new join rule and when its path, join type or resource changes (an existing row stays editable in its other
  attributes); a filter rule's path is never checked. Every association ActiveRecord joins is accepted
  (`Operators::RulePath` asks what `Associations::JoinDependency#build` asks; a canary watches it). Copying a
  Permission Set copies such a rule as it is. **No opt-out:** the rule could only ever raise (and now matches
  nothing).
  <!-- pin: test/permission_forge/models/permission_set_rule_path_test.rb#each cause has its own message -->
  <!-- pin: test/permission_forge/api/permission_set_rules_controller_test.rb#POST create answers 422 on field_accessor_path for an association the model does not have -->
  <!-- pin: test/permission_forge/models/permission_set_rule_path_test.rb#a path ActiveRecord cannot join is refused with its cause, and one it joins is accepted -->
- **A rule qualified with a table that is not there matches nothing, and is refused for a new or changed rule.** A
  `field_name` such as `nosuch.name` or the typo `customer.name` — a table that is none of the rule's and not in the
  database — on a rule that follows no relationship used to reach SQL as written and raise
  `ActiveRecord::StatementInvalid` for every holder, on every query under `auto_query_scoping`. It now matches nothing
  (every holder is denied, as for a missing column), a new or renamed rule gets "names nosuch, which is no table of
  this database" on `field_name` (the JSON API answers 422), and the audit and Home list the stored ones. A qualifier
  naming a **real** table of another model, and any qualifier on a rule **with** a relationship path (the alias a
  self-join gives, `parents_customers.active`), are left to the database as before — `foreign_table_names` names the
  former. **No opt-out:** none of these rules worked; run `rake permission_forge:audit` before upgrading to see the
  rules concerned.
  <!-- pin: test/permission_forge/models/permission_set_rule_column_test.rb#a qualifier naming no table is refused on a rule that joins nothing, and left to the query with a path -->
- **A rule value its column cannot hold is refused on save** (`field_value`: "is not a value Customer.supplier_id can
  hold"; the JSON API answers 422), for a new rule and when its value, operator, field name, path, join type or
  resource changes — `'5_id'` on an integer column, `'maybe'` on a boolean one, `'banana'` on a `uuid` one, a
  `between` bound or a list element the column cannot hold. Such a rule matched nothing for everyone it applies to. A
  rule saved before (or written past the model) stays editable in its other attributes, still matches nothing, and is
  still listed by the audit (`unusable_rule_values`) and on Home; a copy keeps its original's value. `current_user` is
  refused only where no id could be held (a boolean, date, address, json or enum column). **No opt-out:** the rule
  could only ever deny every record to its holders; saving it hid a lock-out behind a successful save.
  <!-- pin: test/permission_forge/operators/rule_problem_taxonomy_test.rb#unusable_value: a new rule is refused with the problem's message -->
- **What a rule or field row names is checked when it changes.** `operator` and `join_type` (`PermissionSetRule`) and
  `mask_strategy` (`ResourceField`, also when `mask_access` changes) are validated for a new row and when the
  attribute changes — as `field_name` and the association path are — so a row written before the check, or past the
  model (a rolling deploy, another application on the shared tables, a custom mask strategy since removed from the
  configuration), stays editable in its other attributes and can be switched off or renamed through the admin and the
  API. It matches nothing (a rule) or masks fully (a field) until it is fixed; the audit and the admin name it.
  **No opt-out:** a loosening (such rows could not be edited at all).
  <!-- pin: test/permission_forge/operators/rule_problem_taxonomy_test.rb#unknown_operator: a row written before the check stays editable in its other attributes -->
- **A rule whose field name is not a name** (a trailing or doubled dot) is listed by the audit under
  `missing_rule_columns` (High while held) instead of `unusable_rule_values`, and on Home. **No opt-out:** a report
  classification; the rule matched nothing before and after.
  <!-- pin: test/permission_forge/services/security_audit_test.rb#rules whose value the column cannot hold are reported as matching nothing -->
- **The admin's rule builder refuses a posted condition it does not know** ("Pick a condition from the list.")
  instead of silently rewriting it to "is" (`RuleFormInput` keeps the operator as posted); a saved rule's condition is
  kept as stored on its edit page, which says the rule matches nothing. **No opt-out:** the form offers only the
  conditions it knows.
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#a posted condition that is not one is refused, never rewritten to "is" -->
  <!-- pin: test/support/decision_parity/rules.rb#the operator is kept as posted, refused when it is none (no rewrite to equal) -->
- **A new record rule on a column that holds a secret is refused.** A rule whose column (after its association path,
  qualified or not) matches `config.rule_secret_column_patterns` — `password_digest`, `*_digest`, `*token*`,
  `encrypted_*`, `*_secret*` — fails validation on create and when its column, path, join type or model changes
  (`names a column that holds a secret …`), and the admin's rule builder no longer offers such columns (except the one
  a stored rule already names). Rules stored before keep evaluating as they did and stay editable in their other
  attributes; the audit (`secret_rule_columns`) and Home list them. **Opt out:** `config.rule_secret_column_patterns =
  []` (or a narrower list).
  <!-- pin: test/permission_forge/models/permission_set_rule_secret_columns_test.rb#a new rule on a secret column is refused, with a message in every locale -->
- **`include_nulls` is off unless asked for — in code, through the JSON API and in the admin's rule builder alike.**
  The column default (`true`) made a rule created in code or through the API let the NULL rows through
  (`owner_id equal 5` also matched unassigned records) while the admin's builder started unchecked; the model now
  declares the default (`attribute :include_nulls, :boolean, default: false`; the install migration writes `false`
  too, and on an upgraded install the model's default wins over the column's). Rows already stored keep their value.
  **Opt out:** pass `include_nulls: true` (code, API) or tick "Also show records where … is empty" in the builder — per
  rule, as before.
  <!-- pin: test/support/decision_parity/rules.rb#include_nulls has one default: off in code, through the API and in the builder -->
- **The rule builder offers every column of the table along the path, `id` included** (flagged "no field row
  (ignored_fields)"), the same list the model's validation accepts (`RuleColumn.names_for`); a virtual field is never
  offered. A rule on `id` — the docs' own example — can be built and repaired in the admin again. **No opt-out:** the
  validation did not change; the admin stopped hiding columns it accepts.
  <!-- pin: test/support/decision_parity/rules.rb#the builder offers exactly the columns the model accepts, ignored_fields included and flagged -->
- **The rule builder only offers associations a join can be built through.** `Admin::ModelCatalog#associations` keeps
  the reflections `Operators::RulePath.unjoinable_cause` accepts: an association with a record-dependent scope, a
  broken `:through` / `inverse_of`, a polymorphic one or one whose class cannot be loaded is no longer listed (a path
  through it matched nothing and the model refused it on save). **No opt-out:** a rule through such an association
  could never match a record.
  <!-- pin: test/permission_forge/admin/services_test.rb#associations are the ones a join can be built through -->
- **RLS: `RlsPolicyGenerator::GENERATOR_VERSION` is 7** (5 in 0.14). A policy compiles every rule the application
  layer matches nothing for — every `Operators::RuleProblem` kind — to `FALSE`, where such rules raised during the
  sync or were skipped and left the policy wider than the application layer (a custom operator without SQL is still
  skipped and reported). It types `uuid` / `inet` / `cidr` / native enum / `json` / array values like the app layer,
  counts an assignment until its `expires_at` included (`>= now()`, as `PermissionSetUser.active_assignments`; it was
  `>`), and grants the `view_all` bypass only to a set without an activation condition as
  `PermissionSet.unconditional` reads it (`conditions_present_sql`): a set with only an end hour no longer bypasses
  the rules, and one whose condition texts are only blanks does. Existing installs see drift until they run `rake
  permission_forge:rls:sync`. **No opt-out:** a policy is never wider than the application layer; the old policies
  stay in force until the sync.
  <!-- pin: test/permission_forge/operators/rule_problem_taxonomy_test.rb#unknown_operator: a row written past the model is named, denies, is listed, compiles to FALSE -->
  <!-- pin: test/permission_forge/services/rls_policy_generator_test.rb#only unconditional sets grant the view_all bypass (consent guard) -->
- **PostgreSQL: a `uuid`, `inet`, `cidr` or native enum value the column cannot hold matches nothing** where it raised
  `ActiveRecord::StatementInvalid` for every holder (`find_by`, `permission_scoped`, every query under
  `auto_query_scoping`) — `'banana'` against a `uuid` column, an address IPAddr cannot read against an `inet` column, an
  address with host bits against a `cidr` column, a word that is not a label against a native enum column. Such a rule
  is refused on save and listed by `rake permission_forge:audit` (`unusable_rule_values`, Medium while held) and on
  Home. **No opt-out:** a value PostgreSQL cannot read never matched a row; a custom operator (an injected
  `operator_registry:`) still receives the value as written.
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#'banana' against a uuid column matches nothing, is refused on save and is listed by the audit -->
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#each of these rules is named by RuleProblem and refused on save -->
- **PostgreSQL: a rule value the gem cannot type itself is asked of PostgreSQL, once per process** (a `CAST` in a
  savepoint, `ValueCasters::PostgresqlTypes::ReadBack`): date and time text in another notation than ISO 8601
  (`today`, `31 Jan 2026`) and every column type no caster knows (`hstore`, `money`, `interval`, `macaddr`, `xml`, ...).
  What PostgreSQL reads is compared as written, as before; what it cannot read (`'banana'` for a date, `'noon'` for a
  time) now matches nothing and is refused on save — it raised for every holder of the rule, on every query, and failed
  `rake permission_forge:rls:sync`. `citext` is text. **No opt-out:** such a rule never matched anything; a custom
  operator still gets the value as written.
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#date text and types no caster knows are read back: what PostgreSQL cannot read matches nothing -->
- **PostgreSQL: a LIKE operator (`contains`, `starts_with`, ...) matches text columns only.** On an integer, decimal,
  boolean, date, `uuid`, `inet`, `cidr`, native enum, `json` or other non-text column it matches nothing and is refused
  on save — PostgreSQL has no LIKE for those, so the query raised for every holder (the RLS policy already compiled it
  to `FALSE`). MySQL and SQLite, which compare such a column's text, are unchanged. **No opt-out:** such a rule never
  matched anything.
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#LIKE matches text columns only: an integer, a date or a boolean matches nothing instead of raising -->
- **A rule on a `json`, `jsonb` or array column matches nothing under every built-in operator but `is_null` /
  `is_not_null`** — also an array or JSON literal that PostgreSQL used to compare as a whole document (`codes equal
  '{1,2}'`), and on MySQL and SQLite, where a `json` column was compared as text. **Opt out:** register a custom
  operator (`operator_registry:`), which receives the value as written.
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#a json or array column matches nothing under every built-in operator but the null checks -->
- **An explicit field row for a variant name decides that name within its Resource.** An `owner_uuid` row next to an
  `owner_id` row used to be OR-ed with the variant derived from `owner_id`, so an explicit Hidden `owner_uuid` read as
  Editable in either row order. Now the row the admin wrote wins, whichever row is older; a derived variant only fills
  a name no row of the resource has. Muting rows still mute their variants. The audit's `variant_rows_conflict` lists
  the pairs before you upgrade. **No opt-out:** the explicit row is what the admin wrote.
  <!-- pin: test/permission_forge/services/permission_hash_builder_test.rb#G5f: the owner_uuid entry is the explicit row when there is one, else the derived variant, in either order -->
- **A field variant gets a permission-hash entry only when the model has that name.** The default
  `field_variant_mappings` (`_id` → `_uuid`, `_cents` → base name) added an entry for every mapped name, so a
  `Customer` with an `owner_id` row and no `owner_uuid` column had an `owner_uuid` entry, which the admin's Effective
  access listed and counted. A variant is now added (and muted) only when the model has it: a column or `attribute`,
  an `alias_attribute`, a public reader or writer, or a declared virtual field; a model this app cannot load keeps
  every variant. The hash format is unchanged, with fewer keys:
  `permissions_hash_for(:Customer)[:fields][:owner_uuid]` is `nil` for a name the model lacks.
  `FiltersResponseAttributes` still filters such a key of a serializer's hash by the entry of its base field.
  **No opt-out:** none needed; if your code reads the entry of a computed variant, give the model the reader (or declare it
  in `extra_fields_for_permissions`).
  <!-- pin: test/permission_forge/field_variants_test.rb#the permission hash has entries for the real variants only -->
  <!-- pin: test/permission_forge/field_variants_test.rb#a response key that is a variant the model lacks follows its base field -->
  <!-- pin: test/permission_forge/admin/effective_access_test.rb#no variant field for a name the model does not have, in the engine or here -->
- **A grant counts only with the permission it depends on**, at read time as well as at save time: a field row with
  `edit_access` but no `read_access`, a Resource row with `edit_access` / `delete_access` but no `read_access` or
  `modify_all` without `view_all` (rows written past `ValidatesDependency`: SQL, an older version, another app) no
  longer grant the dependent permission, and `PermitsAttributes` keeps a key only where the field is readable and
  editable. The audit's `dependency_violations` lists such rows. **No opt-out:** the validation already forbade it.
  <!-- pin: test/permission_forge/services/permission_hash_builder_test.rb#resource flags count edit and delete only with read, Modify All only with View All -->
- **A broken activation condition is unjudgeable in every mode.** An IP entry that is not an address, a list of
  separators, one hour of the two, the same hour twice, or an hour outside 0–23 (stored past the validation) now makes
  a **muting** set apply to every request (it never applied: a lockdown written with newlines through the API muted
  nothing) and a **granting** set never pass, with or without a request context (a blank one let it grant). Called out: a granting set with **one hour of the two** used to pass (the
  hours were ignored) and now never does; a granting set with `start == end` never passed before either. IP lists
  written with newlines or spaces are now read entry by entry (they used to be one invalid entry). The audit's
  `incomplete_conditions` lists every such set — run `rake permission_forge:audit` before upgrading; the admin's
  Conditions tab and the API normalise the list on the next save. **No opt-out:** fix the condition on the set's
  Conditions tab.
  <!-- pin: test/permission_forge/conditional_sets_test.rb#a muting set with a broken condition applies in every mode; a granting one never passes -->
  <!-- pin: test/permission_forge/concerns/conditional_sets_per_context_test.rb#a granting set with a broken condition grants nothing, not even without a context -->
- **A Permission Set's activation conditions are validated on a new row or a changed condition**: an `allowed_ips`
  entry that is not an IP address or CIDR range, a window whose start equals its end, one hour of the two (en/sq/mk
  messages); the stored list is normalised to commas on save. A row stored before the check stays editable in its
  other attributes. **No opt-out:** such a condition cannot be judged (see above).
  <!-- pin: test/permission_forge/models/permission_set_condition_rows_test.rb#a legacy row with a broken list stays editable until the list changes -->
  <!-- pin: test/permission_forge/models/permission_set_condition_rows_test.rb#a new row with the same start and end hour is refused -->
- **`PermissionSet#conditional?` and the `conditional` / `unconditional` scopes agree**: a text of blanks is no
  condition (`TRIM`), one hour of the two is one. Counts on pages and in the audit may change for such rows.
  **No opt-out:** two readings of one row.
  <!-- pin: test/permission_forge/models/permission_set_condition_rows_test.rb#conditional? and the SQL scopes agree: whitespace is no condition, one hour of the two is -->
- **The admin's condition sentence names a broken hour window as one** ("between 09:00 and 09:00 (a window nobody can
  judge — fix it on the Conditions tab)") instead of calling it overnight; the Conditions form refuses a start hour
  equal to the end hour (error keyed `:hours`). **No opt-out:** wording.
  <!-- pin: test/permission_forge/models/permission_set_condition_rows_test.rb#hours_window: none, a window, an overnight window, and the broken shapes -->
- **An unrescued denial answers 403 Forbidden instead of 500.** The engine registers
  `PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError` and
  `PermissionForge::ActionNotAuthorizedError` in `config.action_dispatch.rescue_responses` as `:forbidden`, as
  ActiveRecord registers `RecordNotFound` as 404. In production Rails renders `public/403.html`, which Rails apps do
  not ship (an HTML request gets an empty 403 page until you add one; JSON gets `{"status":403,"error":"Forbidden"}`).
  Like every mapped exception, an unrescued denial is no longer reported to `Rails.error` as unhandled; it stays in
  the audit log (`access.denied`, `action.denied`). Request tests under `show_exceptions = :rescuable` get the 403
  instead of the raised error. A `rescue_from` in your controllers still decides first. **Opt out:** rescue the errors
  yourself, or set another status, e.g.
  `config.action_dispatch.rescue_responses['PermissionForge::ActionNotAuthorizedError'] = :internal_server_error`.
  <!-- pin: test/permission_forge/controllers/denial_status_test.rb#both denials are registered as 403 where ActionDispatch reads them -->
  <!-- pin: test/permission_forge/controllers/denial_status_test.rb#an unrescued row-rule denial answers 403 with an empty page, and JSON for a JSON request -->
  <!-- pin: test/permission_forge/controllers/denial_status_test.rb#a host rescue_from still decides, and reads the rule messages without parsing -->
- **Permission Set names are unique within a tenant, ignoring case and surrounding spaces.** The admin form already
  refused a second "Sales Team"; the console, seeds, services and the API created one silently, and both then showed
  as "Sales Team" in every picker. A new set or a rename to a name another set of the same tenant uses is now a
  validation error (`name_taken`). Two sets that already share a name stay valid until one of them is renamed. A
  clone without a name (`PermissionSetCloner`, the group clone, `POST …/clone`) gets a numbered copy name ("Sales
  Team (copy)", "Sales Team (copy) 2"). No migration: the check is a validation. **No opt-out:** give duplicates
  distinct names.
  <!-- pin: test/permission_forge/models/permission_set_name_uniqueness_test.rb#a second set with the same name is refused, whatever its case -->
  <!-- pin: test/permission_forge/models/permission_set_name_uniqueness_test.rb#two sets that already share a name stay valid until one is renamed -->
  <!-- pin: test/permission_forge/models/permission_set_name_uniqueness_test.rb#a clone without a name gets a numbered copy name instead of failing validation -->
- **Full access applies no personal-data masks.** `ResourceFieldGenerator.call(grant_all: true)`, and through it
  `Resource.grant_full_access!`, `Services::ResourceWithFieldsBuilder` and the admin API's `generate_fields` with
  `grant_all`, now create every field readable and editable in the clear, also the columns that match
  `gdpr_field_patterns` under `gdpr_defaults`. Before, those were created masked (a field test's Admin set read
  customer names as `G*************tion`). The recommended strategy is still stored in `mask_strategy` (with
  `mask_access: false`), so masking the field later uses it, and the fields are still flagged: `GdprFieldAuditor` and
  `rake permission_forge:audit_masks` report them as `unmasked_field`, the admin's Home lists them under "Privacy
  audit". (Without `grant_all`, see the next entry.) **Opt out:** generate without `grant_all` and open the other
  fields, or mask the reported fields afterwards (`resource.resource_fields.where(name: %w[name email]).find_each { |f|
  f.update!(mask_access: true) }`; the stored strategy applies).
  <!-- pin: test/permission_forge/services/resource_field_generator_gdpr_test.rb#grant_all true with gdpr_defaults true leaves the email field unmasked -->
  <!-- pin: test/permission_forge/models/resource_test.rb#.grant_full_access! applies no personal-data masks under gdpr_defaults -->
  <!-- pin: test/permission_forge/api/resources_controller_test.rb#POST generate_fields with grant_all applies no masks under gdpr_defaults -->
- **Generating fields without `grant_all` grants nothing — the personal-data columns included.**
  `ResourceFieldGenerator.call(resource:)`, the API's `POST …/generate_fields` without `grant_all` and the console
  used to create, under `gdpr_defaults`, the columns that look like personal data *readable and masked* while every
  other column was Hidden. They are now Hidden like the rest, with the recommended mask strategy on the row — the same
  row the admin's "Nothing" preset, "Add all new as Hidden" and bulk Hidden write. Rows already written are not
  changed. **Opt out:** to have them readable and masked, add them Read-only (the admin's Sync "Add all new as
  Read-only", bulk Read, or the field drawer: under `gdpr_defaults` a sensitive column granted Read-only starts
  Masked), or generate with `grant_all: true` and mask what the audit lists.
  <!-- pin: test/permission_forge/services/resource_field_generator_gdpr_test.rb#grant_all false with gdpr_defaults true grants nothing: the email field is Hidden, its strategy recorded -->
- **Generating fields on a Muting Permission Set writes the level chosen, and no row without `grant_all`.** Without
  `grant_all` the generator wrote, under `gdpr_defaults`, `read_access: true, mask_access: true` rows for the
  personal-data columns of a muting set — rows that *hide* those columns for the set's holders and force a mask — and
  an Unchanged row (every flag off) for every other column, where the admin's presets and bulk add write none.
  `ResourceFieldGenerator.call(resource:)` (the API's `generate_fields`, the console) now writes no row on a muting set
  (Unchanged mutes nothing, which is what no row means: `FieldLevel.row?`), and `grant_all: true` still writes the
  Hide rows. Rows already written are not changed (the audit's `dependency_violations` and Home list the privacy
  ones). **No opt-out:** a muting row written by a privacy default was a silent removal nobody chose, and the rows it
  no longer writes took nothing away.
  <!-- pin: test/support/decision_parity/fields.rb#(a) Customer, muting=true, gdpr_defaults=true, leave: presets, bulk and the generator write the same rows -->
  <!-- pin: test/permission_forge/services/resource_field_generator_test.rb#without grant_all a Muting Permission Set gets no rows at all, the timestamps included -->
- **The admin's "Full access" masks nothing.** Adding a resource with the **Full access** preset, or Sync's "Add all
  new with full access", now gives every field Editable, also the columns that look like personal data under
  `gdpr_defaults` (the field test's `Customer.name` started Masked). Those columns keep the **Sensitive** badge and
  their recommended mask strategy, and Home's Privacy audit lists them as shown unmasked, with **Fix** and **This is
  intended**. **Read-only** (preset and Sync) still starts them Masked; the muting presets are unchanged. **Opt out:**
  add the resource with **Read-only** and raise the other fields to Editable, or set the reported fields to Masked
  from the Fields tab (bulk: filter **Sensitive**, select all, Set to Masked).
  <!-- pin: test/permission_forge/html/full_access_privacy_test.rb#the Full access preset masks nothing and keeps the recommended strategy -->
  <!-- pin: test/permission_forge/html/full_access_privacy_test.rb#sync: "with full access" masks nothing, "Read-only" masks the sensitive columns -->
- **Generated rows always carry the recommended mask strategy** of a sensitive column (`email` for `email`,
  `first1_last4` for `name`), also with `gdpr_defaults` off and also on a muting set, as the admin's rows already did;
  it is used only when someone masks the field. **No opt-out:** the flags are unchanged.
  <!-- pin: test/permission_forge/services/resource_field_generator_test.rb#without grant_all gdpr_defaults records the recommended strategy and grants nothing: every row Hidden -->
- **Generated fields give `created_at` / `updated_at` a row, at most read-only.** They were in the default
  `ignored_fields`, so they got no row and, under the default `unconfigured_field_strategy = :block`, every reader saw
  `null` timestamps. `ignored_fields` no longer lists them, and every path that generates rows (the generator,
  `Resource.grant_full_access!`, the API's `generate_fields`, the admin's presets, Sync and bulk add) gives them one
  through `TimestampFields`: on a granting set, read-only unmasked for a level that grants read, hidden otherwise; on
  a muting set, the level chosen. **What an existing install sees:** right after the upgrade the admin lists
  `created_at` / `updated_at` as not configured on every resource until its fields are synced. **Opt out:**
  `config.ignored_fields += %w[created_at updated_at]`.
  <!-- pin: test/permission_forge/services/resource_field_generator_test.rb#a user granted the generated fields reads the timestamps under :block, and cannot edit them -->
  <!-- pin: test/permission_forge/admin/column_fields_test.rb#a level that grants read gives the timestamps Read-only, never Editable or Masked -->
  <!-- pin: test/permission_forge/configuration_test.rb#has default ignored_fields -->
- **The GDPR audit, the security audit and the boot warning also count the columns your `filter_parameters` name.**
  While `filter_parameters_integration` is on (the default), a column the host's `filter_parameters` name
  (`api_token`, `license_key`, …) readable in the clear is reported as `unmasked_field` / `unmasked_personal_data`
  with the suggested strategy `full`, and named by the boot warning — as the admin's presets and Sync already masked
  it on Read-only. Every path that generates rows asks the same matcher (`SensitiveColumns`), so `api_token` is no
  longer masked by the admin's Read-only preset and left as it was by `generate_fields`. **Opt out:**
  `config.filter_parameters_integration = false`, or mark the field "This is intended" in the admin's privacy audit.
  <!-- pin: test/support/decision_parity/fields.rb#(b) the GDPR audit and the boot warning name exactly the columns SensitiveColumns matches, with its strategy -->
  <!-- pin: test/support/decision_parity/fields.rb#(a) a column named only by the host filter_parameters starts Masked on every path (Read-only, gdpr_defaults) -->
- **The boot warning about unmasked personal data counts the rows that reach someone.** `unmasked_gdpr_fields` used
  to name any row with `mask_access: false` — Hidden rows, switched-off rows, rows of a muting set. It now names a
  row that is readable in the clear, in effect, in a granting set (`ResourceField.exposing_in_clear`). **No opt-out:**
  a warning about a row that shows nothing was noise.
  <!-- pin: test/support/decision_parity/fields.rb#(b) the GDPR audit and the boot warning name exactly the columns SensitiveColumns matches, with its strategy -->
- **`email_address` is detected as an email.** `DEFAULT_GDPR_FIELD_PATTERNS` adds `email_address` and
  `*_email_address` (the column Rails 8's authentication generator creates) to the email pattern, so it is recommended
  and generated with the `email` strategy (`j***@example.com`) instead of `full` (it matched `address`). Log filtering
  is unchanged. Existing field rows are never rewritten (a row generated with `full` keeps the stricter mask); `rake
  permission_forge:audit_masks` suggests `email` for an unmasked one. Apps that set `gdpr_field_patterns` to their own
  hash keep their patterns; apps that merged into `DEFAULT_GDPR_FIELD_PATTERNS` get the new alternatives. **Opt out:**
  put a pattern ahead of the defaults: `config.gdpr_field_patterns = { /\Aemail_address\z/ => 'full'
  }.merge(PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS)`.
  <!-- pin: test/permission_forge/gdpr_default_patterns_test.rb#email_address is detected as an email, everywhere the patterns are read -->
- **The admin says a privacy flag may not be personal data.** Detection is unchanged (by column name, for every
  model: `name` on a company model is still flagged). The field drawer's recommendation now reads "Matches privacy
  pattern “name”, so it may be personal data", and Home's Privacy audit says that fields are flagged by column name
  and that **This is intended** takes a field that is fine unmasked off the list. **No opt-out:** wording only.
  <!-- pin: test/permission_forge/html/full_access_privacy_test.rb#a flag may not be personal data: the card says so, and This is intended clears it -->
- **A Muting Permission Set's column with no setting is "Unchanged" in the admin.** Its Fields tab counted such
  columns under "Not configured" next to an "Unchanged 0" chip, and their level control had no segment selected,
  although "Not configured · Mutes nothing" and Unchanged are one state. The row now starts on Unchanged (saving it
  still creates no field row), the muting Fields filters drop "Not configured", and the field drawer and "Across all
  Permission Sets" say Unchanged too (`FieldLevel.unconfigured_level`). A turned-off row keeps its saved choice and
  its "Turned off · Mutes nothing" badge. Granting sets are unchanged. **No opt-out:** wording and counts only.
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#in a Muting Permission Set a column with no setting is on Unchanged, counted under Unchanged -->
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#saving a muting column left on Unchanged creates no field row -->
  <!-- pin: test/permission_forge/html/state_rendering_test.rb#a column with no setting: Not configured on a granting set, Unchanged on a muting one, alike everywhere -->
- **The admin words each state one way.** Every field level, effective outcome, CRUD cell, action state, lock and
  actor kind renders from `Admin::StateLabel` (glyph and word together). Visible differences: "Across all
  Permission Sets" shows a muting set's Hide as "⊘ Hide" (was "Muted: hidden"), its Force mask with the strategy;
  the Effective access legend reads "⊘ Blocked" and "– No", as its cells do (was "Muted" / "Not given"); the Fields
  tab's filter for Hide reads "Hide" (was "Hidden"). Locale keys moved: `ui.levels.*` → `ui.states.field_level.*`,
  `ui.states.{granted,blocked,none}` → `ui.states.effective.*`, `people.effective_tab.hidden_by_muting` →
  `ui.states.effective.hidden_by_muting`, `audit_log.actor_types.*` → `ui.states.actor.*`, `ui.badges.locked` →
  `ui.states.lock.locked`, `shared.crud_cell.needs_read` → `ui.needs_read_first`; removed `ui.levels.muted`,
  `ui.badges.not_configured`, `ui.audit.system`, `people.effective_tab.legend_muted` / `legend_none`,
  `shared.across_sets.muted_hidden` and the level keys under `resources.fields_tab.filters`. **Opt out:** a host that
  overrides one of these keys in its own locale files renames it to the new key; the gem's own locales need nothing.
  <!-- pin: test/permission_forge/i18n_test.rb#one state, one label: no English label repeats within the label namespaces -->
  <!-- pin: test/permission_forge/html/state_rendering_test.rb#a column with no setting: Not configured on a granting set, Unchanged on a muting one, alike everywhere -->
- **Settings' health summary reads Home.** While Home lists items that need attention, the summary says how many
  ("Home lists 3 items that need attention.", with a link to Home) and no longer says the settings "look good"
  ("N settings are set as recommended" instead); "look good" is said only with no risky setting and nothing on
  Home — it said "7 settings look good" while Home warned that automatic query scoping leaves record rules to
  `find_by` / `permission_scoped`, which Settings now flags too. `unconfigured_field_strategy = :warn` is now a
  flagged row, as `:pass_through` was (it lets an unconfigured field through too). **No opt-out:** wording and a flag;
  nothing is enforced differently.
  <!-- pin: test/permission_forge/html/labels_and_attention_admin_test.rb#Settings never says the settings look good while Home lists items that need attention -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#Settings warns about automatic query scoping while Home lists rules it leaves out -->
- **A host model, column, association or action without a translation is named as stored, never inflected into
  English.** "Full address", "Created at", "Customers", "Archive" and "Supplier" on a Macedonian or Albanian page read
  `full_address`, `created_at`, "Customer records" (`permission_forge.ui.resource_plural`), `archive`, `supplier` — in
  English too, in every admin screen and in `Admin::ModelCatalog`'s labels (the rule builder, Sync, "Add resource").
  `ResourceAction#display_name` without a label is the key. **Opt out:** translate your models and columns
  (`activerecord.models.<model>` with `one`/`other`, `activerecord.attributes.<model>.<name>`,
  [docs/i18n.md](docs/i18n.md#your-models-and-columns-in-the-admin)) or give the row a label; there is no switch back
  to `humanize`, which is English whatever the locale.
  <!-- pin: test/permission_forge/admin/labels_test.rb#a model is labelled by the Resource row, else the host translation, else the constant name; the plural likewise -->
  <!-- pin: test/permission_forge/admin/services_test.rb#labels are the host translation, else the stored name verbatim -->
- **Every validation message of the gem's models is the gem's own, in the request's locale.** Rails' default messages
  (`uniqueness`, `length`, `numericality`, `presence`, `ValidatesDependency`, `HasUuid`) and the messages that were
  translated once at class load read from `permission_forge.validations.*` at validation time: `blank`, `taken`,
  `too_long`, `requires`, `permission_set.hours_range` ("must be between 0 and 23"), `resource.name_taken`,
  `permission_set_user.taken` ("already holds this Permission Set"), `permission_set_group_user.taken` ("is already a
  member of this group"). The English wording changes for the two assignment uniqueness messages (was "has already
  been taken") and the hours range (was "must be in 0..23"). The audit log's refused filters (`Audit::EventQuery`) say
  `validations.blank` / `validations.invalid`. **No opt-out:** these replace Rails-core keys that are English, or
  "Translation missing", in every host without rails-i18n.
  <!-- pin: test/permission_forge/html/locale_leak_test.rb#every API error class answers in the request language -->
- **A validation sentence in the admin names the attribute with the gem's label.** The uniqueness race flash and
  `Admin::ChangeSet::Invalid` say "Person already holds this Permission Set" (`Admin::ErrorSentence`), not Rails'
  `full_messages` ("User has already been taken"). **No opt-out:** `full_messages` is English without rails-i18n.
  <!-- pin: test/permission_forge/unique_conflict_test.rb#the real error of each indexed table is answered with the message its validation gives -->
- **The rule builder starts a new rule's name and blocked message blank** instead of the install migration's English
  column defaults, which admins of an Albanian or Macedonian admin saved for their end users; a rule left without a
  blocked message denies with `permission_forge.denials.rule_default` in the current locale (see
  `NotAuthorizedError#failure_messages` under Added). **Opt out:** write a `failure_message` on the rule; the stored
  English default of rules created before 0.15 stays until edited (docs/i18n.md
  [Column Defaults Are English](docs/i18n.md#column-defaults-are-english) has the one-liner that blanks them).
  <!-- pin: test/permission_forge/release_readiness/column_default_prefill_test.rb#no new-record screen or re-rendered form pre-fills a text default -->
  <!-- pin: test/permission_forge/concerns/permission_scoped_findable_test.rb#NotAuthorizedError#failure_messages are the denying rules' own messages, without parsing -->
- **`pf_user_option_label`** (the group "Add member" select) is `Admin::PersonLabel`'s answer: a formatter that
  returns blank falls through to the name as everywhere else in the admin (was "User #id"); the default
  `profile_builder` reads `name` raw-column-first (`PersonLabel.raw_value`) past a masked User model. **No opt-out:**
  one definition of a person's label.
  <!-- pin: test/permission_forge/helpers/application_helper_test.rb#pf_user_option_label falls through to the name when the formatter returns blank (Admin::PersonLabel) -->
- **Settings draws configuration values as `<code>`** (the enum pills, the key → value map, the default and the docs
  link's key); the locale keys `settings.row.default` and `settings.row.docs` became `default_html` and `docs_html`.
  **Opt out:** a host that overrode the two keys renames them.
  <!-- pin: test/permission_forge/html/locale_leak_test.rb#every screen shows only translated words and host data -->
- **Three placeholders are short hints**: `permission_forge.ui.search_people` and `home.index.search_placeholder`
  read "Name or email" (sq "Emër ose email", mk "Име или е-пошта"), the Home explanation moved to the new
  `home.index.search_help` under the search box, and `permission_set_rules.builder.message_placeholder` became
  `permission_set_rules.builder.message_help`, a hint under the blocked-message textarea. **Opt out:** a host that
  wants the old sentences overrides these keys in its own locale files (a placeholder longer than 40 Latin / 34
  Cyrillic characters clips on a phone).
  <!-- pin: test/permission_forge/html/layout_lint_test.rb#every placeholder fits a phone-width box in every locale -->
- **"Refresh cached permissions" says when it is needed.** The person page's menu read "Rarely needed: changes
  already apply immediately.", which is wrong with a per-process cache (a memory store) after a change from a
  console, runner or job: the process that made the change cleared only its own entries, and the server keeps the old
  permissions until they expire. It now says that (en, sq, mk), in the words `Cache::Outcome` reports.
  **No opt-out:** text only.
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#Refresh cached permissions says when it is needed, in every locale -->
- **"What people lose" (Remove, Remove all, a set's impact line) counts the resources in effect**
  (`Resource.in_effect`: active rows of an active set), not every active row. **No opt-out:** a label.
  <!-- pin: test/permission_forge/release_readiness/one_definition_guard_test.rb#one definition: the resources that count right now (Resource.in_effect), also for "what people lose" -->
- **Boot and configuration warnings reach the terminal where the log is not read.** Every boot/configuration warning
  of the gem (the per-process cache, conditional sets with an empty context, the API without authorization lambdas,
  unmasked GDPR fields, missing or stale RLS policies, `audit_events = false`, ...) goes through one emitter,
  `PermissionForge::Warnings.emit`: the log always; standard error as well in development and, outside test, in any
  process that is not a web server (a console, a runner, a rake task, a job worker) — once per warning per process,
  and not when the logger already writes to standard output or error. Before, only the development cache warnings
  reached standard error, and every SECURITY warning (a fail-open condition) was in the log alone. **No opt-out:** one
  line per warning per process, only where the log is not on the terminal; each warning names the setting that removes
  its condition.
  <!-- pin: test/permission_forge/boot_warnings_channel_test.rb#the emitter writes where the policy table says -->
  <!-- pin: test/permission_forge/cache_warnings_test.rb#development writes both warnings to standard error as well, once each -->
- **Nothing is checked or logged while `bin/rails generate` or `destroy` boots the app.** The install generator boots
  the app before it writes the initializer and the migration that creates the audit table, and that boot logged six
  `[PermissionForge]` lines describing the defaults (the in-memory cache, HTTP Basic Auth without credentials, masking
  not complete) and told a fresh install to run `permission_forge:upgrade`. While a generator runs
  (`Warnings.generator_running?`: the `generate` / `destroy` command is loaded) the boot checks, their warnings, the
  missing-table check (the first audit event checks again), the "Added N GDPR patterns" line, `PermissionForge.configure`'s
  model-binding warning and the masking machinery keep quiet; `validate_gdpr_explicit_choice!` still raises.
  **No opt-out:** the next server, console or task boot checks and warns about the configuration the app has.
  <!-- pin: test/permission_forge/boot_warnings_channel_test.rb#nothing is written while a generator boots the app -->
  <!-- pin: test/permission_forge/engine_boot_paths_test.rb#BootChecks.run checks and logs nothing while a generator boots the app -->
  <!-- pin: test/permission_forge/audit/boot_warnings_test.rb#no missing-table warning while a generator runs; the first event checks again -->
- **The development masking note is written to standard error too** (with `auto_apply_masked_attributes = :auto` and a
  per-process or null cache store): it says the server re-reads the `Resource` names from the database in development
  and that production would mask a model first named in another process only after a restart. It was in the log only.
  **Opt out:** share the store (`config.cache_store = :file_store, "tmp/cache/store"` in development), list the models
  in `auto_apply_masked_attributes`, or include `MaskedAttributes` in the models with `auto_apply_masked_attributes =
  false` — each removes the condition, and the warning with it.
  <!-- pin: test/permission_forge/cache_warnings_test.rb#development writes both warnings to standard error as well, once each -->
- **The production boot warning about an in-process cache also covers a `:memory_store`.** It fired only for
  `cache_backend = :memory`; `cache_backend = :rails_cache` over a `Rails.cache` that is a `:memory_store` (or a
  `MemoryStore` instance as `cache_backend`) is as inconsistent across Puma workers and is now warned about too. The
  line reads "Using an in-process permission cache in production" (it said "in-process MemoryCache"): update a log
  alert that matches the old text. **Opt out:** use a store the workers share.
  <!-- pin: test/permission_forge/cache_warnings_test.rb#production gets the production warning, not the development one -->
  <!-- pin: test/permission_forge/cache_warnings_test.rb#production with a shared store does not warn -->
- **What the cache tasks print is one outcome.** `rake permission_forge:cache:clear`, `erasure` and
  `cleanup_expired_assignments` print through `RakeOutput` (see Added): "Cached permissions removed: yes (the cache
  store confirmed it)" and a "Cache scope" line that says what the clear means (a shared store: every process sees it,
  each user rebuilds on their next request; a per-process store: this process only), instead of "Cache cleared: true",
  "invalidated 1 user(s)" and a "The cache is cold" line followed by the per-process note it contradicted. Labels
  changed ("Audit log name labels cleared as actor: 2", one key per line). **No opt-out:** output only; the result
  Hashes and events are additive. A script that matched `Cache cleared: true` matches `Cached permissions removed:`.
  <!-- pin: test/permission_forge/tasks/cache_clear_task_test.rb#with ACTOR and REASON: every holder is invalidated, the event names the actor from rake -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#an erasure on an in-memory store says the running servers kept the cached permissions, in output and event -->
- **`DRY_RUN=1`, `yes` or `TRUE` now mean a dry run for `rake permission_forge:erasure`; only `DRY_RUN=false`, `0`
  or `no` executes.** The task treated only the literal `DRY_RUN=true` as a dry run (its default), so `DRY_RUN=1` —
  the value `audit_events:purge` documents for a dry run — really erased the person. **No opt-out:** an erasure runs
  only when asked for explicitly.
  <!-- pin: test/permission_forge/tasks/gdpr_erasure_task_test.rb#test DRY_RUN values other than an explicit false are a dry run -->
- **Service results gained keys (additive).** `ConsentWithdrawalHandler.call` answers the same keys for a real run and
  a dry run (the real run answered `{ revoked_sets:, invalidated: }` only; it now also answers `affected_sets`,
  `affected_assignment_count` and `dry_run: false`, and a dry run also answers `invalidated: false`), and both answer
  `cache`; `ExpiredAssignmentCleaner.call` answers `affected_user_ids`, `permission_sets` and `cache`;
  `DataSubjectErasure.call` answers `permission_sets`, `groups`, `events_scrubbed` and `cache` (`cache_cleared` kept);
  `BulkPermissionSetAssignment.call` and `PermissionCacheClearer.call` answer `cache`. See
  [GDPR data handling](docs/gdpr-data-handling.md). **No opt-out:** nothing was removed or renamed.
  <!-- pin: test/permission_forge/services/consent_withdrawal_handler_test.rb#a real run answers the keys a dry run answers -->
- **`rake permission_forge:audit` reports a per-process cache from the configured store.** `process_local_cache`
  (High, production) now asks the store the configuration builds (`cache_store.process_local?`), so `cache_backend =
  :rails_cache` over a `:memory_store` is reported too, not only `cache_backend = :memory`. **No opt-out:** a finding.
  <!-- pin: test/permission_forge/services/security_audit_test.rb#a process-local cache is flagged only in production -->
- **`rails -T` descriptions.** `permission_forge:audit` no longer says "Read-only": it changes no permission data and
  records the run in the audit log (`report.generated`); the report's footer says "No permission data was changed"
  and that the run is recorded (it said "Read-only: nothing was changed"). `permission_forge:cache:clear` says what it
  does first; the upgrade hint for 0.13 installs comes last. **No opt-out:** text only.
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#the audit task says it changes no permission data and records the run -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#the cache:clear description leads with what it does, the upgrade hint last -->
  <!-- pin: test/permission_forge/services/security_audit_test.rb#report counts, threshold filtering and renderings -->
- **The stale-assignment report and the admin agree on the threshold.** Without `THRESHOLD_DAYS` the rake task, and
  `Services::StaleAssignmentAuditor.call` without `threshold_days:`, now use `config.admin_stale_assignment_days`, as
  the Home Stale list, the person page and `rake permission_forge:audit` already did; they used a fixed 90 before.
  Nothing changes unless you set `admin_stale_assignment_days` to something other than 90. Callers that pass
  `threshold_days:` (the security audit does) are unaffected; `threshold_days: nil` now means the setting instead of
  raising. **Opt out:** run the task with `THRESHOLD_DAYS=90`, and call
  `Services::StaleAssignmentAuditor.call(threshold_days: 90)`.
  <!-- pin: test/permission_forge/services/stale_assignment_auditor_test.rb#the default threshold follows admin_stale_assignment_days -->
  <!-- pin: test/permission_forge/tasks/audit_rake_tasks_test.rb#stale_assignments without THRESHOLD_DAYS uses admin_stale_assignment_days -->
- **`rake permission_forge:audit` refuses a `FAIL_ON` it does not know.** A typo counted as `info` and failed the build
  on any finding; the task now prints the levels on stderr and exits 2 before the review runs (as `stale_assignments`
  does with a bad `THRESHOLD_DAYS`). Levels are read in any case (`FAIL_ON=HIGH` is `high`). **No opt-out:** a valid
  level reads as before; `FAIL_ON=info` keeps failing on every finding.
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#an unknown FAIL_ON stops before the review with exit 2 and the levels -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#FAIL_ON is read in any case -->
- **`rake permission_forge:audit_masks` names the Permission Set, the suggested strategy and what matched.** An
  unmasked field is reported once per set, and the lines looked like duplicates; "matches pattern 'first1_last4'"
  named the mask the pattern suggests, not the pattern. The lines now read `[UNMASKED] Customer.email (Permission Set:
  Support) — personal data, not masked (suggested strategy: 'email'; matches 'email')` and `[UNMAPPED] Customer.phone
  — personal data, no active ResourceField (suggested strategy: 'last4')` (plus `; matches '<pattern>'` or `; named by
  filter_parameters` where the finding records what matched); `unmasked_field` and `unmapped_column`
  findings gain a `pattern` key (the other keys are kept). A CI step that greps `[UNMASKED] Customer.name` still
  matches; one that matches the rest of the old line must change. **No opt-out:** match on `[UNMASKED]
  <Model>.<field>` (or read `Services::GdprFieldAuditor.call`'s Hash) instead of the whole line.
  <!-- pin: test/permission_forge/tasks/audit_masks_task_test.rb#prints one line per finding and exits 1 -->
  <!-- pin: test/permission_forge/services/gdpr_field_auditor_text_report_test.rb#keeps the start of the lines existing CI output already had, names the set and the suggested strategy -->
- **`rule/unenforced_rules` leaves out Resources named after no model.** A Resource named `Custmer` was listed under
  `integrity/unknown_models` and, with its rules, under `rule/unenforced_rules` (and Home's record-rules card) — there
  is no query to scope. Only Resources whose model the app can load (`Admin::ModelCatalog#find`) are listed there now.
  **No opt-out:** `integrity/unknown_models` still names the Resource.
  <!-- pin: test/permission_forge/admin/services_test.rb#rules of a Resource named after no model the app can load are not flagged -->
  <!-- pin: test/permission_forge/services/security_audit_integrity_check_test.rb#a Resource named after a constant that is no model with a table is a Resource for a model this app does not have -->
- **A missing column costs one metadata query per process, and a reset only after a real schema change.** The engine,
  the admin and the services read a missing name (a `_uuid` variant, a timestamp a model lacks, a declared virtual
  field) again through `SchemaRead` once per process: one metadata query, and a model reset only when the database's
  columns differ from Rails' (a migration while the process was up). The admin's model catalog compares a model's
  columns with the database once per request that lists it. `FieldVariants` asks `FieldNames.declares?` plus
  `VirtualFields#include?` whether the model has a variant name. **No opt-out:** the alternative is the stale answer
  until the process restarts.
  <!-- pin: test/permission_forge/schema_freshness_test.rb#a missing name on an unchanged schema never resets the model -->
  <!-- pin: test/permission_forge/schema_freshness_test.rb#every reader sees a column a migration added after the schema was read, without a reset -->
- **The JSON API answers JSON only.** `GET /api/permission_sets.xml` (any extension but `.json`) answered the JSON list
  with a 200; it now names no endpoint and gets the API's JSON 404 (`No API endpoint answers this path and method`).
  No extension and `.json` answer as before. **No opt-out:** the API has no other format.
  <!-- pin: test/permission_forge/api/unmatched_routes_test.rb#an extension other than .json reaches no endpoint: the JSON 404 envelope -->
  <!-- pin: test/permission_forge/api/unmatched_routes_test.rb#.json and no extension still answer -->
- **Unrouted API calls answer the JSON 404 envelope.** Any other path or method under the API mount
  (`/api/unknown`, a `POST`, `PATCH` or `DELETE` on the read-only `audit_events`) answered Rails' HTML 404 page; it is
  now `{"error":{"status":404,"messages":"No API endpoint answers this path and method"}}`, after the same guards as
  every endpoint (a disabled API stays a bodiless 404, a refused `api_auth` a 401). **No opt-out:** an HTML page was no
  API answer.
  <!-- pin: test/permission_forge/api/unmatched_routes_test.rb#an unknown path or method under the API answers the JSON 404 envelope -->
  <!-- pin: test/permission_forge/api/unmatched_routes_test.rb#it runs api_auth first: an unauthenticated caller gets the 401, recorded like any API call -->
- **Every API 422 has one shape: field-keyed messages.** Input the API cannot read answered `messages` as one string
  (`"expires_at is not an ISO 8601 date or time"`, `"param is missing or the value is empty or invalid:
  permission_set"`, `"Invalid action: …"`), while a failed validation answered an object. Both are now an object that
  maps the field to a list of messages, keyed by the request parameter (`{"expires_at": ["is not an ISO 8601 date or
  time"]}`, `{"permission_set": ["is missing, empty or not an object"]}`, `{"bulk_action": ["must be assign or
  revoke"]}`) or `base` when the error names none (`generate_fields`' failure). The messages follow the request's
  locale. 401, 403 and 404 keep their string. **No opt-out:** a client that read the string reads
  `messages.values.flatten` instead. See [`docs/admin-api.md`](docs/admin-api.md#response-format).
  <!-- pin: test/permission_forge/api/permission_sets_controller_test.rb#a section that is not an object is a field-keyed 422, like a validation error -->
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#an expires_at that is not ISO 8601 is a 422 and assigns nobody, single and bulk -->
- **An API `expires_at` given as a date means the end of that day.** `"2026-10-22"` on `POST …/users` and
  `POST …/users/bulk` is now 23:59:59.999999 of that day in `Time.zone`, as the admin's end-date presets and its custom
  date; it was the beginning of the day (00:00), so the assignment had ended when its last day started. A date and time
  (`2026-10-22T10:00`, with or without an offset) is read as before. **Opt out:** send the moment you mean,
  `2026-10-22T00:00`.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a date alone is the end of that day, so today is accepted and lasts through it -->
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a date or a time without an offset is read in Time.zone -->
- **The API refuses an `expires_at` that is not after now.** A single assignment or a bulk `assign` with an end that
  has passed (`"2020-01-01"`, yesterday, a minute ago) created an assignment that granted nothing, answered 201/200. It
  is now a 422 (`{"expires_at": ["must be in the future"]}`) and nobody is assigned. A bulk `revoke` ignores
  `expires_at`, also one that is not ISO 8601 (a revoke removes the assignments whatever their end); the admin's Undo
  still restores a removed assignment with the end it had. **No opt-out:** such an assignment granted nothing.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#an expires_at that is not in the future is a 422 and assigns nobody, single and bulk -->
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a bulk revoke ignores an expires_at it cannot read -->
- **A refusing `api_auth` answers 401 Unauthorized instead of 403.** A wrong or missing token is a failed
  authentication: clients that refresh credentials on 401 did not on the 403. The body is
  `{"error":{"status":401,"messages":"Not authenticated"}}`, in the request's locale; the `api.auth_failed` event keeps
  its reason (`api_auth_denied`) and records `status: 401`. No `WWW-Authenticate` challenge is invented (the gem does
  not know your scheme): one your `api_auth` sets on `controller.response.headers` is kept. 403 now means an
  authenticated caller the authorization lambdas refuse, a lock, a missing tenant or `audit_log_authorization`.
  **No opt-out:** a client that treated 403 as "bad token" checks 401.
  <!-- pin: test/permission_forge/api/base_controller_test.rb#a WWW-Authenticate challenge set by api_auth is sent with the 401; none is invented -->
  <!-- pin: test/permission_forge/audit/admin_plane_events_test.rb#an API request api_auth refuses records api.auth_failed (401) with who the host knows -->
- **A 403 for a missing authorization lambda says so.** While `api_require_authorization` is on and
  `api_action_authorization` / `api_assignment_authorization` is unset, a change or an assignment answered "Action not
  authorized" / "Assignment not authorized", the same text as a real denial. It now names the missing option ("API
  changes need config.api_action_authorization; …"); a lambda's refusal keeps its message. **No opt-out:** a message.
  <!-- pin: test/permission_forge/api/base_controller_test.rb#a mutation refused because an authorization lambda is unset says which option is missing -->
- **`generate_fields` reads `grant_all` as a boolean.** Only the strings `"true"` and `"1"` granted: a JSON `true`
  (or `1`) answered 201 with fields without edit. `true`, `"true"`, `1` and `"1"` now grant; `false`, `"false"`, `0`,
  `"0"`, `null` and no `grant_all` do not; anything else (`"yes"`, `""`, `2`) is a 422
  `{"grant_all": ["must be true or false"]}` and creates no field. **No opt-out:** send one of the values above.
  <!-- pin: test/permission_forge/api/resources_controller_test.rb#POST generate_fields reads grant_all as a JSON boolean, 1 or their strings -->
  <!-- pin: test/permission_forge/api/resources_controller_test.rb#POST generate_fields refuses a grant_all it cannot read with a 422 keyed by grant_all -->
- **A bulk assignment that names nobody is a 422.** `POST …/users/bulk` without `user_ids` (missing, `[]`, `""` or
  only blanks) answered 200 with nothing done; it is now `{"user_ids": ["must name at least one user"]}`, on `assign`
  and `revoke`, and records no event, like the other 422s. Ids that name nobody are still reported in `skipped`.
  **No opt-out:** such a request did nothing.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a bulk request that names nobody is a 422 keyed by user_ids, recorded like the other 422s -->
- **A bulk `user_ids` that is not a list is a 422.** `"user_ids": "1,3"` was read as one unknown id and answered 200
  `{"assigned": 0, "skipped": ["1,3"]}`; a string, a number or an object now answers
  `{"user_ids": ["must be a list of user ids"]}` and changes nothing. **No opt-out:** send a JSON list.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a bulk user_ids that is not a list is a 422 keyed by user_ids and changes nothing -->
- **A single assignment or membership with an unusable `user_id` is a 422 keyed by `user_id`.**
  `POST …/permission_sets/:id/users` and `POST …/permission_set_groups/:id/users` answered 404 `"Record not found"`
  for a missing `user_id`, for one that is not an id (`"abc"`, `[2]`) and for one that names nobody, which read as if
  the set or the group were wrong. They now answer `{"user_id": ["is missing"]}`, `["is not a user id"]` or
  `["names nobody who can be assigned"]`, after the authorization lambdas, and assign nobody. An unknown id and
  someone `user_list_resolver` leaves out read the same, as in a bulk request's `skipped`; a 404 now always means the
  set or the group in the path. **No opt-out:** a client that treated that 404 as "no such person" reads the 422.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#a missing or malformed user_id is a 422 keyed by user_id, on a set that exists -->
  <!-- pin: test/permission_forge/api/permission_set_group_users_controller_test.rb#a missing, malformed or unknown user_id is a 422 keyed by user_id, on a group that exists -->
- **An unknown `permission_set_group_id` is a 422 keyed by `permission_set_group_id`.** A value that names no group of
  the current tenant was a validation error under `permission_set_group`; the API now answers
  `{"permission_set_group_id": ["…"]}`, the parameter the request sent, before anything is saved. **No opt-out:** a
  client that read `messages.permission_set_group` reads `messages.permission_set_group_id`.
  <!-- pin: test/permission_forge/api/record_identifier_test.rb#a permission_set_group_id that names no group is a 422 keyed by it -->
- **A request body the API cannot parse is a 400 in the API's envelope.** Invalid JSON sent as `application/json`
  answered Rails' own `{"status":400,"error":"Bad Request"}` (or raised where exceptions are not shown); it is now
  `{"error":{"status":400,"messages":"The request body could not be read. …"}}`, in the `Accept-Language` locale.
  Rails parses the body before `api_auth` runs, so this 400 can come before a 401; a disabled API stays a 404.
  **No opt-out:** the envelope is the API's.
  <!-- pin: test/permission_forge/api/base_controller_test.rb#a body that is not valid JSON is a 400 in the API envelope, in the Accept-Language locale -->
  <!-- pin: test/permission_forge/api/base_controller_test.rb#a body that is not valid JSON on a disabled API stays a bodiless 404 -->
- **A `per_page` or `page` the API cannot read is the default, not 1.** `per_page=abc`, `0` or a negative number gave
  pages of one row; anything that is not a positive whole number is now `api_default_per_page` (a `page`, the first
  page). The `api_max_per_page` cap is unchanged. **No opt-out:** `meta.pagination` says what was used.
  <!-- pin: test/permission_forge/security/pagination_limits_test.rb#a per_page of 0, a negative one or one that is not a number is the default page size -->
  <!-- pin: test/permission_forge/security/pagination_limits_test.rb#a page that is not a positive whole number is the first page; the max clamp stays -->
- **An API clone without a name is named as the admin's Duplicate names it.** `POST …/permission_sets/:id/clone`
  and `POST …/permission_set_groups/:id/clone` named the copy `"<name> (Copy)"` in English; they now use
  `permission_sets.copy_name`, `"<name> (copy)"` in the request's locale (`(kopje)`, `(копија)`), a set's copy
  numbered when taken, as the admin and the cloners do. **Opt out:** send `name`.
  <!-- pin: test/permission_forge/api/permission_sets_controller_test.rb#POST clone without a name names the copy as the admin does, numbered when taken, in the request locale -->

### Deprecated

- **An `api_auth` that sets `@admin = true` on the controller to open `GET /api/stats`.** Set
  `config.api_stats_authorization = ->(controller) { … }` instead. While that option is unset, `@admin` still allows,
  warning once per process through `PermissionForge.deprecator`; once it is set, `@admin` is ignored. Removed in 0.16.
  <!-- pin: test/permission_forge/api/dashboard_controller_test.rb#an @admin set by api_auth still allows the stats, with a deprecation warning -->
  <!-- pin: test/permission_forge/api/dashboard_controller_test.rb#with api_stats_authorization set, @admin no longer decides -->
- **`PermissionForge::Admin::SensitiveColumns`** — use `PermissionForge::SensitiveColumns`; the old constant answers
  with the new class and warns through `PermissionForge.deprecator`. Removed in 0.16.
  <!-- pin: test/permission_forge/sensitive_columns_test.rb#PermissionForge::Admin::SensitiveColumns is a deprecated name for the same class -->
- **`pf_time_ago`** (`ApplicationHelper`): it read Rails' `datetime.distance_in_words` keys, English without
  rails-i18n; it now answers as `pf_relative` and warns once through `PermissionForge.deprecator`. Removed in 0.16.
  <!-- pin: test/permission_forge/helpers/application_helper_test.rb#pf_time_ago is deprecated and reads as pf_relative -->

### Removed

- **`PermissionForge::Engine.apply_masked_attributes_to_managed_models`**, deprecated in 0.14: use
  `PermissionForge::MaskedModels.apply(only:)`.
  <!-- pin: test/permission_forge/engine_boot_paths_test.rb#the engine carries no boot, masking or warning logic, and nothing reaches into it -->
- **The removal of 0.13's cache keys.** Through 0.14 every invalidation also removed the bare keys 0.13 wrote
  (`user_<id>`, `tenant_<t>_user_<id>`), so that a rolling deploy from 0.13 reached both versions' entries;
  `Cache::UserKeys::PREVIOUS_ENTRY_NAMESPACES` is now empty and an invalidation removes this version's (`v2:`) entries
  only. An application still on 0.13 upgrades through 0.14, or runs `bin/rails permission_forge:cache:clear` once its
  0.13 processes are gone (as the 0.14 notes asked).
  <!-- pin: test/permission_forge/cache/user_keys_test.rb#an invalidation names the stamp and the v2 keys, and no bare key of 0.13 -->
  <!-- pin: test/permission_forge/cache/user_keys_test.rb#the entries live under one namespace, the previous ones are gone -->

### Fixed

- **The dependency validation names the prerequisite by its label** ("requires Read to be enabled", in the request's
  language) instead of the column (`read_access`); sq and mk no longer say "Permission Set", "commit and deploy" or
  "fail-open" in English, and the Effective access action pills word their state, not only a glyph.
  <!-- pin: test/permission_forge/models/resource_test.rb#the dependency message names the prerequisite by its label in every locale -->
  <!-- pin: test/permission_forge/i18n_test.rb#the left-behind lint bites -->
  <!-- pin: test/permission_forge/html/state_rendering_test.rb#an action pill on Effective access words its state, not only its glyph -->
- **A toast no longer covers the sidebar's language and theme switch at desktop widths** (1024px): toasts centre over
  the main column (`--pf-sidebar-width`). The browser layout check now also runs at 390 and 1024px.
  <!-- pin: test/permission_forge/html/layout_lint_test.rb#every scroll container in the stylesheet is a containing block, and the frame paints its cue -->
- **"Review and save" titled the browser tab with a raw value** (`{one: "Review %{count} change", …}`) in every locale:
  the page title now counts the changes. Every admin template is now rendered by the whole-UI walks (the reviews,
  previews, Home cards, the audit log off or refused), so their lints cover it.
  <!-- pin: test/permission_forge/html/admin_page_paths_test.rb#every POST answered with a page renders it -->
  <!-- pin: test/permission_forge/html/admin_page_paths_test.rb#every template under app/views is rendered by a walked screen -->
- **A stored rule never raises at read time.** A rule row with an operator this version does not know (`regex`) raised
  `ArgumentError`, one with a join type that is none (`inner`) raised `ConfigurationError` — from `permission_scoped`,
  `find_by`, `find_by!`, and under `auto_query_scoping = :filter_only` from `Customer.count` and every other query —
  a 500 for every holder of the set. Such a rule matches nothing: `permission_scoped` is empty, `find_by` denies with
  `NotAuthorizedError`. A registry injected as a Hash or as an object answering `fetch(name)` is asked the same way.
  <!-- pin: test/permission_forge/services/permission_rule_applier_test.rb#the holder of such rules is denied every record, in every read path, never a 500 -->
- **A rule naming a missing column denies instead of raising.** A rule whose field name is not a column of its table
  (`onwer_id` on `Customer`, written past the model, or a column renamed since) reached the database, so every
  `find_by` / `find_by!` / `permission_scoped` (and every query under `auto_query_scoping`) of each holder of its
  Permission Set raised `ActiveRecord::StatementInvalid` — a 500 in the host app. Under every built-in operator it now
  matches nothing, like a value the column cannot hold: its holders are denied every record of the resource. A name
  qualified with a real table that is none of the rule's and a custom operator's rule are still left to the database.
  An RLS policy compiles such a rule to `FALSE` (the sync failed on it; see `GENERATOR_VERSION` 7 under Changed). A new
  such rule is refused on save (see Changed). See
  [Using the wrong field name](docs/row-level-rules.md#using-the-wrong-field-name).
  <!-- pin: test/permission_forge/services/rule_value_typing_test.rb#a column the table does not have matches nothing, under every built-in operator -->
  <!-- pin: test/permission_forge/services/rule_value_typing_test.rb#a table that is none of the rule's, or a custom operator, is still left to the database -->
  <!-- pin: test/permission_forge/services/rls_operator_sql_test.rb#a column the table does not have compiles to FALSE, whatever the operator or value -->
- **A rule whose association path cannot be joined denies instead of raising.** A join rule whose
  `field_accessor_path` names no association (`ownr` instead of `owner`, saved through the API with a 201 before this
  release) made every `find_by` / `find_by!` / `permission_scoped` of each holder of its Permission Set raise
  `ActiveRecord::ConfigurationError` ("Can't join 'Customer' to association named 'ownr'") — a 500 in the host app —
  and the audit did not list it. Such a rule — and one through a polymorphic `belongs_to`, a record-dependent scope
  (also one reached along a `:through`, which raised `NoMethodError` when Rails built the join), a broken `:through` /
  `inverse_of` or a class that cannot be loaded — now matches nothing under every operator: the join is never built.
  Paths ActiveRecord joins are unchanged. An RLS policy compiles such a rule to `FALSE` (see Changed).
  <!-- pin: test/permission_forge/models/permission_set_rule_path_test.rb#a holder of a rule whose path cannot be followed is denied every record, never a 500 -->
  <!-- pin: test/permission_forge/security/rule_join_type_test.rb#an association path that cannot be followed matches nothing -->
  <!-- pin: test/permission_forge/operators/rule_path_test.rb#every path ActiveRecord raises for is broken, at the segment it raises for -->
- **A rule value with a NUL byte, or a field name with a control character, matches nothing.** A `field_value`
  carrying a NUL byte (a row written past the model; the request layer drops NUL bytes from parameters) was quoted
  into the statement, which the database read cut short — `ActiveRecord::StatementInvalid` for every holder. It is
  now unusable under every operator, built-in or custom (`Operators::ValueTyping.unquotable?`): the rule matches
  nothing, the audit lists it (`unusable_rule_values`) and Home names it; a new or changed value with a NUL byte is
  refused ("must not contain a NUL byte"; a stored one leaves the row editable). A `field_name` with a control
  character (a newline, a NUL byte) in a segment is no name (`Operators::RuleColumn.name?`): it matches nothing under
  a custom operator too, where a missing column used to reach the database as written.
  <!-- pin: test/permission_forge/services/permission_rule_applier_test.rb#a value with a NUL byte, or a field name with a control character, matches nothing -->
- **The admin no longer draws a rule that matches nothing as a working rule, and shows what it names as stored.** A
  rule naming a missing column read "Only show Customers where Stauts is active, or Stauts is empty" on the Rules tab.
  The Rules tab, the delete confirmation, the field page, the rule preview, a person's effective access (and its
  Records cell, which now summarises such a rule first) and the Permission Set's records summary now say "⊘ Matches
  nothing" and why ("`stauts` is not a column of Customer", "`ownr` is not a relationship of Customer") with the rule
  as stored, never "or empty"; the rule's edit page opens with a banner saying so (a rule written with
  `update_column` is still `valid?` — the checks run when what it names changes — so the page shows what the row
  holds) (en, sq, mk). A missing name is shown as code as stored (it read "Onwer" and "Ownr" like real names); a
  relationship that exists but cannot be followed keeps its label.
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#the Rules tab says the rule matches nothing, and never "or empty" -->
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#the edit page of such a rule says so, as stored -->
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#a broken name is shown as stored, in code, wherever the problem is said -->
- **An empty step in a rule's association path no longer breaks the admin.** A path like `parent..owner` (written past
  the model) made Home and the Rules tab raise (`human_attribute_name('')`); it reads "The relationship path has an
  empty step (two dots in a row, or a dot at the start)", and saving one says "has an empty association name".
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#Home says why a relationship cannot be followed, and names an empty step of the path -->
  <!-- pin: test/permission_forge/models/permission_set_rule_path_test.rb#each cause has its own message -->
- **A model file that raises while it loads no longer breaks Home or the Rules tab.** `Operators::RuleProblem` and
  `Operators::RuleColumn.for_rule` rescued only `NameError`, `ArgumentError` and `ActiveRecordError`: a model (or an
  association's class) whose file raised while it loaded made every page that describes rules a 500. A `ScriptError`
  (`SyntaxError`, `LoadError`) there, or any error while the rule's own model loads, is now "cannot tell" for those
  callers (no problem shown, the save not refused); a `StandardError` while an association's class loads makes the
  path broken ("… whose class cannot be loaded": shown, refused on save, matches nothing). The applier never answers
  for a model it cannot load: a `ScriptError` propagates from the query as before.
  <!-- pin: test/permission_forge/models/permission_set_rule_path_test.rb#a model file that raises while it loads is "cannot tell" for the admin, never an answer from the applier -->
- **A field masked with a strategy this app does not know never raises.** `Services::MaskValue.call` raised
  `ArgumentError` for a strategy it did not know — from the model's masked getter, `attributes`, `as_json`,
  `FiltersResponseAttributes`, the admin's Fields tab — for a row written past the model, a blank strategy, or a custom
  strategy removed from `config.custom_mask_strategies` after rows named it. It masks fully (`********`) and reports
  the name once per process.
  <!-- pin: test/permission_forge/services/mask_value_test.rb#call masks fully with a strategy it does not know, blank included, and never raises -->
- **The field drawer no longer rewrites a mask strategy this app does not know to `full`.** Saving another change
  (a label) saved `full`, audited as a strategy change, and the drawer showed "Masked (emial)" with no option
  selected. It now flags the strategy ("Unknown mask strategy — masked fully until fixed") and offers the stored name,
  selected and marked unknown, so a save that changes something else keeps it; only picking a strategy changes it.
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#saving the drawer with another change keeps a strategy this app does not know; picking one changes it -->
  <!-- pin: test/permission_forge/html/broken_rules_admin_test.rb#a field whose mask strategy this app does not know is drawn masked, with a badge, never a 500 -->
- **A Resource named after a constant that is no model** (`Kernel`, `String`, a model without its table) made
  `ResourceFieldGenerator`, `ResourceWithFieldsBuilder` (the admin's "Add resource" preset path) and the API's
  `generate_fields` raise `NoMethodError`. The generator creates no fields and logs one line; the API answers 422.
  <!-- pin: test/permission_forge/services/resource_field_generator_test.rb#returns empty array when resource name is not a valid class -->
- **API: an activation condition is never dropped silently.** `POST`/`PATCH /api/permission_sets` permitted
  `allowed_ips` as a scalar only, so a JSON array was dropped without a word (201 with `allowed_ips: null`, 200
  changing nothing) and an "office only" granting set applied from any IP. `allowed_ips` now takes a String (commas,
  newlines or spaces between entries) or an Array of Strings, normalised by the one parser; hours take an integer (or a
  String of digits); a session flag a String; `null` clears. Any other shape (an object, a boolean, a number for a
  list, an array for a flag or an hour) is a 422 keyed by the attribute.
  <!-- pin: test/permission_forge/api/permission_set_conditions_api_test.rb#the recorded scenario: an office-only granting set written as an array grants from the office only -->
- **A uniqueness race is no longer a 500.** Two requests that create the same assignment, group membership, Resource
  or field at the same moment both pass the uniqueness validation, and the unique index refuses the second INSERT
  (`ActiveRecord::RecordNotUnique`), which nothing rescued. The API now answers it with the validation's own 422,
  keyed by the attribute (`{"user_id": ["already holds this Permission Set"]}`, `{"name": ["already exists in this
  permission set"]}`); the admin goes back to the page the form was on (303, never another host; its home page
  without a Referer) with the same message in an alert. `PermissionForge::UniqueConflict` names the validation from
  the index the adapter's error names and parses nothing else; an index that belongs to no validation of the gem's
  models is a 422 on `base` / a generic alert.
  <!-- pin: test/permission_forge/security/route_fuzz_test.rb#duplicate insert: POST /api/permission_sets/:set/users is the validation 422 -->
  <!-- pin: test/permission_forge/security/route_fuzz_test.rb#duplicate insert: POST /assignments goes back to the form with the message -->
- **A column a migration added while the process was up was invisible**: a rule on it matched nothing at run time
  (`RuleColumn.find`), "Sync fields" and the field generator did not create its row, the Fields tab and the rule
  builder did not offer it and flagged a configured row on it "missing", a new `updated_at` was not made read-only, a
  `_uuid` variant got no entry in the permission hash, a declared virtual field that became a column stayed
  "virtual", the GDPR audit skipped it and the RLS generator left the tenant predicate out. Each reads it now without
  a restart (`SchemaRead`). A removed column leaves the process at its next comparing read (the admin's Resource page,
  Sync fields, the audit). A table a migration created while the process was up is found too (`data_source_exists?`
  caches a negative answer; `SchemaRead.table?` asks the database again once).
  <!-- pin: test/permission_forge/schema_freshness_test.rb#every reader sees a column a migration added after the schema was read, without a reset -->
  <!-- pin: test/permission_forge/schema_freshness_test.rb#a table created after the schema cache said it is not there is found -->
- **A response key two fields map to reads by the stricter of them.** With custom `field_variant_mappings` that send
  two fields to one name (`supplier_id` and `supplier_ref` both to `supplier_key`) and a model without that name,
  `FiltersResponseAttributes` read a serializer's `supplier_key` by the first field's entry, so a hidden second field
  left the key readable. It now reads by the strictest of the fields' entries: read only if every one reads, edit only
  if every one edits, masked if any masks (with that field's strategy). The default mappings never send two fields to
  one name.
  <!-- pin: test/permission_forge/field_variants_test.rb#a response key two fields map to is hidden when either field is -->
  <!-- pin: test/permission_forge/field_variants_test.rb#a variant two fields map to gets the strictest of their entries -->
- **The admin's effective-access explanation follows the engine on explicit-over-derived variant rows** (`variant_of`
  is nil for an explicit row).
  <!-- pin: test/permission_forge/admin/effective_access_test.rb#an explicit Hidden row for a variant name is hidden, in the engine and here -->
- **A person's effective access composes single-table inheritance the way the engine does.** The view of
  `VipCustomer` showed the subclass entry's own fields and rules, while the engine reads the strictest field entry
  along the chain (`ResourceChain.fields`) and the rules of every entry: a field the base masks read as Editable, and a
  base entry without Read (which hides every field) was not shown at all. A subclass entry now lists the rules of its
  base entries too (a View All on the subclass skips only its own rules), its fields are composed along the chain, the
  resource flags follow `PermissionHashBuilder.granted_flags` (edit and delete only with read, Modify All only with
  View All), the Why panel says which Resource decided ("Decided by Customer, which this inherits from …", "Hidden: it
  inherits from Customer, which doesn't allow Read."), and a field drawer's "In other sets" / "Explain for" reach the
  base Resources a subclass answers to.
  <!-- pin: test/permission_forge/admin/effective_access_test.rb#a subclass entry lists the base entry's rules too, and View All on the subclass skips only its own -->
  <!-- pin: test/permission_forge/admin/effective_access_test.rb#a subclass shows its fields as the chain composes them: the strictest entry decides -->
- **Effective access: the Why panel credits a set only with what it did to the entry.** A Muting Permission Set that
  masks or hides a field no set shows made the panel read "⊘ Hidden by muting" and "Contractors forces this field
  masked." for a field that was hidden because nobody granted it; a muting row that takes editing away was listed for
  a field nobody could edit; with two mutes the weaker one was named first; two masking sets were listed in an
  unstable order, so the first strategy named could differ from the one applied; a mask on a field already masked, or
  a mute on a subclass field its base's grants already hide, was credited too. The badge and the first reason now
  always word the entry's level (and strategy).
  <!-- pin: test/permission_forge/html/admin_view_models_test.rb#every WHY level word equals the level the hash entry gives, for every state -->
- **Effective access says how each Permission Set shows a field.** The WHY panel of a field said "✓ Sales rep shows
  this field." when Sales rep shows it masked. It now reads by level: "shows this field masked (Email)", "shows this
  field read-only", "shows this field and lets people edit it", and for Muting Permission Sets "hides this field" or
  "forces this field masked" (`Admin::EffectiveAccess::FieldSource`, `FieldOutcome#grants` / `#mutes`).
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#the WHY panel says how each set shows the field -->
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#a muting set that forces a mask says so, in every locale -->
- **A field hidden by a Muting Permission Set reads "⊘ Hidden by muting" everywhere.** The field's row said so, but its
  Why panel and the field drawer's "Explain for" showed "∅ Hidden", the badge of a field no set grants; "Explain for"
  also did not say which base Resource decides an inherited field. Row, panel and "Explain for" now draw the same
  badge (`pf_effective_field_badge`) and the same "Decided by …" sentence.
  <!-- pin: test/permission_forge/html/field_test_round_four_admin_ui_test.rb#the Why panel of a field hidden by muting reads as its row does -->
  <!-- pin: test/permission_forge/html/labels_and_attention_admin_test.rb#Explain for names the base Resource that decides an inherited field, as the Why panel does -->
- **"Across all Permission Sets" on an action drew two glyphs** ("✎ ✓ Permitted", "⊘ ⊘ Blocked"); it now reads as
  the action's "Right now" badge.
  <!-- pin: test/permission_forge/html/state_rendering_test.rb#action permitted: Right now and Across all sets word it alike -->
- **The Conditions tab dropped the "same start and end hour" error**: the form refused the window but showed no
  message. The error is drawn under the hour selects, which are marked invalid and point to it.
  <!-- pin: test/permission_forge/html/labels_and_attention_admin_test.rb#the same start and end hour is said next to the hour selects, which are marked invalid -->
- **A record footer that reads "Unknown" says it once, and why.** A change written with no actor (a runner, a job)
  read "Last edited by Unknown" with nothing more, a record created and edited that way read "Created by Unknown · … ·
  Last edited by Unknown", and an explanation started with "Unknown:" again. The footer names Unknown once ("… · Last
  edited today"), adds that no actor was named for the change and that `PermissionForge.with_audit_actor` names one —
  the event page's explanation, from the same helper.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#the footer and the event page explain Unknown with one helper and the same words -->
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#a change made by code with no audit actor names it as the audit log does, with a hint -->
  <!-- pin: test/permission_forge/html/labels_and_attention_admin_test.rb#a record created and edited with no known actor reads Unknown once in its footer -->
- **The audit event page explains an unknown actor.** An event with no actor read "Unknown · Unknown" with an "All
  events by this actor" link. It now names Unknown once, gives the same explanation as the record footer without
  repeating "Unknown:" in front of it, and the link reads "All events with no known actor".
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#the event page of a change with no actor explains Unknown and links to every such event -->
  <!-- pin: test/permission_forge/html/field_test_round_four_admin_ui_test.rb#the event page names Unknown once: the explanation does not start with it again -->
- **"Created by" names who the audit log names.** A record created by the HTTP Basic admin (or an API client) has
  no `created_by_id` — the column holds a user id — so the footer said "Created by System" and a Permission Set's
  Assignments tab "by System", next to "Last edited by admin (password prompt)" and an audit log that named
  "admin (password prompt)". Footers, the Assignments tab, "Assigned by" (person pages, Home), the audit tabs of the
  Person and Permission Set pages and their CSV now take the creator from the record's creation event
  (`permission_set.created`, `assignment.granted`, ...) when the audit log has one, and fall back to `created_by`
  otherwise. The `created_by_id` / `updated_by_id` columns are unchanged.
  <!-- pin: test/permission_forge/html/creator_label_test.rb#a set and an assignment made by the HTTP Basic admin: footer, grid and audit tab name who the audit log names -->
  <!-- pin: test/permission_forge/html/creator_label_test.rb#a person stamped in created_by, with no event, is still named from the column -->
- **Views decided "locked" from the record alone** (13 sites) and so offered what the server refused: Remove and bulk
  revoke on a locked Muting Permission Set's holders, Delete on a set in a locked group, adding or removing members of a
  locked group, the rule links on a locked field's drawer; the Locked badge on a row now follows the chain (a resource or
  rule of a locked set is locked).
  <!-- pin: test/permission_forge/html/locked_pages_test.rb#a locked Muting Permission Set: holders may be added and kept longer, not removed or ended sooner -->
- **A locked Permission Set only offers the end dates it accepts.** The "Change end date…" menu of a locked granting set
  offered "30 days from today" and "No expiry", which the lock then refused; it now lists only the presets that narrow
  access (the other way round for a Muting Permission Set; `Admin::EditableLock.expiry_choices`). A person's Assign
  drawer lists a locked set that cannot take holders as disabled with a "Locked" badge and a note, instead of leaving it
  out. Home's "Ending soon" card shows the "Locked" badge in place of "Extend 30 days" where extending would be
  refused (a locked granting set), and keeps offering it for a locked Muting Permission Set, where extending narrows.
  <!-- pin: test/permission_forge/admin/editable_lock_test.rb#expiry_choices offers only what the lock lets through, in the set's direction -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#the Assign drawer lists a locked granting set as locked, not hidden, and cannot assign it -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#Home offers "Extend 30 days" only where the lock lets it through, and says Locked where not -->
- **Home's privacy audit no longer offers "Fix" for a field of a locked Permission Set.** The field drawer refuses
  every change to a locked set's (or Resource's, or field's) fields, including a mask, so "Fix" opened a drawer with
  nothing to do and "This is intended" was offered when only the set was locked. Such a finding now shows the Locked
  badge and a "View field" link (`AttentionItems::SensitiveFinding#locked?`, by `Admin::EditableLock`), and the
  drawer of a locked field says "Locked, so nothing here can be saved." instead of "Saving applies to … immediately."
  The note under the card's title says to choose "This is intended" only while a listed finding has the button
  (`AttentionItems::SensitiveFinding#acknowledgeable?`).
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#the privacy audit shows a field of a locked set as Locked, with no Fix and no This is intended -->
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#the drawer of a locked field does not say what saving would do -->
  <!-- pin: test/permission_forge/html/field_test_round_four_admin_ui_test.rb#a privacy audit whose rows are all locked does not tell the admin to choose This is intended -->
- **A locked rule that matches nothing says how it gets fixed.** On Home its row has the Locked badge (as on the
  privacy card) and says the set is managed by the system or API that created it, so the rule is fixed there (or the
  set unlocked in code): its page only offers a copy, which would leave the rule as it is.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#Home shows the Locked badge on a locked rule and says where it gets fixed -->
- **Read-only inputs look read-only.** A locked record's inputs (the field drawer's Label and Description, the
  conditions' IP list) were white boxes like editable ones; they are now filled and do not light up on hover (still
  focusable and announced read-only), and a locked set's name and description no longer show an edit outline.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#read-only inputs are drawn filled, without the hover of an editable one -->
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#a locked field drawer keeps Label and Description read-only, labelled -->
- **Re-saving a filter rule that carried a relationship path turned it into a join rule.** The builder loaded the
  stored path of a filter rule (`join_type` nil) and saved it back as `joins`, which changed what the rule matched. It
  loads a path for join rules only (`PermissionSetRule#join_rule?`, the one definition), so a filter rule stays one.
  <!-- pin: test/support/decision_parity/rules.rb#a filter rule that carries a path stays a filter rule through the builder -->
- **Fixing a misspelled relationship keeps the rule's field.** A join rule whose stored path names no relationship
  (`ownr`) showed the first relationship as if it were chosen next to "This model or relationship no longer exists";
  its select now shows "Pick a relationship…" (marked invalid) and the field select keeps the stored field
  (`email_address (as stored)`), so picking the relationship again keeps it when it is a column there — Save answered
  "Pick the field to check." and the field was lost.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#a relationship that is not there shows "Pick a relationship…", not the first one as if chosen -->
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#picking the relationship again keeps the stored field when it is a column there -->
- **A save the rule builder refuses names the field as the builder does.** The model's errors were shown as Rails'
  full messages ("Field accessor path names ownr, …", in English in every locale); they now carry the builder's own
  label ("Relationship names ownr, …", "Field to check names `onwer_id`, which is not a column of …", in the page's
  language). The API's field-keyed messages are unchanged.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#a refused save names the field as the builder does, in every locale -->
- **Rule builder: the banner of a rule that matches nothing names the right fix.** It said "Pick the field again" for
  an unknown condition, join type or a value the column cannot hold; it now says what to change for each kind of
  problem (`RuleProblem#remedy`), and no longer repeats the stored name ("`stauts` is not a column of Customer ·
  stauts").
  <!-- pin: test/permission_forge/html/rule_builder_explanations_test.rb#the banner says the stored name once -->
- **Home's "unenforced rules" and "rules that match nothing" worked on two different sets of resources** (one added
  `read_access`); both read `Resource.in_effect` now. A `join_type` of blanks counted as a join rule in SQL and as a
  filter rule in Ruby; Home and the boot warning count by `filter_join_type?`. A `requires_session_flag` /
  `allowed_ips` of newlines counted as a condition to the SQL scopes and not to `conditional?`; the scopes strip them
  too.
  <!-- pin: test/support/decision_parity/rules.rb#join_type_rules agrees with filter_join_type? on whitespace, for Home and the boot warning -->
- **One definition per decision, read where it was re-derived.** `ManagedIndex.cache_key` reads the tenant through
  `PermissionForge.ambient_tenant_id`; `FieldVariants` composes a shared variant through `ResourceChain.strictest`;
  the cloner copies rows in the hash builder's order (`PermissionHashBuilder.sort_rows`).
  <!-- pin: test/permission_forge/release_readiness/one_definition_guard_test.rb#one definition: the ambient tenant (PermissionForge.ambient_tenant_id / .ambient_tenant) -->
- **The People page marked every permanent assignment "due for review" while `admin_stale_assignment_days` was nil**
  (`nil.to_i` days); it now uses the same threshold as Home and the audit (the 90-day default).
  <!-- pin: test/support/decision_parity/rules.rb#stale: the People page, Home, the audit and the auditor agree with the setting nil and set -->
- **The Fields tab's bulk "Add" wrote rows the presets and Sync never would.** Bulk "Editable" on new columns gave
  `created_at` / `updated_at` edit access (the presets and Sync give Rails' timestamps read-only), and bulk "Read-only"
  on `email` gave it unmasked under `gdpr_defaults` (the presets start it Masked). The three paths now build the row in
  one place; the review page shows the level the row really gets (Masked, Read-only for a timestamp).
  <!-- pin: test/support/decision_parity/fields.rb#(a) Customer, muting=false, gdpr_defaults=true, edit: presets, bulk and the generator write the same rows -->
- **The GDPR audit reported a Hidden row as "readable unmasked".** `rake permission_forge:audit_masks`, the
  `unmasked_personal_data` finding and `cross_set_unmasking` took every row with `mask_access: false`, so a Hidden
  row (read off) of `email` was listed as personal data in the clear and as overriding another set's mask. Only a row
  that exposes the field (read on, no mask) is reported now.
  <!-- pin: test/support/decision_parity/fields.rb#(g) the GDPR audit names exactly the rows that expose a field in the clear; a Hidden row never -->
- **`config.ignored_fields` given as Symbols were ignored by the field generator** (the admin honoured them): the
  generator created rows for `uuid`, `id`, …
  <!-- pin: test/support/decision_parity/fields.rb#(a) Symbol ignored_fields keep their columns out on every path -->
- **A blank virtual field name made "Add resource", Sync and the Fields tab fail** (`ActiveRecord::RecordInvalid`, a
  500) for a host whose `extra_fields_method` lists one; the generator already skipped it. Every path skips it.
  <!-- pin: test/permission_forge/services/blank_name_rows_test.rb#the admin paths skip a blank virtual field name like the generator does -->
- **Copying a Permission Set that holds a field or action row with a blank name failed whole** (such a row, written
  before the names were checked, cannot be created again). The copy leaves those rows out, copies the rest and logs
  how many it skipped.
  <!-- pin: test/permission_forge/services/blank_name_rows_test.rb#cloning a set with blank-named field and action rows skips those rows and copies the rest -->
- **`GdprFieldAuditor`'s `view_all_on_pii_resource` finding listed switched-off field rows** among the resource's
  personal-data fields.
  <!-- pin: test/permission_forge/services/gdpr_field_auditor_view_all_test.rb#a switched-off field row is not among the personal-data fields of a bypassing resource -->
- **A field row created without a label is labelled with its humanized name.** A `ResourceField` created through the
  API or a console without a label took the install migration's column default, "Untitled Field", and the admin
  (Home's privacy audit, the Fields tab) showed that instead of the field; generated rows already had a label from
  their name. A new row whose label is blank or "Untitled Field" now gets the name's label (`billing_email` →
  "Billing email") on create; a label set later is kept, and existing rows are not changed (rename them in the admin).
  Resource actions have no label default (a blank one reads as the action key).
  <!-- pin: test/permission_forge/models/resource_field_test.rb#a new row without a label is labelled with its humanized name -->
  <!-- pin: test/permission_forge/models/resource_field_test.rb#the label default applies on create only -->
- **The console shows the gem's own configuration names.** With `filter_parameters_integration` the GDPR pattern
  `\Aname\z` (meant for people's names) reached the gem's models through `ActiveRecord::Base.filter_attributes`, so
  `#inspect` printed `name: [FILTERED]` for a Permission Set, a Permission Set Group, a Resource, a field, an action
  and a rule. Each of these models now sets its own `filter_attributes`: the application's filters, unable to match
  `name`, `label` or `field_name` (configuration), still hiding whatever else they matched (a rule's `field_value`, a
  description). `AuditEvent` hides `actor_label` and `record_label`, which name people, whenever the application's
  filters hide a `name`. Request-parameter logging, SQL bind logging and the host's models are unchanged.
  <!-- pin: test/permission_forge/inspection_filters_test.rb#a gem model's inspect shows its name under the GDPR patterns; another attribute stays filtered -->
  <!-- pin: test/permission_forge/inspection_filters_test.rb#AuditEvent hides the labels that name people when the application's filters hide a name -->
- **Auto-applied masking reaches the development server.** With Rails 8's development `:memory_store` (or 7.1/7.2's
  `:null_store`) and `auto_apply_masked_attributes = :auto`, a `Resource` row created from a runner, a console or a
  rake task never reached the running server, which served the model's columns in clear while `masked_field?` said
  `true`, until a restart. In development, with a store that cannot carry the masking token, each request or job now
  re-reads the `Resource` names (one query at most every 2 seconds) and masks the model at the next request. No other
  environment runs that query; there the boot warns that a model first named in another process stays unmasked until a
  restart, with the remedies (a shared store, `include PermissionForge::Concerns::MaskedAttributes` with
  `auto_apply_masked_attributes = false`, or a list of models). See [Cache
  Consistency](docs/configuration.md#cache-consistency).
  <!-- pin: test/permission_forge/masking_sync_test.rb#development with a per-process store masks a model named from another process at the next request -->
  <!-- pin: test/permission_forge/masking_sync_test.rb#development re-reads the Resource names at most every DATABASE_RECHECK seconds -->
  <!-- pin: test/permission_forge/cache_warnings_test.rb#production with a per-process or a null store warns that masking is not announced -->
- **The masking-token warning says why, and a store that keeps nothing is not asked.** A store that keeps nothing
  (`cache_backend = :null`, a `:null_store`, Rails 7.1/7.2's development default) logged "The cache store did not
  give or keep the masking token" at boot with no cause or remedy; such a store is no longer asked for the token (the
  boot warning above explains what it means). For a store that fails, the warning now names what the store did — its
  error, or "(it did not answer, or a read right after a write came back empty: the store is down, full, or evicts the
  key at once)" — before the consequence and the remedy (a shared store that keeps entries, or `MaskedAttributes`
  included in the models).
  <!-- pin: test/permission_forge/masking_sync_test.rb#a store that keeps nothing is asked for no token and logs no token warning -->
  <!-- pin: test/permission_forge/release_readiness/masking_sync_regression_test.rb#PERF-N1b a store that does not answer is asked once per pause and logged once -->
- **A gem that loads `rails/generators` at boot no longer hides the audit-table check.** The boot took any process
  with `Rails::Generators` loaded for a generator run and skipped the missing-table warning. It now looks for the
  command `bin/rails generate` / `destroy` loads (`Rails::Command::GenerateCommand` / `DestroyCommand`).
  <!-- pin: test/permission_forge/audit/boot_warnings_test.rb#Rails::Generators alone is no generator run -->
  <!-- pin: test/permission_forge/audit/boot_warnings_test.rb#a generator is running while bin/rails generate or destroy boots the app -->
- **The admin's Erase and Home Clean-up said the web processes kept the cached permissions — while running in the web
  process.** Both recorded `process_local: true` and the log read "in its own process only: the web and job processes
  kept theirs" although the serving process had cleared its store (the person lost access at once). The outcome now
  records where it ran (`in_request`), and the sentence and the flash name the *other* web workers and the job
  processes.
  <!-- pin: test/permission_forge/audit/cache_scope_events_test.rb#cleanup.expired_assignments from an admin request says process-local for the other processes only -->
- **`ConsentWithdrawalHandler` from a runner on a per-process store answered `invalidated: true` and recorded no
  scope.** `consent.withdrawn` carries the outcome like the other three events, the result carries `cache`, and the
  admin's Withdraw consent flash says when the store is per-process.
  <!-- pin: test/permission_forge/audit/cache_scope_events_test.rb#consent.withdrawn on the suite's memory store says process-local in the event and the result, in every locale -->
- **`ExpiredAssignmentCleaner` and `BulkPermissionSetAssignment` from the admin and the API ignored the cache store's
  answer in the flash and said nothing about scope.** The Home Clean-up flash and the bulk assign/revoke flashes say
  when the store did not confirm (`maintenance.cleaned_cache_kept`, `bulk_assignments.assigned_cache_kept` /
  `revoked_cache_kept`) and when it is per-process.
  <!-- pin: test/permission_forge/html/refresh_cache_failure_test.rb#a refresh the store confirmed is announced as done -->
- **`permissions.invalidated` says which processes it reached.** The runtime event (the `cache` group) now carries
  `process_local` and `in_request` (the scope every summary event's `Cache::Outcome` carries), so with a per-process
  store its audit sentence ends with the same cache-scope suffix instead of reading as if every process dropped the
  user's permissions.
  <!-- pin: test/permission_forge/audit/runtime_plumbing_test.rb#a rebuilt and an invalidated permission hash are published, stored only with the cache group -->
- **Users made by Rails 8's `bin/rails generate authentication` show and are found by their email.** That generator
  names the column `email_address`, and PermissionForge only read `email`: a person without a name column showed as
  "User #2" in the admin, searching people by email found nobody, "Paste emails or names" in bulk assignment reported
  existing people as not found, and the cached profile (`permissions_hash[:profile][:email]`) was empty. The admin
  labels, people search and bulk matching now read `email`, then `email_address` (bulk matching tries every such
  column the table has), and the default `profile_builder` and the one the install generator writes fill the
  profile's `email` key from `email_address` when `email` is missing or blank. An existing generated initializer keeps
  its `profile_builder`: change its `email:` to `user.try(:email).presence || user.try(:email_address)` to get the
  same. Users with an `email` column see no change.
  <!-- pin: test/permission_forge/admin/email_address_people_test.rb#the label shows the email_address when there is no name -->
  <!-- pin: test/permission_forge/admin/email_address_people_test.rb#people search finds an email_address in SQL -->
  <!-- pin: test/permission_forge/admin/email_address_people_test.rb#the default profile_builder fills email from email_address and still prefers email -->
- **An `expires_at` that is not ISO 8601 is refused.** The API (`POST …/users`, `POST …/users/bulk`) and the admin's
  Undo after a removal read `expires_at` with `Time.zone.parse`, which takes any text with a recognisable fragment:
  `"tuesday"` or `"next tuesday-ish"` became today 00:00 and was answered 201 with an assignment that had already ended,
  and `"2030-02-30"` became 2 March. `expires_at` is now read only as an ISO 8601 date (`2026-10-22`, now the end of
  that day in `Time.zone`: see **Changed**) or date and time (`2026-10-22T10:00`, optional seconds and fraction, `T` or one
  space, optional `Z` or `±HH:MM`); anything else is a 422 in the API (a 400 in the admin) and assigns nobody. The
  formats are listed in [`docs/admin-api.md`](docs/admin-api.md#expires_at-formats). The values the admin itself sends
  are unchanged.
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#an expires_at that is not ISO 8601 is a 422 and assigns nobody, single and bulk -->
  <!-- pin: test/permission_forge/api/permission_set_users_controller_test.rb#every accepted expires_at form is stored as the time it names, single and bulk -->
  <!-- pin: test/permission_forge/security/bad_input_test.rb#restore with an unreadable end date is a 400, not a permanent assignment -->
- **An API `permission_set_group_id` that starts with digits no longer names another group.** The integer column cast
  `"12ab…"` (a uuid that starts with digits) to 12, so `PATCH …/permission_sets/:uuid` could move the set into the
  group whose id is 12. Only a string of digits is read as an id now; anything else is a uuid (under `:uuid`) or a 422.
  <!-- pin: test/permission_forge/api/record_identifier_test.rb#a uuid that starts with digits is never read as a group id -->
- **The 401 of a refused `api_auth` was always in the default locale** (the request's locale was assigned by a later
  callback); it now follows `locale` / `Accept-Language` like every other API error.
  <!-- pin: test/permission_forge/api/envelope_schema_test.rb#GET /api/permission_sets (permission_sets#index) answers the schema in its success and in every error class -->
- **`GET …/permission_sets/new`, `…/:identifier/edit`** (and the same under resources, fields, actions, rules and
  groups) raised `AbstractController::ActionNotFound` — Rails' own 404 page, outside the API envelope: the API routes
  no longer draw `new` / `edit`, so `…/new` reads as an identifier (the JSON 404 "Record not found") and `…/edit`
  reaches the catch-all (the JSON 404 "No API endpoint answers this path and method").
  <!-- pin: test/permission_forge/api/envelope_schema_test.rb#…/new and …/:identifier/edit answer the JSON 404 envelope -->
- **The audit called `current_user` on a `uuid` column a value the column cannot hold** (it judged the id as `0`); it
  now judges it as a number and as a uuid, and lists it only when neither fits.
  <!-- pin: test/permission_forge/operators/postgres_column_types_test.rb#current_user on a uuid column is a uuid only when the user id is one -->
- **RLS: the policy's "no activation condition" quoted a newline, a carriage return and a tab through `squish`**,
  which turned them into spaces; the `view_all` EXISTS is built without it.
  <!-- pin: test/rls/rls_rule_parity_test.rb#a set whose condition texts are blanks is unconditional to the policy, as to the app layer -->
- **`rake permission_forge:stale_assignments` refuses a `THRESHOLD_DAYS` it cannot read.** The value was read with
  `to_i`, so `THRESHOLD_DAYS=`, `abc`, `0` or `-3` became a threshold of 0 (or less) days and reported every permanent
  assignment, exiting 1. Anything that is not a whole number of days from 1 to 36500 now prints what is expected on
  stderr and exits 2, without running the report.
  <!-- pin: test/permission_forge/tasks/audit_rake_tasks_test.rb#stale_assignments refuses a THRESHOLD_DAYS that is not a number of days -->
- **`rake permission_forge:audit` says why `FAIL_ON` fails the build**: `Failing: N finding(s) at or above <level>
  (FAIL_ON=<value>).` on stderr before the exit 1 (FORMAT=json output on stdout stays parseable).
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#FAIL_ON says why it fails the build -->
  <!-- pin: test/permission_forge/tasks/rake_output_test.rb#FORMAT=json keeps stdout parseable when FAIL_ON fails -->
- **The `no_rules` finding's advice follows `auto_query_scoping`.** It said "enable auto_query_scoping" also when it
  was on (under `config.preset = :strict`).
  <!-- pin: test/permission_forge/services/security_audit_test.rb#no_rules advises enabling auto_query_scoping only while it is off -->
- **Lists in the admin read in Albanian and Macedonian.** A list of people, sets or resources ("Bob Sales and Carol
  Support" on the set page, the review, the assign drawer, the confirmations, the "Assigned" notice) was joined by
  `Array#to_sentence`, which reads Rails' `support.array` keys: an app without `rails-i18n` has them in English only.
  The admin now joins every list with the connectors of the gem's own keys (`permission_forge.support.array.*`, in
  en, sq and mk; helper `pf_to_sentence`, `Admin::ListSentence`); a test fails on a bare `to_sentence` in `app/` or
  `lib/`.
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#a list reads with the connectors of each locale -->
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#nothing in app/ or lib/ joins a list with a bare to_sentence -->
- **In Albanian and Macedonian the admin showed English where it had no key of its own**: Rails-core validation
  messages ("can't be blank", "has already been taken", or "Translation missing: sq.errors.messages.blank"),
  humanized column, model, association and action names in the effective-access tab, the Home privacy card, the Field
  lookup, the rule builder's selects and sentences, the sync panel and the "New Resource" list, the audit log's record
  names ("Permission Set #1" from `titleize`), the person and Permission Set audit CSV headers, the Settings page's
  configuration values. Each now comes from a `permission_forge.*` key or is the stored name verbatim.
  <!-- pin: test/permission_forge/html/locale_leak_test.rb#every screen shows only translated words and host data -->
- **Locale file fixes.** The sq locale file mixed „…“ and “…” (three keys); `ui.badges.fail_open` was "Fail-open" in sq
  and mk; the Settings intro said "deploy" in both.
  <!-- pin: test/permission_forge/i18n_test.rb#sq quotes with one pair of quotation marks -->
- **`pf_operator_label`, the audit log's actor type / category / source / filter labels and the condition flag
  labels showed an unknown value humanized** ("made up operator"); they show it as stored.
  <!-- pin: test/permission_forge/helpers/application_helper_test.rb#pf_operator_label shows an unknown operator as stored, never humanized -->
- **Admin wording.** The empty Rules tab says "every Customer record they can read" (it said "every Customers"); the
  banner of a Muting Permission Set's resource says "take access away from everyone who has “No PII exports”" (it
  said "No PII exports's people"). A person shown by the email or the "User #2" fallback is named in full in sentences
  ("What User #2 can do right now"; it said "What User can do"), and an email label takes its initials from the local
  part (`dave@acme.test` is "DA"; it was "DT"). In a Muting Permission Set the drawer of a field without a setting
  says the set takes nothing away from it, instead of "Blocked by default" and a link to
  `unconfigured_field_strategy`, which only decides for granting sets.
  <!-- pin: test/permission_forge/html/admin_copy_test.rb#the empty Rules tab names the resource in the singular, in every locale -->
  <!-- pin: test/permission_forge/html/admin_copy_test.rb#the muting banner quotes the set name instead of a possessive -->
  <!-- pin: test/permission_forge/html/admin_copy_test.rb#a person labelled by the fallback is named in full on the person page -->
  <!-- pin: test/permission_forge/admin/services_test.rb#an email label takes its initials from the local part -->
  <!-- pin: test/permission_forge/html/admin_copy_test.rb#the field drawer of a Muting Permission Set explains the unconfigured field the same way -->
- **Adding a resource to a Muting Permission Set says what it takes away.** With "Leave everything unchanged" the toast
  read "Added Customer with 0 fields" and the page warned "⚠ Sync fields with model · 8 new columns not configured",
  although a column with no setting in a Muting Permission Set takes nothing away. The toast now says "Added Customer.
  It mutes nothing yet: choose below what it takes away." (or what the preset took away: "It takes away Create, Edit,
  and Delete."), and the sync panel is shown as information ("8 columns with no setting, so they mute nothing"). It
  still warns when a configured field's column is gone, and for granting sets as before
  (`Admin::FieldRows#sync_warning?`).
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#a muting resource added with nothing changed says it mutes nothing yet, and the sync panel is no warning -->
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#a muting resource added with a preset that takes something away says what it takes away -->
- **The savebar of a Permission Set only shows up on its other tabs once there is something to save.** The
  Assignments tab said "Assigning or revoking applies immediately" above "No unsaved changes · Review and save". On
  every tab but Resources the bar is hidden while nothing joined to it (the set's name, description, group, Active)
  has changed; without JavaScript it stays, as the way to save those.
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#the set savebar is quiet on the tabs that apply at once, and stays rendered for the header -->
  <!-- pin: test/permission_forge/html/field_test_round_two_copy_test.rb#only a page running the script hides a quiet savebar, and only while nothing changed -->
- **"Review and save" says what it did not apply.** A request that turns on Edit (or Delete, View All, Modify All)
  while Read is off — a form the admin never sends — was answered "No changes to save." It now says "Customer: Edit not
  turned on, because Read is off" (Modify All: "because it needs View All and Edit"), in the alert when nothing else
  changed and on the review page next to the changes that do apply (`Admin::ChangeSet#refused`).
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#a crafted Edit-without-Read says Edit was not turned on because Read is off -->
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#the review lists a refused flag next to the changes that do apply -->
  <!-- pin: test/permission_forge/admin/change_set_test.rb#Modify All without View All and Edit is refused as needing them -->
- **A success toast no longer covers the "unsaved changes" bar.** On a page with that sticky bar the toasts are shown
  at the top of the window instead of the bottom.
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#toasts move to the top of a page that has a savebar -->
- **Effective access shows the whole rule in the Records cell**, wrapped, instead of cutting it mid-word ("Owner is
  the cur").
  <!-- pin: test/permission_forge/html/admin_behaviour_test.rb#the Records cell shows the whole rule, wrapped, not cut with an ellipsis -->
- **Every Permission Set page scrolled the whole document sideways on a phone** (to 619px at 360–600px) and the
  Permission Set index to 410px, with no cue: a screen-reader-only header cell of the wide grid is `position:
  absolute` and the scroll frame was not its containing block, so the cell sat at its static position in the page,
  outside the frame's clipping, and widened the document. `.pf-scroll-x` and every scroll container are `position:
  relative` now, so what they clip scrolls with them.
  <!-- pin: test/permission_forge/html/layout_lint_test.rb#every scroll container in the stylesheet is a containing block, and the frame paints its cue -->
- **Placeholders that were sentences clipped at phone width**: the Home search in every locale, the people pickers in
  Macedonian, the Permission Set description in Macedonian (53 characters). They are short now (a value or
  placeholder wider than its input ends in an ellipsis), with the sentence as a hint under the control where one is
  needed.
  <!-- pin: test/permission_forge/html/layout_lint_test.rb#every placeholder fits a phone-width box in every locale -->
  <!-- pin: test/permission_forge/html/field_test_round_five_admin_ui_test.rb#the Permission Set description placeholder fits a phone-width input in every locale -->
- **On a phone, long content ran past the card's edge**: a setting's long option list or pattern, the how-to snippet
  panel, a person's long email, a long model name and the group's people picker were cut off; they wrap, or scroll
  inside their own box.
- **The Assignments grid's column headers line up with their cells.** Each row was its own grid, so the
  content-sized actions column took a different width in the header (empty) than in the rows, and "Until 14 Nov"
  sat under "Assigned". The Assignments and Permission Sets tables now share one grid between head and rows
  (CSS subgrid). When the card is narrower than the table (a phone), each Assignments row stacks instead of scrolling
  sideways, where "Reason" was cut off.
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#a table with a content-sized column shares one grid between its head and rows (subgrid) -->
  <!-- pin: test/permission_forge/html/field_test_round_four_admin_ui_test.rb#a narrow card stacks each Assignments row instead of scrolling it -->
- **The Fields grid's level controls line up across rows.** A masked row's strategy preview ("Email · j***@acme.com")
  was a cell of its own that pushed its level control left, and at 600px wrapped "Details ›" onto its own line. The
  preview now sits under the level control, no wider than it.
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#the mask preview sits under the level control, inside its column -->
  <!-- pin: test/permission_forge/html/field_test_round_three_admin_test.rb#the preview does not widen the level column -->

### Documentation

- [Migration guide](docs/migration-guide.md#upgrading-to-015): "Upgrading to 0.15" — run `rake
  permission_forge:audit` first, the behaviour changes with their opt-outs, the locale keys that moved, the removed
  deprecations, and the RLS re-sync (`GENERATOR_VERSION` 7).
  <!-- pin: docs/migration-guide.md#upgrading-to-015 -->
- Every `run` and `file=` block of README.md and docs/*.md executes in a generated Rails 8.1 app (`bin/rails generate
  authentication` + a scaffold `Customer`, PermissionForge installed by the README's own install lines) on every test
  run, one console per document, with `# => literal` comments asserted; the denial flows of "Handling Denials" (a
  Turbo sign-in with no Permission Set, Reload, Sign out, the public index with and without `resume_session`, the
  sign-in page under the guard, README step 4 after an admin-made set, seeds under `:strict`) are driven as requests,
  and in Chrome with Turbo in the `browser` CI job (`test/browser/docs_flows.spec.js`).
  <!-- pin: test/permission_forge/docs/doc_samples_test.rb#every run and file= block of the documentation executes in the docs app, and every literal # => claim holds -->
- [Handling denials](docs/row-level-rules.md#rescuing-them-yourself): the denial handler lives in one place, the
  complete `app/controllers/application_controller.rb` of a Rails 8 authentication-generator app;
  `docs/controller-actions.md` points to it. It renders `errors/forbidden` in the app's layout (with Sign out) and
  sends to sign in only a visitor with no session — never to the refused page (`redirect_back` looped on a refused
  root; a Turbo sign-in ending on a bare 403 reloaded into an empty form). `resume_session` ahead of the guard is
  required on a guarded public action; the `SessionsController` sample is the generator's file plus one `new` line.
  All of it is `file=` blocks the docs app applies.
  <!-- pin: test/permission_forge/docs/doc_blocks_test.rb#the five handler versions the rounds went through are refused -->
  <!-- pin: docs/row-level-rules.md#rescuing-them-yourself -->
- `permission_scoped` / `find_by` apply the row-level rules only: the resource's CRUD flags are the guard's (REST
  actions → flags) or your own `can_read?` check; documented with a driven scenario (a set with a rule and no read:
  rows answered, the page refused).
  <!-- pin: test/permission_forge/docs/doc_samples_test.rb#every run and file= block of the documentation executes in the docs app, and every literal # => claim holds -->
- README Installation and the getting-started guide mount the admin UI and set its credentials; without them there
  is no admin to open. The README Quick Start defines the `user` it assigns, says to run step 4's lines in order (a
  failing `create!` first), and step 5 looks up the person step 4 assigned instead of `User.first`.
  <!-- pin: README.md#installation -->
- The initializer template, README and guides no longer call `controller.current_user` / `controller.current_admin` in
  the authorization examples, which Rails 8's generator does not define (a 500 on the default base controllers):
  they use `PermissionForge.current_user`, and the `audit_actor_resolver` examples show a Rails 8 and a Devise variant
  for HTTP Basic auth.
  <!-- pin: README.md#1-tell-it-who-is-signed-in -->
- [Admin UI](docs/admin-ui.md#rails-8-authentication-generator): with Rails 8's generator as `base_controller_class`, a
  signed-out visit was a 500 (`new_session_path` does not resolve inside the engine); a complete admin base controller
  that redirects through `main_app` and checks for an admin. "API-only applications" sections in the admin UI and
  admin API guides.
  <!-- pin: docs/admin-ui.md#rails-8-authentication-generator -->
- [Controller actions](docs/controller-actions.md#callback-order): the user must be resolved before the guard and any
  model read; an action opened with `allow_unauthenticated_access` needs `prepend_before_action :resume_session`.
  <!-- pin: docs/controller-actions.md#callback-order -->
- [Configuration](docs/configuration.md#how-people-are-labelled-and-searched): how people are labelled, which columns
  are searched in SQL, and that an Array-returning `user_list_resolver` is searched in Ruby and loads every user.
  <!-- pin: docs/configuration.md#how-people-are-labelled-and-searched -->
- [Configuration](docs/configuration.md#where-warnings-appear), Where warnings appear: the one channel policy of
  every boot and configuration warning.
  <!-- pin: docs/configuration.md#where-warnings-appear -->
- [Admin API](docs/admin-api.md#response-format): a flat JSON body is accepted where Rails wraps parameters (only an
  empty, missing or non-object section answers 422); the collection sample shows `meta.pagination`; the condition
  shapes and their 422; the `RecordNotUnique` 422.
  <!-- pin: docs/admin-api.md#response-format -->
- [Admin API](docs/admin-api.md#who-the-audit-log-names-for-an-api-change): why API changes read "API client" even
  from a signed-in browser (the default `api_base_controller_class` runs none of your sign-in, so `Current.user` is not
  set), and the two ways to name the caller: an `api_base_controller_class` that resumes the session, or an
  `audit_actor_resolver` that maps the credential `api_auth` verified (never a caller-chosen header).
  <!-- pin: docs/admin-api.md#who-the-audit-log-names-for-an-api-change -->
- [Admin API](docs/admin-api.md#permission-set-group-users-group-membership--grants-nothing): the group-member
  endpoints say that membership is organisational and grants none of the group's sets.
  <!-- pin: docs/admin-api.md#permission-set-group-users-group-membership--grants-nothing -->
- [Admin API](docs/admin-api.md#disabling-the-api-entirely): while `api_enabled` is off the empty 404 (not the JSON
  envelope) is deliberate: it does not reveal that the API exists.
  <!-- pin: docs/admin-api.md#disabling-the-api-entirely -->
- [Assignment expiration](docs/assignment-expiration.md#rake-task-stale-assignments): `rake
  permission_forge:stale_assignments`, its `THRESHOLD_DAYS`, its output and its exit status 1 when it finds stale
  assignments.
  <!-- pin: docs/assignment-expiration.md#rake-task-stale-assignments -->
- [Getting started](docs/getting-started.md#wiring-a-scaffold): `as_json` leaves out a field with a Hidden row, but a
  column with no row is serialized as `null` under the default `unconfigured_field_strategy = :block`; how to give
  every column a row. The jbuilder example's `only:` keeps the scaffold's columns, and the scaffold's HTML partial
  skips the fields the user may not read (a helper on `field_permissions`). `ResourceFieldGenerator` without
  `grant_all` leaves every column Hidden, `created_at` / `updated_at` and the personal-data columns included; only
  `grant_all` makes the timestamps read-only.
  <!-- pin: docs/getting-started.md#wiring-a-scaffold -->
- [Getting started](docs/getting-started.md#using-rails-8s-authentication-generator): the symptoms of a guarded
  sign-in page (the 403 page where the form should be, also after Sign out) and of a public action without
  `resume_session`; steps 5 and 6 look up the person they assign by email instead of `User.first`, which may be
  someone holding no set; a seed's `find_or_create_by!` run with nobody signed in creates a duplicate on every run
  under `config.preset = :strict` (also in the generated initializer's comment).
  <!-- pin: docs/getting-started.md#using-rails-8s-authentication-generator -->
- [Field filtering](docs/field-filtering.md#telling-the-user-what-was-not-saved): an unchanged form posts every field
  back, so "Not saved: …" named every field the user may not edit; the form renders such fields disabled (not
  submitted) and leaves out the ones they may not read.
  <!-- pin: docs/field-filtering.md#telling-the-user-what-was-not-saved -->
- The generated initializer, README and [Presets](docs/configuration.md#presets): `config.preset = :strict` does not
  close every fail-open default. `masked_attributes_nil_user_strategy` stays `:bypass` (the audit keeps reporting
  `masked_nil_user_bypass`), and the checklist rows that need your code are in no preset.
  <!-- pin: docs/configuration.md#presets -->
- [filter_parameters_integration](docs/configuration.md#filter_parameters_integration) and the GDPR guide: the patterns
  filter every `name` parameter in the app's request logs, the admin's own forms included; how to narrow them. While
  on, the columns `filter_parameters` name count as personal data for the presets, Sync, the audits and the boot
  warning.
  <!-- pin: docs/configuration.md#filter_parameters_integration -->
- [Activation conditions](docs/activation-conditions.md#ip-range-restrictions): IP lists (entries, separators, arrays
  through the API, refusal of entries that are not addresses, normalisation), hour windows (both hours or none;
  `start == end` refused; what a broken stored window does) and the model methods (`allowed_ip_list`, `hours_window`,
  `condition_problems`); [Security audit](docs/security-audit.md): the `conditions` check rows.
  <!-- pin: docs/activation-conditions.md#ip-range-restrictions -->
- [I18n](docs/i18n.md#your-models-and-columns-in-the-admin): what "fully internationalized" means and how it is
  proven; translating `activerecord.models` / `activerecord.attributes` per locale for the admin's labels, else the
  row's label, else the stored name in code; [Column Defaults Are English](docs/i18n.md#column-defaults-are-english)
  (the install migration's defaults, the admin never pre-fills them, the blank-message denial, the one-liner for
  existing rows); the locale-file lints for contributors; the `denials` and `validations` key families.
  <!-- pin: docs/i18n.md#your-models-and-columns-in-the-admin -->
- `rake permission_forge:erasure` is documented with `USER_ID`, `DRY_RUN`, `ACTOR` and `REASON`
  ([GDPR data handling](docs/gdpr-data-handling.md#running-checks-without-claude)), and `rake
  permission_forge:rls:remove` by its full name next to `rls:sync` and `rls:status`
  ([Query scoping](docs/query-scoping.md#how-the-policies-work)).
  <!-- pin: docs/query-scoping.md#how-the-policies-work -->
- The wave-1 docs of this release applied: [Using the wrong field name](docs/row-level-rules.md#using-the-wrong-field-name)
  and the other rule problems (unknown operators and mask strategies, NUL bytes, values the column cannot hold —
  refused on save, matching nothing when stored), activation conditions, variants and the merge logic, the cache scope
  every operation reports, the `RecordNotUnique` 422, the pagination rule, the raw reader table of masked attributes,
  and phone width.
  <!-- pin: test/permission_forge/docs/references_test.rb#every relative link and anchor in the docs resolves -->

## [0.14.1] - 2026-10-14

### Security

- **The admin screens and the API keep checking the CSRF token on Rails 8.2.** Rails 8.2 can verify a request by the
  browser's `Sec-Fetch-Site` header, and `config.load_defaults 8.2` selects `:header_only`, under which a plain-HTTP
  request without that header is not checked at all. The engine's controllers now always use
  `:header_or_legacy_token`: the header decides when the browser sends it (a cross-site request is refused), and
  without it the token is required, as before. One change on Rails 8.2 the engine cannot avoid (Rails accepts it under
  both strategies): a request the browser marks `Sec-Fetch-Site: same-site`, which includes a page on another subdomain
  of your site, passes without a token. Rails 7.1 to 8.1 are unaffected.

### Fixed

- **On Rails 8.2 (main), a Redis that cannot be reached no longer counts as a done invalidation.** Rails 8.2's
  `RedisCacheStore#write_multi` answers the same value whether Redis took the entries or not, so an edit to a Permission
  Set whose holders are invalidated in bulk (two `write_multi` calls per 500 holders) was taken as confirmed while Redis was
  down: nothing was retried, owed or reported through `on_cache_failure`, and the holders kept their cached permissions
  until `cache_ttl`. A batch now counts as written only when the store also handed no error to its `error_handler`
  meanwhile; Rails 7.1 to 8.1 already answered `nil` for it. PermissionForge puts a wrapper in front of the
  `error_handler` of a store it writes a batch to: your handler is still called for every error, with the same
  arguments. The number of Redis round trips does not change.

## [0.14.0] - 2026-10-14

This release closes the findings of a pre-release security review. Several defaults change: each is listed under
**Changed** with its opt-out, and [Upgrading from 0.13](#upgrading-from-013) lists what to check. No migration is needed.

### Security

- **Conditional permission sets are evaluated for the request that reads the permissions.** A set gated on a
  session flag (MFA), an IP allowlist or login hours was evaluated once, when the user's hash was built, and that
  hash was cached per user: for up to `conditional_set_cache_ttl` every other session, IP or job of the same user
  got the grants (or the lockdown) of whichever request built it. The cache now keeps one base entry per user (the
  unconditional sets, plus the user's conditional sets and their conditions) and one variant per combination of
  conditional sets a request context selects, in a slot of the base key (`<key>_c_<1..63>`); every read evaluates the
  current context. A variant is verified against the user's invalidation stamp when it is stored and, on every read,
  against the base entry it was built for (`variant_of`: a digest of the base entry's token and the set ids), so an
  invalidation removes only the base entry: the variants it leaves can no longer be read and expire with
  `conditional_set_cache_ttl`. `DataSubjectErasure` removes every slot of the person's keys (the variants hold the
  profile), and `rake permission_forge:cache:clear` removes them too, found through a small index entry
  (`<key>_c_index`) written before a variant is stored.
  `permissions_hash` keeps its format, and a user without conditional sets costs what it did (one store read, no
  resolver call).
- **Strict mode keeps conditional Muting Permission Sets.** With `conditional_sets_strict_mode` and no request
  context (the resolver returns nothing, or neither an IP nor session flags: a job, the console), conditional
  *muting* sets now still apply and only conditional *granting* sets are dropped. Before, both were dropped, so a
  missing context removed a lockdown. With a request context, a conditional muting set whose condition cannot be
  judged also applies in strict mode: an IP allowlist when the request has no IP (a proxy that strips it), a session
  flag when the context has no `:session_flags` at all. Granting sets are unchanged.
- **Masked in one set and Hidden in another no longer unmasks.** A field Masked in one Permission Set and Hidden
  (read off) in another was merged as readable and unmasked, in either order: getters, `as_json` and
  `FiltersResponseAttributes` returned the plaintext. Only rows that grant read now decide the mask and its strategy;
  a Hidden row never votes. The admin's Effective Access uses the same merge (`FieldPermissionMerger.merge_row`).
- **STI subclasses obey their base class's Resource.** A subclass of a protected model (`VipCustomer < Customer`)
  looked up a Resource by its own name only, so `find_by`, `permission_scoped`, auto-scoping and `has_many`
  traversal returned rows the `Customer` rules deny, and its fields were unconfigured. `PermissionForge::ResourceChain`
  now resolves a class to its own Resource entry and every ancestor's up to `base_class`: the rules of all of them
  apply; a `view_all`/`modify_all` bypass skips only the rules of the entry that grants it; a field is as closed as the
  strictest entry that configures it, and an entry that does not grant read hides every field the chain configures.
  Only single-table inheritance forms a chain. Rules on a Resource named after a subclass apply to queries through
  that subclass, not through the base class, and are not part of the RLS policy (reported in `skipped_rules`).
- **Muting a Resource's read hides its fields.** A Muting Permission Set that revoked read on a resource left every
  field readable through getters, `as_json` and the response filter. Fields of a resource whose read is muted are now
  forced to `read_access: false, edit_access: false`, including variants and implicit virtual fields; this also
  blocks them on create through `PermitsAttributes`. Muting a resource's edit still mutes only the flag. A muting
  field row that mutes read now mutes edit too (the API could write a row with `read_access` alone, which hid the
  field but left it writable). A muting resource row naming an STI base reaches the entries of its subclasses the
  person holds (CRUD flags, View All / Modify All, actions and field rows), so `can_*?` and the controller guard on
  `VipCustomer` follow a muted `Customer`; a row naming a subclass reaches that subclass alone.
- **`PermitsAttributes` fails closed on shaped values and nested payloads.** A non-editable key whose value was a
  Hash or an Array of Hashes (a json column, or `email: { name: 'x' }`) was kept when an inner key matched an editable
  parent field, and a nested payload for a child model the user was never granted was filtered against the parent's
  fields. Now a key the user cannot edit is dropped whatever its value; only `<assoc>_attributes` for an
  `accepts_nested_attributes_for` association recurses, record by record, against the child model's own Resource; a
  child model absent from the user's permissions drops the payload (see `nested_attributes_parent_fallback` under
  Changed); non-record elements are dropped. A nested record keeps its `id` only when the id names a row the child
  model's row-level rules let the user reach (one query per payload); otherwise the whole record is dropped. A child
  model without `PermissionScopedFindable` is left to Rails.
- **The JSON API's CSRF check runs before `api_auth`.** `protect_from_forgery with: :null_session` ran after the
  authentication callbacks, so a cross-site form post carrying an admin's cookies was authenticated against the real
  session and its change went through. The check is now prepended: a forged request reaches `api_auth` with an empty
  session and cookie jar. Token or header authentication is unaffected. If your `api_base_controller_class` declares
  `protect_from_forgery with: :exception`, the API controllers use `:null_session` instead, and same-origin
  JavaScript that relies on the session must send `X-CSRF-Token`. `:null_session` does not empty the raw `Cookie`
  header, identities computed by middleware, or browser-cached HTTP Basic credentials (see `docs/admin-api.md`).
- **The admin and the API reach people by id only within `user_list_resolver`.** A person the resolver leaves out
  (for example another tenant's user) is now not found (404) on the person page, erasure, assignment, restore, group
  membership, bulk assignment and the API's assignment endpoints, and on every path that takes an assignment or
  membership id (end date, Keep, Remove, Undo, removing a group member, the API's `DELETE …/users/:id`). Lists of a
  set's holders still show every holder.
- **The `is_editable` lock covers what a record holds.** The API checked only the record's own flag, so children of a
  locked Permission Set or Resource could be created, changed or deleted, and holders added. A locked Permission Set
  now gains no resources, fields, rules, actions or holders; a locked Resource keeps its fields, rules and actions; a
  locked Permission Set Group keeps its name, members and list of sets. Refusals are 403 / an alert, recorded as
  `admin.lock_refused`. Narrowing access is always allowed and widening it is refused, in the direction the set
  works (`Admin::EditableLock.widens_access?`): on a granting set holders can be removed and end dates set or moved
  earlier; on a Muting Permission Set holders can be added and end dates cleared or moved later, and "Remove all
  access" keeps a person's locked muting sets and says so. The group page cannot move a set out of a locked group,
  and saving a set leaves the fields of a locked Resource as they are.
- **Auto-applied masking reaches every process.** `MaskedAttributes` was mixed into a model only in the process that
  committed its first `Resource` row (and at boot); other web and job processes served its columns unmasked until
  restarted, and a development code reload dropped it. The committing process now writes a token to the cache store,
  and every process checks it at the start of each request or job (one store read; the Resource names are re-read only
  when it changed). Renaming a Resource to a new model is covered. This needs a shared cache store: under `:memory`
  or a null store other processes pick a new model up at their next boot. The token is written with no expiry (also
  under a store-wide `expires_in`), and a process that finds none writes a new one, so an evicted token costs one
  query per process, never a model left unmasked. Two rows for a new model committed together announce it. When the
  store does not answer, a process stops reading it for 30 seconds (then one request per process probes it) and logs
  once per outage; a token the store did
  not take is written once it answers again, and a store that raises never makes the `Resource` save raise. A model
  whose table cannot be read when masking is applied is no longer left unmasked silently: it is logged with a
  SECURITY warning and retried at each request or job.
- **RLS `view_all` bypass respects `Resource.is_active` and the row's tenant** (PostgreSQL, opt-in). Deactivating a
  view_all row stopped the application's bypass but not the policy's, and a view_all grant in one tenant bypassed the
  rules on every tenant's rows. The bypass now requires an active resource row and, with tenancy on, one in the row's
  tenant (a row with no tenant gets no bypass), and a rule set applies only while its resource row is active, read live
  by the policy. `RlsPolicyGenerator::GENERATOR_VERSION` is 5: existing installs see a drift warning until they run
  `rake permission_forge:rls:sync`.
- **`inspect` and `pretty_print` show what the getters return.** A masked record in a log line, an error report or a
  console printed its masked and hidden values in full. They now go through the field guard (Rails 7.1 to 8.1), are not
  audited reads, and never raise: a read, or Rails' formatting of the value, that fails shows the hidden value.
  `*_before_type_cast`, `*_in_database`, `attributes_for_database`, the dirty-tracking helpers, `Marshal`, `pluck` and
  SQL aliases still read raw values (documented).
- **A declared virtual field is editable only when the resource grants edit.** Under
  `extra_fields_default_access = :grant`, a read-only user could write a declared extra field. The implicit entry
  now follows the resource's `read_access` and `edit_access`.
- **The data-subject erasure's audit-label scrub stays in the current tenant.** With a tenant set (the admin UI), a
  tenant admin could clear a person's name labels in every tenant's audit log. With no tenant set
  (`rake permission_forge:erasure`) it still covers every tenant.
- **Destroying a user removes their assignments and memberships in every tenant**, each through its callbacks
  (audited, cache invalidated). Rows in other tenants stayed behind with a `user_id` that a reused id could inherit.
- **`ExpiredAssignmentCleaner` re-reads each assignment under a row lock** before destroying it; an assignment
  renewed while the clean-up ran was deleted anyway.
- **A host `User` method can no longer replace one of the gem's private helpers.** A user model with its own
  `read_permissions` or `context_hash` (two of 33 unprefixed private names the `PermissionedUser` concerns added)
  replaced the gem's: cache hits could raise, or an MFA-gated Permission Set applied without the flag. The same held
  for `guard` and `hidden_attribute?`, which `MaskedAttributes` added to every protected model. Every private method
  the gem adds to a host model now starts with `pf_`, and guard tests keep it so (see Changed).
- **Admin preference cookies (`pf_theme`, `pf_help`) are `Secure` when the admin is served over HTTPS.**
- **Crafted input answers 4xx instead of 500.** A String where a form section is expected, a Hash where an id or a
  tab is, out-of-range pages, ids and dates, NUL bytes in text or attribute hashes, blank names, and a backslash or
  control character in `return_to` are refused (400/422) or ignored. An unreadable `expires_at` is refused instead of
  creating a permanent assignment.
- **Nothing a request left set in the gem's per-execution state can reach the next request on the same thread.** At
  the end of every executor run (request, job), whatever the run added to `PermissionForge::ExecutionState` (the
  `without_permission_scope` flag, re-entrancy guards, masking escape hatches, the audit context) is removed, and
  nothing is ever written back. The scoping and masking flags stay per fiber under every `isolation_level`: an
  Enumerator paused inside `without_permission_scope` never leaves the rest of the request unscoped.
- **The getting-started guide no longer suggests a thread-local user.** Its `current_user_resolver` example read
  `Thread.current[:current_user]`, which nothing clears between requests on a reused thread: a request that did not
  set it (unauthenticated, an error path, a job) resolved the previous request's user and got that user's
  permissions. The guide now uses `ActiveSupport::CurrentAttributes` and says why. If you copied the old example,
  change it.

### Changed

- **Cache keys move to the `v2:` namespace** (`pf:v2:user_<id>`, `pf:v2:tenant_<t>_user_<id>`, variants
  `…_c_<1..63>`; `Cache::UserKeys`), and `user.permission_cache_key` returns the new key. An invalidation
  also removes the 0.13 keys (until 0.15), but a 0.13 process cannot reach a 0.14 entry: see step 1 of
  [Upgrading from 0.13](#upgrading-from-013).
- **`request_context_resolver` runs on every permission read of a user who holds a conditional set.** It must be
  cheap, return `{}` (or anything with `#to_h`) where there is no request (a resolver that raises there raises on
  every such read), and must not read the permissions of the user it resolves for (a masked attribute of the
  current user, a `can_*?`): such a read raises `PermissionForge::ConfigurationError`.
- `regenerate_permissions` builds the base entry and, when the request context selects conditional sets, the
  variant, and returns the hash for the current context. The raw entry under `user.permission_cache_key` is the base
  (unconditional sets) plus `:conditional_sets` for a user who has any.
- A user who holds more than 6 conditional sets (`ConditionalSets::MAX_CACHED_SETS`) has the per-context variants
  built per request and kept on the instance, never cached: one rebuild per request for that user.
- **The strategy options are validated when set**: `nil_user_strategy`, `response_filter_nil_user_strategy`,
  `masked_attributes_nil_user_strategy`, `masked_write_protection`, `action_guard_nil_user_strategy`,
  `admin_tenantless_access`, `unconfigured_action_strategy` and `extra_fields_default_access`. A String is taken as its Symbol (`'block'` is
  `:block`) and any other value raises `ConfigurationError` in the initializer. Before, a String was read as an
  unknown value: `response_filter_nil_user_strategy = 'block'` meant `:bypass`, and `nil_user_strategy = 'raise'`
  meant `:bypass` in `find_by`. The other options' unknown values failed closed; they now raise instead.
- **`api_require_authorization` defaults to `true`.** Until both `api_action_authorization` and
  `api_assignment_authorization` are set, API changes and assignments are refused (403, `api.auth_failed`). Opt out
  with `config.api_require_authorization = false` (the boot warning and `rake permission_forge:audit` still report it).
- **With `tenant_model` set, admin and admin API requests that have no current tenant are refused (403)**, recorded as
  `admin.auth_failed` / `api.auth_failed` with reason `tenant_missing`. Set the tenant in `base_controller_class` /
  `api_base_controller_class` (or middleware). Opt out with `config.admin_tenantless_access = :allow`: tenant-less
  requests then read, change and delete existing records of every tenant; creating a record still needs a tenant.
  A boot warning and the audit finding `tenantless_admin` flag tenancy with a default `ActionController::Base` base.
- **`nested_attributes_parent_fallback` defaults to `false`.** A `<assoc>_attributes` payload for a child model the
  user has no Resource entry for is dropped. `true` filters it against the parent's fields instead (not recommended;
  reported by `rake permission_forge:audit` as medium). The other `PermitsAttributes` changes above apply either way.
- **The private helpers the gem adds to host models are `pf_`-prefixed** (`PermissionedUser`'s 33, for example
  `pf_read_permissions`, `pf_context_hash`, `pf_invalidation_stamp_key`; `MaskedAttributes`' `pf_guard`,
  `pf_guarded_user`, `pf_hidden_attribute?`, `pf_guard_attributes_hash`). A host override of a former name
  (`invalidation_stamp_key`, `resource_permissions`, `context_hash`) no longer takes effect: override the public
  methods (`permissions_hash`, `regenerate_permissions`, `invalidate_permissions`, `permission_cache_key`) instead.
  `active_non_expired_permission_sets` stays as a private alias until 1.0.
- **`PermitsAttributes` keeps a nested record's `_destroy` when the user may delete the child model**: the
  `delete_access` of the entry that model answers to (its own, or its nearest STI base's when it has none; the
  parent's under `nested_attributes_parent_fallback`). It used to drop `_destroy` for every user. Without that access
  it is dropped and reported in `params.filtered` as `<assoc>_attributes.*._destroy`; a record whose `id` the child's
  rules deny is still dropped whole.
- **`NotAuthorizedError#message` (and `to_s`, `full_message`) is always a String**: the rule messages joined by
  `', '`, the `:message` of a Hash, or the class name. Read the structured value from `#details`. An error built with
  keywords only (`new(user:, record:)`) reads as the class name, so the user's `inspect` never reaches the message.
- `config.user_list_resolver` is the boundary of the people the admin and the API can reach by id, not only the
  picker list. The default resolver lists every user, as before.
- Permission Set, Permission Set Group, field and action names must not be blank when a row is created or renamed
  (422 in the API). Rows already blank stay editable in their other attributes. Blank names returned by
  `extra_fields_for_permissions` are skipped (and logged) when fields are generated.
- A Permission Set's group id must name an existing group of the current tenant.
- `api_assignment_authorization` receives `user_ids` as an Array cast to the user key's type (Integers for integer
  keys) on every endpoint.
- The API's `POST /permission_sets/:id/clone` makes an editable copy (editable rows), outside a locked group, like
  the admin's Duplicate. Cloning or duplicating a Permission Set Group makes an editable group whose copied sets and
  rows are editable too. Clone names that are not text fall back to "<name> (Copy)".
- A permission-hash rebuild reads its rows in a fixed number of queries (7; 8 when an assignment names its grantor)
  instead of about four per resource (10 sets with 20 resources each: 828 queries before).
- The holders of a changed Permission Set are invalidated by id, in slices of 500, with one multi-key stamp write
  and one multi-key removal per slice and no read (`Cache::Base#write_many` / `#expunge_many` / `#delete_many`;
  `RailsCache` uses the store's `write_multi` where it has it: Redis pipelines it, Solid Cache writes one statement).
  For 10,000 holders on local Redis this is 40 round trips and about 0.45–0.55 s, whatever the size of their cached
  hashes and the number of conditional sets they hold, instead of 40,000 to 50,000 round trips. The per-user path
  (`User#invalidate_permissions`) is still used when the user model overrides `invalidate_permissions`,
  `permission_cache_key` or the private `pf_invalidation_stamp_key`, when something subscribes to
  `permissions.invalidated`, or inside a snapshot transaction. A delegating wrapper around the cache backend must
  forward these methods' blocks (they carry errors into the failure report).
- A permission hash merges resources, fields, actions and rules in id order (sets keep `created_at, id`). Before,
  rows within a set came in query-plan order. Only ties can change: when two fields map to one variant (`customer_id`
  and `customer_uuid`) the older row's `mask_strategy` wins on every database (on SQLite it was the alphabetically
  first), and the order of keys, rules and actions in the hash may differ. Snapshot tests of the JSON may need
  updating.
- `BulkPermissionSetAssignment` invalidates each assigned or revoked user once, after the commit. `invalidated`
  counts only users whose assignment changed, and is `nil` when the call runs inside a caller's transaction.
- A cache store that raises (no failsafe) during a rebuild no longer makes `permissions_hash` raise: the request uses
  the hash it built and nothing is cached. A store that raises on a plain read still raises.
- `rake permission_forge:erasure` says what it removes and what it keeps.
- Internal APIs: `ExtraFieldDefaults.call` takes `entry:` instead of `fields:` (`IMPLICIT_ENTRY` is replaced by
  `ExtraFieldDefaults.implicit_entry(permissions)`); `AttributeAccessGuard.call(resource_name:)` accepts the chain of
  names a class answers to; `RlsPolicyGenerator#call[:skipped_rules]` gains reason `:sti_subclass_resource`;
  `Engine.apply_masked_attributes_to_managed_models` returns `true`/`false`.
- Documentation: the README has a production hardening checklist of every default that fails open and how to close
  it, and the guides no longer claim more than the code does (the API's CSRF protection, `user_active_check`, which
  does not remove access, `on_erasure` timing, RLS outside the application, which `find_by` calls apply rules,
  resource CRUD flags, which are enforced where you call `can_*?` or use `ControllerActionGuard`, rules across sets,
  which intersect, log parameter filtering, which is on by default, the benchmarks' Redis/Oj claims, and the
  compliance guides).

- **The models live in `app/models/permission_forge/` and are autoloaded by your application** (previously
  required by the gem at `require` time). They read the configuration when they load, right after
  `config/initializers`, so `config.user_class`, `config.audit_user_class` and `config.tenant_model` apply without
  any re-declaration; in development they reload with your code. Configure PermissionForge in `config/initializers`:
  a setting changed later (in `after_initialize`, a console) does not reach a class that has already loaded (in
  production every class, eager-loaded at boot) and PermissionForge logs a warning naming the setting and the
  classes.
  - A `PermissionForge::...` model cannot be referenced before the application has booted: not from the top level
    of a file in `config/initializers`, an engine or railtie initializer, or a file required from
    `config/application.rb` (the boot fails with a `NameError` that says so). There, `defined?(PermissionForge::Resource)`
    and `safe_constantize` answer `nil`. Reference a model from a method (a model, controller, job or rake task).
    To change a class (include a module, add a callback), use `Rails.application.config.to_prepare` or
    `Rails.autoloaders.main.on_load('PermissionForge::PermissionSet') { |klass, _| ... }`, which run again after every
    code reload; `config.after_initialize` runs once, so a change made there is lost at the first reload in
    development: use it only to read.
  - Outside a Rails application, `require 'permission_forge'` no longer defines the model classes.
- **`ActiveRecord::Base` now loads after your `config/initializers`, as Rails intends.** Before, the gem loaded it at
  `Bundler.require`, so `config.active_record.*` settings made in an initializer (including every
  `config.active_record` value in `config/initializers/new_framework_defaults_*.rb`, such as
  `belongs_to_required_by_default` and `partial_inserts`) were silently ignored, and `config.filter_parameters`
  never reached `ActiveRecord::Base.filter_attributes`. They now take effect: check them before upgrading.
  Consequence you will see: attributes matching `config.filter_parameters` print as `[FILTERED]` in `#inspect`,
  `pretty_print` and error reports. With the default `gdpr_defaults` and `filter_parameters_integration` that
  includes the GDPR patterns, so `name`, `email`, `first_name`, `phone`, `address`, `city`, … of every model,
  PermissionForge's own `name` columns included (`#<PermissionForge::PermissionSet ... name: [FILTERED]>`). To keep
  them visible in the console, set `config.filter_parameters_integration = false` or narrow `config.filter_parameters`.
- PermissionForge's associations state `optional:` explicitly and no longer follow `belongs_to_required_by_default`:
  an assignment needs its user and every permission row needs its tenant (when tenancy is on) whatever that setting
  says; the parent associations stay optional, as before (the foreign keys hold). Only a host that set
  `belongs_to_required_by_default = false` sees a difference: a user-less assignment or a tenant-less row is now
  refused by validation.
- The default GDPR field patterns match the short stems `tel`, `city`, `dob`, `fax`, `mobile` and `zip` as a name
  segment (`home_tel`, `tel2`, `telNumber`, `city_name`, `cityName`, `zipcode`), not inside another word: `capacity`,
  `hotel_id`, `telemetry_enabled`, `automobile_id` and `gzip_enabled` are no longer masked by `gdpr_defaults`,
  reported by the GDPR audit or filtered from logs. A name that glues a stem to another word (`homecity`, `telno`)
  is no longer matched either: add what your schema needs to `config.gdpr_field_patterns`. `ethnicity` and
  `telegram_*`, which only matched by accident, now have a pattern of their own. The same patterns serve
  masking detection and `filter_parameters`, so both change together.
- `PermissionForge::RESOURCE_NAME_FORMAT` is the one definition of a Resource name (`Resource::NAME_FORMAT` and
  `ControllerActions::RESOURCE_FORMAT` point at it); `PermissionForge::MODEL_NAMES` lists the nine models.
- **Validators of a masked model judge the stored value of the attribute they validate.** Before, they read the
  masked getter: under `masked_attributes_nil_user_strategy = :hide`, `create!`/`update!` with nobody signed in failed
  "can't be blank", and a signed-in user who reads a masked or hidden column failed format or presence checks on any
  save, while uniqueness was checked against the mask. Only that attribute is read raw, only while the validators
  run; other getters and a custom `validate` block read masked. Errors still show what the user reads:
  `errors.details` values and `%{value}` are the masked value, or absent for a hidden column.
- **Inside `PermissionForge.without_permission_scope`, with nobody signed in, `find_by`, `find_by!` (so
  `authenticate_by`) and `permission_scoped` apply no rules whatever `nil_user_strategy` says** (before: `:deny`
  returned nothing, `:raise` raised). Reported as `rule.bypassed` (`scope_suspended`). The block is the host's
  explicit opt-out, so wrap trusted code only, never code an anonymous request reaches; a signed-in user's lookups
  still apply their rules. The gem's own scope suspensions (holders of an assignment, a cache clear, the record an
  audit event names) no longer count as the host's, and nobody signed in gets no bypass inside them.
- **`masked_attributes_nil_user_strategy = :hide` no longer hides the user model** (`user_class` and its subclasses)
  when nobody is signed in: authentication reads it before anyone is signed in, so with a Resource row for the user
  model nobody could sign in. Every other masked model still hides. The consequence: with nobody signed in the user
  model's columns, password digests included, read as stored, so do not render it with no current user
  (`permission_forge:audit` reports `user_model_unmasked_without_user`). `explain_all` reports
  `:no_user_user_model_exempt`.
- The install generator writes a short initializer (148 lines, was 430): `action_guard_nil_user_strategy = :deny`,
  `conditional_sets_strict_mode = true` and `cache_backend = :rails_cache` set, `config.preset = :strict` and
  `masked_attributes_nil_user_strategy = :hide` offered commented with what each costs, and the integration points.
  Every option stays documented in docs/configuration.md, and the library defaults do not change. Existing installs
  are not affected. A new install no longer assigns its own `ignored_fields` list, so it keeps the library's frozen one (`+=` works, `<<` raises).
- Auto-applied masking no longer reads the cache store at every request or job when `auto_apply_masked_attributes`
  and `mask_virtual_attributes` are each a list of models or off (before: one read per request or job), and
  committing a `Resource` row then writes no masking token; with both off the per-request check reads nothing.
  `:auto` is unchanged. The guides now recommend `include PermissionForge::Concerns::MaskedAttributes` in each model
  with `auto_apply_masked_attributes = false` in production.
- A name in an `auto_apply_masked_attributes` or `mask_virtual_attributes` list that is no model in the process is
  now logged as a SECURITY warning (once per name) and retried at the next request or job, instead of counting as
  masked.
- Internal APIs: `PermissionForge::Engine` only wires initializers and hooks; it no longer extends `BootChecks`,
  `MaskedModels` or `QueryScopingWarnings`. `Engine.try_apply_masked_attributes` / `try_mask_virtual_readers` are
  `MaskedModels.apply_concern` / `mask_virtual_readers`, `Engine.run_boot_checks` is `PermissionForge::BootChecks.run`,
  and `MaskingSync.named!` takes the "another row has this name" answer as a block.
  `Engine.apply_masked_attributes_to_managed_models` stays as a deprecated delegator (see Deprecated).
- The audit context set by `PermissionForge.with_audit_actor` (or `Audit::Context.with`) around code that runs an
  executor run (an inline ActiveJob in a console or rake task) is kept after that run. Before, it was emptied at the
  end of the run, and the changes after the job were recorded without the actor. A request or job still ends with an
  empty context.
- A cache failure reported in another fiber of the same thread (an Enumerator iterated with `next`) now counts for
  the `Cache::Failure` check around it, so such an invalidation is reported as unconfirmed instead of silently passing.
- `PermissionForge::RLS` no longer calls `ActiveRecord::Base.connection` (soft-deprecated from Rails 7.2; raises
  under `ActiveRecord.permanent_connection_checkout = :disallowed`). `with_user`, `sync!`, `remove!`, `drift_report`
  and `postgres?` use `connection_pool.with_connection` and give back a connection the thread did not hold;
  `set_user!` / `clear_user!` keep using the connection the thread keeps (`lease_connection`).
- `ControllerActions.guarded?` raises `ConfigurationError` when a controller's before_action chain cannot be read
  (`_process_action_callbacks`), instead of reporting the controller as guarded. The admin action catalog leaves such
  entries out (logged once); `SecurityAudit` then reports `action_guard_missing`.
- The `find_by` / `find_by!` override on models with `PermissionScopedFindable` finds its record with
  `where(...).take` instead of a relation's `find_by` (same query; no reliance on how Rails routes `Relation#find_by`).
- Admin UI: the field drawer, audit event and rule builder pages read from `Admin::FieldDetail`,
  `Admin::AuditEventDetail` and `Admin::RuleBuilder`; no admin markup is marked safe by hand (a test bans
  `html_safe`, `safe_concat`, `<%==` and `raw` in `app/` and `lib/`); `pf_admin.js` uses `const`/`let` and builds no
  markup from strings.

#### Upgrading from 0.13

No migration is needed. Check each item that applies to your app:

1. **Every app: clear the permission cache once.** When every process runs 0.14 and the last 0.13 process is gone,
   run `bin/rails permission_forge:cache:clear ACTOR="..." REASON="deploy 0.14"`. During a rolling deploy a 0.13
   process cannot invalidate a 0.14 entry, so a change made there could stay cached until `cache_ttl`; running the
   task earlier does not help, since a 0.13 invalidation after it would miss the new entries again. Every user's
   entries are removed (both versions', and the variants), by key pattern where the store can (Redis, memory, file)
   or user by user; the cache is cold afterwards, one rebuild per user on their next request. User by user (Solid
   Cache, Memcached), a user who had a per-context variant stored costs 64 more keys per cache key (10,000 such users
   took about 7 s on local Redis), and each removed key is written as an empty entry, which Solid
   Cache keeps as a row until it trims its table.
2. **JSON API enabled?** Set `api_action_authorization` and `api_assignment_authorization`, or API changes are
   refused with 403. To keep 0.13's behaviour, set `api_require_authorization = false`.
3. **Multi-tenant (`tenant_model` set)?** Make `base_controller_class` (and `api_base_controller_class`) a controller
   that sets the current tenant, or the admin answers 403. `admin_tenantless_access = :allow` restores 0.13's
   behaviour.
4. **Nested attributes through `PermitsAttributes`?** Give each child model its own Resource entry, or set
   `nested_attributes_parent_fallback = true`.
5. **Code reading `NotAuthorizedError#message` as an Array or Hash?** Use `#details`.
6. **PostgreSQL RLS?** Run `rake permission_forge:rls:sync` (with eager loading, so subclass rules are reported).
7. **Controllers using `ControllerActionGuard` with `nil_user_strategy = :bypass`?** Signed-out requests still pass
   mapped actions. New installs set `action_guard_nil_user_strategy = :deny`; consider setting it.
8. **Several app processes?** Use a shared cache store (`:rails_cache` over Redis, Memcached or Solid Cache) so
   auto-applied masking reaches every process.
9. **`PermissionForge::Cache::RedisCache` referenced?** It is removed; use `cache_backend = :rails_cache` with
   `redis_cache_store`.
10. **STI subclasses of protected models?** They now obey the base class's rules and fields; check that users who
    should read them still can.
11. **Conditional Permission Sets?** Check that `request_context_resolver` is cheap, returns `{}` outside a request
    and reads no permissions; consider `conditional_sets_strict_mode = true`.
12. **Anything in `config/initializers` (or an engine/railtie initializer, or a file `config/application.rb`
    requires) that names a `PermissionForge::` model at the top level?** The models are autoloaded after the
    initializers now, so the boot fails with a `NameError`. Move the code into `Rails.application.config.to_prepare`
    or `Rails.autoloaders.main.on_load('PermissionForge::PermissionSet')` (they run again after a reload, so keep
    them idempotent), or into a method. Configure PermissionForge only in `config/initializers`; a later change does
    not reach a loaded class and is logged.
13. **`config.active_record.*` in an initializer or in `new_framework_defaults_*.rb`?** It now applies (before it was
    ignored in an app with PermissionForge installed): check `belongs_to_required_by_default`, `partial_inserts` and
    the rest before deploying.
14. **`#inspect` shows `[FILTERED]`?** `config.filter_parameters` now reaches `ActiveRecord::Base.filter_attributes`,
    and the GDPR patterns are part of it. Narrow `config.filter_parameters`, or set
    `filter_parameters_integration = false`, if you need the values in a console. The patterns for `tel`, `city`,
    `dob`, `fax`, `mobile` and `zip` now match a name segment only: check your schema with
    `rake permission_forge:audit` and add what you lost to `config.gdpr_field_patterns`.
15. **Calling `PermissionForge::Engine.apply_masked_attributes_to_managed_models`?** It warns through
    `PermissionForge.deprecator` and is removed in 0.15: call `PermissionForge::MaskedModels.apply(only:)`. Other
    `Engine` helpers (`try_apply_masked_attributes`, `try_mask_virtual_readers`, `run_boot_checks`,
    `apply_tenant_scoping_to_models`, `rebind_configurable_associations`) moved or are gone (see Removed).
16. **Calling `PermissionForge::RLS.connection`?** It was undocumented and is removed.
17. **Models with `masked_attributes_nil_user_strategy = :hide`, or code under `without_permission_scope`?** Validators
    now read stored values; the user model is not hidden with nobody signed in; `find_by` / `permission_scoped`
    inside `without_permission_scope` apply no rules when nobody is signed in. Do not include
    `PermissionScopedFindable` in your user model.
18. **Large app?** Consider `config.preset = :strict` (the production hardening checklist in one line, see
    docs/configuration.md#presets) and, in production, `include PermissionForge::Concerns::MaskedAttributes` in each
    model with `auto_apply_masked_attributes = false` (no cache-store read per request).
19. **`current_user_resolver` reading `Thread.current[:current_user]` or a class variable?** Use
    `ActiveSupport::CurrentAttributes` (see Security above).

### Added

- `rake permission_forge:cache:clear` (`Services::PermissionCacheClearer`): removes every user's cached permissions
  in every tenant, by key pattern where the store can (verified by writing and reading back canary keys) or
  through the bulk invalidation of every user. Records one `cache.cleared` event per tenant plus one without a
  tenant. The cache is cold afterwards. On an in-memory store (`:memory`, `:memory_store`) it says that only its own
  process's store was cleared.
- `PermissionForge::ConditionalSets` and `Concerns::PermissionsPerContext` (per-context selection);
  `Cache::Base#read_many` (`RailsCache`: one `read_multi`), `#clear_entries` / `#purge_entries`.
- `PermissionSetConditionEvaluator` accepts an `IPAddr` as the request IP.
- `config.masked_attributes_nil_user_strategy` (`:bypass` default, `:hide`). With no current user, `:hide` hides
  every guarded attribute of a masked model (getters, `read_attribute`, `[]`, `attributes`, `as_json`, wrapped
  virtual readers and store accessors); the primary key and the raw paths are untouched. `rake
  permission_forge:audit` reports `:bypass` as `masked_nil_user_bypass` (medium), the Settings page lists it, and the
  generated initializer offers it commented, with the trade-off for jobs and mailers that read masked data.
- `config.action_guard_nil_user_strategy`: what `ControllerActionGuard` does for a mapped action when nobody is signed
  in (`nil` or blank follows `nil_user_strategy`; `:bypass`; `:deny`). The install generator sets `:deny`.
- `config.admin_tenantless_access` (`:deny` by default, `:allow`).
- `config.nested_attributes_parent_fallback` (`false` by default).
- `PermissionForge::ResourceChain`, the one resolver of the Resource entries a model class answers to;
  `MaskedAttributes.explain` reports it as `:resource_chain`.
- Audit-log data: `assignment.changed` carries `previous_subject_user_id` when an assignment moves to another user.
- `rake permission_forge:audit` findings `nested_parent_fallback` (medium) and `tenantless_admin`.
- `config.preset = :strict` closes the fail-open defaults of the Production hardening checklist in one line
  (`nil_user_strategy :deny`, `response_filter_nil_user_strategy :block`, `auto_query_scoping :filter_only`,
  `unconfigured_action_strategy :block`, `action_guard_nil_user_strategy :deny`, `conditional_sets_strict_mode true`,
  `mask_virtual_attributes :auto`, `extra_fields_default_access :unconfigured`, `cache_backend :rails_cache`) and keeps
  the closed ones closed. `:compat` (the default) is the library defaults. A setting you make yourself always wins,
  in any order. `masked_attributes_nil_user_strategy` is in no preset. `rake permission_forge:audit` prints the preset
  (also `preset` in `FORMAT=json`) and reports `strict_overrides`; the Settings page shows it.
- `PermissionForge.deprecator`, an `ActiveSupport::Deprecation` registered as
  `Rails.application.deprecators[:permission_forge]`.
- `rake permission_forge:audit` reports `user_model_scoped` (the user model includes PermissionScopedFindable under
  `nil_user_strategy :deny`/`:raise`: sign-in lookups find nothing) and `user_model_unmasked_without_user` (under
  `:hide` the user model reads as stored with nobody signed in).
- `@api public` / `@api private` markers on every class and module, a `.yardopts`, and `rake yard:check` in CI; the
  supported surface is now machine-readable (README, Versioning and stability).

### Deprecated

- `PermissionForge::Engine.apply_masked_attributes_to_managed_models`: use `PermissionForge::MaskedModels.apply`;
  removed in 0.15. From this release on, renamed or removed public API is listed here and warns through
  `PermissionForge.deprecator` for at least one minor version.

### Fixed

- **A user instance kept across requests stops granting at an assignment's `expires_at`.** It kept granting from an
  expired assignment until an invalidation in its process or `reload`; the memo is now retired at the soonest
  `expires_at` that went into it.
- **The maintenance services run tenant-less under `require_tenant = true`.** `ExpiredAssignmentCleaner`,
  `DataSubjectErasure`, `StaleAssignmentAuditor` and `ConsentWithdrawalHandler` raised
  `ActsAsTenant::Errors::NoTenantSet` when run without a tenant (the setting the tenancy guide recommends); they now
  lift the tenant scope for that run (`Services::Concerns::AcrossTenants`), like the purge and the cache clearer. The
  `cleanup.expired_assignments` and `consent.withdrawn` summaries of such a run are written in each tenant concerned
  (its counts and sets) and once without a tenant (the totals), with `across_tenants: true`.
- **An unusual `Accept` header on a failing admin form was a 500** (a missing template, for example
  `Accept: application/json` on `POST /assignments`). The admin answers HTML unless the action has that export.
- **The missing audit table warning names the right step.** A fresh install booted before `db:migrate` was told to
  run `permission_forge:upgrade` (which would duplicate migrations); it now says `bin/rails db:migrate`, and names the
  upgrade generator only when no migration of the gem creates the table.
- **`attributes` keeps the primary key.** Under `unconfigured_field_strategy = :block` the guarded `attributes`
  hash left out `id`, though `read_attribute` and `as_json` never guard it.
- **`PermissionForge.cache.clear` removes only the gem's keys.** On the memory and file stores the `"pf:*"`
  String became an unanchored pattern that removed any key containing "pf" (a host's `apfx_session`), and on a
  store with its own `namespace:` it raised `NoMethodError`. It now uses `/^pf:/` there (Redis keeps the glob).
- A user cached by 0.13 with Active Record's 6.1 marshalling format (its memo is an Array) is read from the store
  again instead of raising.
- **The app boots when the database cannot be reached** (a Docker build running `assets:precompile`, a deploy during
  a failover). On Rails 7.2+ the boot checks raised `ActiveRecord::DatabaseConnectionError`. They now ping the
  database once and skip the steps that read it, with one log line; masking is applied at the first request or job
  that reaches the database.
- **The generated initializer works without a `Current` class.** `current_user_resolver` reads `Current.user` only
  when `Current` exists and answers `user`; apps without one raised `NameError` on every permission check. The
  generated `profile_builder` keeps `uuid`, as the hash contract says.
- **A user model without a `uuid` column** no longer makes `permissions_hash` raise once an assignment was made by a
  signed-in admin (`audit_trail_enabled`): `permission_set_granted_by` / `_updated_by` hold the user's uuid when it
  has one, else its id.
- **A string longer than its column is a validation error (422), not a 500 on MySQL.** Only a Permission Set's name
  had a length rule; MySQL in strict mode raised `ActiveRecord::ValueTooLong` for the other strings the admin and the
  API write. Each permission model (`Concerns::ValidatesColumnLengths`) checks the attributes being written against
  the limit their column declares (characters for a string column, bytes for a text column). A column that declares
  no limit (a `string` on PostgreSQL or SQLite) is not checked, and a longer value stored before does not block edits
  to the row's other attributes.
- `DataSubjectErasure(on_erasure:)` called inside a transaction runs the callback after that transaction commits, and
  never after a rollback. `callback_invoked` is then `nil`, and an error the callback raises is reported through
  `Rails.error` and the log.
- Moving an assignment to another user invalidates the previous holder's cached permissions too. A resource, field,
  action or rule moved to another set or resource invalidates the holders of every set it left in the transaction,
  also after a savepoint rollback or when another instance of the row commits.
- A purge run with no tenant set writes one `audit.purged` per tenant whose events it deleted (that tenant's count,
  `across_tenants: true`) plus one for untenanted rows; tenant auditors could not see the single tenant-less event.
- `cleanup.expired_assignments` stores `affected_user_count` and at most 100 ids (`affected_user_ids_truncated`)
  instead of an unbounded list, which could overflow a MySQL TEXT column.
- `POST /api/…/rules` with `is_null` / `is_not_null` and no `field_value` answered 500; the value is stored as empty.
- The admin's Effective Access sorts rows like the hash builder, so it shows the same `mask_strategy` on a variant
  tie (`PermissionHashBuilder.sort_rows`).
- The erasure and stale-assignment dry runs no longer raise on an assignment whose Permission Set is gone.
- `BulkPermissionSetAssignment` no longer counts a revocation that a callback refused.
- `ManagedIndex` keeps one per-request copy per tenant key instead of one per cache-version bump.
- The GDPR boot scan plucks field names instead of loading every unmasked `ResourceField`.
- The test suite passes on MySQL (test-only fixes for backtick quoting, DDL inside a transaction and foreign keys
  on drop); CI gains a MySQL job.
- `PermissionForge::AuditEvent` refuses `update_counters` on a relation too (`increment!`/`decrement!` take that
  path on Rails 8.2), so an audit row cannot be changed that way.
- Admin UI accessibility: every page has one h1 (drawer and confirmation titles, Permission Set and Group names),
  heading levels no longer skip, filter chips use `aria-current`, links in footers and hints are underlined, an
  existing action's key is no longer a label for a missing control, the erasure confirmation points
  `aria-describedby` at its error only when it is shown.

### Removed

- `PermissionForge::Cache::RedisCache`. It was never loaded, could not be configured and did not match the cache
  interface. Use `cache_backend = :rails_cache` with `ActiveSupport::Cache::RedisCacheStore` (or pass the store).
- `Cache::Base#json_dump`, `#json_load` and `.oj_available?`, which only `RedisCache` used.
- Internal planning documents (`docs/plan-*.md`, `docs/prd-*.md`) and the duplicate `LICENSE` file (the license
  is `LICENSE.txt`).
- `PermissionForge::RLS.connection` (undocumented).
- Internal: `HasAuditTrail.rebind_audit_associations!`, `Engine#rebind_configurable_associations`, the
  `permission_forge.rebind_associations` and `permission_forge.load_models` initializers (nothing is rebound after
  boot; the 288 "method redefined" warnings at boot under `ruby -w` are gone), `Engine.apply_tenant_scoping_to_models`
  (each model scopes itself as it loads) and `MaskingSync.boot_skipped!` (use `reset!`).

### Internal

- Rails-internals canary (`test/permission_forge/rails_internals_canary_test.rb`): one test per private
  ActiveRecord/ActiveSupport API the gem relies on, each naming the code that relies on it; CI runs it on Rails
  `main` in an allow-failure job.
- Test suite: the configuration is restored from a snapshot after every test instead of a hand-written reset; the
  SQLite suite runs in forked workers (about 30 s instead of about 2 minutes; `PARALLEL_WORKERS=1` for one process);
  the dummy app logs warnings only; no wall-clock sleeps; the suite's own Ruby warnings are gone.

## [0.13.0] - 2026-10-06

Includes the fixes for the four blockers found by the pre-release review (the first four entries under Fixed).

### Security

- **API lookups under `api_record_identifier = :id` no longer match an identifier by its leading digits.** The identifier went to the database as given, which casts `1abc` — or a uuid that starts with `1` — to `1`, so `GET /api/permission_sets/1abc` returned Permission Set 1 and a uuid could name an unrelated record. Every API lookup now goes through one method that accepts only digits under `:id` (and refuses a NUL byte under either setting, which PostgreSQL answered with a 500); anything else is a 404.
- **The compliance documents no longer claim more than the code does.** The HIPAA, GDPR, masking and security-audit guides and the three compliance skills now map each control as "what the gem evidences (with the event or feature) / what the host must add". Removed: `PermissionsRegenerator` (cache invalidation) as an audit-control row, the sentence that audit reports are "certification evidence", the withdrawn ISO 27001:2013 numbering (Annex A 2022 is used), and mappings that did not hold — expiry and allowed hours as "automatic logoff", masking as "encryption/decryption", API auth, UUID ids and pagination as "transmission security", assignments as "identity management". Nothing claims compliance or certification.
- **Symbol-named extra fields could unmask a configured field.** When a model's `extra_fields_for_permissions` returned Symbols (`%i[email]`), a name that collided with a configured `ResourceField` slipped past the collision check added in 0.10.0 and replaced the configured entry once the cache symbolized the hash — the field became readable, editable and unmasked. A muting set also could not hide a Symbol-named extra field. Names are now normalized to Strings before merging. Apps declaring Strings (`%w[...]`) were not affected.
- **A permission-hash rebuild that raced a change could cache stale permissions for the whole TTL.** A request whose cache entry was missing read the permission rows, an admin then committed a change (or revoked an assignment) and invalidated, and the request stored what it had read — after the invalidation's delete. Every invalidation now leaves a per-user stamp (written before the delete) and a rebuild checks it before reading the rows and after storing: if it moved, the stored hash is dropped and built again. Rebuilds read their rows outside ActiveRecord's query cache, and the stamp past the cache store's per-request local cache, so the check also holds inside a web request. Host apps that derive their own cache entry in a `regenerate_permissions` override should compare `permission_invalidation_stamp` the same way (see `docs/architecture.md`).
- **A configured virtual field could lose to the implicit grant, depending on which Permission Set was older.** The implicit read + edit entry for extra fields was added after each granting set. For a person with two sets containing the resource, a row in the *newer* set (say Masked, read-only) merged into the older set's implicit entry and the field stayed editable and unmasked; with the sets the other way round the row won. The implicit entry is now added once per resource, after every granting set is merged (`Services::ExtraFieldDefaults`), so a row in any of the person's sets wins. **This can reduce access** for people in that situation; the admin's Effective access page showed the stricter result all along.
- **`alias_attribute` names bypassed field-level masking on a model with `MaskedAttributes`.** For `alias_attribute :mail, :email` with `email` hidden or masked, `record.mail` returned the stored value on Rails 7.2 and later (on 7.1 when the model was in use before the concern arrived), `record[:mail]` and `read_attribute(:mail)` returned it on every Rails version unless `unconfigured_field_strategy` was `:block`, `as_json(methods: [:mail])` exposed it, and `record.mail = …` skipped the write-back protection, so a hidden `nil` read through the alias and assigned back cleared the column. An alias is now judged as the attribute it points to on every path — getter, `[]`, `read_attribute`, `slice`, serialization, setter — whenever and wherever it was declared (before or after the concern, in a subclass, on a parent with or without the concern), and otherwise does what Rails does for an alias on that Rails version. Code that reached a hidden column through its alias on purpose must use `*_before_type_cast`. See "Aliases" in `docs/masked-attributes.md`.
- **A subclass that was in use before its parent got `MaskedAttributes` kept unguarded column getters.** Rails gives each subclass its own column methods on first use; a subclass used before the concern arrived — host code touching a record during boot, or the parent's first `Resource` row created at runtime in a process that had already used the subclass — went on calling them. A normal boot was not affected. **Upgrade note:** such a subclass is now guarded like any other, under its own class name: with the default `unconfigured_field_strategy = :block` and no `Resource` rows of its own, every getter returns the hidden value, including columns readable on the parent. Give each subclass its own Resource and field rows.
- **On databases whose transactions read from a snapshot, a permission hash built inside a transaction is no longer cached.** Under REPEATABLE READ or SERIALIZABLE — MySQL's default, SQLite, and PostgreSQL inside `transaction(isolation: :repeatable_read)` or `:serializable` — a transaction keeps reading the rows as they were when it began, so a rebuild inside it could store a hash older than a change that had already been invalidated, and keep it until `cache_ttl`. Inside such a transaction the request now builds and uses its own hash and the cache store is left alone; the user object does not read the store again until the transaction has ended. `regenerate_permissions` and `invalidate_permissions` called there take effect in the cache once the outermost transaction has committed (once per user per transaction, nothing after a rollback, also when a commit callback of another record raises). Which transactions count is the new `config.snapshot_transactions` (`:auto`). **PostgreSQL at READ COMMITTED is not affected: inside a transaction everything is cached and invalidated as before** — including the known limit that a grant regenerated inside a transaction that then rolls back stays cached until the next invalidation (invalidate after a rollback). On MySQL and SQLite, permissions first read inside a transaction are built once per transaction and not cached: read them once before a loop of saves (50 saves on a cold entry are 50 builds and 350 queries instead of 1 and 7), or set the option to `false` on a MySQL that runs at READ COMMITTED. Until the commit, another instance of the same user goes on reading the entry of the committed rows. A single `transaction(joinable: false)` with nothing joinable around it is not recognised — it is what wraps a test.
- **A cache store that fails without raising no longer loses an invalidation silently.** Redis, Memcached and Solid Cache stores answer false or nil when unreachable — a delete also for "nothing there". The answers are checked: an unconfirmed invalidation is tried three times, then logged at error level, published as `cache_failure.permission_forge` and handed to `config.on_cache_failure`. Nothing is raised out of `after_commit` (a raising hook or notification subscriber is contained too). The process that failed keeps the invalidation as owed (up to 500 users), does not serve those users from the store meanwhile, and makes the invalidation when the store answers again, 25 per pass — extra effort, not a guarantee: other processes, a restart or an overflow leave `cache_ttl` as the backstop. A store that is down never widens access: requests work with the hash they build, never an empty one (an empty hash switched row-level rules off).
- **Invalidation follows the changed record's tenant, not the ambient one.** A record of tenant A saved while tenant B — or none — was ambient looked in the wrong tenant and invalidated nobody. The assigned users are loaded past the default scopes of the host's user model. A permission table without the tenant column is looked up without one instead of failing.
- **The managed-actions index is not written to the cache from inside a transaction.** A guard check inside a transaction that switched a managed action off and was then rolled back left "not managed" in the shared cache for up to 60 seconds, allowing the action for everybody under the default `unconfigured_action_strategy`. An index built inside an open transaction now stays with that request (a guard check inside a transaction costs the index's two queries each time), and a drop of the index made inside a transaction is repeated after the commit.
- **The managed-actions index is invalidated and rebuilt like a permission hash.** A request that read the rows before a new action was committed could store its older index after the commit had dropped it; and a drop the cache store did not confirm was reported but neither tried again nor avoided. Either way later requests saw the action as unmanaged and, under the default `unconfigured_action_strategy = :allow`, could run it without a grant until the index expired (60 seconds), also after the store had recovered. The index now goes through `Cache::Invalidation` and `Cache::Rebuild`: every drop writes the stamp `managed_actions_invalidation` first, a build stores the index only when that stamp did not move meanwhile (otherwise it is removed and built once more, reading past the query cache), and a drop the store does not confirm is tried again, reported and owed — until the store confirms it, the process builds the index from the database instead of reading it. Other processes may serve the old index for 60 seconds at most. `Cache::Backlog` now lists entries by stamp key (`Invalidation.owed?` takes the stamp key).
- **Nothing is cached from `rails console --sandbox`.** A grant tried out in a sandbox console was cached and outlived the sandbox's rollback.
- A request that had just rebuilt its hash read the entry back and could pick up another rebuild's not-yet-verified hash for that one request. It now keeps the hash it built and verified.
- **Row-level rule values are compared in the type of their column, on every database.** A rule's `field_value` used to reach the database as text. PostgreSQL raised on text it could not cast, SQLite compared as text, and MySQL converted it: `supplier_id equal '5_id'` matched 5, `'abc'` matched 0, and `deactivated equal 'true'` matched the rows where it was false. On SQLite `not_equal` or `less_than` with such a value matched every row. `Operators::ValueTyping` now types the value (number, boolean, ISO 8601 date/time, text, enum label → stored value). **A value the column cannot hold makes the rule match nothing**, for the negative operators too and without the `include_nulls` rows. The column is found the way the database resolves the name: any case on MySQL and SQLite, a schema or database prefix, a column in `ignored_columns`, dotted names and join rules. Not typed, as before: array, uuid and json columns, the table alias of a self-join, and the row id pseudo-column (`_rowid`, `rowid`). See "How Values Are Compared" in `docs/row-level-rules.md`, and **Upgrading** below for what changes per database.
- **A rule's `join_type` is looked up in an allow-list.** It was passed to `Relation#send`, so a rule row written past the model's validation — the rule tables can be shared with other applications — could call any relation method: `send` with a `field_accessor_path` of `delete_all` emptied the table, `unscope` dropped the rules applied before it. Anything but `joins`, `left_joins`, `left_outer_joins` (or nothing, blank or `filter`, which mean a filter on the model's own table) now raises `PermissionForge::ConfigurationError` in `find_by`, `find_by!` and `permission_scoped`.
- **`contains`, `not_contains`, `starts_with`, `ends_with` match `%`, `_` and `\` literally on SQLite, and on MySQL under `NO_BACKSLASH_ESCAPES` with the trilogy adapter.** The SQL had no `ESCAPE` clause, so `not_contains '50%'` let rows containing `50%` through. (With the mysql2 adapter a text value raises in that mode, as before.)
- **RLS policies select the rows the application layer selects, and never more.** String operators compile to `ILIKE` on the column itself (they were case-sensitive, so `not_contains 'acme'` left `ACME` rows visible, and cast `char(n)` to text, which dropped the padding). `include_nulls` adds NULL rows only for `equal`, `not_equal`, `in`, `not_in` (it made `is_not_null` always true). A string operator on a non-text column compiles to `FALSE` (the application layer raises there). Values are typed by the same code. A rule whose `join_type` is `filter` is no longer skipped. **Run `rake permission_forge:rls:sync` after upgrading** (`GENERATOR_VERSION` 3; `rls:status` reports every protected table as stale until then, and the old policies stay in force meanwhile — wider than the application layer in the cases above).
- **A user object read on several threads at once could be left with an empty permission hash.** A read-through rebuild handed its hash back to `permissions_hash` through instance variables of the user, which every rebuild cleared when it finished. When two threads missed the cache on the same user object at once (a user handed to threads of a request, or kept across requests), one of them could get `{}` and memoize it until the next invalidation in the process: every `can_*?` check denied, every field hidden under the default `unconfigured_field_strategy = :block` (passed in the clear under `:warn` or `:pass_through`), and row-level rules switched off for that object, because an empty hash has no `permission_set_rules`. Each rebuild now hands its hash back on its own thread, and a host override of `regenerate_permissions` whose `super` runs on another thread or fiber gets the hash `super` memoized. The `{}` a build is answered when it asks for its own user's permissions (a masked attribute read by the profile builder) used to be memoized as well, so another thread reading that object during the build was served it; it is now returned to that call alone and never memoized. A host override of `regenerate_permissions` that returns without building the hash for the cache key — it skips `super`, or runs it where the tenant is another — used to leave `{}` on every call (row-level rules off); it now raises `PermissionForge::ConfigurationError` naming the key. A user object loaded per request on one thread was not affected.
- **A user object read on several threads at once could keep another tenant's hash, or a hash read from the store before an invalidation.** The memoized hash was stored as four instance variables (key, version, transaction, hash) written one after the other, so two threads memoizing on the same object could leave one thread's key with the other thread's hash — another tenant's permissions under this tenant's key — or a hash read before an invalidation under the version after it. The memo is now one frozen object written in one assignment, and a hash read from the cache store is memoized under the version from before the read, so an invalidation during the read retires it. A hash built inside a transaction whose hashes are withheld (`config.snapshot_transactions`) is served only on that transaction's connection: another thread's connection does not see the rows it was built from (`OpenTransaction#visible?`), and a thread on another connection neither replaces it nor stays away from the store because of it. The transaction the user object is tied to now lives in the memo too. Objects kept on a user still survive `Marshal.dump`.
- **Reading a record while `MaskedAttributes` was being applied to its class could raise.** When the concern was included at runtime (the engine applies it when a model's first `Resource` row appears) while other threads read records of that model, `read_attribute`, `[]`, `attributes`, `as_json` and `to_json` could raise `NoMethodError` (`pf_resource_symbol`) for an instant, and `as_json(methods: [...])` `NameError` (`guarded_user`). Every read during the include now answers either as without the concern or as with it; no step returns nil, or a stored value once the guard is in place.

### Added

- **Audit event log.** Every create, update and destroy of a Permission Set, Resource, field, action, rule, group, assignment or group membership is recorded in the new `audit_events` table — who did it (`actor_type/id/label`), from where, when, the changed attributes with their previous values or a full snapshot of a deleted row, the Permission Set and person concerned, and one `correlation_id` per transaction — inside the change's own transaction: a change made through the models whose event cannot be written (writes that skip callbacks are never recorded) raises `PermissionForge::Audit::EventNotRecordedError` and rolls back, also when the error is rescued inside an enclosing transaction (`config.audit_change_failure_strategy`). Events are insert-only in Ruby only (`update_all`, `delete_all`, `insert_all` and database access still reach the table; protect it at database level), tenant-scoped, published as `"<event>.permission_forge"` notifications after the commit, and switched by `config.audit_events` (`:auto`: on when the table exists; a boot warning says when it is missing). New: `PermissionForge::Audit.record/instrument/instrument?/correlate`, `PermissionForge.with_audit_actor`, `record.audit_as`, `Audit::Context`, `Audit::EventCatalog` (adding an event is one entry), `Concerns::RecordsAuditEvents`, `OpenTransaction#before_commit` and `#after_end`, and the options `audit_events`, `audit_actor_resolver`, `audit_request_context`, `audit_change_failure_strategy`, `audit_hook_failure_strategy`, `audit_runtime_events`, `audit_log_subscriber`, `audit_retention_period`, `audit_log_authorization` and `admin_assignment_authorization`. Run `bin/rails generate permission_forge:upgrade` and migrate; the migration (`--tenant-column`, irreversible) also adds the assignment-review and acknowledgement columns. See `docs/audit-log.md`, which also lists what is not recorded.
- **Who did it, in every request.** The admin UI and the API record the acting person on every audit event — `config.audit_actor_resolver`, else the signed-in user, else the HTTP Basic username (`actor_type: basic_auth`) or an anonymous API client — with the request id, IP (`config.audit_request_context`; client-influenced, correct only with trusted proxies configured), an optional `reason` parameter and one correlation id per change request; jobs are recorded with source `job`. Failed Basic and API sign-ins, refused API authorizations and locked-record refusals are recorded (`admin.auth_failed`, `api.auth_failed`, `admin.lock_refused`) even when the surrounding transaction rolls back (not inside a non-joinable one), and viewing someone's effective access, the audit tabs and CSV exports are recorded (`admin.effective_access_viewed`, `audit.viewed`, `audit.exported`). Event columns are cleaned once (valid UTF-8, one line, no control characters, at most 255 characters). Refusals of `admin_assignment_authorization` and `audit_log_authorization` are recorded, and so are reads of the audit log through the API. `created_by` / `updated_by` are only stamped for a record of `audit_user_class`.
- **Audit events cover copies and cascades.** Duplicating a Permission Set or group (admin UI, "start from", API clone) credits the person making the copy on every copied row (fresh uuid, `created_by`/`updated_by` reset) and records `permission_set.cloned` / `permission_set_group.cloned` with the source; copies are created unlocked instead of unlocked afterwards with `update_all`; deleting a group detaches its Permission Sets through audited saves (one `permission_set.updated` each) instead of `dependent: :nullify`; Review-and-save and field sync run all-or-nothing under one correlation id, and a Review-and-save that fails halfway leaves neither changes nor events, even inside a caller's transaction; field generation (`Resource.grant_full_access!`, API `generate_fields`) is all or nothing under one correlation id; a copied field starts without the original's "This is intended" acknowledgement.
- **Access review and assignment evidence.** "Keep" records `reviewed_at` and `reviewed_by_id` with an `assignment.reviewed` event (decision `keep`). "This is intended" records `sensitive_acknowledged_by_id` with a `field.sensitive_acknowledged` event. Every grant, expiry change, revocation and group membership change from the admin UI and the API writes its event with actor, person, expiry and reason, and the reason is also kept on the row. New `config.admin_assignment_authorization = ->(controller, target, user_ids, action)` is asked before each of them (`:grant :revoke :change_expiry :review :add_member :remove_member`), for example to forbid self-assignment; consent withdrawal, erasure, the expired-assignment clean-up, assignments removed with a deleted Permission Set or group, and Ruby/console calls are not gated by it. `record.audit_as` only renames a model's own update events to the names listed in `RecordsAuditEvents::AUDIT_AS_RENAMES`.
- **Audit trail for housekeeping, and retention.** `DataSubjectErasure`, `ConsentWithdrawalHandler` and `ExpiredAssignmentCleaner` take `actor:` and `reason:` and write one summary event (`erasure.performed`, `consent.withdrawn`, `cleanup.expired_assignments`) next to the per-row revocations; erasure also clears the person's name from existing events in every tenant (ids stay). New `Services::AuditEventPurger` and `rake permission_forge:audit_events:purge` (`DRY_RUN=1`, `ACTOR=`) delete events older than `audit_retention_period` in batches, each batch with its own `audit.purged` event in one transaction (a batch whose event cannot be written is not deleted; `audit.purged` events are never purged; no route or API reaches the purge). Rake tasks take `ACTOR=`/`REASON=`; report tasks record `report.generated`.
- **Runtime decision events.** Row denials and nil-user denials (`access.denied`), refused controller actions (`action.denied`), every way past the row-level rules (`rule.bypassed`: view_all, modify_all, nil_user, scope_suspended, auto_scope_opt_out, no_rules, guard_bypass — once per request under auto-scoping), Level 2 findings (`query.unscoped`), field reads (`field.access`, one per record read, listing hidden and masked field names, never values), dropped params (`params.filtered`), refused masked write-backs (`write.masked_skipped`) and permission hash rebuilds/invalidations are published as `"<event>.permission_forge"` notifications; denials are stored by default, the other groups per `config.audit_runtime_events` (`denied bypass field_read params_filtered cache`). Denials inside a transaction that rolls back are still recorded. `NotAuthorizedError` gains `#user`, `#record`, `#record_id`; `ActionNotAuthorizedError` gains `#user`, `#record`. `config.audit_log_subscriber = true` writes one JSON line per event (name labels left out, event `data` included). With nobody listening, attribute reads are not slower than before (measured against the previous commit in `docs/benchmarks.md`, "Audit events: attribute reads").
- **Audit log in the admin.** A new Audit log page lists every recorded event with filters (dates in the application's time zone, event, category, actor, person, Permission Set, action), page links and no cap, opens each event with who/where/why and its before and after, and exports the current filter as CSV or JSON with every column and a metadata block (exported at, time zone, by, filters, row count), CSV-injection safe and streamed in batches. The Permission Set and person audit tabs show real timelines; a "Who holds what" export lists every assignment with who granted it, its expiry and last review; review labels read "Reviewed by … on …" or "Never reviewed"; "Last edited by" comes from the latest change event; change forms take an optional reason; views of the log are hidden from lists unless asked for and always exported; Home warns when the audit log is not recording. The log, its exports, "Who holds what" and the audit tabs and CSVs are gated by `config.audit_log_authorization` (refusals recorded as `admin.auth_failed`, views and exports as `audit.viewed` / `audit.exported`); the "Last edited by" footer and the "Assigned by" labels are not. Settings: "Record who created and last edited".
- **Read-only audit API.** `GET /api/audit_events` and `/api/audit_events/:identifier` with filters (time range, event, category, actor, subject, Permission Set, record, correlation id), pagination, `config.audit_log_authorization` enforced through `Audit::LogAccess`. A `page` beyond 2,147,483,647 is clamped on every paginated API endpoint.
- **Security audit: audit-log check.** `rake permission_forge:audit` gains the `audit_trail` check (table missing, audit off, shared login, anonymous API client, unknown actors, self-granted access, runtime groups, failure strategies, retention). Boot warns for audit off and for a shared login; `audit.settings_observed` records audit-setting changes at boot (a toggle made at run time after boot is not observed).
- **Documentation:** `docs/audit-log.md` (what is recorded and what is not, configuration, failure strategies, exports, retention, protecting the table at database level, forwarding, clock synchronisation and the other host duties).
- **Controller actions as permissions.** Include `PermissionForge::Concerns::ControllerActionGuard` in a controller and its actions are checked against the current user's Permission Sets before they run: REST actions against the Resource's CRUD flags, other actions against the Resource's custom actions (`user.can?(:export, :Customer)`). A denied request raises `PermissionForge::ActionNotAuthorizedError` (with `resource`, `action`, `controller_path`, `reason`) — the guard never renders. Actions map to a Resource by convention (`customers` → `Customer`), by `permission_forge_actions resource:, actions:, rest_actions:` on the controller, or by `config.controller_action_resolver`. `ControllerActions::Authorizer.allowed?` answers the same question for hiding buttons. See `docs/controller-actions.md`.
- **Managed actions.** An action is *managed* once an active row for it exists in any active Permission Set; from then on only people whose sets permit it can run it. An action or Resource nobody manages follows `config.unconfigured_action_strategy` (`:allow` by default, or `:block`). `config.action_guard_bypass` skips the guard for chosen people; with no current user the guard follows `nil_user_strategy`.
- **Admin: controller actions on the Actions tab** (`config.controller_action_discovery = true`). Lists the app's controller actions that map to the Resource, with their endpoints, whether the controller includes the guard, and what applies right now. Discovered actions are added per row or in bulk through *Review and save*, which states when adding makes an action managed for everyone. With discovery off the tab is unchanged.
- **Virtual fields are first-class in the admin.** *Add a resource* presets and *Sync with model* now create rows for a model's declared virtual fields, and an unconfigured virtual row says what applies to it right now.
- `config.extra_fields_default_access` — `:grant` (default, as before) or `:unconfigured`: a declared virtual field with no row gets no implicit access and follows `unconfigured_field_strategy`.
- `config.virtual_field_discovery` — the admin also lists attribute-API attributes and store accessors as virtual fields. Discovered names never get implicit access.
- `config.mask_virtual_attributes` (`false` / `:auto` / list of models) — model-level masking of virtual reader methods on top of column masking: a Hidden or Masked virtual field is hidden or masked when code calls the reader, including `as_json(methods:)`. `record.pf_without_virtual_masking { ... }` reads the real value inside the model. See `docs/masked-attributes.md`.
- Audits cover virtual fields: `GdprFieldAuditor` (new `:implicit_virtual_grant` finding), `MaskedAttributes.explain_all`, `rake permission_forge:audit` (`implicit_virtual_personal_data`).
- `rake permission_forge:audit` has a new `action` check: managed actions nobody is granted, managed actions with an endpoint on a controller that does not run the guard, action rows no controller action maps to, rows whose name is not a valid action key, and discovery without any guarded controller.
- `config.snapshot_transactions` (`:auto`, `true`, `false`) — whether a transaction is treated as reading from a snapshot. `:auto` decides from the adapter and the isolation level Rails opened the transaction with, without asking the server; set `true` for a PostgreSQL whose default isolation level was raised for the database or role, `false` for a MySQL at READ COMMITTED. Any other value raises `ConfigurationError`.
- `config.on_cache_failure` and the `cache_failure.permission_forge` notification (`operation:`, `user_id:`, `keys:`, `error:`).
- `User#invalidate_permissions` returns whether the cache store confirmed it. `PermissionForge::Cache::Failure.none? { … }` says the same for a block of code, whatever a host's override of that method returns; the services and admin screens use it: `DataSubjectErasure` (`cache_cleared`; `nil` when called inside a transaction, where it is only known at the commit), `ConsentWithdrawalHandler` (`invalidated`), the `invalidated` count of `BulkPermissionSetAssignment` and `ExpiredAssignmentCleaner`, and the People screens' "refresh cached permissions", "erase", "withdraw consent" and "remove all", which show an error when the store did not confirm. It sees failures reported during the block on the calling fiber: one reported later, by an `after_commit` of a transaction the host opened around the call, is not seen (it still reaches `on_cache_failure`).
- `PermissionForge::OpenTransaction.withholding` — for a host that writes a cache entry of its own derived from the permissions (a `regenerate_permissions` override): non-nil when the hash just built must not be shared.
- `PermissionForge::Cache::Base#expunge(key)` — remove a key and say whether it is certainly gone (custom backends inherit a default built on `delete`).
- `rake permission_forge:audit` lists rules in effect that match nothing because their value is not one their column can hold, or their field name is not a name (`unusable_rule_values`; medium when people hold the set, otherwise low). Run it after upgrading.
- The suite runs on MySQL: `DB=mysql BUNDLE_GEMFILE=gemfiles/mysql.gemfile bundle exec rake test` (trilogy; `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`).
- Install generator options `--user-id-type` and `--tenant-id-type` (`bigint`, `integer`, `uuid`, `string`), detected from the configured user model and the `--tenant` model when not given.
- `PermissionForge::Services::HostKeyGuard` — reading permissions or writing an assignment raises `ConfigurationError` when an integer column would have to hold a non-integer host key. It checks `user_id` and every tenant column, including the audit log's once `audit_events` exists (a truncated tenant id would show one tenant another's events). Checked at the point of use, not at boot, so `db:migrate` can still run.
- A fresh-install test: a child process boots a brand-new Rails app, runs the real install generator with default flags, the generated initializer and migration, and exercises the core contract on the stock `rails new` test settings (default prefix, `:null_store`), for integer and string user keys.

### Changed

- **The "who holds what" export is streamed.** Assignments were all read into memory before the first byte was sent; they are now read in batches of 500 while the file is written, as the audit log export does. Output is the same. `row_count` is the count when the export starts: an assignment removed while the file is written is missing from it. The streamed body of both exports now runs with the action's tenant and with record rules suspended, as the action did (a host that set the tenant in its own `around_action` made the body raise or read the wrong tenant, and a record rule on the user model blanked the person columns).
- **Audit closing fixes.**
  - The association writers Rails generates for the gem's collections (`user.permission_sets.delete`, `set.user_ids = []`, `group.permission_sets = []`, `clear`, …) remove assignments, memberships and set links through callbacks: an event and a cache invalidation each. `clear` and `delete_all` without an argument now run record by record; an explicit `delete_all(:delete_all)` or a narrowed relation is still plain SQL and not recorded.
  - Consent withdrawal is one transaction with its revocations and its `consent.withdrawn` summary.
  - `field.access` names the fields read in the clear (`passed_fields`); a hidden virtual reader dropped from `as_json(methods:)` is listed; `record.attributes` with no user publishes the bypassed decisions and calls `on_field_filtered`.
  - Audit sentences name sets, groups and people as they were at the event, and say when a revocation removed an expired assignment (the clean-up's reason defaults to `expired`).
  - Every form that changes permission data takes an optional reason.
  - New security finding `audit_anonymous_api`; `audit_unknown_actors` counts change events only; the other audit-trail findings say more precisely what is at risk.
  - `audit_events = true` without the table is shown as a risk in Settings, Home and the log.
  - The set and person CSVs are `no-store`, and `/permission_sets/:id.csv` no longer fails without `?tab=audit`.
  - The upgrade's de-dup migration prints what it deleted.
- **Upgrading: the audit log.** Run `bin/rails generate permission_forge:upgrade --skip` (adds the migrations you do not have yet and leaves earlier ones alone; `--tenant-column=<column>` for tenant-scoped installs; a fresh `install` takes `--tenant=Model`) and `bin/rails db:migrate`; the upgrade also runs on installs that already have the resource-field unique index (every install from 0.11 on); the migration is irreversible and leaves existing assignments with no `reviewed_at`. Set `config.audit_actor_resolver` so events name a person. `rake permission_forge:audit` with `FAIL_ON=high` now also fails on an app that has not run the migration (`audit_table_missing`), on `audit_events = false` and on self-granted access; `FAIL_ON=medium` or `low` also on a default HTTP Basic install, and on an install with the API enabled (`audit_anonymous_api`), until `audit_actor_resolver` is set, on `unknown`-actor change events in the last 30 days and on `audit_change_failure_strategy` other than `:raise`; `FAIL_ON=low` also on `audit_hook_failure_strategy = :log`. See `docs/migration-guide.md`.
- **Staleness is measured from the last review.** An assignment is stale when it is permanent and its `reviewed_at` (else `created_at`) is older than `admin_stale_assignment_days`; editing an assignment is no longer a review, and existing rows are not backfilled. `StaleAssignmentAuditor` rows gain `last_reviewed_at` and `reviewed_by_id` and count `days_stale` from the review; `rake permission_forge:stale_assignments` prints days since the last review or grant.
- **A change fails when its audit event cannot be written** (`audit_change_failure_strategy = :raise`, the default); so does a view or export of the audit log. Choose `:report` or `:log` to let changes through; the security audit then reports `audit_changes_unrecorded`.
- **`config.audit_runtime_events` is stored frozen**: `config.audit_runtime_events << :bypass` raises; assign an array.
- **`on_rule_bypass` and `on_field_filtered` are subscribers of the new events.** Same signatures; their errors are no longer swallowed but follow `config.audit_hook_failure_strategy` (default `:report`: logged and handed to `Rails.error`; `:raise` lets the error replace the decision's outcome); `on_field_filtered` is called once per field decision, in the same order with the same arguments: as the decision is made when it is the only listener and `field_read` is not stored (as before), otherwise when the read returns.
- **The per-person and per-Permission-Set CSV exports (the records a person created or last edited) are no longer capped at 500 rows per type.**
- With defaults unchanged, apps whose models declare sensitive-looking virtual fields without rows will see them in the Home privacy audit, in *Sync with model* ("N new"), and in `rake permission_forge:audit`. **`rake permission_forge:audit_masks` now exits 1 for them** — give the fields a row or set `extra_fields_default_access = :unconfigured`.
- `ResourceFieldGenerator` also creates rows for declared virtual fields when `extra_fields_default_access = :unconfigured`.
- **The JSON API rejects action names that are not valid keys** (lowercase letters, digits and `_`, starting with a letter, up to 63 characters) with a 422 on create and on rename — the rule the admin screens already applied. Existing rows are untouched and can still be updated, cloned, or renamed to a valid key.
- **Cache invalidation is coalesced per transaction.** Each permission record used to invalidate every affected person's cached hash in its own `after_commit` — once per record, per person. The records written in one transaction now share an invalidation batch: each person (per tenant) is invalidated once per commit, and the affected-user lookup is not repeated for records of the same Permission Set. Saving 20 records in a set assigned to 50 people goes from 1,000 `invalidate_permissions` calls and about 1,120 SQL statements to 50 calls and about 65 statements. `User#invalidate_permissions` is still the method called, once per person. The three callbacks `:invalidate_permissions_for_users`, `:invalidate_managed_actions` and `:invalidate_user_permissions` are now one `after_commit :invalidate_after_commit`; a host `skip_callback` on the old names raises. Writes that skip callbacks (`update_all`, `insert_all`) still need a manual `invalidate_permissions`, as before.
- Moving a `Resource` (or a field, action or rule) to another Permission Set also invalidates the people of the set it left.
- `FieldPermissionMerger` merges field rows only; the implicit entries for extra fields come from `Services::ExtraFieldDefaults` (called by `PermissionHashBuilder`). Code calling the merger directly no longer gets them.
- Locale keys `resource_actions.show.{permitted,not_permitted,blocked,unchanged}` moved to `resource_actions.states.*`. Host overrides of the old keys need renaming.
- `ResourceActionsController::KEY_FORMAT` moved to `PermissionForge::ControllerActions::KEY_FORMAT`.
- **Reading a column that was not loaded raises on a model with `MaskedAttributes`, as it does on any model.** On a record loaded with a partial `select` (`Customer.select(:id)`), a masked getter, `email?`, `slice`, `as_json(methods:)` and `read_attribute_for_serialization` returned `nil` or `false` where Rails raises `ActiveModel::MissingAttributeError`; they now raise. Code that leaned on that `nil` must select the column or rescue.
- `record[:id_value]` and `read_attribute(:id_value)` return the id on a model with `MaskedAttributes` (Rails' own alias of `id`); for a user under `:block` they returned the hidden value.
- Every class that declares an `alias_attribute` in or above a model with `MaskedAttributes` gets a `MaskedAliasAccessors` module in front of its generated attribute methods, including a parent or abstract base that does not have the concern. Records of classes without the concern behave as before; `instance_method(:alias).owner` is that module. On Rails 7.1 the deprecation "model aliases `x` and has a method called `x` defined" is no longer printed for such classes.
- After a rebuild the user object keeps the hash it built; it is not read back from the store (a rebuild is 3 store reads and 1 write, was 4 and 1). One invalidation is 2 writes and 2 deletes for a cached user and 3 writes and 2 deletes for an uncached one (was 1 write and 2 deletes): a delete that answers "nothing there" is followed by a one-second placeholder write, which is what tells an absent entry from a store that is down.
- `ControllerActions::ManagedIndex.invalidate!` checks the store's answers, tries every key, reports a removal it could not confirm, returns whether all were confirmed, and no longer raises.
- `PermissionForge.cache.clear` removes nothing on Solid Cache and Memcached (no `delete_matched`); the log message and docs now say so and name the alternatives (`docs/configuration.md`, "Cache Consistency").
- With Solid Cache on the application's own database connection (not a separate cache database), an `invalidate_permissions` inside a transaction holds a row until the commit, so another request of that user — or an admin's invalidation of them — waits for it.
- **Upgrading: rule values.** Rules are rows somebody typed, so check them with `rake permission_forge:audit` (`unusable_rule_values`).
  - *Newly matches.* PostgreSQL (these raised): a decimal, a number past the column's range or scientific notation on an integer column; an integer-backed enum label; `current_user` on a string column. SQLite: boolean words other than `1`/`0`; enum labels; `T`-notation date-times; time columns; `%`, `_`, `\` in string operators.
  - *Newly matches nothing, everywhere.* Text that is not a number or one of the boolean words `true t yes y on 1` / `false f no n off 0` (PostgreSQL also read prefixes such as `tr`); `0x1F`, `1_000`, `NaN`, `Infinity` and numbers past double range; an unknown enum label; `current_user` on a boolean or date column, or inside a list or range on a number column; `not_in` with an empty list; `between` without exactly two values; a field name with an empty part (`owner_id.`), which is also rejected on new rules and renames. On MySQL and SQLite only: a date or time that is not ISO 8601 — PostgreSQL still reads its own notations (`today`, `10.01.2026`) and raises on the rest, as before.
  - *Returns other rows.* MySQL: `true`/`yes`/`on` matched the FALSE rows; an enum label matched the stored-0 rows; `current_user` on a string column compared numerically; decimal `in`/`not_in` compared as floats; a `tinyint(1)` column holding other numbers only matches boolean words. All databases: a string-backed enum label now means its stored value (when a label equals another label's stored value, the label wins); a date-time offset is applied (PostgreSQL ignored it on `timestamp without time zone`; MySQL used the session zone); `between '5,50'` on a string column is a text range. MySQL and SQLite: a date column compared with a date-time value compares the day.
  - *Host operator strategies.* One registered under a built-in operator name receives Integer / BigDecimal / true / false / Date / Time / String, and an Array for `in`, `not_in`, `between`; it is not called when the value is unusable. A strategy under a name of its own gets the value as written (`current_user` replaced by the id).
  - *RLS.* A rule with an unusable value now syncs (as `FALSE`) instead of failing the sync. A date PostgreSQL cannot read still fails the sync at that table and leaves the tables after it as they were. A word like `today` in a policy is read when the policy is created, not per query. `RlsOperatorSql` strategies and helpers take the typed value.

### Fixed

- **The default install works.** The install migration prefixed foreign-key *columns* as well as tables (`permission_forge_permission_set_id`), while the models read `permission_set_id`, so an install with any non-empty table prefix — including the default — could not create or read permission data. Columns are never prefixed now; only table names and `to_table` are. Unprefixed installs generate the same migration as before. The `permission_forge:upgrade` de-duplication migration had the same mistake and is fixed too. `docs/table-prefix.md` has the column renames for a prefixed install made with 0.12.2 or earlier.
- **A cache that drops writes no longer switches row-level rules off.** After a rebuild the read-through re-read the store and fell back to `{}`. With `cache_backend = :null`, a `NullStore` behind `Rails.cache` (the stock Rails test environment) or a store outage, every `can_*?` was false but `permission_set_rules` was empty too, so `find_by`, `permission_scoped` and auto query scoping applied no rules. The freshly built hash is returned instead; `{}` remains only for the re-entrancy guard.
- **UUID and string keys no longer merge users.** `user_id`, `created_by_id` / `updated_by_id` and the `--tenant` column were always `bigint`; a UUID was stored as its leading digits with no error, so a user who was never assigned inherited the sets of any user sharing those digits (and UUID-keyed tenants would have shared permission data the same way). The install generator now types these columns from the user and tenant models' primary keys — the audit log's `reviewed_by_id`, `sensitive_acknowledged_by_id` and tenant column included (the upgrade copies the types of your existing columns) — and `BulkPermissionSetAssignment` no longer calls `to_i` on ids.
- **API `generate_fields` is authorized and honours locks.** `POST .../resources/:id/generate_fields` skipped `api_action_authorization`, `api_require_authorization` and the `is_editable` lock, so a caller the hooks would deny could grant read and edit on every unconfigured column. It now passes the hook (action `:generate_fields`) and returns 403 when the resource or its permission set is locked.
- **An edit by nobody, a Basic-auth login or an API client no longer blanks `updated_by_id`**; the previous editor is kept; `created_by_id` is stamped on create and `updated_by_id` on create and on each update, only from an actor that is a record of `audit_user_class`. The admin's "Last edited by" comes from the latest change event, because the row can pair a kept editor with a newer `updated_at`.
- **A switched-off field row is described as what it is.** The engine skips a row with `is_active: false`, so the field behaves as if that set had no row for it. The Home privacy card now says its setting is *turned off* (it said "Not configured"), the "in other sets" list of the field drawer and Field lookup marks a row that is not in effect — the row, its resource or its Permission Set is off — with an Off badge instead of showing its level as if in force, and the card notes that each line looks at one Permission Set on its own.
- **`GdprFieldAuditor` reads only rows in effect** (active row, active resource, active granting Permission Set — `ResourceField.in_effect`). A switched-off unmasked row was reported as `:unmasked_field` although masking it would do nothing, and a column whose only row was switched off, or sat in a switched-off resource, a switched-off set or a muting set, counted as mapped. Such a column is now reported once, as `:unmapped_column`. **`rake permission_forge:audit_masks` can newly exit 1, and `rake permission_forge:audit` can newly report a high finding** (under `unconfigured_field_strategy` `pass_through` / `warn`) for these columns; rows that are not in effect no longer produce `:unmasked_field` or `:cross_set_unmasking` findings.
- **Admin: the Fields tab's bulk "Set to" buttons did nothing with JavaScript on.** The script that opens *Review and save* in a dialog posted the form without the pressed button, so the chosen level was lost and the page answered "No changes to save". It now sends the button. Related fixes in the same script:
  - "Select all shown fields" no longer ticks rows hidden by the search box, and a row that is filtered out leaves the selection.
  - *Discard* also clears the bulk selection bar.
  - Going *Back* from the review dialog keeps the leave-page warning armed.
  - If the script's request fails, the retry is made by pressing the same button again, so it keeps the button's value and target (a failed "Check names" preview could fall back to posting the real assignment).
- **Admin: Enter in a text box no longer triggers the wrong button.** On the Resource page it submitted through the first bulk "Set to" button, proposing that level for the ticked rows; in the field drawer it submitted through "Apply recommendation" (changing the level at once and dropping the typed label) or "Explain". Both forms now have a plain default button, so Enter means review, or save.
- **Store accessors on a hidden or masked store column no longer crash or wipe the stored data.** Rails reads and writes a store (`store :settings, accessors: [...]`, `store_accessor`) through the column's getter, which `MaskedAttributes` masks. With the column hidden or masked for the current user, Rails saw `nil` where it expects the hash: on Rails 7.1–8.0 reading a key raised `NoMethodError`, and on every version Rails replaced the column with an empty hash in memory, so a later `save` wiped the stored data. Reading a key now returns the hidden value without touching the column, and writing a key works on the stored hash, so the other keys survive.
- Admin copy: the Albanian and Macedonian strings added in this release now use the same words as the rest of each file ("kontrollues", "e ndryshueshme", "картичка", "ја следи поставката …"), and the "add discovered actions" label carries its count in the singular form too — Macedonian uses the singular for 21, 31, 101.
- Admin: the default buttons added above stay rendered (clipped out of sight, out of the tab order) instead of `hidden` — Safari before 16.4 ignores a `display:none` button when Enter looks for a form's default button. The rule builder gets the same default button (Enter in the Name box re-rendered the builder and saved nothing), and a drawer opening moves focus to its first real control again. Verified in Firefox 155, WebKit 26.6 and Chromium 153, with and without JavaScript.
- **A resource can no longer get a second action row with the same name.** Two rows for one action are OR-ed when permissions are built, so a second row could permit what the first one blocks. Through the JSON API a duplicate raised `ActiveRecord::RecordNotUnique` (a 500) on tables that have the unique index and was accepted on tables that do not; it is now a 422 with the engine's translated message, on create, on rename and when a row is moved to another resource. Rows that already share a name stay editable: `rake permission_forge:audit` lists them (`duplicate_actions`, medium), and cloning a Permission Set copies them as the single row they amount to.
- **`rake permission_forge:audit_masks` prints every finding it counts.** The header counted five kinds of finding and only three had a line. View All on a resource with sensitive fields now prints as `[VIEW ALL]`, a field unmasked in one Permission Set and masked in another as `[OVERRIDES MASK]`; the three existing lines, the all-clear line and the exit status are unchanged (`GdprFieldAuditor::TextReport`). Both checks are also more exact, in `GdprFieldAuditor` and so in the `personal_data` check of `rake permission_forge:audit`: View All is reported only for a resource in effect in a granting set (it was also reported for a muting set, where `view_all` takes the bypass away, and for switched-off rows), and cross-set unmasking only when the same field of the same resource is masked in another granting set (it matched on the field name alone, across resources and inside a single set). **`audit_masks` can newly exit 0** where those were the only findings.
- `ResourceField` name uniqueness is checked the way the column's collation compares. The forced case-sensitive check let `Email` through beside `email` on MySQL's default (case-insensitive) collation, and the unique index then raised `ActiveRecord::RecordNotUnique`; it is now a validation error there. Nothing changes on PostgreSQL and SQLite, where the two stay separate fields.
- **A store accessor on a partially loaded record could wipe the stored hash.** On a record loaded without its store column, reading a store key and saving nulled the column, and writing a key replaced the whole hash, on a model with `MaskedAttributes`. The accessor is now left to Rails, which raises `ActiveModel::MissingAttributeError`; the stored hash is untouched.
- `RlsPolicyGenerator#digest` raised `ArgumentError` for two rules of one set that differ only in `include_nulls`.
- `DB=postgres bundle exec rake test` failed five `RlsEnforcementTest` cases that pass under `rake test:rls`: other test files define more protected models on the `customers` table, and the last one synced replaced `Customer`'s policies. The test now narrows the protected models to `Customer`. (The cause is a limit of its own: two protected models on one table share one set of policies.)

### Upgrade notes

- An `api_action_authorization` lambda that switches on the action name must handle `:generate_fields`; anything it does not allow is now denied.
- Hosts with UUID or string user keys on a schema created by 0.12.2 or earlier get `ConfigurationError` on the first permission check. See "UUID or string keys" in `docs/migration-guide.md`.


## [0.12.2] - 2026-10-04

### Fixed

- **`config.tenant_column` is now honoured.** It was never passed to `acts_as_tenant`, so a custom column scoped queries on the inferred `<model>_id` column while cache invalidation read the configured one. `HasTenantScoping` now declares the association with `foreign_key: config.resolved_tenant_column` and `class_name: config.tenant_model`.
- **Namespaced tenant models** (`config.tenant_model = 'Billing::Account'`, `--tenant=Billing::Account`) produced an invalid association name and a `billing/account_id` column. Both now use the demodulized name (`:account`, `account_id`).
- **Boot now fails when `tenant_model` is set but the `acts_as_tenant` gem is not loaded** (`PermissionForge::ConfigurationError`). Previously the tenant scope was silently skipped and every tenant's permission data was visible to every other tenant.
- `apply_tenant_scoping!` is idempotent — a second application no longer adds a second tenant default scope.
- Configuration docs claimed rows with a NULL tenant column were visible to all tenants; acts_as_tenant hides them under every tenant. The comment and `docs/multi-tenancy.md` now say so, and document the tenant-less (job/console) behaviour.

### Added

- The install migration indexes the tenant column on all 8 tables, and `rails generate permission_forge:install --tenant=Account` writes `config.tenant_model = 'Account'` into the generated initializer.
- Tenancy test suite (`test/permission_forge/tenancy/`): row isolation across all 8 models, per-tenant cache invalidation including changes made with no tenant set, `PermissionScopedFindable` on a tenant-scoped host model in both declaration orders, API and admin UI isolation, and the configuration/generator surface.

## [0.12.1] - 2026-10-03

### Added

- **`rake permission_forge:audit`** — a read-only security review, safe to run in production (`kamal app exec -i "bin/rails permission_forge:audit"`). Reports findings from Critical to Info across configuration (admin UI with no authentication, process-local cache in production, fail-open flags, unguarded API mutations), privileged access (View All / Modify All, temporary-looking sets, broad delete), assignments (stale, deleted or deactivated users, expired rows, people with 3+ sets), record rules, data integrity (duplicate field rows, dependency violations, unknown models) and personal data. `FORMAT=json` for machine output, `FAIL_ON=high` to fail CI. In code: `PermissionForge::Services::SecurityAudit.call`. See `docs/security-audit.md`.
- **Admin Home: "Record rules not applied everywhere"** — lists active rules the app's query scoping won't apply to every query (all of them while `auto_query_scoping` is off; join rules when it's on). The Rules tab shows the same warning as a banner.
- `PermissionSetRule#join_rule?` / `.join_type_rules` and `Resource#rules_bypassed?`.

### Fixed

- **`permission_forge:upgrade` now uses the app's table prefix.** It defaulted to `permission_forge_`, so apps on another prefix (e.g. `""`) got migrations for tables that don't exist unless they passed `--table-prefix`. The default is now the configured `config.table_name_prefix`; the flag still overrides it. If you generated with the wrong prefix, delete the unapplied migration files and run the generator again.
- The Rules tab's empty state said nobody with the set sees any records. No rules means records aren't limited; it now says so.
- The admin classified rules with a join type but no relationship path as filter rules, while auto-scoping skips them. Both now decide by `join_type`.

## [0.12.0] - 2026-10-03

### Admin UI — redesigned

The built-in admin is rebuilt around the owner's questions ("who can see and do what, and why?"). **The HTML routes changed** (the JSON API is untouched); see `docs/admin-ui.md`.

- **New information architecture:** Home · People · Permission Sets · Permission Set Groups · Settings. Resources are edited *inside* their Permission Set (the old top-level Resources list, which showed the same model once per set, is gone).
- **Home — Needs attention:** privacy audit (sensitive fields shown unmasked, sensitive columns not configured while `unconfigured_field_strategy` lets them through) with *Fix* and *This is intended*; access ending this week (*Extend 30 days*); expired-assignment cleanup with a dry run; stale assignments (*Keep* / *Remove*; staleness measured like `StaleAssignmentAuditor`); sets to tidy up. All-good and first-run states.
- **People and Person:** search and filters; per-person *Access* (end dates, keep, remove, undo), **Effective access** with provenance (which set granted or muted every flag, field, action and record rule) via `PermissionForge::Admin::EffectiveAccess`, parity-tested against `PermissionHashBuilder`; *Audit* (access received, changes made, CSV export). Person actions: remove all access, withdraw consent (dry run), GDPR Art. 17 erasure (dry run + typed confirmation), refresh cached permissions.
- **Permission Set editor:** granting vs **muting** chosen at creation (and switchable behind an inversion warning); start from a copy; Resources matrix with dependency-aware CRUD cells; batched edits confirmed in **Review and save** (lists every change, cascades and affected people; one transaction); Assignments with bulk assign (paste emails/names) and bulk revoke; Conditions tab (IPv4/IPv6/CIDR validation per line, overnight hours, session flag); Audit tab with filters and CSV; deep **Duplicate** that unlocks the copy.
- **Resource page:** CRUD + View All / Modify All, **Sync fields with model** (new columns, missing columns, ignored columns), Fields with a 4-level control (Hidden / Masked / Read-only / Editable; Unchanged / Force mask / Hide in muting sets), filters, search and bulk edit; **Actions** (previously no HTML UI); Rules.
- **Field drawer:** mask strategy with live preview (real `MaskValue`, custom strategies included), privacy recommendation, linked variants, virtual fields, rules using the field, the field **across all Permission Sets**, *Explain for a person*. **Field lookup** ("Who can see iban?").
- **Rule builder:** sentence-style, with field and relationship pickers from model reflection (no free text), 15 operators in plain words, "the current user", include-empty (only for operators it affects), blocked message, join type under *Advanced*, live preview.
- **Settings (read-only):** every option with plain-language copy, current vs default, risk/secure markers, health summary, the 3-level query-scoping ladder, and a copy-paste "How to change" snippet. Secrets are only shown as set/not set; lambdas only as default/custom/not set.
- **Audit:** created-by / last-edited-by footers on every record; person and set audit tabs; a clearly marked "coming soon" change-timeline preview (needs a future audit-log table).
- **Brand:** new logo, favicon and touch icon in the admin; README header uses the new light/dark logo.

### Admin UI — zero host dependencies

- CSS/JS/brand are served by the engine (`PermissionForge::AssetsController`, fingerprinted, cached forever). The admin no longer registers `permission_forge/application.css` with Sprockets/Propshaft; `app/assets` was removed.
- Everything is namespaced: `pf-*` classes, `data-pf-*` attributes, `pf_*` cookies scoped to the mount path, `pf_*` helpers. No inline scripts, styles or handlers (strict-CSP safe; script tag carries the CSP nonce). Every flow works without JavaScript.
- Light / dark / auto themes; English, Albanian, Macedonian. System font stack only (no third-party fonts).
- Host theming hook: override `permission_forge/shared/_head_extra` to add a stylesheet that re-defines `--pf-*` tokens.

### Added

- `config.admin_model_resolver`, `config.admin_session_flags`, `config.admin_stale_assignment_days`, `config.admin_app_name`, `config.admin_back_url` (the "← Back to <app>" link under the logo), `config.admin_docs_url` (admin UI only).
- People search and bulk name matching also use `firstname`/`lastname`/`username`/`login` columns, and multi-word queries match across split name columns ("ana kras" finds Ana Krasniqi whether the app stores `name` or first/last names). Labels compose `firstname`/`lastname` when there is no `name`.
- `resource_fields.sensitive_acknowledged_at` (nullable) for the privacy audit's *This is intended*. New installs get it; existing installs: `bin/rails generate permission_forge:upgrade && bin/rails db:migrate`. The UI hides the button until the column exists.
- `PermissionForge::Admin::*` read models/services behind the screens: `EffectiveAccess`, `ChangeSet`, `AttentionItems`, `SettingsCatalog`, `ModelCatalog`, `FieldRows`, `RuleForm`, `AuditTrail`, `PeopleDirectory`, `PersonLabel`, `SensitiveColumns`, `ExpiryPresets`, `BulkPeopleMatcher`, `FieldLevel`.
- `docs/configuration.md` gains an *Option reference* with one anchor per option (the Settings page links to them).

### Removed

- Old HTML admin controllers/views (`DashboardController`, top-level `ResourcesController` routes, `PermissionSetUsersController`, the `HtmlCrudActions` concern) and the asset-pipeline stylesheet. Hosts that overrode old engine views should re-check overrides against the new view paths.

### Noted (engine behaviour, unchanged)

- Field `mask_access` is AND-merged across every granting set that configures the field, so a set that lists a field as **Hidden** (read off, mask off) still counts towards *unmasking* it for people who also have a set that reads it masked. The Effective access screen shows the real outcome.
- `user_active_check` is not applied when building permissions (only `PermissionSetUser#deactivated?` uses it).

## [0.11.0] - 2026-07-28

### Performance — fixed

- **`permissions_hash` is now memoized per user instance** (retired by a process-wide version bump on any `invalidate_permissions` / `regenerate_permissions` / cache-store swap, by `#reload`, and by a tenant cache-key change). Previously EVERY call — and MaskedAttributes triggers one per attribute read — paid a full cache-store round-trip plus deserialization of the entire hash; on a host with a multi-MB hash and a store-backed cache this turned an admin show page rendering a user dropdown into a 40-second, GC-thrashing request. The memoized hash is a shared object: **treat it as read-only** and deep-dup before mutating.
- **`pf_raw_user_attribute` now reads real columns via `read_attribute_before_type_cast` FIRST**, falling back to the public reader only for virtual attributes or blank columns. Dropdown labels no longer route through the AttributeAccessGuard per attribute per user, and can no longer show masked/hidden sentinels (the dropdown is documented masking-exempt admin infrastructure). Note: a host method overriding a *populated* column is no longer consulted for labels — use `config.user_label_formatter` for custom label logic.
- **`DataSubjectErasure` invalidates through `invalidate_permissions`** (all cache keys + memo version bump) instead of a raw single-key cache delete, so no live instance can keep serving an erased user's permissions from its memo.

### Added

- **`config.user_list_limit` (default 500)** — hard cap on the admin UI assignment dropdowns, applied after excluding already-assigned users. Without a `user_list_resolver` the dropdown falls back to the host's ENTIRE users table; the cap stops that from rendering six-figure `<option>` lists. A resolver relation carrying its own smaller LIMIT is preserved; `nil` disables. When the cap trims the list the dropdown renders a localized hint (new i18n key `permission_forge.shared.user_select_truncated` in en/sq/mk). **Behavior change for hosts with >500 users and no `user_list_resolver`** — configure a resolver to control which users appear.

- **Three-level configurable query scoping** (all default OFF — zero behavior change unless enabled; see `docs/query-scoping.md`):
  - **Level 1 — ENFORCE (`config.auto_query_scoping = :filter_only`).** A permanent `default_scope` on protected models applies the current user's filter-type rules to every relation (`where`/`all`/`find`/`first`/`count`/`pluck`/association traversal). Join-type rules still require `permission_scoped` (boot warning fires when both are in play). view_all/modify_all bypasses; nil user follows `nil_user_strategy` (`:deny`/`:raise` fail closed to an empty relation). Tenant scoping and host `default_scope`s are preserved in both declaration orders. Per-model opt-out via `self.permission_forge_auto_scope = false`.
  - **Level 2 — DETECT (`config.unscoped_query_detection = :log | :raise`).** A `sql.active_record` subscriber flags SELECT/UPDATE/DELETE statements on protected tables that bypassed a permission-scoped path (scoped paths carry a `/* pf_scoped */` annotation). Environment-gated via `unscoped_query_detection_environments` (default dev/test); `:raise` surfaces `PermissionForge::UnscopedQueryError` at the offending call site. With Level 1 on, detection flags exactly the true escapes: `unscoped`, `find_by_sql`, raw SQL.
  - **Level 3 — Postgres Row-Level Security (`config.database_row_level_security`).** `bin/rails generate permission_forge:rls` installs policies compiled from filter-type rules with *dynamic membership* (assign/revoke needs no resync; only rule-content edits do — `rake permission_forge:rls:sync`, drift detected via policy-comment digest + boot warning + `rls:status`). Runtime plumbing: `PermissionForge::RLS.with_user(user) { }` (transaction-local) and `set_user!`/`clear_user!` for around_action. Enforced below ActiveRecord: `unscoped` and raw SQL are filtered by the database. Muting sets cancel view_all bypasses dynamically; missing session variable follows `nil_user_strategy`; **only unconditional sets grant the DB-level view_all bypass** (a consent/IP/hours-gated set granting view_all never widens RLS access while its condition can't be evaluated in SQL — found by GDPR audit, enforcement-tested).
  - `PermissionForge.without_permission_scope { }` — nesting-safe escape hatch suspending Levels 1–2 for intentional unscoped access.
  - New Postgres CI job + `rake test:rls` enforcement suite (runs as a non-superuser role; skips cleanly without Postgres).
- Boot warnings: join-type rules under Level 1, `:raise` detection configured for production, RLS enabled on a non-Postgres adapter, RLS policy drift.

### Fixed

- **`equal`/`is_null` rule predicates no longer crash `Model.new`/`create` under a `default_scope`.** Operator predicates built on SQL-literal columns are now wrapped in `Arel::Nodes::Grouping`, so Rails' `scope_for_create` attribute inference skips them instead of raising `NoMethodError` (and rule values can never leak into new-record attributes).
- **The install migration template now adds the tenant column to all 8 tables** when `--tenant` is given — previously only `permission_set_groups` got it, so a multi-tenant install would fail `acts_as_tenant` scoping on the other 7 models. Single-tenant installs are unaffected (no tenant column is rendered without `--tenant`).
- **The HTML admin UI now enforces the `is_editable` lock.** Update/destroy of a record flagged `is_editable: false` redirects with a flash alert instead of mutating, matching the API's 403 behavior. New i18n key `permission_forge.flash.not_editable` (en/sq/mk).
- The boot warning for missing HTTP Basic Auth credentials now names the real config option (`http_basic_auth_user`, previously the nonexistent `http_basic_auth_username`).

### Changed (behavior)
- **Service result keys renamed `regenerated:` → `invalidated:`** in `ExpiredAssignmentCleaner`, `BulkPermissionSetAssignment`, and `ConsentWithdrawalHandler` — the counters have counted cache invalidations (lazy rebuild) since 0.10.0, and the old name was misleading. The API bulk-assignment response (`POST .../users/bulk`) returns `invalidated` accordingly, and the `permission_forge:cleanup_expired_assignments` rake output wording matches.

### Internal
- Test suite grown from 899 to 1090 tests (HTML admin controllers, application helper, response renderer, MaskedAttributes diagnostics/write-guard edges, engine boot warnings, install migration template, permissions_hash memoization, dropdown cap). All gates green: RuboCop, Reek, i18n-tasks health.

## [0.10.0] - 2026-07-14

Security & correctness hardening release. **Contains behavior changes** (all pre-1.0, documented below). No changes to the cached permission-hash public structure.

### Security — fixed

- **Revocation now takes effect immediately (critical).** Removing a user's permission-set assignment — via the admin UI, the JSON API single-user endpoint, or cascading `PermissionSet#destroy` — previously left the user's cached permissions live until an unrelated change or the expiry cron ran (with the old `cache_ttl: nil`, that was indefinitely). `PermissionSetUser` now invalidates the affected user's cache on create/update/destroy, so `PermissionSet#destroy` invalidates every previously-assigned user through the `dependent: :destroy` cascade.
- **Read path now fails closed.** `FiltersResponseAttributes` no longer returns raw attributes when an authenticated user has no configured access to a resource — every field is routed through `unconfigured_field_strategy` (default `:block`). `masked_field?` reports unconfigured fields as masked under `:block`/`:mask_all`. Unknown `unconfigured_field_strategy` values fall back to `:block`, never pass-through. New `response_filter_nil_user_strategy` (`:bypass` default / `:block`) controls the no-current-user case.
- **Cache miss is no longer fail-open.** `permissions_hash` is now read-through: a miss (eviction, TTL expiry, flush) rebuilds in the *current* request rather than silently returning `{}`.
- **Muting sets now revoke field variants.** A muting set revoking `user_id` (or `price_cents`) now also revokes its `user_uuid` (or `price`) variant — previously the variant stayed readable.
- **Row-level rule columns use real identifier quoting** (`quote_table_name` / `quote_column_name`) instead of the previous no-op `sanitize_sql`, hardening against a malformed `field_name` reaching SQL even if a rule bypassed model validation.
- **Masked values can no longer be persisted back.** New `masked_write_protection` (`:skip` default) prevents a callback that reads a masked/hidden value and writes it back from corrupting the stored column.
- **Activation conditions evaluate against the right principal.** Cross-user permission changes now *invalidate* affected users (rebuilt lazily in each user's own request) instead of rebuilding in the editing admin's request context. Conditional sets get a short cache TTL (`conditional_set_cache_ttl`, default 300s) so IP/hours changes go stale quickly.
- **API CSRF posture.** The API base controller now uses `protect_from_forgery with: :null_session` instead of unconditionally skipping forgery protection, neutralizing cross-site form POSTs against session-authenticated deployments while leaving token clients unaffected.
- **is_editable is enforced** on API create/update/destroy (records flagged `is_editable: false` return 403).
- **Authorization hook coverage.** `api_action_authorization` now gates create/update/destroy (not just clone); `api_assignment_authorization` now gates single-user revoke and group-user create/destroy.
- **No internal error leakage.** `generate_fields` (API + HTML) now logs the exception and returns a generic message instead of echoing `e.message`.
- **Resource#name is validated** as a Ruby constant path (it is resolved via `safe_constantize`).
- **HTML locale switcher** no longer reflects arbitrary query parameters through `url_for` (removes an off-site link-injection primitive).
- **Dependency CVEs patched**: puma, sqlite3, oj, nokogiri, net-imap, json, concurrent-ruby, crass, websocket-driver bumped in the dev lockfile; `bundle-audit` is now clean.
- **Accept-Language parsing** fixed to match bare tags (`en`) and always reset locale per request (was leaking across requests on reused threads).
- **`extra_fields` can no longer unmask a configured field.** A host-declared extra field whose name collides with a DB-configured `ResourceField` is now strictly additive — it no longer overwrites the configured entry's `mask_access`/`edit_access` (previously a name collision stripped masking and granted edit).
- **Config options are no longer frozen at gem-require time.** `config.user_class` (and `audit_user_class`) associations and the `audit_trail_enabled` toggle are now honored — associations are re-declared after host initializers load, and the audit callbacks check the toggle at runtime. Previously `user_class`/`audit_trail_enabled`/`audit_user_class` set in the initializer were silent no-ops.
- **Duplicate `ResourceField` rows are blocked** — a unique index on `(resource_id, name)` plus a model validation (a duplicate row with `mask_access: false` could otherwise silently unmask the field via mask AND-logic). Companion uniqueness validations added on `PermissionSetUser`/`PermissionSetGroupUser` so a repeat assignment returns 422 instead of a `RecordNotUnique` 500. Run `bin/rails generate permission_forge:upgrade` to add the index (and de-dup) on existing installs.
- **Masked write-back protection now survives a request boundary.** The guard additionally compares an incoming write to the mask of the *currently-persisted* value, so the classic form roundtrip (render `********`, submit it back on a freshly-loaded record) no longer overwrites the stored value — the previous ledger only covered same-instance read-modify-write.
- **`find_by` honors its nil contract.** A genuinely missing record returns `nil` (matching stock Rails) instead of raising `NotAuthorizedError`; the error is now raised only when the record exists but a rule denies it.
- **`find_by` no longer resurrects default-scoped rows.** The internal fallback uses `where(nil)` instead of `unscoped`, preserving a host model's `default_scope` (e.g. soft-delete) and the tenant scope.

### Added

- `Model.permission_scoped` — a rule-constrained, chainable relation (`.where`, `.first`, `.find`, `.count`), plus a `find_by!` override, extending row-level enforcement beyond `find_by`.
- `User#invalidate_permissions(tenant_id:)` — deletes a user's cached hash so the next read rebuilds it.
- Config: `conditional_set_cache_ttl`, `response_filter_nil_user_strategy`, `masked_write_protection`.
- **`config.conditional_sets_strict_mode`** (default `false`) — when `true`, a permission set with activation conditions (session flag / `allowed_ips` / login hours) is treated as **inactive** when `request_context_resolver` returns a blank context, so an unwired resolver can no longer silently leave IP/hours/consent restrictions unenforced. A boot warning fires when conditional sets exist without a context resolver. **Default flips to `true` in the next major.**
- **`config.api_require_authorization`** (default `false`) — when `true`, API mutation and assignment endpoints deny (403) if `api_action_authorization` / `api_assignment_authorization` is unset, closing the "`api_auth` proves identity but not admin-ness" escalation. A boot warning fires when the API is enabled without both authorization lambdas. **Default flips to `true` in the next major.**
- `bin/rails generate permission_forge:upgrade` — migration generator that de-dups and adds the `resource_fields` unique index for pre-existing installs.
- `Configuration#field_variants_for` — shared variant computation used by the granting and muting phases.
- CI: dedicated `security` job running Brakeman and bundler-audit.
- CI: the Rails matrix now actually exercises each version via per-Rails gemfiles (`gemfiles/rails_*.gemfile` selected through `BUNDLE_GEMFILE`) — previously every cell installed the same latest Rails. The dummy test app now eager-loads so the admin-UI controllers/views are covered.
- The install initializer template now documents admin-UI Basic Auth, activation-condition context, and the two new secure-default flags.

### Changed (behavior)

- **`cache_ttl` now defaults to `3600`** (was `nil`/never-expire) as a staleness backstop; the effective TTL is clamped to `conditional_set_cache_ttl` for conditional sets and to the soonest assignment `expires_at`.
- Cross-user permission changes now **invalidate** caches (lazy rebuild) rather than eagerly rebuilding; deactivated users are invalidated too (fixes stale cache on reactivation).
- Permission sets are merged in a deterministic order (`created_at, id`) so "first `mask_strategy` wins" is stable.
- `PermitsAttributes` is now non-mutating (returns a new hash) and filters nested `*_attributes` against the association's own resource when configured (falling back to the parent otherwise).
- Row-level `field_value` is used verbatim — the undocumented `_id` → integer coercion was removed (`'current_user'` substitution is unchanged).

### Internal

- `PermissionRuleApplier` happy path is now a single existence check (per-rule queries only run when access is denied).
- `MemoryCache` is mutex-guarded and dups on write; `RailsCache#clear` logs loudly when the store can't honor a bulk clear.
- All gates green: 899 tests / 0 failures, RuboCop 0 offenses, Reek 0 warnings, Brakeman 0 warnings, bundler-audit clean, i18n-tasks health perfect across en/sq/mk.

## [0.9.0] - 2026-05-03

### Added
- **MaskedAttributes concern** — model-level field masking that auto-applies to managed models. Direct AR readers (e.g. `customer.email`) now route through PermissionForge's masking logic instead of bypassing it via AR's generated attribute methods.
  - New `MaskedAttributesSettings` configuration module
  - `auto_apply_masked_attributes` config — auto-applies the concern to every model with a matching `Resource` row
  - `omit_hidden_in_attributes_hash` and `hidden_attribute_value` config options
  - Diagnostic helpers: `MaskedAttributes.explain(record, attr)` and `.explain_all(record)` for debugging field decisions
- **AttributeAccessGuard service** — centralizes per-attribute access decisions (passed/masked/hidden/unconfigured/bypassed) shared by `MaskedAttributes` reads and `FiltersResponseAttributes`
- **User list resolver + label formatter** — `config.user_list_resolver` and `config.user_label_formatter` lambdas for customizing the admin UI's user-assignment dropdown
- **Search in resources index** — search input with clear-query support
- **Assignment expiration UI** — datetime picker on the user assignment form
- **`PermissionForge::BUNDLED_LOCALES`** — canonical fallback for the locale dropdown when `config.available_locales` is unset

### Fixed
- Locale fallback now uses `BUNDLED_LOCALES` (`[:en, :sq, :mk]`) instead of `I18n.available_locales`, so the admin UI dropdown only shows locales the gem actually supports (no more host-app/Faker pollution)
- `module_eval` for per-column attribute readers replaced with `define_method` — safer code generation, brakeman-clean
- Two pre-existing test bugs in `assert_raises(Class, /regex/)` calls (invalid Minitest API)

### Internal
- All static analysis clean: rubocop 0 offenses, reek 0 warnings, brakeman 0 warnings
- Extracted `pf_compose_name` and `pf_format_name_and_email` helpers from `pf_default_user_label`
- `MaskedAttributes#guard_attributes_hash` refactored to `filter_map { ... }.to_h`
- `MaskedAttributes.decide` converted to keyword args

## [0.8.0] - 2026-04-28

### Added
- **Rails 8.1 support** — gemspec dependency upper bound raised to `< 8.2` for `activerecord`, `activesupport`, and `railties`. Tested against Rails 8.1.3 and Ruby 3.4.5 / 3.4.7.
- CI matrix now includes Rails 8.1 alongside 7.1, 7.2, and 8.0.

## [0.7.0] - 2026-03-24

### Added
- **Multi-Tenancy (acts_as_tenant)** — optional integration with acts_as_tenant for full tenant isolation
  - New `config.tenant_model` / `config.tenant_column` configuration (nil = disabled, fully backward compatible)
  - New `HasTenantScoping` concern — conditionally applies `acts_as_tenant` to all 8 models
  - Engine initializer applies tenant scoping after configuration is loaded
  - Tenant-aware cache key: `tenant_#{id}_user_#{id}` prevents cross-tenant cache collisions
  - `PermissionScopedFindable` uses `tenant_safe_find_by` to preserve tenant scope in fallback queries
  - Migration generator accepts `--tenant=Account` to add tenant column to all tables
  - Cross-tenant user sharing: same user, different permissions per tenant
  - All services (DashboardStats, ExpiredAssignmentCleaner, GdprFieldAuditor, etc.) auto-scoped via default scope
  - New doc: `docs/multi-tenancy.md`
- **Activation Conditions** — unified conditional activation system for permission sets (Salesforce-inspired)
  - **Session-Based Permissions**: `requires_session_flag` — set only activates when session flag is present (e.g., after MFA step-up)
  - **IP Range Restrictions**: `allowed_ips` — comma-separated CIDR ranges, set only activates from matching IPs
  - **Login Hour Restrictions**: `allowed_hours_start` / `allowed_hours_end` — set only activates during allowed hours (supports midnight wrap)
  - New `PermissionSetConditionEvaluator` service — evaluates all conditions against a request context
  - New `config.request_context_resolver` lambda — provides `{ ip:, session_flags:, time: }` context at regeneration time
  - `PermissionCacheAccessor` filters conditional sets through evaluator when context is available
  - `conditional?` / `unconditional?` instance methods and `.conditional` / `.unconditional` scopes
  - Hour validations (0-23 range)
  - Admin UI: activation conditions fieldset on permission set form
  - Admin API: all condition columns exposed in serializer and accepted in params
  - i18n: condition labels/hints/placeholders added to all 3 locale files
  - New doc: `docs/activation-conditions.md`
  - Fully backward compatible — default resolver returns `{}`, no filtering occurs
- **Assignment Expiration** — time-bound permission set assignments that auto-expire (Salesforce-inspired)
  - New `expires_at` datetime column on `permission_set_users` table (nullable — nil = never expires)
  - `PermissionCacheAccessor` filters expired assignments before building permission hash
  - `ExpiredAssignmentCleaner` service — removes expired records + regenerates permissions (supports `dry_run:`)
  - `.active_assignments` / `.expired` scopes on PermissionSetUser
  - `expired?` / `active_assignment?` instance methods on PermissionSetUser
  - `BulkPermissionSetAssignment` accepts optional `expires_at:` parameter
  - Admin API: `expires_at` exposed in serializer, accepted in create/bulk params
  - Admin UI: datetime picker on user assignment form, expiration status in users table
  - i18n: expiration labels added to all 3 locale files (en, sq, mk)
  - New doc: `docs/assignment-expiration.md`
- **Muting Permission Sets** — permission sets that subtract permissions instead of granting them (Salesforce-inspired)
  - New `is_muting` boolean column on `permission_sets` table (default: `false`)
  - `PermissionHashBuilder` partitions sets into granting/muting, applies granting merge first, then subtracts muting
  - Muting revokes: resource CRUD, view_all/modify_all, field read/edit access, action is_permitted
  - Muting forces: field `mask_access` to `true` when muting field has `mask_access: true`
  - Muting does NOT add row-level rules (subtraction only)
  - `muting?` / `granting?` instance methods on PermissionSet
  - `.muting` / `.granting` scopes on PermissionSet
  - `source_permission_sets` in cache hash now includes `is_muting` flag
  - `ValidatesDependency` skips validation for muting sets (inverted semantics — `delete_access: true` means "revoke delete")
  - Admin UI: muting checkbox on permission set form, muting badge on index/show
  - Admin API: `is_muting` exposed in serializer, accepted in create/update params
  - Deep clone preserves `is_muting` flag
  - i18n: muting labels/hints added to all 3 locale files (en, sq, mk)
  - New doc: `docs/muting-permission-sets.md`

### Changed
- `PermissionHashBuilder#call` now partitions permission sets before processing (internal, no API change)
- `ValidatesDependency` now checks `belongs_to_muting_permission_set?` before enforcing dependency rules
- Migration template includes `is_muting` column on `permission_sets` table

### Tests
- 55 new tests across 4 test files (model, builder, integration, API)
- Edge cases: inactive muting sets, inactive muting resources/fields/actions, multiple stacking muting sets, muting-only users, order independence, disjoint resources

## [0.6.0] - 2026-03-24

### Refactored (non-breaking)
- **PermissionedUser** split into 3 focused concerns: `PermissionCacheAccessor`, `ResourcePermissionChecker`, `FieldMaskChecker`. The original concern is preserved as a composition for backward compatibility.
- **PermissionScopedFindable** query logic extracted to `PermissionRuleApplier` service. Concern remains thin orchestrator.
- **PermissionHashBuilder** field logic extracted to `FieldPermissionMerger` service.
- **PermissionSet/PermissionSetGroup** `deep_clone` extracted to `PermissionSetCloner`/`PermissionSetGroupCloner` services.
- **Resource** `grant_full_access!` extracted to `ResourceWithFieldsBuilder` service.
- **FiltersResponseAttributes** unconfigured field strategies use registry pattern (extensible via `UNCONFIGURED_FIELD_STRATEGIES`).
- **MaskValue** supports custom strategies via `config.custom_mask_strategies` and `MaskValue.strategies`.
- **BulkPermissionSetAssignment** actions use strategy pattern via `ACTION_STRATEGIES`.
- **PermissionSetRule** field value validation delegated to `Operators::Validations`.
- **Api::BaseController** split into `ResponseRenderer`, `Pagination`, `SerializerResolver` concerns.
- **DashboardController** stats extracted to `DashboardStats` service.

### Added
- `config.custom_mask_strategies` — register custom masking strategies without modifying MaskValue
- `PermissionForge::Operators::Validations` — extensible operator validation registry
- DIP: New services accept injectable dependencies (`current_user`, `configuration`, `operator_registry`) with sensible defaults

### DRY improvements
- Extracted shared view partials: `_form_errors`, `_form_actions`, `_empty_state` — eliminates 13 duplicate blocks across forms and index views
- `HasActiveScope` concern — eliminates `scope :active` repeated in 6 models
- `Clonable` service concern — shares clone/duplicate logic between `PermissionSetCloner` and `PermissionSetGroupCloner`
- `NestedResourceLookup` API concern — shares `set_resource` and `find_nested_record` across 3 API controllers
- `HtmlCrudActions` concern — shares `crud_create`, `crud_update`, `crud_destroy` helpers across 5 HTML controllers

### No breaking changes
- All public APIs preserved. Models delegate to services for backward compatibility.
- Permission hash structure unchanged.
- `NotAuthorizedError` namespace unchanged.

## [0.5.0] - 2026-03-23

### Added — Security Audit Remediation

**Phase 1: Critical Model Validations**
- **PermissionSetRule validations** — `operator` inclusion (15 operators), `field_value` presence (except is_null/is_not_null), `join_type` inclusion (3 types), `field_name` presence + format (`/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/`), operator-specific validation (between requires 2 values, in/not_in requires 1+)
- **ResourceField mask_strategy validation** — when `mask_access: true`, `mask_strategy` must be present and one of `full`, `email`, `last4`, `first1_last4`
- **MaskValue strict mode** — raises `ArgumentError` for unknown strategies instead of silent fallback to `full`

**Phase 2: GDPR Configuration Defaults**
- **`gdpr_defaults` now defaults to `true`** — safe-by-default for new installations
- **`config.gdpr_require_explicit_choice`** — when `true`, raises `ConfigurationError` at boot if `gdpr_defaults` was never explicitly set
- **`grant_all: true` respects GDPR masks** — `grant_all` grants read/edit access but does NOT unmask GDPR fields
- **GDPR Masking Disclaimer** — new `docs/gdpr_masking_disclaimer.md` documenting that masking is display-level obfuscation, not GDPR anonymization

**Phase 3: Unconfigured Field Strategy & GdprFieldAuditor**
- **`config.unconfigured_field_strategy`** — choose how unmapped fields are handled in `FiltersResponseAttributes`: `:pass_through`, `:warn` (default), `:mask_all`, `:block`
- **GdprFieldAuditor extended** — now detects unmapped model columns (no ResourceField exists) matching GDPR patterns, in addition to existing unmasked field detection. Report items include `type: :unmasked_field` or `type: :unmapped_column`

**Phase 4: Production Safety & BETWEEN Coercion**
- **Production MemoryCache warning** — logs warning at boot when using in-process MemoryCache in production (permissions will be inconsistent across Puma workers)
- **BETWEEN type coercion** — auto-coerces integer, float, and date string pairs for the `between` operator

**Phase 5: API Hardening**
- **`config.api_stats_require_admin`** — when `true`, the `/api/stats` endpoint returns 403 unless `@admin = true` is set by the auth lambda
- **BulkPermissionSetAssignment nil safety** — gracefully handles `nil` action parameter

**Phase 6: GDPR Pattern Validation & Drift Protection**
- **GDPR pattern regex validation** — invalid regex patterns in `gdpr_field_patterns` raise `ConfigurationError` at config time
- **`rake permission_forge:audit_masks`** — CI-friendly rake task that exits non-zero when GDPR audit finds issues
- **Pattern drift detection** — `config.gdpr_patterns_changed_since_generation?` detects when patterns changed since last `ResourceFieldGenerator` run

**Phase 7: Low-Priority Hardening**
- **HTTP Basic Auth boot warning** — logs warning when HTTP Basic Auth is enabled but credentials are blank
- **PermissionSet name length validation** — `validates :name, length: { maximum: 255 }`
- **`PermissionSetRule.recently_deactivated` scope** — queryable scope for rules deactivated within the last 7 days
- **`config.on_field_filtered` audit hook** — optional lambda called for each field processed by `FiltersResponseAttributes` with `action: :hidden | :masked | :passed`. Errors in the hook are rescued and logged — never break filtering.

### Changed
- **`gdpr_defaults` default: `false` → `true`** — existing apps that explicitly set `gdpr_defaults = false` are unaffected
- **`unconfigured_field_strategy` default: `:warn`** — previously unconfigured fields silently passed through (`:pass_through` behavior). Now logs a warning. Set to `:pass_through` to restore old behavior.
- **GdprFieldAuditor report format** — report items now include a `:type` key (`:unmasked_field` or `:unmapped_column`). Existing fields like `:field_name`, `:suggested_strategy` are preserved.
- **MaskValue load order** — `mask_value.rb` is now required before models (was after) to support `MaskValue::STRATEGIES` constant in ResourceField validation

### Performance
- **Zero measurable regression** on hot paths (cache lookups, read-path filtering, row-level rules)
- Read-path: +2.7% on mixed access scenario (from audit hook nil-check overhead)
- Cache lookups: unchanged (~0.026ms/call)
- Row-level rules: unchanged (~0.28ms/rule)
- Full benchmark comparison in [docs/benchmarks.md](docs/benchmarks.md#historical-v050-security-audit-impact)

### New Config Options

| Option | Default | Description |
|--------|---------|-------------|
| `gdpr_require_explicit_choice` | `false` | Raise at boot if `gdpr_defaults` not explicitly set |
| `unconfigured_field_strategy` | `:warn` | How to handle unmapped fields in read-path |
| `on_field_filtered` | `nil` | Audit hook for field-level compliance logging |
| `api_stats_require_admin` | `false` | Gate dashboard stats behind admin flag |

### New Constants

| Constant | Location | Description |
|----------|----------|-------------|
| `PermissionSetRule::OPERATORS` | `Operators::Constants` | Frozen array of 15 valid operators |
| `PermissionSetRule::JOIN_TYPES` | `Operators::Constants` | Frozen array of 3 valid join types |
| `MaskValue::STRATEGIES` | `Services::MaskValue` | Frozen array of 4 valid mask strategies |
| `BulkPermissionSetAssignment::VALID_ACTIONS` | `Services::BulkPermissionSetAssignment` | `%i[assign revoke]` |

### Tests
- **72 new tests** (446 → 518 total), 96.11% line coverage
- New test files for all validation, configuration, and service changes

## [0.4.0] - 2026-03-11

### Added
- **15 Operators** — expanded from 6 to 15 row-level rule operators
  - Comparison: `equal`, `not_equal`, `less_than`, `greater_than`, `less_than_or_equal`, `greater_than_or_equal`
  - Set: `in`, `not_in`
  - String: `contains`, `not_contains`, `starts_with`, `ends_with`
  - Range: `between`
  - Null: `is_null`, `is_not_null`
- **ViewAll / ModifyAll** — resource-level permissions that bypass all row-level rules (Salesforce-inspired)
  - `can_view_all?` and `can_modify_all?` helpers on PermissionedUser
  - `PermissionScopedFindable` automatically skips rules when enabled
- **Dependency Validations** — enforced at model level
  - `edit_access` requires `read_access` (on Resource and ResourceField)
  - `delete_access` requires `read_access` (on Resource)
  - `modify_all` requires `view_all` (on Resource)
  - `mask_access` requires `read_access` (on ResourceField)
- **Bulk Assign/Revoke** — `BulkPermissionSetAssignment` service for batch user ↔ permission set operations with single cache regeneration pass
- **YARD Documentation** — minimal `@param`, `@return`, `@example` docs on all public APIs (PermissionedUser, PermissionScopedFindable, all services, Operators::Registry)

### Changed (Internal — no breaking changes)
- **Strategy Pattern: Operators::Registry** — replaced 15-branch case/when in `PermissionScopedFindable` with frozen Hash registry of callable operator objects. O(1) lookup, open/closed for extension.
- **HasPermissionSetUsers concern** — extracted duplicated `users_on_permission_set` logic from 5 models into a shared concern with 3 strategies (`:self`, `:direct`, `:via_resource`)
- **ValidatesDependency concern** — extracted 5 identical validation methods across Resource and ResourceField into a declarative DSL (`validates_dependency :field, requires: :other`)
- **CrudActions concern** — extracted duplicate CRUD methods from 4 API controllers into a Template Method concern (index/show/create/update/destroy)

### Performance
- Read-path overhead improved: ~0.05ms/record (was ~0.08ms)
- Cache lookups improved: ~0.046ms/call (was ~0.07ms)
- Write-path overhead: ~0.10ms/request (was ~0.15ms)

### Fixed
- **Resource `label` column** — added `label` field to resources table in install migration and dummy schema for human-readable resource names in the admin UI
- **Resource uniqueness** — added `validates :name, uniqueness: { scope: :permission_set_id }` and a composite unique index (`permission_set_id`, `name`) to prevent duplicate resources within a permission set
- **Auto-generate fields idempotent** — `ResourceFieldGenerator` now skips columns that already have a `ResourceField` record, preventing duplicates on repeated use
- **Admin UI: Resource form** — added permission set dropdown to the new resource form, preventing `NOT NULL` constraint errors on `permission_set_id`
- **Admin UI: User assignment** — `PermissionSetUsersController#create` now uses `find_by` instead of `find`, returning a translated flash error instead of crashing with `RecordNotFound` when the user doesn't exist
- **Admin UI: Resource create** — added `NotNullViolation` rescue in `ResourcesController#create` so missing `permission_set_id` renders the form with validation errors instead of a 500
- **Admin UI: i18n completeness** — added `permission_set_label`, `permission_set_prompt`, and `user_not_found` i18n keys to all 6 locales
- **Security: Brakeman SQL injection** — rewrote all 15 operators in `Operators::Registry` from raw SQL string interpolation to Arel node methods (`.eq()`, `.lt()`, `.matches()`, etc.), eliminating all 19 Brakeman warnings

## [0.3.0] - 2026-03-10

### Added
- **Admin JSON API** — built-in RESTful JSON endpoints for managing permissions programmatically
  - 9 API controllers under `PermissionForge::Api::` namespace
  - Full CRUD for permission sets, resources, fields, actions, rules, groups
  - Clone permission set, auto-generate fields, dashboard stats
  - Lightweight built-in serializers with AMS override support
  - Configurable pagination, record identifier, and authentication
- **API Authentication** — 3-tier: lambda auth, base controller inheritance, or locked-by-default
- **Configuration** — `api_enabled`, `api_auth`, `api_base_controller_class`, `api_pagination_handler`, `api_record_identifier`, `api_serializer_overrides`

### Fixed
- **HTML Admin UI** — added `mask_access` checkbox and `mask_strategy` dropdown to resource fields form

## [0.2.0] - 2026-03-10

### Added
- **FiltersResponseAttributes** — read-path attribute filtering service (parallel to write-path `PermitsAttributes`)
  - Removes fields without `read_access`, masks fields with `mask_access`, unconfigured fields pass through
  - Framework-agnostic — works with any serializer (AMS, Blueprinter, jbuilder, etc.)
  - Non-mutating (returns new hash), single cache read, O(n) per object
- **Masked Attributes** — field-level masking with `mask_access` and `mask_strategy` columns on ResourceField
  - 4 built-in strategies: `full`, `email`, `last4`, `first1_last4`
  - `MaskValue` service for applying masks to values
  - `masked_field?`, `mask_strategy_for`, `field_permissions` helpers on PermissionedUser
- **GDPR Defaults** — auto-mask PII fields when generating resource fields
  - `config.gdpr_defaults = true` enables automatic masking on field creation
  - `DEFAULT_GDPR_FIELD_PATTERNS` covers email, phone, name, address, SSN, IBAN, DOB, IP
  - `config.gdpr_field_patterns` for extending or overriding patterns
  - `GdprFieldAuditor` service to scan existing fields for unmasked GDPR-sensitive data
- **Custom Resource Actions** — admin-configurable actions per resource (sync, export, approve, etc.)
  - New `ResourceAction` model (8th model) with `name`, `is_permitted`, `is_active`
  - `can?(action, resource)` generic method on PermissionedUser — delegates CRUD, checks custom actions
  - Actions included in cached permission hash under `actions:` key
  - `PermissionSet#deep_clone` clones resource actions

### Changed
- Cache format: field entries now include `mask_access` and `mask_strategy` (additive, backward-compatible)
- Cache format: resource entries now include `actions` hash (additive, backward-compatible)
- `PermissionHashBuilder` includes mask metadata and resource actions in output
- Migration template includes `resource_actions` table and mask columns on `resource_fields`

### Fixed
- **Multi-set merge: most permissive wins** — when a user belongs to multiple permission sets:
  - `mask_access`: changed from last-wins to AND logic (FALSE = unmasked wins)
  - `mask_strategy`: changed from last-wins to first-wins (`||=`)
  - Resource action `is_permitted`: changed from last-wins to OR logic (TRUE wins)
  - Resource CRUD and field read/edit already used `||=` (TRUE wins) — no change needed

## [0.1.0] - 2026-03-10

### Added
- Initial release
- Configuration DSL with configurable user resolution, cache backend, table prefix
- 7 ActiveRecord models: PermissionSet, PermissionSetUser, PermissionSetGroup, PermissionSetGroupUser, Resource, ResourceField, PermissionSetRule
- PermissionedUser concern (permission generation, caching, access checks)
- PermissionScopedFindable concern (row-level query enforcement)
- PermissionsRegenerator concern (cascading permission refresh)
- HasUuid and HasAuditTrail utility concerns
- Cache backends: Redis, Memory, Null
- PermissionHashBuilder, PermitsAttributes, ResourceFieldGenerator services
- Install generator (migration + initializer)
- Admin API generator (controllers, serializers, routes)

[Unreleased]: https://github.com/fetijashari/permission_forge/compare/v0.14.1...HEAD
[0.14.1]: https://github.com/fetijashari/permission_forge/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/fetijashari/permission_forge/releases/tag/v0.14.0
