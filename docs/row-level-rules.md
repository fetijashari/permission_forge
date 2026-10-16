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
> **No rules means no restriction.** A user who has no active rule for a model — including a user with no `Resource` row for it at all — gets every row through `find_by` and `permission_scoped`. Rules only ever narrow. To refuse every row to a signed-in user whose sets do not grant Read on the model, set `config.no_read_access_strategy = :deny` (see [Rules only, not the CRUD flags](#rules-only-not-the-crud-flags)).

## How It Works

1. You create a `PermissionSetRule` that defines a filter condition
2. You include `PermissionScopedFindable` in your model
3. Every time `Model.find_by(...)` / `Model.find_by!(...)` is called on the class, the rule's condition is applied to the query
4. If the record exists but doesn't match the rule, `NotAuthorizedError` is raised (a record that does not exist gives `nil`, as in Rails)

### What is enforced

The concern overrides the class methods `find_by` and `find_by!`, and adds a `permission_scoped` relation. It does **not** rewrite `find` (by primary key), bare `where`, `first`, `all`, association traversal, or `find_by` called on a relation or an association — Rails resolves those through relation methods the concern does not hook. With `auto_query_scoping = :off` (the default) these all skip the rules:

```ruby fragment
Customer.where(active: true).find_by(uuid: uuid)  # no rules
supplier.customers.find_by(uuid: uuid)            # no rules
Customer.where(nil).find_by!(uuid: uuid)          # no rules
Customer.unscoped.find_by(uuid: uuid)             # no rules
Customer.find_sole_by(uuid: uuid)                 # no rules
```

- Use the class-level **`Customer.find_by` / `Customer.find_by!`** for single-record lookups.
- Start from **`Model.permission_scoped`** to get a rule-constrained relation you can chain freely:

```ruby fragment
Customer.permission_scoped                      # rules applied
Customer.permission_scoped.where(active: true)  # rules carried through
Customer.permission_scoped.order(:name).first   # still scoped
Customer.permission_scoped.find(id)             # scoped find by PK
```

`permission_scoped` honors `view_all`/`modify_all` (returns the unconstrained relation) and `nil_user_strategy` (`:bypass` → all, `:deny` → none, `:raise` → raises).

### Rules only, not the CRUD flags

By default (`config.no_read_access_strategy = :rules_only`) `find_by`, `find_by!` and `permission_scoped` apply the row-level rules of the user's sets. They do not ask whether the user may read the resource at all: a user whose set has a rule on `Customer` but `read_access: false` still gets the rows the rule selects (the field rows then hide every column), and a user with no `Customer` Resource has no rule there and gets every row. The CRUD flags are answers to `can_read?`, `can_edit?`, ... and are enforced where you ask them, or by the controller guard: with [`ControllerActionGuard`](controller-actions.md) a REST action is checked against the matching flag before it runs (`index` and `show` need `read_access`, `create` `create_access`, ...), so a controller that includes the guard and queries through `permission_scoped` enforces both. Without the guard, ask first:

```ruby fragment
class CustomersController < ApplicationController
  before_action { head :forbidden unless Current.user&.can_read?(:Customer) } # the resource flag; the rules follow

  def index
    @customers = Customer.permission_scoped
  end
end
```

Or let the record reads ask for read themselves:

```ruby fragment
PermissionForge.configure do |config|
  config.no_read_access_strategy = :deny # part of config.preset = :strict
end
```

Under `:deny`, for a signed-in user whose entries for the model's Resource (and, for a single-table-inheritance subclass, its bases' along the chain) do not all grant `read_access` — no entry at all, an entry without read, read taken by a Muting Permission Set or by a granting set whose conditions do not pass:

- `permission_scoped` and the `auto_query_scoping` default scope return `none`;
- `find_by` and `find_by!` raise `NotAuthorizedError` for a record that exists, with one `failure_messages` entry ("You do not have permission to read Customer records.", `permission_forge.denials.no_read_access` in every locale), and return `nil` / raise `RecordNotFound` for one that does not;
- each denial is an `access.denied` event with reason `no_read_access`.

View All and Modify All skip the rules of an entry that grants read; they never stand in for it. With nobody signed in `nil_user_strategy` decides, as before. The check is lifted where the rules are: `without_permission_scope` lifts the default scope, and a signed-in user's `find_by` and `permission_scoped` keep both inside it. The generated RLS policies follow the option as well: under `:deny` a session user without read access to the table's Resource chain sees no row in PostgreSQL either (re-sync the policies after switching it; see [Read access in a policy](query-scoping.md#read-access-in-a-policy)).

## Step 1: Include the Concern

Add `PermissionScopedFindable` to any model you want to protect:

```ruby fragment
class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable
end
```

> **What this does:** It overrides `Customer.find_by(...)` so that permission rules are checked before returning the record.

## Step 2: Create a Rule

```ruby fragment
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

```ruby fragment
# Rails 8's generated Current holds the session and delegates `user` to it
# (`Current.user = ...` raises NoMethodError there); the default
# current_user_resolver reads Current.user.
Current.session = user.sessions.create!  # user.id = 42

# This record is owned by the current user
customer_a = Customer.create!(name: 'Acme', owner_id: 42)

# This record is owned by someone else
customer_b = Customer.create!(name: 'Beta', owner_id: 99)

Customer.find_by(id: customer_a.id)
# => #<Customer id: 1, name: "Acme", owner_id: 42>  (allowed!)

Customer.find_by(id: customer_b.id)
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

```ruby fragment
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

```ruby fragment
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

`include_nulls` is **off unless asked for** — in code, through the JSON API and in the admin's rule builder alike (the model's default since 0.15; before, a rule created in code or through the API let the NULL rows through by the column default while the admin's builder started unchecked). Rows already stored keep their value.

When `include_nulls` is `true` and the operator is `equal`, the generated SQL is:

```sql
WHERE owner_id IS NULL OR owner_id = 42
```

When it is `false` (the default):

```sql
WHERE owner_id = 42
```

> **Tip:** pass `include_nulls: true` (or tick "Also show records where … is empty" in the builder) to also show the records that have not been assigned yet.

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
| uuid (PostgreSQL) | the text of a UUID, `7d1f0c0e-6f0a-4a57-9f0d-0f3f6f0a4a57`, in either case; also in braces, after `urn:uuid:` or as the 32 digits without hyphens, as PostgreSQL reads them | a uuid (any notation is read as the uuid it holds) |
| inet (PostgreSQL) | an IPv4 or IPv6 address, optionally with a prefix length: `10.0.0.1`, `10.0.0.5/24`, `2001:db8::1` (no netmask, no zone) | an address |
| cidr (PostgreSQL) | a network: `10.0.0.0/24`, `2001:db8::/32` — no bits set right of the prefix (`10.0.0.5/24` is not one) | a network |
| a native enum type (PostgreSQL `CREATE TYPE … AS ENUM`) | one of the type's labels, exactly as the database has it (case counts) | the label; `less_than` and the others follow the type's order |
| json (every database), jsonb and array columns (PostgreSQL) | nothing: only `is_null` / `is_not_null` work on such a column under the built-in operators (a custom operator gets the value as written) | — |
| an `enum` attribute | one of the enum's labels (`archived`), or the stored value (`1`) | the value the model stores for the label — for a string-backed enum too (`enum :tier, { gold: 'G' }`: `gold` is compared as `G`, where it used to be compared as the text `gold`). A value that is a label always means that label, also when it happens to equal another label's stored value |

**A value the column cannot hold makes the rule match nothing.** `owner_id equal '5_id'` and `active equal 'maybe'` let no record through — on every database, for the negative operators (`not_equal`, `not_in`) too, and `include_nulls` adds no NULL rows to such a rule. The rule denies; it never widens access. Saving such a rule is refused (`field_value`: "is not a value Customer.owner_id can hold"; the JSON API answers 422) — for a new rule and whenever its value, operator, field name, path, join type or resource changes. The same holds for `between` without exactly two values, for an empty list, and for a list with one element the column cannot hold. A rule saved before this check, or written past the model, still matches nothing: `bin/rails permission_forge:audit` lists the rules in effect that match nothing for this reason (`unusable_rule_values`) — worth running after an upgrade. A field name that is not a column of the table matches nothing as well — see [Using the wrong field name](#using-the-wrong-field-name).

Things worth knowing:

- **Number notation is strict.** `0x1F`, `1_000`, `NaN` and `Infinity` are not numbers here, whatever your database would make of them. Neither is a number past the range of a double-precision float (`1e999`, `1e-400`).
- **ISO 8601 is the portable notation for dates and times.** It is typed the same way on every database. Any other text — `31.01.2026`, `Jan 31 2026`, `today`, `now`, `infinity`, `someday` — matches nothing on MySQL and SQLite. On PostgreSQL such text is asked of PostgreSQL once per process (a `CAST` in a savepoint, `ValueCasters::PostgresqlTypes::ReadBack`): text it reads in its own notations is handed to it exactly as written (`due_on less_than '31 Jan 2026'` and `due_on between 'yesterday,tomorrow'` keep working), and text it cannot read (`someday`) matches nothing and is refused on save — through 0.14 it raised for every holder of the rule, on every query. The model's validation is narrower than PostgreSQL for the ordering operators — it takes a number or a date Ruby can parse, so `less_than 'today'` cannot be saved through the model, the admin or the API; a rule like that only exists where it was written past the validation (SQL, `update_column`, another application on the same tables), and it is still read by PostgreSQL. Two things to know before relying on PostgreSQL's notations: the rule means nothing on another database, and **in an RLS policy PostgreSQL reads such a word once, when the policy is created** — `tomorrow` in a policy is the day after the last `rls:sync`, while the application layer reads it with every query. That was always so; prefer ISO dates in rules that back a policy.
- **An offset in a date-time is applied.** `2026-01-31 14:30:00+02:00` is 12:30 UTC on every database. On a PostgreSQL `timestamp without time zone` column — what `t.datetime` creates — PostgreSQL used to ignore the offset and compare with 14:30.
- **Single-precision float columns.** On PostgreSQL a `real` column gets the number as text, so PostgreSQL compares in single precision and `equal '0.1'` finds a stored 0.1, as it always did. (`between` with two plain numbers is the exception it always was: those bounds go as numbers and are compared in double precision, where a stored 0.1 is a little more than 0.1.) MySQL compares a `FLOAT` column — which is what `t.float` creates there — in double precision whatever it is compared with, so `equal '0.1'` does not find a stored 0.1 on MySQL (`0.5`, which a float holds exactly, is found); use `DOUBLE` (`t.float ..., limit: 53`) or `DECIMAL` for a column a rule has to equal. SQLite only has double precision.
- **`current_user`** stands for the user's id wherever one value is compared (`equal`, `less_than`, `contains`, ...). On a string column it is compared as the id's text; on a boolean or date column it matches nothing. Inside an `in` / `not_in` list or a `between` range it is **not** replaced — there it is the literal text `current_user`: an element like any other on a string column, and on a number column a value the column cannot hold, so the rule matches nothing. (It never worked there: PostgreSQL raised, and MySQL read the word as 0 and matched the rows with id 0.)
- **Boolean words are the whole words in the table.** PostgreSQL also reads a prefix (`tr`, `fal`, `ye`, `of`); a rule written that way now matches nothing on every database.
- **A MySQL `tinyint(1)` column is a boolean** to ActiveRecord, and so to a rule: only the boolean words above match, also when the column holds other numbers. `equal '2'` matches nothing; use a wider integer type for a column that is not a flag.
- **LIKE operators on an enum column search what is stored**, not the labels: `status contains 'arch'` looks for `arch` in the stored value. On PostgreSQL that works for an enum stored as text only (next bullet).
- **On PostgreSQL a LIKE operator matches text columns only** (`contains`, `not_contains`, `starts_with`, `ends_with`). On an integer, decimal, boolean, date, uuid, inet, cidr, native enum or other non-text column it matches nothing and is refused on save — PostgreSQL has no LIKE for those types, so the query used to raise for every holder. MySQL and SQLite, which compare such a column's text, are unchanged. On every database a LIKE operator on a `json` or array column matches nothing.
- **String comparisons follow the column's collation on MySQL and SQLite.** With MySQL's default collations (`utf8mb4_0900_ai_ci`, `utf8mb4_general_ci`) `equal`, `in` and `between` on a string column ignore case and accents: `status equal 'active'` also matches `Active` and `áctive`. PostgreSQL compares exactly unless the column has a case-insensitive collation or type. Give the column a binary or `_cs` collation if a rule has to tell them apart. Which string is "less than" another (`less_than`, `between`, ...) is the collation's decision on every database.
- **Dotted field names** (`customers.owner_id`, or `users.active` on a rule with a `field_accessor_path`) are typed too, when the table is the rule's own model's or one along its association path — with a schema or database in front as well (`public.customers.owner_id`). A filter rule compares its own table: qualified with another model's table it matches nothing, and so does any qualifier that names no table the rule's query gives — see [Using the wrong field name](#using-the-wrong-field-name).
- **A field name is looked up the way the database resolves it**: without regard to case on MySQL and SQLite (`Owner_ID` is `owner_id` there; PostgreSQL rejects it), and among the table's columns, so a column in the model's `ignored_columns` is typed too.
- **A field name with an empty part** — a trailing, leading or doubled dot (`owner_id.`, `customers..owner_id`) — is not a name. It cannot be saved on a new rule or by renaming one; a rule that already carries such a name matches nothing (and is listed by the audit). Neither is a name with a control character in it (a newline, a NUL byte): such a rule matches nothing under every operator, a custom one included.
- **Column types without an entry above** — `money`, `interval`, `macaddr`, ... — are asked of PostgreSQL once per process and database, like a date it has to read (`ValueCasters::PostgresqlTypes::ReadBack`): a value it reads is handed to it as written, one it cannot read matches nothing and is refused on save. Only a type PostgreSQL can compare is asked (a default btree operator class with `=` and `<`): `xml`, `point`, `polygon`, `path` and `hstore` take no value — every operator but `is_null` / `is_not_null` matches nothing. A failed read that is not a refusal of the value (a statement timeout, a lost connection) denies that one query and is asked again. `citext` is text. On MySQL and SQLite such a column, and on every database a field name that is not a known column, gets the value exactly as written, and the database decides.
- **A native enum's labels are read from the database** once per process; a label added by a migration while the process runs (`ALTER TYPE … ADD VALUE`) is read again the first time a rule names it. A model `enum` declared over a native enum column maps its own label to the database's first.
- **`current_user` on a uuid column** is the user's id where ids are uuids; with integer ids such a rule matches nothing.
- **Custom operators.** A strategy registered under a name of your own (through an injected `operator_registry:`) receives the value untouched, with `current_user` replaced by the id — also on a `json`, `jsonb` or array column, where the built-in operators match nothing: register one to compare such a column. The built-in `in`, `not_in` and `between` strategies receive an Array of typed values.
- **A strategy of your own registered under a built-in operator name** receives the typed value — Integer or BigDecimal, `true`/`false`, Date or Time, String, and an Array for `in`, `not_in` and `between` — and is not called at all when the value is one the column cannot hold: the rule matches nothing.
- **Two names are still left to the database, untyped:** the table alias ActiveRecord gives a self-join (`parents_customers.active` on a join rule whose path leads back to the same table: a name the join's FROM or JOIN gives a table, never one its ON clause mentions), and the row id pseudo-column (`_rowid` on MySQL, `rowid` on SQLite). On MySQL and SQLite a value such a column cannot hold is then converted or compared as text, as every value was before. Name the column itself.

## The `current_user` Magic Value

When `field_value` is the string `'current_user'`, it's automatically replaced with `PermissionForge.current_user.id` at query time.

This is how you create "show me only my records" rules without hardcoding user IDs.

## Rules with Joins (Nested Associations)

Sometimes the field you want to filter on isn't directly on the model — it's on a related model. For example, you want to filter Customers by the user associated with the organization's members.

```ruby fragment
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

A filter rule (`join_type` nil) never joins: the admin's builder does not load a stored `field_accessor_path` of a filter rule, so saving it again keeps it a filter rule.

### How `field_accessor_path` Works

The path `'organization.members.user'` tells PermissionForge to:
1. Join `customers` to `organizations` (via `customer.organization`)
2. Join `organizations` to `members` (via `organization.members`)
3. Join `members` to `users` (via `member.user`)
4. Apply the `field_name` filter on the final joined table (`users.id = current_user.id`)

> **Important:** The association names in `field_accessor_path` must match your ActiveRecord association names exactly, and each one must be an association ActiveRecord can join: `has_many`, `has_one`, `belongs_to`, `has_and_belongs_to_many`, `:through` and scoped associations all work; a polymorphic `belongs_to` and an association whose scope takes the record (`->(record) { … }`) do not. A path that names anything else is refused when the rule is saved, and one saved before matches nothing — see [Using the wrong field name](#using-the-wrong-field-name).

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

This page is what Rails shows when no handler runs. It is static: no layout, nobody named as signed in, no way to sign out, and its link leads to the start page, which may be the page that was refused. The handler below renders a template of your app in its layout instead.

Like every mapped exception, an unrescued denial is not reported to `Rails.error` as an unhandled exception. The denial is still in the audit log: `access.denied` (rule) and `action.denied` (guard) are stored whenever the audit log is on (`audit_runtime_events` holds `:denied` by default; see [audit-log.md](audit-log.md)).

**Opting out.** A `rescue_from` in your controller runs first and decides (below). To answer a different status without a handler, set it in `config/application.rb` or `config/environments/*.rb` — `config/initializers` run after Rails has read the setting:

```ruby fragment
# config/application.rb — e.g. hide that the record exists
config.action_dispatch.rescue_responses['PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError'] = :not_found
```

### Rescuing them yourself

An HTML app (`ActionController::Base`), here with Rails 8's authentication generator and the guard in `ApplicationController` (what the [getting-started guide](getting-started.md#using-rails-8s-authentication-generator) sets up):

```ruby file=app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication # the generator's concern: authenticated?, resume_session, require_authentication
  include PermissionForge::Concerns::ControllerActionGuard # after Authentication: the session is resumed before the guard runs
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError do |error|
    respond_to do |format|
      format.html do
        @reasons = error.failure_messages # the rules' own messages, as the admin wrote them ([] when no rule denied)
        render 'errors/forbidden', status: :forbidden # in your layout: your header and Sign out stay
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
        # The guard saw nobody signed in. authenticated? resumes the session first: on an action opened with
        # allow_unauthenticated_access nothing else has, and a signed-in visitor would otherwise be sent to sign in,
        # from where SessionsController#new (below) sends them back: a loop. Only a visitor who is signed out is
        # sent to the sign-in page, and never from the sign-in page itself.
        if error.reason == :nil_user_denied && !authenticated? && request.path != new_session_path
          redirect_to new_session_path, alert: t('errors.sign_in_first')
        else
          # The 403 page in place: never a redirect to the page that was just refused (the browser would loop).
          render 'errors/forbidden', status: :forbidden
        end
      end
      format.any { head :forbidden } # JSON, CSV, ...: a 403 without HTML
    end
  end
end
```

```erb file=app/views/errors/forbidden.html.erb
<%# app/views/errors/forbidden.html.erb: rendered in your layout %>
<h1>You are not allowed to see this page</h1>
<% if authenticated? %>
  <p>Your account does not give you access to it. If you think it should, ask an administrator.</p>
  <% if @reasons.present? %>
    <ul><% @reasons.each do |reason| %><li><%= reason %></li><% end %></ul>
  <% end %>
  <%= button_to 'Sign out', session_path, method: :delete %>
<% else %>
  <p>Sign in to see it. <%= link_to 'Sign in', new_session_path %></p>
<% end %>
```

```yaml file=config/locales/permission_denials.en.yml
# config/locales/permission_denials.en.yml: the handler's own message, in a file of its own
# (Rails loads every file under config/locales), or add the key to your config/locales/en.yml
en:
  errors:
    sign_in_first: "Please sign in first."
```

`authenticated?`, `new_session_path` and `session_path` are the generator's; with Devise use `user_signed_in?` (which also resumes the session), `new_user_session_path` and `destroy_user_session_path`. `format.html` also answers a Turbo request and a browser's `*/*`; `format.any` answers every other format with an empty 403 (Rails 7.1 and later).

The template has no link to the start page on purpose: for someone who holds no Permission Set the root is refused too, so from any refused page that link leads to this page again. If your app has a page every signed-in person may open (an account page outside the guard), link to that one; otherwise your layout's navigation, the browser's Back button and Sign out are the ways on.

**Render the 403 page in your layout, not `public/403.html`.** A signed-in person who holds no Permission Set is refused right after signing in when the root is a guarded page: Rails 8's sign-in redirects to the root, and the sign-in is a Turbo form submission. Turbo shows a 403 answer to it only when the page carries the same tracked assets (`data-turbo-track`) as the page it replaces, which a page in your layout does. With `public/403.html` (`render file: ..., layout: false`) Turbo reloads the sign-in page instead, and with an empty `head :forbidden` it keeps the filled-in form: either way the person is left on the sign-in form, as if signing in had failed. In the layout they read why under your header, and can sign out.

**After that sign-in the address bar still shows the sign-in page.** Turbo renders a 4xx answer to a form submission in place without changing the URL, so the 403 page of the root is shown at `/session/new`. Pressing Reload then asks for the sign-in page again, and the generator's `SessionsController#new` (`allow_unauthenticated_access`) neither resumes the session nor sends a signed-in visitor anywhere: the sign-in form comes back with nobody shown as signed in, although the session is valid. Send a signed-in visitor on from the sign-in page:

```ruby file=app/controllers/sessions_controller.rb
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
    redirect_to after_authentication_url if authenticated? # signed in already: never the sign-in form
  end

  # create and destroy as generated
  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
```

`authenticated?` resumes the session, and `after_authentication_url` is the page that sent them to sign in, if signing in has not used it yet, else the root. A refused page answers the 403 page in place, now at its own address, so Reload shows the 403 page again instead of the form. A signed-out visitor still gets the form.

**This line and the handler belong together.** The handler sends a visitor to the sign-in page only once `authenticated?` found no session. A signed-in visitor the guard took for signed out — on an action opened with `allow_unauthenticated_access`, where nothing resumes the session before the guard runs — gets the 403 page instead. With a handler that sends every `:nil_user_denied` to sign in (the version documented through 0.14.1), that visitor loops: `/` → `/session/new` → `/` …, one `action.denied` event per hop, until the browser gives up (`ERR_TOO_MANY_REDIRECTS`). The 403 page is the honest answer there, not the right one: the visitor is signed in and may hold the permissions. On every guarded action opened with `allow_unauthenticated_access`, resume the session ahead of the guard (`prepend_before_action :resume_session, only: ...`, see [Callback order](controller-actions.md#callback-order)); the visitor then gets the page, with their permissions.

Do not answer a denial with `redirect_back fallback_location: root_path`. When the refused page is the root itself (a guarded `index` mounted at `root`, visited by someone who is not signed in, or who may not read it), the fallback sends the browser back to the page that was just refused: it loops until the browser gives up, and every hop writes an `action.denied` event. The handler above redirects only a signed-out visitor, to sign in, and never from the sign-in page itself; everyone else gets the 403 page in place, at the address they opened (after a Turbo sign-in, the sign-in page's: see above), so no denial loops.

**Keep the sign-in pages out of the guard.** With the guard in `ApplicationController`, Rails 8's `SessionsController` is guarded too (the guard maps it to the generator's `Session` model), and under `action_guard_nil_user_strategy = :deny` every signed-out request to it is refused. Nobody can sign in: the sign-in page shows the 403 page ("Sign in to see it", with a link to the same page) instead of the form. Sign out ends the session, then lands on that page; with a handler that answers an empty 403, Sign out seems to do nothing: Turbo keeps the old page, "Signed in as …" still in the header. Exclude the controllers (`passwords` too, so that a `Password` model added later does not lock out password resets) — in `config/initializers/permission_forge.rb`, or in an initializer of its own:

```ruby file=config/initializers/permission_forge_sign_in.rb
# The sign-in pages stay reachable signed out: the guard never maps SessionsController or PasswordsController.
PermissionForge.configure do |config|
  config.controller_discovery_exclude += %w[sessions passwords]
end
```

The same holds for any controller a signed-out visitor must reach whose name matches a model.

Write the message yourself. `error.action` is the key that was checked (`index`, `export`), so "You may not index customers" is what interpolating it gives; `errors.sign_in_first` above is your own translation key, and `error.resource` names the model if you want it in the text.

A JSON API (`ActionController::API`):

```ruby file=app/controllers/api/base_controller.rb
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

- `error.failure_messages` — an Array of the `failure_message` of each rule that denied the record, in rule order, without repeats (two Permission Sets can carry the same rule). Empty when no rule denied: nobody signed in under `nil_user_strategy = :raise`, or an error your own code raised without `failure_messages:`. Use it for a friendly 403 without parsing `message`. A rule whose **Blocked message** is blank denies with the gem's own sentence in the current locale (`permission_forge.denials.rule_default`: "You do not have permission to perform this action.", translated in sq and mk), so `failure_messages` is never empty when a rule denied. The install migration gives the `failure_message` column that English sentence as its default; the admin never pre-fills it (a new rule starts blank), but a rule created through the API, a script or the admin of 0.14 may hold the English text — [Column Defaults Are English](i18n.md#column-defaults-are-english) has the one-liner that blanks such rules so they fall back to the translated sentence.
- `error.message` — always a String: the denying rules joined by `, `, each as `[Forbidden by Rule: <name>] with message: <failure_message>`. Meant for logs.
- `error.details` — the structured value the error was raised with: the Array of those strings for a rule denial, or a Hash with `:message` when there is no user under `nil_user_strategy = :raise`.
- `error.user` and `error.record_id` — the user the rules were applied for and the record that was denied (`error.record` is `nil`: the denied row is not loaded).

Rule names and failure messages are written by admins; decide whether you want them in a response before you render them.

## ViewAll / ModifyAll

If a resource has `view_all: true` or `modify_all: true`, **all row-level rules are bypassed** for that user on that model. This is the Salesforce-inspired equivalent of "see all records regardless of ownership rules." The flags are merged across granting sets like the other resource flags, so one set that grants `view_all` bypasses the rules every other set has on that resource. For a subclass (see [Single-table inheritance](#single-table-inheritance)) the bypass only skips the rules of the entry that grants it.

`view_all` lets the user past the rules of `find_by`, `find_by!` and `permission_scoped` (the gem does not tell reads from writes there); `modify_all` counts only together with `view_all`, so a row with `modify_all` and no `view_all` (written past the validation) bypasses nothing — in the application layer and in an RLS policy alike.

```ruby fragment
resource = PermissionForge::Resource.create!(
  permission_set: admin_pset,
  name: 'Customer',
  read_access: true, edit_access: true,
  view_all: true,    # Bypasses all row-level rules
  modify_all: true   # Same effect on the rules; requires view_all
)
```

Check at runtime:

```ruby fragment
user.can_view_all?('Customer')   # => true
user.can_modify_all?('Customer') # => true
```

> **Note:** `modify_all` requires `view_all` to be enabled (enforced by validation).

## Bypassing Rules

Rules are bypassed when:
1. `PermissionForge.current_user` returns nil (e.g., background jobs) and `config.nil_user_strategy` is `:bypass` (the default). With `:deny`, `find_by` returns `nil` and `permission_scoped` returns no rows; with `:raise`, both raise `NotAuthorizedError`.
2. The user has `view_all` or `modify_all` on the resource
3. The user has no active rule for the model (no rules means no restriction)

```ruby fragment
# In a job — no current user, default nil_user_strategy :bypass
Current.reset                # no session, so Current.user is nil
Customer.find_by(id: 1)      # Works normally, no rules applied
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

Only where the column's type is not known (a field name that is not a known column, or on MySQL and SQLite a column type without an entry in the table) the older guess from the text still applies: two integers, two decimals or two ISO dates are compared as such, anything else as text.

## Common Mistakes

### Rule name doesn't match the resource

The rule's `resource` must point to the same `PermissionForge::Resource` that represents the model. If you create a rule for the wrong resource, it won't be applied.

### Expecting a second set to widen the rows

Rules from all of a user's granting sets apply together. Giving someone a second Permission Set never shows them more rows if that set has rules of its own on the model: it can only narrow (see [Several Permission Sets](#several-permission-sets)). To widen, grant `view_all` on the resource in that set, or change the rules.

### Writing rules past ActiveRecord

Rules are cached in each user's permission hash. Saving a rule through ActiveRecord (the admin, the API, `create!`/`update!`) invalidates the cache of every holder of its Permission Set automatically. A change that skips callbacks (`update_all`, `insert_all`, raw SQL) does not: call `user.invalidate_permissions` for the affected users afterwards. Such a change also writes no audit event.

### Using the wrong field name

`field_name` must be a column of the model's table, or of the table at the end of `field_accessor_path` for a join rule. A name qualified with a table (`suppliers.owner_id`) must be a column of that table. Every name in a join rule's `field_accessor_path` must be an association ActiveRecord can join, of the model before it on the path.

- **Saving refuses it.** When the Resource's model can be loaded, a rule whose field name is not a column (`onwer_id` on `Customer`) does not save: `field_name` gets the error "names onwer_id, which is not a column of Customer" (it names what was written), and the JSON API answers 422 with `{"field_name": ["names onwer_id, which is not a column of Customer"]}`. A join rule whose path names no association (`ownr` for `owner`) does not save either: `field_accessor_path` gets "names ownr, which is not an association of Customer" (the segment and the model it was looked up in), and one naming an association no join can be built through gets a message that says why — "names subject, a polymorphic association of Comment: a rule cannot join it", "… whose scope (or one along its :through) takes the record: a rule cannot join it", "… whose :through, :source or inverse_of names an association that is not there", "… whose class cannot be loaded" — the same cases for which ActiveRecord raises when it builds the join (a scope that takes the record counts also on the `:through` association or the source of a `:through`). A path with an empty step (`parent..owner`) gets "has an empty association name". The checks run for a new rule; the column check also when its field name, path, join type or resource changes, the path check when its path, join type or resource changes. A filter rule's path is never checked (it is never joined). They are skipped when nothing can be told at that moment: the model cannot be loaded (or its table does not exist yet), or a join rule's name is qualified with a real table that is none of the rule's (one your query joins itself). Copying a Permission Set copies an existing rule as it is, also one whose operator, join type or field name a check made since refuses.
- **A rule that names a missing column, or a path that cannot be followed, matches nothing.** A rule saved before these checks (or written past the model, a column or association since renamed or removed) lets no record through to the users it applies to — a missing column under every built-in operator, a broken path under every operator (the join is never built). Neither reaches the database or ActiveRecord, which would raise and turn every `find_by` / `permission_scoped` of its holders into a 500 (`ActiveRecord::StatementInvalid`, or `ActiveRecord::ConfigurationError: Can't join 'Customer' to association named 'ownr'`). An RLS policy compiles a missing column to `FALSE` as well (a join rule whose path cannot be followed, and a rule with an operator or join type this version does not know, compile to `FALSE` too; a join rule that works is not compiled into a policy: it is reported as skipped). `bin/rails permission_forge:audit` lists such rules in effect (`missing_rule_columns`, High when people hold the set), and the admin shows them: Home lists them under "Rules that match nothing", and the Rules tab, the rule's edit page and a person's effective access say "Matches nothing" and why, instead of the rule's sentence. Columns are read from Rails' schema cache, and a name the cache does not have is read again from the database once before the rule is refused or matches nothing (`PermissionForge::SchemaRead`): a running server, or an old process during a rolling deploy, sees a column a migration added after it booted. A process that already asked about the name before the migration ran keeps the answer until the table is read again — a restart, a code reload in development, or opening the model's Resource page (or Sync fields) in the admin, which compares the columns with the database — so deploy the migration before the rule. A removed column leaves a process at that same comparing read. Associations are read from the model as loaded: deploy the model change before a rule that follows the new association.
- **A table that is none of the rule's.** A field name qualified with a table that is not the model's nor one along the rule's relationship path:
  - **On a filter rule, another model's table** (`suppliers.name` on a rule for `Customer`) matches nothing in every query the gem builds (`find_by`, `find_by!`, `permission_scoped`, the default scope), whatever the query joins: a filter rule compares its own table. A new rule or a rename is refused ("names suppliers, a table that is not Customer's: … use a join rule"); the audit lists stored ones as `foreign_table_filter_rules` (High while people hold the set), Home under "Rules that match nothing". For a column of another table, write a join rule: `join_type` and the relationship in `field_accessor_path`, so the column is checked and the value typed.
  - **On a join rule, a real table its query joins itself** (a `default_scope`, a `joins` the host chains before `permission_scoped`) is left to the database, its value compared as text; where the query does not join it, the rule matches nothing. `rake permission_forge:audit` lists such rules as `foreign_table_names` (Info). An alias ActiveRecord gives a table joined twice (`parents_customers.active` on a path that leads back to the same table) is left to the database as well.
  - **Anything else** — no table of this database (`nosuch.name`, the typo `customer.name`), or a name the join's ON clause mentions but gives no table (`supplier_id.id` on a rule joining `supplier`) — matches nothing (it raised `ActiveRecord::StatementInvalid` for every holder), cannot be saved on a new rule or by renaming one ("names nosuch, which is no table of this database"), and is listed under `missing_rule_columns` and on Home.
- **Still left to the database:** a rule under a custom operator naming a missing column (its strategy decides what the name means), and a table along the path that does not exist.
- **An operator or join type this version does not know matches nothing.** A rule row with an operator such as `regex` or a join type such as `inner` — written by a newer version of PermissionForge during a rolling deploy, by another application on the shared tables, or past the model — denies every record to its holders (it used to raise `ArgumentError` / `ConfigurationError` from `permission_scoped`, `find_by` and, under `auto_query_scoping`, from every query). `rake permission_forge:audit` lists them as `unknown_rule_operators` (High while people hold the set); Home lists them under "Rules that match nothing"; the rule's edit page says so and keeps the stored condition. **Rolling deploys:** old processes deny through such a rule until they restart — finish the deploy, or save the rule after it. The rule can still be switched off or renamed: what a rule names is checked only when it changes.

The admin's rule builder offers every column of the table along the relationship path — `id` included, flagged "no field row (ignored_fields)": a column `config.ignored_fields` leaves out of the field rows can still be compared by a rule — and never a virtual field. The list it offers is exactly the list the validation accepts (`Operators::RuleColumn.names_for`), less the columns that hold a secret (below).

**Columns that hold secrets.** A rule never compares a password digest, a token, an encrypted value or a secret (`config.rule_secret_column_patterns`; defaults `*_digest`, `*token*`, `encrypted_*`, `*_secret*`, `*passw*`, `secret*`, `api_key` / `private_key` / `secret_key` / `access_key`, `crypted_*`, `*_salt`, `otp_*`, each tied to a name segment). Who can read which record would tell the secret apart, and the rule's value — stored, shown in the admin and returned by the API — would be a guess at it. Such a rule is refused when it is created or its column, path, join type or resource changes ("names a column that holds a secret …"), and the rule builder does not offer these columns; rules stored before keep applying (their value and operator can no longer change), and the audit (`secret_rule_columns`) and Home list them. Set `config.rule_secret_column_patterns = []` to allow them, or a narrower list to keep only some.

### A value the column cannot hold

A rule whose value is not a value of the column (`'5_id'` on an integer column, `'maybe'` on a boolean one, `'banana'` on a PostgreSQL `uuid` one) cannot be saved: `field_value` gets "is not a value Customer.owner_id can hold" (the JSON API answers 422), on a new rule and when its value, operator or column changes. A rule that already holds such a value (saved before 0.15, or written past the model) stays editable in its other attributes and matches nothing: every record is denied for the users it applies to. If a rule suddenly lets nobody through, check its value against the column's type in [How Values Are Compared](#how-values-are-compared). Such a rule is listed on the admin's Home under "Rules that match nothing" as well as by the audit (`unusable_rule_values`). A value containing a NUL byte is one no column can hold, under a custom operator too: it cannot be saved on a new rule or by changing the value ("must not contain a NUL byte"), and a stored one matches nothing (it used to raise `ActiveRecord::StatementInvalid` for every holder: the statement was read cut short).
