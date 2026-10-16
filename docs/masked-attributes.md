# Model-Level Masked Attributes

`PermissionForge::Concerns::MaskedAttributes` auto-applies field-level read permissions inside the model itself. Once a model has the concern, any code path that goes through `read_attribute`, `attributes`, `as_json`, `to_json`, `serializable_hash`, or a direct getter (`customer.email`) is enforced — without controllers needing to call `FiltersResponseAttributes` explicitly.

This is the model-level counterpart to [`FiltersResponseAttributes`](field-filtering.md). The two complement each other: the concern protects model-level access; the service still protects hash-shaped data from non-AR sources (raw SQL, external APIs, `pluck`).

## How it gets applied

By default (zero-config), the gem **auto-applies** the concern to every host model that has a matching `PermissionForge::Resource` record:

- **At engine boot**: scans existing `Resource` rows and includes the concern on each named class.
- **At runtime**: when a `Resource` row names a model for the first time (created, or renamed to a new model — also two rows for a new model committed together), the concern is included on that class in the process that commits the row, and every other process includes it at the start of its next request or job (`PermissionForge::MaskingSync`, below). A request already running in another process when the row commits finishes unmasked.
- **After a code reload** (development): the concern is applied again to the reloaded classes.

### How other processes learn about a new model (`MaskingSync`)

The committing process writes a new token (`masked_models_version`) to the cache store. Every process reads it once at the start of each request or job (Rails' executor, which Active Job and Sidekiq also run through) and, when it changed, re-reads the `Resource` names and applies the concern to the models it has not masked yet. Nothing is read when both settings are off, or when every setting that is on is a list of models: the models are then fixed by the configuration, so a process masks them once (at boot, or at its first request or job if the boot could not reach the database, and again after a code reload) and reads nothing per request. A name in a list that is no model in the process is logged once as a SECURITY warning and tried again at the next request or job.

The token is written with no expiry, also under a Rails cache with a default `expires_in`. A process that finds no token (evicted by an LRU store, or flushed) writes a new one and re-applies, and every other process re-applies once when it sees it: losing the token costs one query per process, never a model left unmasked.

- **This needs a shared cache store**: `:rails_cache` over Redis, Memcached or Solid Cache (or `:file_store` on one machine), or a store instance every process shares. Under `cache_backend = :memory` or a `:memory_store` each process has a token of its own, and other processes pick a new model up only at their next boot. A store that keeps nothing (`cache_backend = :null`, a `:null_store`) is never asked for the token: it would read as lost at every check. Production boots with such a store warn that a model first named in another process stays unmasked there until a restart.
- **In development** (Rails 8 generates a `:memory_store`, Rails 7.1/7.2 a `:null_store` unless `bin/rails dev:cache`), the token cannot reach the server either: a `Resource` row created from a console, `bin/rails runner` or a rake task used to leave the model unmasked in the running server until a restart. There each request or job re-reads the `Resource` names from the database instead, one query at most every 2 seconds (`MaskingSync::DATABASE_RECHECK`), so the model is masked at the server's next request after that. The boot says so (in the log and [on standard error](configuration.md#where-warnings-appear)). To avoid the query, share the store or [include the concern](#recommended-in-production-include-the-concern-explicitly).
- **Cost:** one store read per request or job while either setting is `:auto` (the default for `auto_apply_masked_attributes`). The `Resource` names are read (one query) only when the token changed (or was lost). With lists or `false`, nothing per request.
- **When the store does not answer** (unreachable, or it neither gives nor keeps the token), the process stops reading it for 30 seconds and logs that once per outage (`The cache store did not give or keep the masking token ...`: a store that is up but loses the token at once cannot sync masking — share one that keeps entries, or include the concern in the models). When the store answers nothing the warning says so — `(it did not answer, or a read right after a write came back empty: the store is down, full, or evicts the key at once)` — and names the remedy (a shared store that keeps entries, or the concern included in the models). When the pause ends, one request or job per process probes the store (the others make no store call): it pays the timeout twice on an error-swallowing store such as `RedisCacheStore` (the read, then the token write) and once on a store that raises. An outage then adds that to one request or job per process every 30 seconds, not to every one. A model named in another process during the outage is masked here at the first check after the pause. If the process that names the model cannot write the token (the store is down, or raises), it logs a warning, never fails the save, and writes the token at its first request or job after the store answers again (after the pause). Until then the other processes do not mask that model: an outage plus up to 30 seconds, as long as the announcing process serves another request or job.
- **A process that booted without its database** (a deploy during a failover, a database that is not configured yet; an image build running `assets:precompile` does not even try) masks at its first request or job that can read the `Resource` rows. Until then each request or job tries once, quietly.

**A model whose table cannot be read** when masking is applied (a `Resource` row seeded before the model's migration ran, or a database that is down) is skipped, and the other models are still masked. The log says so once per model and process (again after a code reload):

```
[PermissionForge] SECURITY warning: Invoice has a Resource row but its table cannot be read: its columns are NOT masked in this process. It is tried again at the next request or job.
```

At boot this is followed by `Auto-applied masking is not complete at boot ...`. While it lasts, every request and job in every process costs one store read and two SQL statements (the `Resource` names and a table-existence check) until the table exists and the model is masked. A subclass with a `Resource` row of its own is masked through its parent and costs nothing extra. A `PermissionForge::ConfigurationError` raised while masking still stops the boot.

You can change this behavior via `config.auto_apply_masked_attributes`:

```ruby fragment
PermissionForge.configure do |config|
  # :auto / true  — auto-apply to every model with a Resource record (default)
  config.auto_apply_masked_attributes = :auto

  # Array          — auto-apply only to these named models
  config.auto_apply_masked_attributes = ['Customer', 'Order']

  # false / nil    — no auto-apply; include manually per model
  config.auto_apply_masked_attributes = false
end
```

## Recommended in production: include the concern explicitly

Auto-apply is convenient: a model is masked as soon as a `Resource` row names it, in every process. It costs one cache-store read per request and job, and a model is masked only once a row names it. In production, include `MaskedAttributes` in every model that holds personal data and turn auto-apply off (or list those models):

```ruby fragment
# config/initializers/permission_forge.rb
config.auto_apply_masked_attributes = false   # or ['Customer', 'Order']

# app/models/customer.rb
class Customer < ApplicationRecord
  include PermissionForge::Concerns::MaskedAttributes
end
```

The model is masked from the moment it loads, whatever the rows say, and no request or job reads the store. Keep `mask_virtual_attributes` off or a list for the same reason: `:auto` takes its models from the `Resource` rows and reads the store too. Including the concern yourself while auto-apply stays `:auto` does not remove the read: a row committed later in another process can name a model that does not include it.

## Manual include (when auto-apply is off)

```ruby fragment
class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable  # row-level
  include PermissionForge::Concerns::MaskedAttributes          # field-level
end
```

The concern is idempotent — manual `include` plus auto-apply on the same class won't double-prepend.

## What gets enforced

| Path | Enforced? |
|------|-----------|
| `customer.email` (direct getter) | yes |
| `customer.read_attribute(:email)` | yes |
| `customer[:email]` | yes |
| `customer.attributes` | yes (hidden keys omitted) |
| `customer.as_json` / `to_json` | yes (hidden keys omitted) |
| `customer.serializable_hash` | yes |
| `customer.mail`, `customer[:mail]`, `customer.mail = …` (an `alias_attribute` of `email`) | yes — at the level of `email`; see [Aliases](#aliases-alias_attribute) |
| `customer.full_address` (virtual reader) | only with `config.mask_virtual_attributes` — see [Virtual readers](#virtual-readers) |
| `customer.id` (primary key) | **no** — never masked (used for routing, associations, tenant scoping) |
| `customer.slice(:email)`, `values_at`, `dup`, `becomes`, `reload` | yes |
| `customer.inspect`, `pp customer` / `pretty_print`, `attribute_for_inspect` | yes — see [inspect](#inspect-and-pretty_print) |
| `customer.email_before_type_cast`, `customer.email_for_database`, `customer.read_attribute_before_type_cast(:email)`, `attributes_before_type_cast` | **no** — the raw path, for code that needs the stored value |
| `customer.email_in_database`, `attribute_in_database(:email)`, `_read_attribute(:email)`, `attributes_for_database` | **no** — raw |
| Dirty tracking: `email_was`, `email_change`, `email_will_change!`, `email_change_to_be_saved`, `email_previously_was`, `email_previous_change`, `email_before_last_save`, `saved_change_to_email`, `changes`, `changes_to_save` | **no** — the raw change set (the predicates `email_changed?`, `email_previously_changed?`, `saved_change_to_email?`, `will_save_change_to_email?` answer true/false and reveal no value) |
| `Marshal.dump(customer)` (and caches that marshal records) | **no** — the stored values |
| `Customer.pluck(:email)` | **no** — bypasses the model layer entirely |
| Raw SQL via `connection.execute` | **no** |
| A column selected under another name (`select("email AS contact")`), read as `customer.contact` or through `as_json` | **no** — a raw-SQL path, see below |

Every attribute-method pattern Rails gives a model is checked against this table by the test suite (`test/permission_forge/concerns/masked_reader_surface_test.rb`), on every Rails version the gem supports: a reader that returns the stored value is listed here, and nothing listed here is intercepted. A pattern a new Rails release adds fails that test until it is masked or listed.

### How direct getters work

The concern prepends a module at include time that overrides every column's getter to delegate to `read_attribute` — the masking logic lives in one place — and every column's setter, which powers the write-back protection below. Column changes after the class loads require an app reload to pick up — same as adding a new column normally would.

### Subclasses

A subclass of a model that has the concern is guarded like its parent. Which `Resource` entries judge it depends on its table; see [Single-table inheritance](#single-table-inheritance) below. A subclass with a table of its own (not STI) is judged under its own class name alone: `Car < Vehicle` with its own table needs a `Resource` row and field rows named `Car`, and without them its columns follow `config.unconfigured_field_strategy` — under the default `:block`, every getter returns the hidden value.

The subclass's own methods keep answering first: a reader or setter it defines for a column, or one from a module it includes, still runs, and `super` in it reaches the masked getter or the guarded setter. (This is not so for the class that has the concern itself, where the concern's getter answers before the class's own reader for the same column.)

It makes no difference whether the subclass was loaded before the concern arrived or after. Rails gives a subclass column methods of its own the first time it is used, unless its parent already defines them — which the parent does once it has the concern. A subclass that was **in use before** its parent got the concern has such methods, and at the moment the concern arrives they are removed, so that it finds its parent's like any other subclass. That order needs one of two things: host code that touches a record of the subclass during boot, before the engine applies the concern (`config.to_prepare { Car.first }`), or the parent's first `Resource` row being created while the app is running and has already used the subclass. A normal boot, eager-loaded or not, does not produce it: the engine applies the concern before any subclass has generated its methods.

### Single-table inheritance

A subclass on its parent's table (`VipCustomer < Customer`) answers to its own `Resource` and to every ancestor's up to the base class (`PermissionForge::ResourceChain`; nearest first: `[:VipCustomer, :Customer]`). Since 0.14, before which a subclass answered to its own name only:

- **A subclass with no `Resource` row of its own is its base.** Its fields read as the user's `Customer` entry says.
- **Several entries: the strictest wins.** When the user has an entry for the subclass and for an ancestor, a field is readable (or editable) only when every entry that configures it grants that, and masked when any of them masks it (with the first masking entry's strategy, nearest first). An entry that does not configure a field does not veto it, so the subclass's row can configure a field the base leaves unconfigured. A subclass can never be more open than its base for a field both configure.
- **An entry that does not grant read hides everything.** When any entry along the chain has `read_access` other than `true` on the resource, every field the chain configures is hidden — also fields only the other entry configures. In practice: **a subclass `Resource` row must grant read**. A row added to a subclass only to carry rules, with `read_access: false`, hides every field of that subclass, including those the base's row makes readable. A muted read on the base hides the subclass's fields the same way.
- **A muting set naming the base reaches the subclass entry.** The permission hash's muting phase applies a muting resource row to every entry whose chain names it — CRUD flags, View All / Modify All, actions and field rows — so `can_read?` / `can_delete?` and the controller guard on the subclass follow a muted base, and the subclass entry lists the muting set in `source_permission_sets`. A muting row naming a subclass reaches that subclass alone. The admin's *Effective access* shows the muting set as blocking the subclass's flags.
- **A host override of `User#field_permissions` is bypassed** for an STI subclass: its field entry is composed from the user's `permissions_hash` entries directly. A plain model (one name) still goes through `field_permissions`.
- **Only single-table inheritance forms a chain.** A subclass with a table of its own answers to its own name alone.

`MaskedAttributes.explain(record, :email)[:resource_chain]` shows the names a record's class answers to. `FiltersResponseAttributes`, `PermitsAttributes` and the row-level rules use the same chain ([row-level-rules.md](row-level-rules.md#single-table-inheritance)). The admin's *Effective access* screen shows one Resource name at a time and does not compose the chain.

### Aliases (`alias_attribute`)

An alias is not a field of its own. Reading or writing it is reading or writing the attribute it points to, at that attribute's level:

```ruby fragment
class Customer < ApplicationRecord
  alias_attribute :mail, :email
end

# email is hidden for the current user
customer.mail                      # => nil, as customer.email
customer[:mail]                    # => nil
customer.read_attribute(:mail)     # => nil
customer.as_json(methods: [:mail]) # no "mail" key, as there is no "email" key
customer.mail?                     # => false, as customer.email?
customer.mail = customer.email     # skipped by the write-back protection, as customer.email = … is
```

- **No field row is needed for the alias, and one named after it is not consulted.** (The one exception: a model that lists the alias in its `extra_fields_method` and has `config.mask_virtual_attributes` on gets that field's level applied on top of the column's.)
- **It does not matter when the alias is declared**: before the concern is included, after it, in a subclass, or on a parent class (with the concern or without); nor when Rails generates its own alias methods, which it does lazily.
- **An alias does what it does in your Rails version, plus the guard.** On Rails 7.2 and later Rails reads and writes the attribute itself for an alias, whatever reader or setter the model defines for the target column; so does the concern, through the guard. On Rails 7.1 Rails calls the model's own reader or setter for the target when the model defines one (deprecated there). The concern calls the model's setter the same way. A reader the model defines for a column does not run on the class that has the concern (the concern's getter answers first, see [Limitations](#limitations)), so there an alias of that column returns the attribute and not that reader's value, as the column's own getter does. On 7.1 the concern also decides between the model's method and the attribute the first time an alias is called and keeps that choice, where Rails decides each time it generates the methods; the two differ only for a class that is reopened after it was first used. Apart from these, with no current user a model's aliases read and store exactly what they do without the concern.
- **A method of your own under the alias's name still runs** — defined in the class, in a module it includes, in a parent or in a subclass — and `super` inside it returns the guarded value.
- **An alias its parent declares** is guarded for the class that has the concern even when the parent does not have it. The parent itself and its other subclasses are not affected.
- **The raw paths are the column's raw paths**: `mail_before_type_cast` returns the stored value, as `email_before_type_cast` does. The dirty helpers (`mail_was`, `mail_change`, `mail_changed?`, `saved_change_to_mail`, …) read the raw change set, exactly as `email_was` and the others do for a hidden column. `write_attribute(:mail, …)` and `customer[:mail] = …` are not covered by the write-back protection, as `write_attribute(:email, …)` is not.
- **`pluck(:mail)` bypasses the model**, as `pluck(:email)` does.
- An alias of the primary key (Rails' own `id_value`) is left alone: `customer.id_value` and `customer[:id_value]` return the id. An alias of an attribute-API attribute follows that attribute: masked through `read_attribute` always, and through the getter when [virtual readers](#virtual-readers) are masked. An alias of an alias is judged as the attribute at the end of the chain, and reads what Rails reads for it (`nil`: Rails follows one alias only).

One order is not covered: an alias added to a parent class that does not have the concern, *after* a subclass got it — a class reopened later. `customer[:mail]` and `read_attribute(:mail)` are still judged by the column, but the direct getter and setter are Rails' own. Declare the alias on the model that has the concern, or before the concern is included.

### Partially loaded records

A record loaded with only some of its columns (`Customer.select(:id)`) behaves as it does on a model without the concern. The getter of a column that was not loaded raises `ActiveModel::MissingAttributeError` — whatever the column's level, with a current user or without — and so does everything built on it: `email?`, an alias, `slice`, `as_json(methods: [:email])`, `read_attribute_for_serialization`, a store accessor on a store column that was not loaded. `customer[:email]` raises and `customer.read_attribute(:email)` returns `nil`, as Rails does. `attributes` and `as_json` list the loaded attributes only. Assigning to a column that was not loaded works, as in Rails.

Nothing is revealed this way: a column that *was* loaded and that the user may not read still returns the hidden value.

### `inspect` and `pretty_print`

`inspect`, `pretty_print` / `pp` and `attribute_for_inspect` print what the current user's getters return (Rails 7.1 to 8.1), with Rails' `filter_attributes` applied on top: a record in a log line, an error report or a console no longer prints masked and hidden values in full. Two things to know:

- They are not audited reads: they write no `field.access` event and do not call `on_field_filtered`.
- They never raise. A read that fails (a dead cache store, a failed transaction), or Rails' formatting of the value that fails, prints the hidden value, never the stored one. Under `masked_attributes_nil_user_strategy = :hide` the hidden value prints when nobody is signed in.

Under `unconfigured_field_strategy = :block`, columns without a field row (timestamps, foreign keys) print as `nil`, as their getters return. With no current user the stored values print, as the getters return them. `MaskedAttributes.explain` remains the way to see the raw value next to the returned one.

### `pluck` and raw SQL bypass

These run in the database, not the model. There's no Ruby-level hook to intercept them. For controllers that `pluck` and serialize, keep using [`FiltersResponseAttributes`](field-filtering.md) on the resulting hashes.

A column selected under another name is such a path too: after `Customer.select("id, email AS contact")`, `customer.contact` and `customer.as_json` return the stored address, whatever the level of `email` (`customer[:contact]` and `customer.attributes` treat `contact` as an unconfigured field).

This is the same fundamental limitation Salesforce has — `Database.query` without `WITH SECURITY_ENFORCED` bypasses Field-Level Security, too.

## Hidden vs. omitted (Salesforce semantics)

When the user lacks `read_access` on a field:

- **`attributes` / `as_json` / `to_json`**: the key is **omitted entirely** by default. This matches `Security.stripInaccessible()` — the field literally doesn't exist in the hash. Set `config.omit_hidden_in_attributes_hash = false` to include the key with a sentinel value instead.
- **`read_attribute` / `[]`**: returns `config.hidden_attribute_value` (default: `nil`). Set this to a custom sentinel (e.g. `RedactedValue.new`) if `nil` is ambiguous in your domain.

```ruby fragment
# Default
customer.read_attribute(:domain)  # => nil
customer.attributes               # => { 'name' => 'Acme', 'email' => 'c***@acme.com' }
                                  #    (no 'domain' key)

# Switch to keep keys with sentinel
PermissionForge.configure do |c|
  c.omit_hidden_in_attributes_hash = false
end
customer.attributes               # => { ..., 'domain' => nil }
```

## Masked vs. hidden vs. raw

The same precedence as `FiltersResponseAttributes`:

| `read_access` | `mask_access` | Result |
|---------------|---------------|--------|
| `false` | * | Hidden / omitted |
| `true` | `true` | Masked via `MaskValue` (`mask_strategy`) |
| `true` | `false` | Raw value |

```ruby fragment
customer.read_attribute(:email)
# => "c***@acme.com"  when read_access: true, mask_access: true, mask_strategy: 'email'
# => "contact@acme.com"  when read_access: true, mask_access: false
# => nil  when read_access: false
```

**A strategy this app does not know masks fully.** A field row whose `mask_strategy` is none of the built-in ones and none of `config.custom_mask_strategies` — a row written past the model, a blank, or a custom strategy you removed from the configuration after rows named it — masks the value fully (`********`) wherever it is read (the model's getters, `as_json`, `FiltersResponseAttributes`, the admin), never raises, and is reported once per process per name: a warning in the log and the `mask_strategy_unknown.permission_forge` notification (payload `strategy`, `fallback`). `rake permission_forge:audit` lists such rows (`unknown_mask_strategies`, High while people hold the set); the field drawer flags them ("Unknown mask strategy — masked fully until fixed") and keeps the stored name until you pick another. `PermissionForge::Services::MaskValue.call!` is the strict form (raises) for previews and validations; `MaskValue.known?(name)` says whether a name is a strategy.

## Write-back protection

Because the getters return masked/hidden sentinels, a host callback like `before_save { self.email = email.strip }` — or a form that renders the masked value and submits it back — would otherwise persist the sentinel over the real data. The setter overrides guard against this, controlled by `config.masked_write_protection`:

- `:skip` (default) — silently discard the write, preserving the stored value
- `:raise` — raise `PermissionForge::Concerns::MaskedAttributes::MaskedWriteError` (surfaces the bug)
- `:off` — disable the guard (legacy behavior; risks silent corruption)

A write is treated as a masked write-back when either:

1. **Ledger** — this instance handed out that exact sentinel for the attribute earlier (covers same-instance read-modify-write, e.g. a `before_save` callback), or
2. **Stateless** — the incoming value equals the mask of the value *currently persisted* in the database. This survives a request boundary: a form rendered `********` and submitted back onto a freshly-loaded record has no ledger entry, but still matches the persisted value's mask. The stateless check only fires when the incoming value differs from the persisted one — writing the same value back is a harmless no-op either way.

Callbacks that legitimately need the raw value should read it via `read_attribute_before_type_cast`, which bypasses the masking readers.

Writing a column through an `alias_attribute` name passes the same guard.

## Virtual readers

A virtual field is a field that is not a column: a method, a store accessor, an attribute-API attribute (see [Extra Virtual Fields](field-filtering.md#extra-virtual-fields)). By default the concern masks columns only, and a virtual field's level is enforced by `PermitsAttributes` and `FiltersResponseAttributes`. `customer.full_address` returns the real value.

`config.mask_virtual_attributes` extends the model-level enforcement to virtual readers:

```ruby fragment
PermissionForge.configure do |config|
  # false / nil    — off (default)
  config.mask_virtual_attributes = false

  # :auto / true   — every model that has MaskedAttributes
  config.mask_virtual_attributes = :auto

  # Array          — only these models
  config.mask_virtual_attributes = ['Customer', 'Order']
end
```

It is off by default because it changes what the model's own code sees: a validation or callback that calls `full_address` gets the masked value too (see the escape hatch below).

### Which readers are wrapped

The virtual fields the admin lists for the model: the names the model declares through `extra_fields_method`, plus discovered attribute-API attributes and store accessors while `config.virtual_field_discovery` is on.

A name is never wrapped when it is the primary key, a column, a method `ActiveRecord::Base` itself defines (`attributes`, `save`, …), a method that does not exist, a method that is not public, or a method that needs arguments. Readers with only optional arguments are wrapped and keep their arguments.

The engine wraps the readers at boot and whenever the concern is applied to a newly named model (in every process, through `MaskingSync`), for every selected model that has the concern — auto-applied or included by the model itself. If you include the concern yourself on a model that has no `Resource` row yet, or want other names covered, call it at the end of the class body:

```ruby fragment
class Customer < ApplicationRecord
  include PermissionForge::Concerns::MaskedAttributes

  def self.extra_fields_for_permissions = %w[full_address]

  def full_address = [street, city].join(', ')
  def credit_score = ScoreService.for(self)

  pf_mask_virtual_readers                   # the model's virtual fields (full_address)
  pf_mask_virtual_readers(%w[credit_score]) # or explicit names
end
```

Wrapping is idempotent and permanent for the class. The decision is not: every wrapper checks `config.mask_virtual_attributes` on each call, so a wrapped model behaves exactly like an unwrapped one while the config does not select it.

If the model's `extra_fields_method` raises while the readers are being wrapped, its declared names cannot be read and those readers are not wrapped. Boot continues, and the log gets a `SECURITY warning` that names the model and the error and says its virtual readers are not masked. Fix the method and restart, or pass the names to `pf_mask_virtual_readers` yourself.

To check one reader from the console:

```ruby fragment
PermissionForge::Concerns::MaskedAttributes::VirtualReaders.masked?(Customer, :full_address)
# => true when the reader is wrapped and the config selects Customer
```

The admin's field drawer uses the same check: it says a virtual field's level applies on the model only when that reader is really masked there.

### What a wrapped reader returns

The decision is the same one columns get, made by `AttributeAccessGuard` (so `config.on_field_filtered` fires for virtual reads too):

| Field entry | Result |
|-------------|--------|
| `read_access: false` | `config.hidden_attribute_value` (default `nil`) |
| `read_access: true, mask_access: true` | The mask, when the value is a String, Symbol or Numeric. `config.hidden_attribute_value` for anything else. |
| `read_access: true, mask_access: false` | The real value |
| No entry | `config.unconfigured_field_strategy` (a declared field with no row has an entry under `extra_fields_default_access = :grant`) |
| No current user | The real value under `masked_attributes_nil_user_strategy = :bypass` (the default); `config.hidden_attribute_value` for every guarded attribute under `:hide`, except on the user model (`user_class` and its subclasses), which reads as stored |

An array, hash, record, boolean or date is never masked: a mask of its `to_s` would be meaningless and could leak, so a masked field with such a value is hidden instead. That holds for every mask strategy, including a custom one that returns values it does not recognise unchanged: the value is never passed to the strategy.

The reader itself always runs; its result is then passed, masked or hidden.

Attribute-API attributes go through `read_attribute`, exactly like columns. (`attributes` and `as_json` already guard them without this option. The option adds the direct getter.)

### Serialization

`as_json(methods: [...])`, `to_json` and `serializable_hash` call the wrapped readers, so masked values come out masked. A name in `methods:` that the user may not read is dropped from the output when `config.omit_hidden_in_attributes_hash` is on (the default), the way hidden columns are dropped. With it off, the key stays with `hidden_attribute_value`.

### Escape hatch

Code that needs the real value (the model's own validations and callbacks, exports run for a signed-in user) asks for it explicitly:

```ruby fragment
before_save :normalize_address

def normalize_address
  self.address_line = pf_without_virtual_masking { full_address }.strip
end
```

`record.pf_without_virtual_masking { ... }` switches virtual masking off for that record, for the duration of the block. It is scoped to the instance, nests, and is restored when the block ends, even if it raises. It does not affect columns (use `read_attribute_before_type_cast` for those), other records, copies of the record made inside the block (`dup`, `clone`, a cached copy), or other threads.

### Caveats

- **Setters are not guarded.** Write-back protection covers columns only. A form that renders a masked virtual value and posts it back can overwrite the real one; filter params with `PermitsAttributes`.
- **A store accessor is one view of its column.** Hiding `theme` does not hide the `theme` key inside the `settings` column itself. Hide or mask the store column too if the whole hash should not be readable. While the store column is hidden or masked for a user, its accessors return the hidden value for them, whatever their own level, and never touch the column. Writing a key through an accessor works on the stored hash, so the other keys survive; the accessors and the column getter still return nothing readable afterwards. Rails' dirty helpers for a store accessor (`theme_was`, `theme_change`, `saved_change_to_theme`, `theme_before_last_save`) read the raw change set, as `email_was` does for a hidden column. (Without this handling, Rails would see `nil` where it expects the hash and replace the column with an empty hash in memory, which a later save would persist; on Rails 7.1–8.0 the read then also raised.) Only a store whose getter the concern masks is affected — a column, or a wrapped virtual reader while virtual masking is on. On a record loaded without the store column (`select(:id)`), reading or writing a key raises `ActiveModel::MissingAttributeError`, as in Rails, and the stored hash is left alone.
- **Methods built on other readers see what those readers return.** A virtual reader that calls masked column getters computes from masked values. Read raw values with `read_attribute_before_type_cast` inside such methods.
- **Reloading in development.** After a code reload the engine wraps the readers again for the models with a `Resource` row that the config selects (`MaskingSync`). A model without a `Resource` row should call `pf_mask_virtual_readers` itself.
- **Subclasses.** Wrappers are inherited. A subclass that overrides a wrapped reader gets its own wrapper the next time `pf_mask_virtual_readers` runs on it. Its field entry is looked up along its [resource chain](#single-table-inheritance).

## Unconfigured fields

If a column has no matching `ResourceField`, the concern uses the same `config.unconfigured_field_strategy` as `FiltersResponseAttributes`:

- `:block` (default) — hide unconfigured fields: `attributes` omits them; `as_json`, `serializable_hash` and `to_json` keep the key with `nil` (no value leaks)
- `:pass_through` — return raw value
- `:warn` — return raw value, log a warning
- `:mask_all` — apply full masking

Unknown strategy values fall back to `:block` (fail closed), never pass-through.

### Rails timestamps

Generating fields gives Rails' timestamps (`created_at`, `updated_at`, `created_on`, `updated_on`) a row, so under `:block` a reader who is granted them reads them as stored instead of `nil`. Through 0.14.1 they were in `ignored_fields` and got no row: every reader, admin included, saw `null`. All the paths that generate rows treat them alike — `ResourceFieldGenerator` (also `Resource.grant_full_access!` and `generate_fields` in the API) and the admin's presets, "Add all new", "Sync fields" and the Fields tab's bulk add (through 0.14.1 the bulk add did not). All of them build the row in one place (`ResourceFieldGenerator::RowBuilder`), so the level, the privacy default and the timestamp rule cannot drift between them:

| On a granting Permission Set, the level chosen | A timestamp row |
|---|---|
| Editable (Full access, `grant_all: true`), Read-only, Masked | Read-only: read on, edit off, never masked |
| Hidden ("No access", `grant_all: false`) | Hidden, like every other column: a granting row adds access, so "No access" stays no access |

On a **Muting Permission Set** a timestamp row gets the level chosen, like every other column (read on there means "take read away", so a read-only rule would mute the timestamps for the set's holders). A row you set one by one (the field editor, the API, the console) is never changed.

A resource generated before keeps its fields until you sync them: on an existing install the admin lists `created_at` / `updated_at` as not configured on every resource. Sync them (at the level you want), or keep them out with `config.ignored_fields += %w[created_at updated_at]`, which also stops the admin listing them.

## Without a current user

When `PermissionForge.current_user` returns `nil` (background jobs, mailers, the console, migrations), the concern follows `config.masked_attributes_nil_user_strategy`, not `nil_user_strategy` (that option governs the row-level rules). `:bypass` (the default) returns the stored values. `:hide` hides every guarded attribute: getters, `read_attribute`, `[]`, `attributes` (keys left out, or present with `hidden_attribute_value` when `omit_hidden_in_attributes_hash` is false), `as_json` (only the primary key remains), the wrapped virtual readers and store accessors. The primary key and the raw paths listed under "What is not intercepted" are untouched. `MaskedAttributes.explain_all` reports `:no_user_bypassed`, `:no_user_hidden` or `:no_user_user_model_exempt`; `explain` has `user_model_exempt`. Under `:hide` the user model (`user_class` and its subclasses) reads as stored with nobody signed in: authentication reads it before anyone is signed in, so hiding it would lock everyone out. Do not render it with no current user (`rake permission_forge:audit` reports `user_model_unmasked_without_user`); another authenticatable model is not exempt. Code that reads other masked models with no user then sees hidden values: set the current user there. `rake permission_forge:audit` reports `:bypass` as `masked_nil_user_bypass` (medium).

## Validations

Validators judge the stored value of the attribute they validate: a masked or hidden value never fails a presence, format or uniqueness check the stored value passes, nor passes one it fails. Only that attribute, only while the validators run: other getters (a derived reader too) and a custom `validate` block read masked. What errors report is what the current user reads: `errors.details[...][:value]` and `%{value}` in messages show the masked value, and nothing for a column the user may not read.

## Diagnostics

When a field returns an unexpected value (nil where you expected raw, raw where you expected masked), ask the concern to explain its decision from the console:

```ruby fragment
PermissionForge::Concerns::MaskedAttributes.explain(customer, :email)
# => { attribute: :email, field_configured: true, field_entry: { read_access: true, ... },
#      unconfigured_field_strategy: :block, raw_value: "contact@acme.com",
#      returned_value: "c***@acme.com", ... }

PermissionForge::Concerns::MaskedAttributes.explain_all(customer)
# prints a per-column table of raw vs. returned values with the decision made:
# passed_raw / masked / hidden_no_read_access / unconfigured / no_user_bypassed / primary_key_skipped
# Virtual readers are listed after the columns (virtual: true). One that is not
# masked on the model reports virtual_masking_off.
```

## Performance

Per attribute access on the cache-warm path: roughly 3 hash lookups + 1 branch (+ 1 method dispatch + 1 string transform if masked). The user's `permissions_hash` is fetched once per request and cached.

For a 1000-row index page calling `customers.map(&:as_json)`, expect 5–15ms additional wall time depending on cache backend. Negligible for individual records; meaningful on large collections — benchmark before enabling on hot models.

## Configuration reference

```ruby fragment
PermissionForge.configure do |config|
  # Auto-apply mode. :auto/true (default), array of names, or false/nil.
  config.auto_apply_masked_attributes = :auto

  # Value returned by read_attribute when access denied. Default: nil.
  config.hidden_attribute_value = nil

  # When true, hidden keys are omitted from `attributes` / `as_json`.
  # When false, they're present with hidden_attribute_value. Default: true.
  config.omit_hidden_in_attributes_hash = true

  # Write-back guard: :skip (default) silently discards masked write-backs,
  # :raise raises MaskedAttributes::MaskedWriteError, :off disables the guard.
  config.masked_write_protection = :skip

  # Also mask virtual readers on the model: false/nil (default), :auto/true,
  # or an array of model names.
  config.mask_virtual_attributes = false
end
```

## Upgrade notes: aliases, subclasses, partially loaded records

The release that made `alias_attribute` names guarded changed four other things a host app can notice:

1. **A subclass that was in use before its parent got the concern is now guarded** (see [Subclasses](#subclasses)); its getters used to return the stored values. In that release it was judged under its own class name only. Since 0.14 an STI subclass without a `Resource` row of its own is judged as its base ([Single-table inheritance](#single-table-inheritance)); a subclass with a table of its own still needs its own rows.
2. **Reading a column that was not loaded raises**, as on any Rails model. On a record from `select(:id)`, getters, `email?`, `slice`, `as_json(methods: [...])` and store accessors used to return `nil` for a column outside the select; they now raise `ActiveModel::MissingAttributeError` (see [Partially loaded records](#partially-loaded-records)).
3. **`record[:id_value]` returns the id.** It used to be judged as an unconfigured field (`nil` under `:block`).
4. **An alias read through `[]` or `read_attribute` is judged as its column.** It used to be judged as an unconfigured field: the stored value under `:warn` and `:pass_through`, `nil` under `:block` even for a readable column.

## When to use which

- **`MaskedAttributes` concern** — model code, controller responses that go through serializers, anywhere AR records flow through `as_json`. The "always-on" enforcement.
- **`FiltersResponseAttributes` service** — non-AR data: API responses, external service calls, `pluck` results, JSON received from another system that needs filtering before re-rendering.

The two are designed to coexist. Use both.

## Limitations

1. **Primary key is never masked.** `customer.id` returns raw — masking it would break routing, associations, and tenant scoping. If you need to hide identity, hide the entire record via row-level rules instead.
2. **`pluck` bypasses** — same as Salesforce. Filter the hash post-pluck if needed. So does a column selected under another name: after `select("email AS contact")`, `customer.contact` and `as_json` return the stored value.
3. **Column changes need a reload** — the per-getter overrides are generated at class load time from `columns_hash`. Adding a column at runtime won't be picked up until the class is reloaded.
4. **Resource names come from class names** — a class answers to its own name and, under single-table inheritance, to its ancestors' (see [Single-table inheritance](#single-table-inheritance)). There is no other mapping: to judge a class under another name, override `self.name`.
5. **Auto-apply is permanent within a process** — once the concern is mixed into a class, you can't undo it. Removing the last `Resource` row of a model never un-masks it; toggling `auto_apply_masked_attributes = false` later only prevents new applications; existing classes keep the concern until the next restart. Renaming a `Resource` row to a new model applies the concern to that model in every process, like creating one.
