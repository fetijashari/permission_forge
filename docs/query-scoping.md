# Query Scoping — Three Configurable Defense Levels

Out of the box, PermissionForge applies row-level rules on the class-level `Model.find_by` /
`Model.find_by!` and the explicit `Model.permission_scoped` relation. Plain `Model.where(...)`,
`.all`, `.find(id)`, `.first`, association traversal (`user.customers`), and `find_by` called on a
relation or an association (`Model.where(nil).find_by!`, `Model.unscoped.find_by`,
`user.customers.find_by`, `Model.find_sole_by`) do **not** apply rules.

A user with no rules for a model sees every row: rules only narrow. Rules from several granting
sets apply together (AND), and for an STI subclass the rules of its own resource and of every
ancestor's apply together — see [row-level-rules.md](row-level-rules.md#several-permission-sets).

This guide covers the three optional defense levels that close that gap. Each is
independently configurable and **all default to OFF** — nothing changes until you opt in.

| Level | Option | What it does |
|---|---|---|
| 1 — ENFORCE | `auto_query_scoping` | Auto-applies filter-type rules to every relation |
| 2 — DETECT | `unscoped_query_detection` | Logs/raises on queries that bypassed scoping |
| 3 — DATABASE | `database_row_level_security` | Postgres RLS policies enforce rules below ActiveRecord |

**Recommended adoption path:** Level 2 `:log` in development → fix flagged call sites →
Level 2 `:raise` in test/CI → Level 1 → Level 3 where rules must hold below ActiveRecord (raw SQL, other database clients).

---

## Level 1 — ENFORCE (`auto_query_scoping = :filter_only`)

```ruby fragment
PermissionForge.configure do |config|
  config.auto_query_scoping = :filter_only   # default: :off
end
```

Every relation built on a protected model (a model including
`PermissionForge::Concerns::PermissionScopedFindable`) now carries the current user's
**filter-type** rules automatically:

```ruby fragment
Customer.where(active: true)   # rules applied
Customer.all                   # rules applied
Customer.find(42)              # RecordNotFound if rule-denied
Customer.count                 # counts only permitted rows
user.customers                 # association traversal scoped too
```

### What you should know

- **Join-type rules are NOT auto-applied** (they would break `includes`/`count`). Queries
  relying on join rules must still start from `permission_scoped`. A boot warning fires
  when Level 1 is on and join rules exist.
- **Denial is silent.** Auto-scoping filters rows; it cannot attribute a denial. `find` on
  a denied row raises `RecordNotFound`. For the detailed `NotAuthorizedError` (with rule
  failure messages), use `find_by` / `permission_scoped` — their behavior is unchanged.
- **view_all / modify_all bypasses auto-scoping**, same as `find_by`: it skips the rules of
  the resource entry that grants it. The `on_rule_bypass` hook is *not* fired from the auto
  path (it would fire on every query).
- **STI subclasses** get the rules of their own resource and of every ancestor's, as with
  `find_by`. A query through the base class applies the base's rules only, also to rows of a
  subclass.
- **Nil current user** follows `nil_user_strategy`: `:bypass` → unscoped, `:deny`/`:raise`
  → empty relation (fail closed — the auto path never raises from inside a scope, so
  consoles and rake tasks don't detonate).
- **The scope is decided when the relation is built, not when it loads.** A relation built
  while there is no current user (under the default `:bypass`) stays unscoped after a user is
  set: `Customer.where(nil)` built before authentication returns every row when it is loaded
  later. Do not keep relations in constants, build them in a `before_action` that runs before
  your authentication, or capture them in lambdas created without a user; build them in the
  request, after the user is known.
- **Tenant scoping and host `default_scope`s (soft-delete) are preserved.**
- **Cost:** one permissions-cache read per relation build (the user's hash is memoized on the
  user instance, so within a request it is usually a hash lookup); hot loops can batch through
  `permission_scoped` once instead.

### Escape hatches

```ruby fragment
# Block form — intentional unscoped access (reports, admin maintenance, jobs):
PermissionForge.without_permission_scope do
  Customer.all.find_each { |c| ... }
end
```

`without_permission_scope { }` suspends auto-scoping and detection, and with nobody signed in lets `find_by`, `find_by!` and `permission_scoped` past `nil_user_strategy`; a signed-in user's `find_by` and `permission_scoped` still apply their rules (reported as `rule.bypassed`, `scope_suspended`). Inside the block nobody signed in is trusted more than a signed-in user: wrap trusted code only (jobs, seeds, rake tasks, sign-in lookups), never code an anonymous request reaches. A block that runs inside one of the gem's own suspensions (a model callback during a permission-cache invalidation or an audit lookup) is not trusted that way: there nobody signed in still follows `nil_user_strategy` (fails closed). Only the gem's admin controllers use the public block (after your authentication); the flags are per fiber.

```ruby fragment
# Per-model opt-out:
class AuditLog < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable
  self.permission_forge_auto_scope = false
end
```

---

## Level 2 — DETECT (`unscoped_query_detection = :log | :raise`)

```ruby fragment
PermissionForge.configure do |config|
  config.unscoped_query_detection = :log                        # default: :off
  config.unscoped_query_detection_environments = %w[development test]  # default
end
```

A `sql.active_record` subscriber watches SELECT/UPDATE/DELETE statements touching protected
tables. Queries that went through a permission-scoped path carry a `/* pf_scoped */` SQL
annotation and are ignored; everything else is reported:

- `:log` — `Rails.logger.warn` with the offending SQL and the first app-level call site
- `:raise` — `PermissionForge::UnscopedQueryError` (turn a missed call site into a CI failure)

### What you should know

- **It's a development/CI aid, not a production control.** Detection only activates in
  environments listed in `unscoped_query_detection_environments`. Adding `production` is
  possible but `:raise` there triggers a boot warning — a single missed query becomes an
  outage.
- **With Level 1 ON**, ordinary queries are auto-scoped (and annotated), so detection stays
  quiet and flags exactly the true escapes: `Model.unscoped`, `find_by_sql`, raw SQL.
- **With Level 1 OFF**, every bare `where`/association load is flagged — that's the
  migration-aid mode for finding call sites to convert.
- `Model.new` / `create` / INSERTs and schema queries are never flagged.
- `PermissionForge.without_permission_scope { }` silences detection for intentional access.

---

## Level 3 — DATABASE (Postgres Row-Level Security)

Levels 1–2 live in Ruby — `unscoped`, `find_by_sql`, raw SQL, and a production console all
bypass them. Level 3 pushes enforcement into PostgreSQL itself, for every statement made on a
connection whose session variable names a user. A session **without** the variable (a console,
`psql`, a job that never calls `RLS.with_user`) follows `nil_user_strategy`: under the default
`:bypass` it sees every row. Only with `nil_user_strategy = :deny` or `:raise` does such a session
see no rows:

```bash fragment
bin/rails generate permission_forge:rls   # migration: enable RLS + install policies
bin/rails db:migrate
```

```ruby fragment
PermissionForge.configure do |config|
  config.database_row_level_security = true
  # config.rls_session_variable = 'permission_forge.user_id'   # default
end
```

Then tell Postgres who the current user is:

```ruby fragment
# Controllers (around_action):
around_action do |_controller, action|
  PermissionForge::RLS.set_user!(current_user)
  action.call
ensure
  PermissionForge::RLS.clear_user!
end

# Jobs / services (transaction-scoped, self-cleaning):
PermissionForge::RLS.with_user(user) do
  Customer.unscoped.to_a   # STILL filtered — the database enforces the rules
end
```

`with_user` runs the block on the connection it sets the user on: the one the thread already holds, or one it takes for the block and gives back to the pool afterwards. `set_user!` sets the user on the connection the thread keeps for the rest of the request (`lease_connection`); pair it with `clear_user!` in an `ensure`.

`PermissionForge::RLS` works on `ActiveRecord::Base`'s connection pool. If your protected models connect through their own pool (`connects_to` on an abstract class) or you query inside `connected_to(role: :reading)`, the variable is set on a connection those queries do not use, and the policies see no user: set it yourself on the right connection (`SELECT set_config('<rls_session_variable>', '<id>', true)`), or keep the protected models on the primary pool.

Call `set_user!` / `clear_user!` at the request level (an `around_action`), never inside a `with_connection(prevent_permanent_checkout: true)` block: there the connection goes back to the pool with the variable still set, and `clear_user!` clears another one. In a thread of your own, wrap the work in `Rails.application.executor.wrap { … }` so the connection `set_user!` keeps is returned when it ends.

### How the policies work

- **Membership is dynamic.** Policies check `permission_set_users` (including `expires_at`)
  and view_all/modify_all at query time — assigning or revoking a user needs **no resync**.
- **Rule content is static.** Each granting set's active filter-type rules are compiled into
  the policy SQL — whether the set and its resource row are switched on or off at sync time.
  Whether a set and its resource row are active is read live by the policy, so switching
  either off or on needs no re-sync. After editing rules run:

  ```bash fragment
  rake permission_forge:rls:sync     # regenerate policies
  rake permission_forge:rls:status   # per-table drift report (exit 1 when stale)
  rake permission_forge:rls:remove   # drop the policies and switch row-level security off
  ```

  A digest of the rule state is stored on the policy; a boot warning fires when the live
  policies drift from the current rules.
- **Semantics parity:** muting sets contribute no rules but *do* cancel a view_all bypass;
  users in no rule-bearing set see all rows (rules only restrict); a missing session
  variable follows `nil_user_strategy` (`:bypass` allows, `:deny`/`:raise` hides all rows).
- **The view_all bypass needs a resource row in effect.** A `view_all` / `modify_all` grant
  bypasses the rules only while its resource row and its set are active and, with tenancy
  on, only for rows of the grant's own tenant: a grant in tenant A never bypasses the rules
  on tenant B's rows. A row whose tenant column is NULL gets no bypass under RLS (narrower
  than the application layer there, never wider). If the protected table has no tenant
  column, the tenant condition is left out and a grant in any tenant bypasses the rules on
  that table.
- **Values are typed like the application layer types them** (see
  [How Values Are Compared](row-level-rules.md#how-values-are-compared)): a number, a
  boolean, a date, the stored value of an enum label. A value the column cannot hold
  compiles to `FALSE` — the policy is created and hides every row from the members of that
  set, exactly as the application layer denies them. A date or time that is not ISO 8601
  is written into the policy as it is, for PostgreSQL to read. A word like `tomorrow` or
  `infinity` is read **once, when the policy is created** — it does not move with the
  clock the way it does in the application layer, which sends it with every query. Text
  PostgreSQL cannot read as a date fails the sync at that table: its policies, and those of
  the tables that come after it, stay as they were. Use ISO dates in rules that back a
  policy. `contains` and the other string operators compile to `ILIKE` on the column itself
  (the padding of a `char(n)` value counts, as in the application layer), and
  `include_nulls` adds the NULL rows for `equal`, `not_equal`, `in` and `not_in` only — both
  as in the application layer.
- **A policy is never wider than the application layer.** Where the application layer's
  query raises — a string operator on a number, date or boolean column — the rule compiles
  to `FALSE`. A field name that is not a name (`owner_id.`) compiles to `FALSE` as well, and
  so does one that is not a column of the table (`onwer_id`), which the application layer
  denies too (see [Using the wrong field name](row-level-rules.md#using-the-wrong-field-name)).
- **What a rule compiles to also depends on the model** — the column's type, an enum's
  stored values. Re-sync after changing either; the drift report covers the compiled SQL.
- **After upgrading the gem,** `rake permission_forge:rls:status` reports drift whenever the
  generated SQL changed between versions (`RlsPolicyGenerator::GENERATOR_VERSION`, part of
  the stored digest). Run `rake permission_forge:rls:sync` once after the upgrade. Until you
  do, the old policies stay in force.
  - **Version 6:** a rule whose field name is not a column of the table compiles to
    `FALSE`; the sync used to fail at that table.
  - **Version 5 (0.14):** the view_all bypass requires the resource row to be active and,
    with tenancy on, in the row's tenant (rows with a NULL tenant get no bypass); a rule set
    is compiled whatever its set's and resource row's state, and its membership check
    requires the resource row to be active, so switching a set or a resource off or on is
    live without a re-sync. Policies from before 0.14 are wider than the application layer
    in these cases: a switched-off view_all row still bypasses the rules, and a view_all
    grant in one tenant bypasses them on every tenant's rows.
  - **Version 3 (value typing):** policies older than that are also wider in these cases: a
    string operator compared case-sensitively (`not_contains 'acme'` still shows `ACME`
    rows); `include_nulls` adds the NULL rows for every operator (`is_not_null` with it
    shows every row); a string operator on a number column matches the number's text; and
    a pattern on a `char(n)` column ignores the padding.
- **Not translatable:** join-type rules and dotted field names — they are reported by the
  sync task (`skipped_rules`, and a log line) and enforced at the application layer only.
- **Activation conditions cannot be evaluated in a policy.** The application layer selects a
  user's conditional sets per request (see [activation-conditions.md](activation-conditions.md));
  a policy has no request context. So a conditional set's rules always apply, whether or not its
  conditions hold, and only unconditional sets grant the view_all bypass (a conditional muting
  set still cancels it). The policy is narrower than the application layer here, never wider.
- **STI subclass rules are application-layer only.** A policy is per table and compiled for
  the class that includes the concern. Rules on a `Resource` named after an STI subclass of
  it are not compiled; they are reported as skipped (reason `sti_subclass_resource`). The
  report only sees subclasses that are loaded when the sync runs: run
  `rake permission_forge:rls:sync` with eager loading (`config.rake_eager_load = true`), or
  the rules of a subclass that was not loaded are left out of the report without a word. The same holds for the protected models themselves: the sync
  covers the models that include `PermissionScopedFindable` and are loaded when it runs.

### Critical deployment notes

- **Connect as a regular role.** Superusers and roles with `BYPASSRLS` skip policies
  entirely. The generated migration uses `FORCE ROW LEVEL SECURITY` so even the table owner
  is subject to them — but a superuser never is.
- Under RLS a denied row is *invisible*: `find_by` on it reports missing (nil /
  `RecordNotFound`) instead of `NotAuthorizedError`. That's inherent — the database conceals
  the row's existence, which is usually the stronger security posture.
- Requires PostgreSQL. Enabling `database_row_level_security` on another adapter logs a boot
  warning and RLS helpers raise `ConfigurationError`.

---

## What each level does — and does not — stop

| Attack / mistake | L1 ENFORCE | L2 DETECT | L3 RLS |
|---|---|---|---|
| Forgotten `permission_scoped` on `where`/`all` | ✅ scoped | ✅ flagged | ✅ filtered |
| `find(id)` on a denied row | ✅ `RecordNotFound` | ✅ flagged | ✅ `RecordNotFound` |
| Association traversal | ✅ scoped | ✅ flagged | ✅ filtered |
| `Model.unscoped` | ❌ | ✅ flagged | ✅ filtered |
| `find_by_sql` / raw SQL | ❌ | ✅ flagged | ✅ filtered |
| Production console | ❌ | ❌ (env-gated) | ✅ filtered only with `nil_user_strategy :deny/:raise` or the session variable set; under the default `:bypass` every row is visible |
| Superuser / `BYPASSRLS` DB role | ❌ | ❌ | ❌ |
| Join-type rules on bare `where` | ❌ (warned) | ✅ flagged | ❌ (filter rules only) |

No single level is airtight; together they are defense in depth. Be honest with your
security review about which levels you run and which caveats apply.

## Testing your app with levels enabled

- Enable Level 2 `:raise` in your test environment to catch unscoped queries in CI.
- The gem's own RLS enforcement suite runs against real Postgres
  (`DB=postgres bundle exec rake test:rls`) — use it as a template for host-app RLS tests.
- `PermissionForge.without_permission_scope` around test data setup avoids fighting the
  scoping while arranging fixtures.
