# Row-Level Rules

Row-level rules let you restrict **which records** a user can access, not just whether they can access a resource at all.

## The Problem

Without row-level rules, if a user `can_read?('Customer')`, they can see **all** customers. But in a multi-tenant app, you might want:
- Users to only see records **they own**
- Regional managers to only see records **in their region**
- Team members to only see records **assigned to them**

Row-level rules solve this.

> **Where rules apply.** With the default `auto_query_scoping = :off`, rules only apply to the class-level `Model.find_by`, `Model.find_by!` and `Model.permission_scoped`. Everything else returns every record: a bare `where`, `all`, `find`, an association (`supplier.customers.find_by(...)`), a `find_by` on a relation (`Customer.where(...).find_by(...)`, `Customer.unscoped.find_by(...)`) and `find_sole_by`. Set `auto_query_scoping = :filter_only` to apply filter rules to every query (join rules still need `permission_scoped`); see [Query scoping](query-scoping.md). The admin Home lists rules that aren't applied everywhere, and the Rules tab warns about them.
>
> **No rules means no restriction.** A user who has no active rule for a model — including a user with no `Resource` row for it at all — gets every row through `find_by` and `permission_scoped`. Rules only ever narrow.

## How It Works

1. You create a `PermissionSetRule` that defines a filter condition
2. You include `PermissionScopedFindable` in your model
3. Every time `Model.find_by(...)` / `Model.find_by!(...)` is called on the class, the rule's condition is applied to the query
4. If the record exists but doesn't match the rule, `NotAuthorizedError` is raised (a record that does not exist gives `nil`, as in Rails)

### What is enforced

The concern overrides the class methods `find_by` and `find_by!`, and adds a `permission_scoped` relation. It does **not** rewrite `find` (by primary key), bare `where`, `first`, `all`, association traversal, or `find_by` called on a relation or an association — Rails resolves those through relation methods the concern does not hook. With `auto_query_scoping = :off` (the default) these all skip the rules:

```ruby
Customer.where(active: true).find_by(uuid: uuid)  # no rules
supplier.customers.find_by(uuid: uuid)            # no rules
Customer.where(nil).find_by!(uuid: uuid)          # no rules
Customer.unscoped.find_by(uuid: uuid)             # no rules
Customer.find_sole_by(uuid: uuid)                 # no rules
```

- Use the class-level **`Customer.find_by` / `Customer.find_by!`** for single-record lookups.
- Start from **`Model.permission_scoped`** to get a rule-constrained relation you can chain freely:

```ruby
Customer.permission_scoped                      # rules applied
Customer.permission_scoped.where(active: true)  # rules carried through
Customer.permission_scoped.order(:name).first   # still scoped
Customer.permission_scoped.find(id)             # scoped find by PK
```

`permission_scoped` honors `view_all`/`modify_all` (returns the unconstrained relation) and `nil_user_strategy` (`:bypass` → all, `:deny` → none, `:raise` → raises).

## Step 1: Include the Concern

Add `PermissionScopedFindable` to any model you want to protect:

```ruby
class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable
end
```

> **What this does:** It overrides `Customer.find_by(...)` so that permission rules are checked before returning the record.

## Step 2: Create a Rule

```ruby
PermissionForge::PermissionSetRule.create!(
  permission_set: sales_pset,
  resource: customer_resource,
  name: 'Own Records Only',
  failure_message: 'You can only view your own records',
  field_name: 'owner_id',
  field_value: 'current_user',  # Magic value — replaced with PermissionForge.current_user.id at runtime
  operator: 'equal',
  include_nulls: true           # Also allow records where owner_id IS NULL
)
```

No refresh step is needed: saving the rule invalidates the cached permissions of everyone who holds its Permission Set, and their next permission read rebuilds them.

## Step 3: It Just Works

```ruby
Current.user = user  # user.id = 42

# This record is owned by the current user
customer_a = Customer.create!(name: 'Acme', owner_id: 42)

# This record is owned by someone else
customer_b = Customer.create!(name: 'Beta', owner_id: 99)

Customer.find_by(uuid: customer_a.uuid)
# => #<Customer id: 1, name: "Acme", owner_id: 42>  (allowed!)

Customer.find_by(uuid: customer_b.uuid)
# => raises PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError
```

## Available Operators

### Comparison Operators

| Operator | SQL Equivalent | Example Use Case |
|----------|---------------|-----------------|
| `equal` | `= value` | Show only my own records |
| `not_equal` | `!= value` | Hide records from a specific source |
| `less_than` | `< value` | Show records below a threshold |
| `greater_than` | `> value` | Show records above a threshold |
| `less_than_or_equal` | `<= value` | At most X |
| `greater_than_or_equal` | `>= value` | At least X |

### Set Operators

| Operator | SQL Equivalent | Example Use Case |
|----------|---------------|-----------------|
| `in` | `IN (a, b, c)` | Show records matching a list of values |
| `not_in` | `NOT IN (a, b, c)` | Exclude records matching a list |

For `in` and `not_in`, pass a **comma-separated** `field_value`:

```ruby
PermissionForge::PermissionSetRule.create!(
  # ...
  operator: 'in',
  field_value: 'active,pending,review',  # Comma-separated list
  include_nulls: false
)
```

### String Operators

| Operator | SQL Equivalent | Example Use Case |
|----------|---------------|-----------------|
| `contains` | `LIKE '%value%'` | Match records containing a substring |
| `not_contains` | `NOT LIKE '%value%'` | Exclude records containing a substring |
| `starts_with` | `LIKE 'value%'` | Match records starting with a prefix |
| `ends_with` | `LIKE '%value'` | Match records ending with a suffix |

> **Note:** Special characters (`%`, `_`, `\`) in the field value are escaped and match literally, on every database (the generated SQL carries an `ESCAPE` clause). On MySQL with the `NO_BACKSLASH_ESCAPES` SQL mode this holds with the trilogy adapter; the mysql2 adapter cannot quote any text in that mode (`Mysql2::Client#escape` raises), so there a rule with a text value raises, as it always did. Whether upper and lower case differ is the database's matter: PostgreSQL gets `ILIKE`, MySQL follows the column's collation and SQLite ignores case for ASCII letters — so in practice these operators ignore case. They are meant for string and text columns; on PostgreSQL, using one on a number or date column raises.

### Range Operator

| Operator | SQL Equivalent | Example Use Case |
|----------|---------------|-----------------|
| `between` | `BETWEEN low AND high` | Show records within a date or numeric range |

For `between`, pass **exactly two comma-separated values** (low, high), each a value of the column's type:

```ruby
PermissionForge::PermissionSetRule.create!(
  # ...
  operator: 'between',
  field_value: '2024-01-01,2024-12-31',  # low,high
  include_nulls: false
)
```

### Null Operators

| Operator | SQL Equivalent | Example Use Case |
|----------|---------------|-----------------|
| `is_null` | `IS NULL` | Show records with no value assigned |
| `is_not_null` | `IS NOT NULL` | Show only records that have a value |

> **Note:** `is_null` and `is_not_null` take no `field_value`. Leave it out (it is stored as an empty string); a rule that has a value with one of these operators is refused when it is saved.

## The `include_nulls` Flag

When `include_nulls` is `true` and the operator is `equal`, the generated SQL is:

```sql
WHERE owner_id IS NULL OR owner_id = 42
```

When `include_nulls` is `false`:

```sql
WHERE owner_id = 42
```

> **Tip:** Set `include_nulls: true` if you want to also show records that haven't been assigned yet (NULL values).

`include_nulls` applies to `equal`, `not_equal`, `in` and `not_in`. The other operators ignore it — in the application layer and in a generated RLS policy alike.

## How Values Are Compared

A rule's `field_value` is text. Before it reaches the database it is turned into a value of the **type of the column** it is compared with, so a rule selects the same rows on PostgreSQL, MySQL and SQLite:

| Column type | The value has to be | Compared as |
|-------------|--------------------|-------------|
| integer, bigint, decimal, float | a number: `5`, `+5`, `-0.25`, `.5`, `1e3` (surrounding spaces are fine) | a number — `5.5` on an integer column and a number past the column's range compare numerically, they never raise |
| boolean | `true` `t` `yes` `y` `on` `1` or `false` `f` `no` `n` `off` `0`, in any case | a boolean |
| string, text | anything | text, as written |
| date | an ISO 8601 date, `2026-01-31` (a time after it is ignored); on PostgreSQL also whatever PostgreSQL reads as a date — see below | a date |
| datetime | an ISO 8601 date-time: `2026-01-31`, `2026-01-31 14:30`, `2026-01-31T14:30:00Z`, `2026-01-31 14:30:00+02:00`; on PostgreSQL also whatever PostgreSQL reads | a point in time; without an offset it is read in the time zone the database stores times in (`ActiveRecord.default_timezone`, UTC unless you changed it) |
| time | a time of day, `14:30` or `14:30:00` (`9:05` is fine); on PostgreSQL also whatever PostgreSQL reads | a time of day |
| an `enum` attribute | one of the enum's labels (`archived`), or the stored value (`1`) | the value the model stores for the label — for a string-backed enum too (`enum :tier, { gold: 'G' }`: `gold` is compared as `G`, where it used to be compared as the text `gold`). A value that is a label always means that label, also when it happens to equal another label's stored value |

**A value the column cannot hold makes the rule match nothing.** `owner_id equal '5_id'` and `active equal 'maybe'` let no record through — on every database, for the negative operators (`not_equal`, `not_in`) too, and `include_nulls` adds no NULL rows to such a rule. The rule denies; it never widens access. The same holds for `between` without exactly two values, for an empty list, and for a list with one element the column cannot hold. `bin/rails permission_forge:audit` lists the rules in effect that match nothing for this reason (`unusable_rule_values`) — worth running after an upgrade. A field name that is not a column of the table matches nothing as well — see [Using the wrong field name](#using-the-wrong-field-name).

Things worth knowing:

- **Number notation is strict.** `0x1F`, `1_000`, `NaN` and `Infinity` are not numbers here, whatever your database would make of them. Neither is a number past the range of a double-precision float (`1e999`, `1e-400`).
- **ISO 8601 is the portable notation for dates and times.** It is typed the same way on every database. Any other text — `31.01.2026`, `Jan 31 2026`, `today`, `now`, `infinity`, `someday` — matches nothing on MySQL and SQLite. On PostgreSQL such text is handed to PostgreSQL exactly as written, as it always was: PostgreSQL reads it in its own notations (`due_on less_than '31 Jan 2026'` and `due_on between 'yesterday,tomorrow'` keep working) and raises on text it cannot read (`someday`). The model's validation is narrower than PostgreSQL for the ordering operators — it takes a number or a date Ruby can parse, so `less_than 'today'` cannot be saved through the model, the admin or the API; a rule like that only exists where it was written past the validation (SQL, `update_column`, another application on the same tables), and it is still read by PostgreSQL. Two things to know before relying on PostgreSQL's notations: the rule means nothing on another database, and **in an RLS policy PostgreSQL reads such a word once, when the policy is created** — `tomorrow` in a policy is the day after the last `rls:sync`, while the application layer reads it with every query. That was always so; prefer ISO dates in rules that back a policy.
- **An offset in a date-time is applied.** `2026-01-31 14:30:00+02:00` is 12:30 UTC on every database. On a PostgreSQL `timestamp without time zone` column — what `t.datetime` creates — PostgreSQL used to ignore the offset and compare with 14:30.
- **Single-precision float columns.** On PostgreSQL a `real` column gets the number as text, so PostgreSQL compares in single precision and `equal '0.1'` finds a stored 0.1, as it always did. (`between` with two plain numbers is the exception it always was: those bounds go as numbers and are compared in double precision, where a stored 0.1 is a little more than 0.1.) MySQL compares a `FLOAT` column — which is what `t.float` creates there — in double precision whatever it is compared with, so `equal '0.1'` does not find a stored 0.1 on MySQL (`0.5`, which a float holds exactly, is found); use `DOUBLE` (`t.float ..., limit: 53`) or `DECIMAL` for a column a rule has to equal. SQLite only has double precision.
- **`current_user`** stands for the user's id wherever one value is compared (`equal`, `less_than`, `contains`, ...). On a string column it is compared as the id's text; on a boolean or date column it matches nothing. Inside an `in` / `not_in` list or a `between` range it is **not** replaced — there it is the literal text `current_user`: an element like any other on a string column, and on a number column a value the column cannot hold, so the rule matches nothing. (It never worked there: PostgreSQL raised, and MySQL read the word as 0 and matched the rows with id 0.)
- **Boolean words are the whole words in the table.** PostgreSQL also reads a prefix (`tr`, `fal`, `ye`, `of`); a rule written that way now matches nothing on every database.
- **A MySQL `tinyint(1)` column is a boolean** to ActiveRecord, and so to a rule: only the boolean words above match, also when the column holds other numbers. `equal '2'` matches nothing; use a wider integer type for a column that is not a flag.
- **LIKE operators on an enum column search what is stored**, not the labels: `status contains 'arch'` looks for `arch` in the stored value (and raises on PostgreSQL when that is a number).
- **String comparisons follow the column's collation on MySQL and SQLite.** With MySQL's default collations (`utf8mb4_0900_ai_ci`, `utf8mb4_general_ci`) `equal`, `in` and `between` on a string column ignore case and accents: `status equal 'active'` also matches `Active` and `áctive`. PostgreSQL compares exactly unless the column has a case-insensitive collation or type. Give the column a binary or `_cs` collation if a rule has to tell them apart. Which string is "less than" another (`less_than`, `between`, ...) is the collation's decision on every database.
- **Dotted field names** (`customers.owner_id`, or `users.active` on a rule with a `field_accessor_path`) are typed too, when the table is the rule's own model's or one along its association path — with a schema or database in front as well (`public.customers.owner_id`).
- **A field name is looked up the way the database resolves it**: without regard to case on MySQL and SQLite (`Owner_ID` is `owner_id` there; PostgreSQL rejects it), and among the table's columns, so a column in the model's `ignored_columns` is typed too.
- **A field name with an empty part** — a trailing, leading or doubled dot (`owner_id.`, `customers..owner_id`) — is not a name. It cannot be saved on a new rule or by renaming one; a rule that already carries such a name matches nothing (and is listed by the audit).
- **Column types without an entry above** — arrays, `uuid`, `json`, `inet`, PostgreSQL enum types — and field names that are not a known column get the value exactly as written, and the database decides.
- **Custom operators.** A strategy registered under a name of your own (through an injected `operator_registry:`) receives the value untouched, with `current_user` replaced by the id. The built-in `in`, `not_in` and `between` strategies receive an Array of typed values.
- **A strategy of your own registered under a built-in operator name** receives the typed value — Integer or BigDecimal, `true`/`false`, Date or Time, String, and an Array for `in`, `not_in` and `between` — and is not called at all when the value is one the column cannot hold: the rule matches nothing.
- **Two names are still left to the database, untyped:** the table alias ActiveRecord gives a self-join (`parents_customers.active` on a rule whose path leads back to the same table), and the row id pseudo-column (`_rowid` on MySQL, `rowid` on SQLite). On MySQL and SQLite a value such a column cannot hold is then converted or compared as text, as every value was before. Name the column itself.

## The `current_user` Magic Value

When `field_value` is the string `'current_user'`, it's automatically replaced with `PermissionForge.current_user.id` at query time.

This is how you create "show me only my records" rules without hardcoding user IDs.

## Rules with Joins (Nested Associations)

Sometimes the field you want to filter on isn't directly on the model — it's on a related model. For example, you want to filter Customers by the user associated with the organization's members.

```ruby
PermissionForge::PermissionSetRule.create!(
  permission_set: pset,
  resource: customer_resource,
  name: 'Organization Member Rule',
  failure_message: 'Not a member of this organization',
  join_type: 'left_joins',                            # How to join
  field_accessor_path: 'organization.members.user',   # Association chain
  field_name: 'id',                              # Field on the final joined table
  field_value: 'current_user',
  operator: 'equal',
  include_nulls: false
)
```

### Join Types

| Join Type | When to Use |
|-----------|-------------|
| `joins` | Record **must** have the association (INNER JOIN) |
| `left_joins` | Record **may** have the association (LEFT JOIN) |
| `left_outer_joins` | Same as `left_joins` but more explicit |

Leave `join_type` out (`nil`) for a filter on the model's own table. The model accepts `nil` or one of the three values above; anything else — an empty string and `filter` included — is refused when the rule is saved. A row written past the model (SQL, another application on the same tables) is read like this: a blank `join_type` or `filter` is a filter on the model's own table, and anything else raises `PermissionForge::ConfigurationError` in `find_by`, `find_by!` and `permission_scoped` (it is never passed to the relation as a method name).

### How `field_accessor_path` Works

The path `'organization.members.user'` tells PermissionForge to:
1. Join `customers` to `organizations` (via `customer.organization`)
2. Join `organizations` to `members` (via `organization.members`)
3. Join `members` to `users` (via `member.user`)
4. Apply the `field_name` filter on the final joined table (`users.id = current_user.id`)

> **Important:** The association names in `field_accessor_path` must match your ActiveRecord association names exactly.

## Handling Denials

Two errors refuse access. This section is the one place for both; [Controller Actions](controller-actions.md#2-answer-denied-requests) links here.

| Error | Raised by | Readers |
|-------|-----------|---------|
| `PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError` | `find_by` / `find_by!` when a row-level rule denies a record that exists; `find_by` / `find_by!` / `permission_scoped` with nobody signed in under `nil_user_strategy = :raise` | `failure_messages`, `message`, `details`, `user`, `record_id`, `record` |
| `PermissionForge::ActionNotAuthorizedError` | `ControllerActionGuard`, before the action runs | `resource`, `action`, `controller_path`, `reason`, `user`, `record` |

### The default: 403 Forbidden

The engine registers both errors in `config.action_dispatch.rescue_responses` as `:forbidden`, so a denial your app does not rescue answers **403**, the way Rails answers 404 for `ActiveRecord::RecordNotFound`. Through 0.14.1 it was a 500. Rails looks the status up by the exact class name, so only these two classes are mapped: a subclass your app defines answers 500 unless you register it too.

What the response looks like depends on Rails' error pages, not on the gem:

- **Production** (`consider_all_requests_local = false`): `ActionDispatch::PublicExceptions` renders `public/403.html` (or `public/403.<locale>.html`). **Rails apps ship no `public/403.html`**, so an HTML request gets a 403 with an empty body, and the browser shows its own error page, until you add one (below) or rescue the error. A JSON request gets `{"status":403,"error":"Forbidden"}`.
- **Development**: the debug page, with status 403.
- **Request tests**: under `config.action_dispatch.show_exceptions = :rescuable` (what a Rails 7.1+ app generates in `config/environments/test.rb`) the test now gets the 403 response, as it gets a 404 for `RecordNotFound`: a test that wrapped the request in `assert_raises` asserts `assert_response :forbidden` instead. Under `:none` the error still raises in the test.

Add `public/403.html` yourself. Do not start from a copy of Rails' `public/404.html`: in Rails 8 its "404" and "Not Found" are drawn by an inline SVG, so a copy with the text changed still shows "404 Not Found". A page of its own is enough:

```html
<!-- public/403.html -->
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Not allowed (403)</title>
  </head>
  <body>
    <h1>You are not allowed to see this page</h1>
    <p>Your account does not give you access to it. If you think it should, ask an administrator.</p>
    <p><a href="/">Back to the start page</a></p>
  </body>
</html>
```

The handler below renders the same file when it has no other page to send the visitor to.

Like every mapped exception, an unrescued denial is not reported to `Rails.error` as an unhandled exception. The denial is still in the audit log: `access.denied` (rule) and `action.denied` (guard) are stored whenever the audit log is on (`audit_runtime_events` holds `:denied` by default; see [audit-log.md](audit-log.md)).

**Opting out.** A `rescue_from` in your controller runs first and decides (below). To answer a different status without a handler, set it in `config/application.rb` or `config/environments/*.rb` — `config/initializers` run after Rails has read the setting:

```ruby
# config/application.rb — e.g. hide that the record exists
config.action_dispatch.rescue_responses['PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError'] = :not_found
```

### Rescuing them yourself

An HTML app (`ActionController::Base`):

```ruby
class ApplicationController < ActionController::Base
  rescue_from PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError do |error|
    respond_to do |format|
      format.html do
        # The rules' own messages, as the admin wrote them ([] when no rule denied).
        @reasons = error.failure_messages
        render 'errors/forbidden', status: :forbidden
      end
      format.any { head :forbidden } # JSON, CSV, ...: a 403 without HTML
    end
  end

  rescue_from PermissionForge::ActionNotAuthorizedError do |error|
    # error.resource => "Customer", error.action => "index" (the action key, not a sentence),
    # error.controller_path => "customers",
    # error.reason => :crud_denied, :action_denied, ... (:nil_user_denied when nobody is signed in)
    respond_to do |format|
      format.html do
        signed_out = error.reason == :nil_user_denied
        target = signed_out ? new_session_path : root_path # your sign-in page; a page every user may open
        if request.path == target
          # Never redirect to the page that was just refused (the browser would loop): show the 403 page.
          render file: Rails.public_path.join('403.html'), status: :forbidden, layout: false
        else
          redirect_to target, alert: t(signed_out ? 'errors.sign_in_first' : 'errors.not_allowed')
        end
      end
      format.any { head :forbidden } # JSON, CSV, ...: a 403 without HTML
    end
  end
end
```

`format.html` also answers a Turbo request and a browser's `*/*`; `format.any` answers every other format with an empty 403 (Rails 7.1 and later).

Do not answer a denial with `redirect_back fallback_location: root_path`. When the refused page is the root itself (a guarded `index` mounted at `root`, visited by someone who is not signed in, or who may not read it), the fallback sends the browser back to the page that was just refused: it loops until the browser gives up (`ERR_TOO_MANY_REDIRECTS`), and every hop writes an `action.denied` event. The handler above sends a signed-out visitor to sign in (Devise: `new_user_session_path`; on an action opened with Rails 8's `allow_unauthenticated_access`, a signed-in visitor also reads as signed out unless the session is resumed: see [Callback order](controller-actions.md#callback-order)) and anyone else to a page they may open. When the refused page is that page, it renders `public/403.html` with status 403. That is what a signed-in person who holds no Permission Set sees after signing in, when the root is a guarded page: Rails 8's sign-in redirects to the root, and with an empty `head :forbidden` there Turbo would leave them on the filled-in sign-in form, as if signing in had failed.

**Keep the sign-in pages out of the guard.** With the guard in `ApplicationController`, Rails 8's `SessionsController` is guarded too (the guard maps it to the generator's `Session` model), and under `action_guard_nil_user_strategy = :deny` every signed-out request to it is refused. Nobody can sign in, and **Sign out seems to do nothing**: it ends the session, then the redirect lands on the refused sign-in page, which shows the 403 page, or, with a handler that answers an empty 403, nothing at all: Turbo keeps the old page, "Signed in as …" still in the header. Exclude the controllers in the initializer (`passwords` too, so that a `Password` model added later does not lock out password resets):

```ruby
config.controller_discovery_exclude += %w[sessions passwords] # the sign-in pages stay reachable signed out
```

The same holds for any controller a signed-out visitor must reach whose name matches a model.

Write the message yourself. `error.action` is the key that was checked (`index`, `export`), so "You may not index customers" is what interpolating it gives; `errors.not_allowed` above is your own translation key ("You are not allowed to open that page."), and `error.resource` names the model if you want it in the text.

A JSON API (`ActionController::API`):

```ruby
class Api::BaseController < ActionController::API
  rescue_from PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError do |error|
    render json: { error: { status: 403, messages: error.failure_messages.presence || ['Forbidden'] } },
           status: :forbidden
  end

  rescue_from PermissionForge::ActionNotAuthorizedError do |error|
    render json: { error: { status: 403, action: error.action, resource: error.resource } }, status: :forbidden
  end
end
```

A handler may answer any status (a 404 to hide that the record exists, a redirect to sign in when `error.reason == :nil_user_denied`); whatever it renders is the response.

### What `NotAuthorizedError` tells you

- `error.failure_messages` — an Array of the `failure_message` of each rule that denied the record, in rule order, without blanks and repeats (two Permission Sets can carry the same rule). Empty when no rule denied: nobody signed in under `nil_user_strategy = :raise`, or an error your own code raised without `failure_messages:`. Use it for a friendly 403 without parsing `message`.
- `error.message` — always a String: the denying rules joined by `, `, each as `[Forbidden by Rule: <name>] with message: <failure_message>`. Meant for logs.
- `error.details` — the structured value the error was raised with: the Array of those strings for a rule denial, or a Hash with `:message` when there is no user under `nil_user_strategy = :raise`.
- `error.user` and `error.record_id` — the user the rules were applied for and the record that was denied (`error.record` is `nil`: the denied row is not loaded).

Rule names and failure messages are written by admins; decide whether you want them in a response before you render them.

## ViewAll / ModifyAll

If a resource has `view_all: true` or `modify_all: true`, **all row-level rules are bypassed** for that user on that model. This is the Salesforce-inspired equivalent of "see all records regardless of ownership rules." The flags are merged across granting sets like the other resource flags, so one set that grants `view_all` bypasses the rules every other set has on that resource. For a subclass (see [Single-table inheritance](#single-table-inheritance)) the bypass only skips the rules of the entry that grants it.

`view_all` and `modify_all` are read the same way: either one lets the user past the rules of `find_by`, `find_by!` and `permission_scoped` (the gem does not tell reads from writes there).

```ruby
resource = PermissionForge::Resource.create!(
  permission_set: admin_pset,
  name: 'Customer',
  read_access: true, edit_access: true,
  view_all: true,    # Bypasses all row-level rules
  modify_all: true   # Same effect on the rules; requires view_all
)
```

Check at runtime:

```ruby
user.can_view_all?('Customer')   # => true
user.can_modify_all?('Customer') # => true
```

> **Note:** `modify_all` requires `view_all` to be enabled (enforced by validation).

## Bypassing Rules

Rules are bypassed when:
1. `PermissionForge.current_user` returns nil (e.g., background jobs) and `config.nil_user_strategy` is `:bypass` (the default). With `:deny`, `find_by` returns `nil` and `permission_scoped` returns no rows; with `:raise`, both raise `NotAuthorizedError`.
2. The user has `view_all` or `modify_all` on the resource
3. The user has no active rule for the model (no rules means no restriction)

```ruby
# In a job — no current user, default nil_user_strategy :bypass
Current.user = nil
Customer.find_by(uuid: 'abc')  # Works normally, no rules applied
```

> **Tip:** To skip the rules on purpose while a user is signed in, call `find_by` on a relation: `Customer.where(nil).find_by(uuid: 'abc')` keeps the model's default scopes (a tenant or soft-delete scope) under `auto_query_scoping = :off`. `Customer.unscoped.find_by(...)` skips the rules too, but also drops every default scope, the tenant scope included. For a signed-in user, `PermissionForge.without_permission_scope { }` suspends only the automatic scope of `auto_query_scoping`; it does not switch off the rules of the class-level `find_by` or `permission_scoped`. With nobody signed in it does: inside the block `find_by`, `find_by!` and `permission_scoped` apply no rules whatever `nil_user_strategy` says (reported as `rule.bypassed`, `scope_suspended`), so wrap trusted code only (jobs, seeds, rake tasks, sign-in lookups), never code an anonymous request reaches.

## Several Permission Sets

A user's rules for a model are collected from every granting set they hold, and **all of them must pass** (they are combined with AND). So rules intersect across sets: if one set lets a user see the customers they own and another set adds a rule `region equal 'EU'`, the user now sees only the EU customers they own. Adding a set that has a rule can narrow the rows another set allowed — the opposite of resource and field flags, where any granting set that allows wins.

Two things to keep in mind:

- `view_all` or `modify_all` from any granting set bypasses every rule on that resource (a muting set can take the flag away again).
- A set with no rules for the model adds no restriction. A user whose sets have no rules for it sees every row.

Muting sets never add rules.

## Single-table inheritance

A subclass on the same table (`VipCustomer < Customer`) answers to its own `Resource` and to every ancestor's up to the base class:

- **Rules of every entry apply together.** `VipCustomer.find_by` and `VipCustomer.permission_scoped` apply the rules of the user's `VipCustomer` entry and of their `Customer` entry. A subclass with no `Resource` row of its own is its base: the base's rules apply.
- **A bypass is local.** `view_all` / `modify_all` skips the rules of the entry that grants it and no other: `view_all` on `Customer` does not skip the rules on `VipCustomer`, and the other way round.
- **Rules on a subclass hold only for queries through the subclass.** A query through the base class (`Customer.find_by`, `Customer.permission_scoped`) applies the base's rules only, also to rows that are `VipCustomer`s. If a rule must hold for every row of the table, put it on the base class's resource.
- **Only single-table inheritance forms a chain.** A subclass with a table of its own answers to its own name alone.

Field masking follows the same chain; see [Single-table inheritance in masked-attributes.md](masked-attributes.md#single-table-inheritance). A PostgreSQL RLS policy is compiled per table for the class that includes the concern: rules on a subclass's resource are enforced in the application only (see [Query scoping](query-scoping.md#level-3--database-postgres-row-level-security)).

## Nested attributes

`PermitsAttributes` checks nested records against these rules too. A record in a `<association>_attributes` payload that carries an `id` is kept only when the id names a row the child model's rules let the user reach (the child includes `PermissionScopedFindable` and the id is inside `Child.permission_scoped`); otherwise the whole record is dropped, so it can neither update nor destroy a row the user may not see. A child model without the concern is left to Rails. See [Nested attributes in field-filtering.md](field-filtering.md#nested-attributes).

## Validations (v0.5.0+)

`PermissionSetRule` now validates data integrity at the model level:

- **`operator`** — must be one of the 15 known operators (raises validation error for typos)
- **`field_value`** — required for all operators except `is_null` / `is_not_null`, which take none (a value is refused; a missing one is stored as an empty string)
- **`field_value` for `between`** — must contain exactly 2 comma-separated values
- **`field_value` for `in` / `not_in`** — must contain at least 1 non-blank value
- **`join_type`** — `nil`, or one of `joins`, `left_joins`, `left_outer_joins` (an empty string or `filter` is refused)
- **`field_name`** — required, must match `/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/` (prevents SQL injection via field names)

### BETWEEN values

The two values of `between` are typed for the column like any other value (see [How Values Are Compared](#how-values-are-compared)): `"5,50"` is a number range on a number column and a text range on a string column, `"2025-01-01,2025-12-31"` a date range on a date column. A value the column cannot hold — or anything but exactly two values — makes the rule match nothing.

Only where the column's type is not known (an array or `uuid` column, a field name that is not a known column) the older guess from the text still applies: two integers, two decimals or two ISO dates are compared as such, anything else as text.

## Common Mistakes

### Rule name doesn't match the resource

The rule's `resource` must point to the same `PermissionForge::Resource` that represents the model. If you create a rule for the wrong resource, it won't be applied.

### Expecting a second set to widen the rows

Rules from all of a user's granting sets apply together. Giving someone a second Permission Set never shows them more rows if that set has rules of its own on the model: it can only narrow (see [Several Permission Sets](#several-permission-sets)). To widen, grant `view_all` on the resource in that set, or change the rules.

### Writing rules past ActiveRecord

Rules are cached in each user's permission hash. Saving a rule through ActiveRecord (the admin, the API, `create!`/`update!`) invalidates the cache of every holder of its Permission Set automatically. A change that skips callbacks (`update_all`, `insert_all`, raw SQL) does not: call `user.invalidate_permissions` for the affected users afterwards. Such a change also writes no audit event.

### Using the wrong field name

`field_name` must be a column of the model's table, or of the table at the end of `field_accessor_path` for a join rule. A name qualified with a table (`suppliers.owner_id`) must be a column of that table.

- **Saving refuses it.** When the Resource's model can be loaded, a rule whose field name is not a column (`onwer_id` on `Customer`) does not save: `field_name` gets the error "is not a column of Customer", and the JSON API answers 422 with `{"field_name": ["is not a column of Customer"]}`. The check runs for a new rule and when its field name, path, join type or resource changes. It is skipped when the column cannot be told at that moment: the model cannot be loaded (or its table does not exist yet), the association path cannot be followed, or the name is qualified with a table that is none of the rule's (an alias your query joins itself). Copying a Permission Set copies an existing rule as it is.
- **A rule that names a missing column matches nothing.** A rule saved before this check (or written past the model, a column since renamed or dropped) lets no record through to the users it applies to, under every built-in operator — it is not sent to the database, which would reject the query and turn every `find_by` / `permission_scoped` of its holders into a 500. An RLS policy compiles it to `FALSE` as well. `bin/rails permission_forge:audit` lists such rules in effect (`missing_rule_columns`, High when people hold the set). Columns are read from Rails' schema cache: saving a rule reads the table again before refusing a name, but a process that read the schema before a migration added the column (a running server, an old process during a rolling deploy) denies through a rule on it until it restarts — deploy the migration before the rule.
- **What is still left to the database:** a name qualified with a table that is none of the rule's (the query may join it under that name), and a rule under a custom operator (its strategy decides what the name means). If that table or column is not there, the query raises.

### A value the column cannot hold

A rule whose value is not a value of the column (`'5_id'` on an integer column, `'maybe'` on a boolean one) is valid to save and then matches nothing: every record is denied for the users it applies to. If a rule suddenly lets nobody through, check its value against the column's type in [How Values Are Compared](#how-values-are-compared).
