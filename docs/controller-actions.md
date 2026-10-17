# Controller Actions

## Overview

The controller action guard checks every controller action against the current user's
Permission Sets **before the action runs**.

- REST actions (`index`, `show`, `create`, ...) are checked against the Resource's CRUD flags.
- Every other action (`export`, `archive`, `merge`, ...) is checked as a **custom action** of
  the Resource — the same `ResourceAction` rows that `user.can?(:export, :Customer)` reads.

Nothing new is stored: no new table, no new key in the permission hash. The guard is
**opt-in per controller**. Once a controller includes it, a mapped action runs only for the
people whose Permission Sets permit it: an action no Permission Set manages yet is refused
(`unconfigured_action_strategy = :block`, the default since 0.15; `:allow` is the
[opt-out](#unconfigured_action_strategy)). Before you include the guard in a controller, put
its Resource and actions into the Permission Sets that should run them, and run
`bin/rails permission_forge:audit`: `unmanaged_actions_refused` lists every guarded action
no Permission Set manages.

## Quick Start

### 1. Include the guard

```ruby fragment
class CustomersController < ApplicationController
  include PermissionForge::Concerns::ControllerActionGuard

  def index; end
  def export; end
end
```

The guard adds one `before_action`. Include it **after** the callback that signs the user
in — see [Callback order](#callback-order).

> **Included in `ApplicationController`, the guard also runs on your sign-in pages.** Rails 8's
> `SessionsController` maps to the generator's `Session` model, so under
> `action_guard_nil_user_strategy = :deny` (what new installs get) a signed-out visitor is refused
> the sign-in form. Nobody can sign in, and Sign out ends the session, then lands on the refused
> sign-in page: with the handler below, the 403 page ("Sign in to see it") where the form should be;
> with a handler that answers an empty 403, **Sign out seems to do nothing** (Turbo keeps the old page,
> "Signed in as …" still in the header). Exclude them in the initializer:
>
> ```ruby fragment
> config.controller_discovery_exclude += %w[sessions passwords]
> ```

### 2. Answer denied requests

The guard never renders or redirects. A denied action raises
`PermissionForge::ActionNotAuthorizedError` (`error.resource` is `"Customer"`, `error.action` `"export"`,
`error.controller_path` `"customers"`, `error.reason` `:action_denied`, or `:nil_user_denied` when nobody is
signed in); your app decides what the user sees. The handler is kept in one place, so that this page and that
one cannot drift: copy the `rescue_from` for this error from
[Handling Denials → Rescuing them yourself](row-level-rules.md#rescuing-them-yourself), which also has the
`errors/forbidden` template and the `SessionsController#new` line that goes with it.

What that handler does: only a signed-out visitor is redirected, to sign in, and never from the sign-in page itself. Not
`redirect_back fallback_location: root_path`: when the refused action is the root page, that
redirects to it again, forever (`ERR_TOO_MANY_REDIRECTS`, one `action.denied` event per hop).
Everyone else gets the 403 page in place, rendered as a template in your layout, not
`public/403.html`: a signed-in person who holds no Permission Set, sent to a guarded root by Rails 8's
Turbo sign-in, sees it under your header with a way to sign out, where a static page (or an empty
`head :forbidden`) leaves them on the sign-in form, as if signing in had failed.
[Handling Denials](row-level-rules.md#rescuing-them-yourself) has the template and why, and the line
`SessionsController#new` needs so that Reload after that sign-in (Turbo leaves the address bar on
`/session/new`) does not bring the sign-in form back. Write the message yourself: `error.action` is
a key (`index`), not a sentence.

Without a `rescue_from` the request answers **403 Forbidden**: the engine registers the error in
`config.action_dispatch.rescue_responses`. In production Rails renders `public/403.html`, which Rails apps do
not ship, so an HTML request gets an empty 403 page until you add `public/403.html` or rescue the error. See
[Handling Denials](row-level-rules.md#handling-denials) for the default, how to change it, and HTML and JSON
handlers for this error and the row-level `NotAuthorizedError`.

### 3. Permit the action in a Permission Set

```ruby fragment
resource = PermissionForge::Resource.find_by!(permission_set: support_set, name: 'Customer')

PermissionForge::ResourceAction.create!(
  resource: resource,
  name: 'export',        # the action key
  label: 'Export to CSV',
  is_permitted: true
)
```

Admins can do the same from a Resource's **Actions** tab (see [admin-ui.md](admin-ui.md)).

## How an Action Maps to a Resource and a Key

Every check needs two things: a **Resource** (`Customer`) and a **key** (`export`, or a CRUD
permission). They are looked up in this order — the first source that answers wins, for the
Resource and for the key independently:

1. the controller's own `permission_forge_actions` declaration
2. `config.controller_action_resolver`
3. the convention

### The convention

The Resource is the model the controller is named after. The full path is tried first, then
its last segment:

| Controller | Resource |
|---|---|
| `CustomersController` | `Customer` |
| `Api::V1::CustomersController` | `Api::V1::Customer` if that model exists, else `Customer` |
| `ReportsController` (no `Report` model) | none — not checked |

The key is the action name. REST action names mean a CRUD permission:

| Action | Checked as |
|---|---|
| `index`, `show` | `read_access` |
| `new`, `create` | `create_access` |
| `edit`, `update` | `edit_access` |
| `destroy` | `delete_access` |
| anything else (`export`) | the custom action `export` |

An action named after one of the CRUD words `user.can?` understands (`read`, `create`, `edit`,
`update`, `delete`, `destroy`) is checked as that CRUD permission too.

### `permission_forge_actions`

Declare the mapping on the controller when the convention does not fit:

```ruby fragment
class Customers::MergesController < ApplicationController
  include PermissionForge::Concerns::ControllerActionGuard

  # POST /customers/1/merge runs `create`, but it means "merge a Customer"
  permission_forge_actions resource: 'Customer', actions: { create: :merge }

  def create; end
end
```

| Option | Meaning |
|---|---|
| `resource:` | The Resource name (`'Customer'`, `:Customer` or the class). Leave it out to keep the convention. |
| `actions:` | `{ controller_action => key }`. A CRUD word as the key (`{ approve: :edit }` — `read`, `create`, `edit`, `update`, `delete` or `destroy`) checks that CRUD flag instead of a custom action. |
| `rest_actions:` | `false` leaves `index`/`show`/`new`/`create`/`edit`/`update`/`destroy` unchecked, unless they are listed in `actions:`. Default `true`. |

Subclasses inherit the declaration. Declaring again — in the same class or in a subclass —
**adds to** it: a `resource:` or `rest_actions:` you give replaces the earlier value, and
`actions:` are merged. A subclass's additions apply to that subclass only.

A Resource that is not a constant name (`'customer'`) or a key that is not a valid action key
(`'Merge'`) raises `ArgumentError` when the controller loads, so a typo cannot quietly leave
an action unchecked.

### `config.controller_action_resolver`

One lambda for the whole app, useful when you cannot or do not want to touch the controllers:

```ruby fragment
PermissionForge.configure do |config|
  config.controller_action_resolver = lambda do |controller_path, action_name|
    next ['Customer', 'merge'] if controller_path == 'customers/merges' && action_name == 'create'
    next false if controller_path.start_with?('webhooks/')   # never checked

    nil                                                      # use the convention
  end
end
```

| Return value | Meaning |
|---|---|
| `['Customer', 'merge']` | this Resource, this key (either element may be `nil` to keep the convention for it) |
| `false` | never checked — this wins even over a controller declaration |
| `nil` | use the convention |
| anything else | raises `PermissionForge::ConfigurationError` |

If the resolver raises, the error is not swallowed (the request fails). Treating it as
"not checked" would silently open the action. For the same reason, an answer that is not a
valid name — a Resource such as `'customer'`, a key such as `'Merge'` — raises
`PermissionForge::ConfigurationError` instead of leaving the action unchecked.

### Actions that are never checked

The guard lets an action through without looking at any Permission Set when:

- the controller maps to no model and declares no `resource:`
- the controller matches `config.controller_discovery_exclude` (Rails' own controllers by
  default; PermissionForge's own controllers always)
- the resolver returns `false`
- `rest_actions: false` is declared and the action is a REST action

An action whose name is not a valid action key (lowercase letters, digits and `_`, starting
with a letter, up to 63 characters) — for example `exportCSV` — **is** checked, but no
Permission Set can list it, so it always follows `unconfigured_action_strategy`. Give it a
usable key with `actions: { exportCSV: :export_csv }` to manage it.

## The Decision Table

For every request the guard walks this table from the top. The first row that applies decides.

| # | Condition | Result |
|---|---|---|
| 1 | The action maps to no Resource (see above) | allow |
| 2 | There is no current user | `action_guard_nil_user_strategy` (nil or blank: `nil_user_strategy`): `:bypass` allows, anything else denies |
| 3 | `action_guard_bypass` returns `true` | allow |
| 4 | No Permission Set manages the Resource | `unconfigured_action_strategy` |
| 5 | The action means a CRUD permission | `user.can?(:read / :create / :edit / :delete, resource)` |
| 6 | Custom action, and `user.can?(key, resource)` | allow |
| 7 | Custom action that some Permission Set manages | deny |
| 8 | Custom action that no Permission Set manages | `unconfigured_action_strategy` |

A grant (rows 5 and 6) is looked up first: a user can only be granted something on a
managed Resource, so the answer is the same and a granted request reads nothing extra.

Nothing unexpected opens an action: a user object that does not respond to `can?` is denied
(unless row 3 let it through), an unknown strategy value counts as `:block`, and a bypass
lambda that raises counts as "no bypass" — the Permission Sets decide as usual.

## What "Managed" Means

A Resource or an action is **managed** when an active row for it exists in **any** active
Permission Set of the current tenant — granting or muting, permitted or not, and whether or
not the current user is assigned to that set.

This is how the guard tells two situations apart:

- *Nobody configured this action yet* → `unconfigured_action_strategy` decides (refused by default since 0.15).
- *Somebody configured it, and this user was not granted it* → denied.

> **The first Permission Set that lists an action makes it managed for everyone in the
> tenant.** Before the row exists, nobody may run the action under the default `:block` (every
> signed-in user may under `:allow`). After it exists, only users whose Permission Sets permit it
> may. Under `:allow`, permit the action in every set that needs it at the same time as you add
> the first row.

The same holds for Resources: once any Permission Set contains a `Customer` Resource, the
REST actions of `CustomersController` require the matching CRUD flag.

Details:

- A row in a **muting** Permission Set also makes the action managed, and takes the action
  away from the users assigned to that set.
- Inactive rows, inactive Resources and inactive Permission Sets do not count.
- The list of managed Resources and actions is cached for at most 60 seconds (one small
  entry per tenant) and dropped whenever a Permission Set, Resource or action is added,
  removed, renamed or switched on or off. It is invalidated and rebuilt like a person's
  permissions: a list built while a change was being committed is not left in the cache,
  and a drop the cache store does not confirm is tried again, reported
  (`config.on_cache_failure`) and owed — until the store confirms it, that process builds
  the list from the database. Other processes may use the old list until it expires,
  60 seconds at most. A change made behind the callbacks (`update_all`, raw SQL) is seen
  within a minute.

## `unconfigured_action_strategy`

What happens to a Resource or an action that no Permission Set manages (rows 4 and 8):

```ruby fragment
PermissionForge.configure do |config|
  config.unconfigured_action_strategy = :block   # default since 0.15
  # config.unconfigured_action_strategy = :allow # opt-out: fails open
end
```

| Value | Behaviour |
|---|---|
| `:block` (default) | Deny (`ActionNotAuthorizedError`, a 403) until a Permission Set permits it. Every guarded action must be granted explicitly; a new action is refused until someone decides who may run it. |
| `:allow` | Let it through. Adding the guard to a controller changes nothing until an admin lists the Resource or the action in a Permission Set, and a new action is open to every signed-in user until then. The default before 0.15. `bin/rails permission_forge:audit` reports it (`unconfigured_actions_allowed`, medium) and lists the guarded actions it opens (`unmanaged_actions_allowed`). |

Any other value raises `ConfigurationError` when it is set. Under `:block`,
`bin/rails permission_forge:audit` lists the guarded actions no Permission Set manages, the ones
the guard refuses to everyone (`unmanaged_actions_refused`).

**Upgrading from 0.14**, where `:allow` was the default: run the audit before you deploy. For
each action in `unmanaged_actions_refused`, add its Resource or action to the Permission Sets
that should run it, or set `config.unconfigured_action_strategy = :allow` to keep the old
behaviour.

`:block` does not apply to actions that are [never checked](#actions-that-are-never-checked) —
those are outside the guard altogether.

## `action_guard_bypass`

A lambda that lets chosen users skip the guard, for example administrators:

```ruby fragment
PermissionForge.configure do |config|
  config.action_guard_bypass = ->(user, controller) { user.admin? }
end
```

- It receives the current user and the controller instance (`controller.request`,
  `controller.action_name`, ... are available).
- Only an exact `true` bypasses. Any other return value, and a lambda that raises, means
  "no bypass": the Permission Sets decide as usual, and the error is logged.
- It is not called when there is no current user (row 2 comes first).

## Without a Current User

When `PermissionForge.current_user` is `nil`, the guard follows
`config.action_guard_nil_user_strategy`; while that is `nil` or blank (the default), it
follows `config.nil_user_strategy`:

| Value | Guard |
|---|---|
| `:bypass` | allow |
| `:deny`, `:raise`, anything else | deny (`ActionNotAuthorizedError`) |

`nil_user_strategy` defaults to `:bypass`, so an app that sets neither lets the request
through. The install generator writes `config.action_guard_nil_user_strategy = :deny` for new
installs.

The guard is not an authentication check. Keep your own `authenticate_user!` (or similar) in
front of it, and set `action_guard_nil_user_strategy = :deny` so that a request that slips past
authentication is refused. That option only affects the guard; `nil_user_strategy` is shared with
[row-level rules](row-level-rules.md): changing it also changes what `find_by` and
`permission_scoped` do without a user (jobs, consoles, rake tasks).

**`:deny` here protects only the actions the guard runs on.** The model layer has its own
nil-user defaults, and they fail open: `nil_user_strategy = :bypass` (row rules) and
`masked_attributes_nil_user_strategy = :bypass` (masking). An action that skips the guard, or
skips it for signed-out visitors (`skip_before_action`, a public index), then serves every row
with every field as stored — notes, full emails — to a visitor who is not signed in. Close those
two as well before production: see the
[hardening checklist](../README.md#production-hardening-checklist) (`config.preset = :strict`
closes the first; the second is a deliberate choice of its own).

### Callback order

The guard reads the user from `config.current_user_resolver` when its `before_action` runs.
The rule: **the user must be resolved before the guard runs and before any model read** (a
`find_by`, `permission_scoped`, a masked getter), on every action, public ones included. If your
app sets the user in a `before_action` too, that callback has to come first:

```ruby fragment
class ApplicationController < ActionController::Base
  before_action :authenticate_user!                         # 1. sets Current.user
  include PermissionForge::Concerns::ControllerActionGuard  # 2. the guard
end
```

In the opposite order the guard sees no user: under `action_guard_nil_user_strategy = :deny` it
refuses everything, and with neither option set (`nil_user_strategy` `:bypass`) it lets
everything through.

**Rails 8's authentication generator.** Its `Authentication` concern adds
`before_action :require_authentication` to `ApplicationController`, and `require_authentication`
is what resumes the session (`resume_session` sets `Current.session`, and `Current.user` comes from
it). A controller that includes the guard after inheriting from it gets the right order. An action
opened with `allow_unauthenticated_access` skips `require_authentication`, so nothing resumes the
session there: `Current.user` is `nil` even for a signed-in visitor. The guard then treats them as
signed out — refused under `action_guard_nil_user_strategy = :deny`: with the
[Handling Denials](row-level-rules.md#rescuing-them-yourself) handler a signed-in visitor gets the
403 page as if not signed in, and with a handler that sends every signed-out denial to the sign-in
page (the version documented through 0.14.1) they loop between the two pages, because
`SessionsController#new` sends a signed-in visitor back — and if the guard is skipped too,
row-level rules and masking follow the nil-user strategies, whose default `:bypass` shows every
row unmasked. On every guarded action opened this way, resume the session ahead of the guard
(required: it is what gives the visitor the page instead of the 403 page):

```ruby fragment
class CustomersController < ApplicationController
  include PermissionForge::Concerns::ControllerActionGuard
  allow_unauthenticated_access only: :index
  prepend_before_action :resume_session, only: :index # Current.user for a signed-in visitor
end
```

`prepend_before_action` puts it ahead of the guard wherever the `include` is; a plain
`before_action :resume_session` works only when it is declared before the `include`.
`resume_session` reads the session cookie and never redirects, so a signed-out visitor still
reaches the action, as `nil` — and under `action_guard_nil_user_strategy = :deny` the guard then
refuses them (the handler sends them to sign in): a guarded action is never public to a
signed-out visitor, whatever `allow_unauthenticated_access` says. Both variants are driven as
requests in the test suite's docs app (`test/support/docs_app.rb`): without `resume_session` a
signed-in visitor gets the 403 page, once; with it, the page.

## Hiding Buttons

Ask the same question the guard asks, without raising:

```erb fragment
<% if PermissionForge::ControllerActions::Authorizer.allowed?(controller_path: 'customers', action_name: 'export') %>
  <%= link_to 'Export', export_customers_path %>
<% end %>
```

A small helper keeps views short:

```ruby file=app/helpers/application_helper.rb
module ApplicationHelper
  def action_allowed?(controller_path, action_name)
    PermissionForge::ControllerActions::Authorizer.allowed?(controller_path: controller_path, action_name: action_name)
  end
end
```

`controller_path` is the controller's name as the router writes it: `'customers'`,
`'customers/merges'`, `'api/v1/customers'`. The controller's `permission_forge_actions`
declaration is found from the path, so `action_allowed?('customers/merges', 'create')` checks
the `merge` action.

Optional arguments:

| Argument | Default |
|---|---|
| `user:` | `PermissionForge.current_user` |
| `controller_class:` | the controller the path names |
| `controller:` | `nil` — the controller instance handed to `action_guard_bypass` |

`allowed?` tells you what the guard *would* decide. It does not know whether the controller
actually includes the guard.

### Why was it denied?

`Authorizer.call` returns the full decision:

```ruby fragment
decision = PermissionForge::ControllerActions::Authorizer.call(controller_path: 'customers', action_name: 'export')
decision.allowed?   # => false
decision.reason     # => :action_denied
decision.target     # => resource "Customer", action "export", crud nil
```

| `reason` | Row | Allowed? |
|---|---|---|
| `:unmapped` | 1 | yes |
| `:nil_user_bypassed` | 2 | yes |
| `:nil_user_denied` | 2 | no |
| `:guard_bypassed` | 3 | yes |
| `:unsupported_user` | — (the user has no `can?`) | no |
| `:resource_not_managed` | 4 | yes |
| `:resource_not_managed_blocked` | 4 | no |
| `:crud_granted` | 5 | yes |
| `:crud_denied` | 5 | no |
| `:action_granted` | 6 | yes |
| `:action_denied` | 7 | no |
| `:action_not_managed` | 8 | yes |
| `:action_not_managed_blocked` | 8 | no |

## Limits

- **Controllers without a model.** A controller is only checked when it maps to a Resource,
  and a Resource is always a model. A model-less controller (`ReportsController`) can borrow
  a model's Resource with `permission_forge_actions resource: 'Customer'`; it cannot have a
  Resource of its own.
- **Other engines' routes.** The guard runs only in controllers that include it. Controllers
  that belong to other mounted engines are not covered.
- **`skip_before_action :pf_authorize_action!, only: :index`** works, but nothing else knows
  about it: the admin and `Authorizer.allowed?` still answer as if the action were checked.
  Prefer `rest_actions: false`, `actions:` or the resolver returning `false`, which all go
  through the same mapping.
- **Actions, not records.** The guard answers "may this user run `export` on Customers at
  all?". Which Customers the user may see is still the job of
  [row-level rules](row-level-rules.md) and [query scoping](query-scoping.md).
- **Cost.** The guard reads the user's permission hash on every checked request. A request
  that already touches a protected model pays nothing extra (the hash is memoized on the user
  object); a request that would not otherwise load the hash now does, and for a broad grant
  that hash can be large. A request that is not granted — every action and every Resource
  nobody manages yet included — also costs one small cache read (the managed list), once per
  request however many checks it makes. To keep
  controllers out of both, exclude them (`controller_discovery_exclude`), return `false`
  from the resolver, declare `rest_actions: false`, or use `action_guard_bypass`.

## Configuration Reference

| Option | Default | Used by the guard for |
|---|---|---|
| `unconfigured_action_strategy` | `:block` (`:allow` before 0.15) | Resources and actions no Permission Set manages |
| `action_guard_bypass` | `nil` | Users who skip the guard |
| `action_guard_nil_user_strategy` | `nil` (generated initializer: `:deny`) | Requests without a current user |
| `nil_user_strategy` | `:bypass` | Requests without a current user, while `action_guard_nil_user_strategy` is nil or blank |
| `controller_action_resolver` | `nil` | Mapping a controller action to a Resource and key |
| `controller_discovery_exclude` | Rails' own controllers | Controllers that are never checked |
| `current_user_resolver` | — | Who the current user is |

See [configuration.md](configuration.md) for the full list.
