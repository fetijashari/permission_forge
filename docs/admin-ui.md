# Admin UI

PermissionForge ships with an optional, built-in admin for the business owner: **who can see and do what, and why**. No extra gems, no JavaScript build, no asset pipeline.

## What You Get

| Screen | What the owner does there |
|--------|---------------------------|
| **Home: Needs attention** | Privacy audit (sensitive fields shown unmasked, including fields that are not configured and fields whose setting is turned off, marked **○ Off**; fields are flagged by column name, so a flag may not be personal data — **This is intended** takes a field off the list), record rules not applied everywhere (all active rules while `auto_query_scoping` is off; join rules when it's on), record rules that match nothing because they name a column or relationship that does not exist (the audit's `missing_rule_columns`; **Fix rule** opens the rule — the Rules tab, the rule's edit page and a person's effective access mark such a rule **⊘ Matches nothing** and say why), access ending this week, expired assignments to clean up (with a dry run), stale assignments to review ("Reviewed by … on …" or "Never reviewed", with who granted them), Permission Sets to tidy up, and a first card when the audit log is switched off or its table is missing. Person search and Field lookup. |
| **People** | Search everyone, filter (ending soon, expired, has a muting set, no access). "Ends in N days" (and Home's "Ending soon") means within 7 days; "due for review" uses `admin_stale_assignment_days` (90 when unset) — the same threshold on the People page, Home and `rake permission_forge:audit`. |
| **Person** | *Access*: assignments with end dates, Keep/Remove. *Effective access*: everything the person can do with all sets combined, and **why** (which set granted or muted each flag, field and action) — each set is named with what it did to the result (a Muting Permission Set that changed nothing is not listed); for a single-table-inheritance subclass the fields are composed with its base's entry, as the app enforces them, and the Why panel names the Resource that decided. The Effective access tab lists the record rules of the base Resources too (the engine applies every entry's rules; a View All on the subclass skips only its own). *Audit*: a timeline of events about the person and by the person, access received (with reason, review label and the real grantor), and a CSV of the records they created or last edited (the events are exported from the Audit log, filtered to the person). Actions: add a set, remove all access, withdraw consent, GDPR erasure (dry run first), refresh cached permissions. |
| **Permission Sets** | List with filters; create a granting or **muting** set (or start from a copy); one-page editor with a Resources matrix (Read/Create/Edit/Delete/Records), Assignments (bulk assign / revoke), activation Conditions (IP ranges, hours, session flag) and Audit (a change timeline of the set's events, and its CSV). Edits are batched and confirmed in **Review and save**, which lists every change and who it affects. |
| **Resource** | **Add a resource** starts from a preset (Full access / Read-only / Nothing; in a muting set Hide sensitive fields / Block all changes / Leave everything unchanged). Under `gdpr_defaults` columns that look like personal data start Masked when they are added Read-only (**Nothing** leaves them Hidden, with their recommended mask strategy on the row); **Full access** (and Sync's "Add all new with full access") masks nothing: they keep the **Sensitive** badge and appear in Home's Privacy audit, for you to mask or confirm. CRUD + record scope (View All / Modify All), **Sync fields with model**, Fields (4-level control: Hidden / Masked / Read-only / Editable, or Unchanged / Force mask / Hide in muting sets; bulk edit), Actions (custom actions; optionally your app's controller actions with their routes, guard status and current effect — see [The Actions tab](#the-actions-tab)), Rules. The Fields tab's bulk add and the field drawer write the same rows as the presets and Sync (one row builder): a sensitive column added Read-only starts Masked, Rails' timestamps added Editable are Read-only, and the review page shows the level the row gets. Sync and the Fields tab compare the model's columns with the database when they open, so a column a migration added while the server was running is offered without a restart (a removed one is flagged as missing). Column, model, association and action names are shown as your application translated them (`activerecord.attributes.<model>.<name>`, `activerecord.models.<model>` with `one`/`other`), else as the label stored on the row, else as the stored name itself in code (`full_address`) — never an English "Full address" made up from the name; [Your Models and Columns in the Admin](i18n.md#your-models-and-columns-in-the-admin) has the locale keys to add. |
| **Field drawer** | Access level, mask strategy with a live preview (the real `MaskValue`), privacy recommendation, linked variants, virtual fields, rules that use it, the field **across all Permission Sets** (a setting that does not count right now, because it, its resource or its Permission Set is switched off, is marked **○ Off**), and *Explain for a person*. For a single-table-inheritance subclass "In other sets" and "Explain for" include the base Resources the subclass answers to. |
| **Rule builder** | Record rules as sentences: field and relationship pickers from model reflection (never free text), 15 operators in plain words, "the current user", include-empty, blocked message, join type under Advanced, and a preview that is the sentence the saved rule will show (rendered by the server as you type; without JavaScript it changes when the form refreshes). A rule that matches nothing says why and what to change: the field, the relationship, the condition, the join type (under Advanced) or the value. The field list offers every column of the table along the path — `id` included, flagged "no field row (ignored_fields)" — except the columns that hold a secret (`config.rule_secret_column_patterns`), and never a virtual field. The relationship list only offers associations a rule's path can follow: one with a scope that takes the record, a broken `:through` or `inverse_of`, a polymorphic one, or one whose class cannot be loaded is left out (a rule through it could never match a record). |
| **Permission Set Groups** | Organise sets; members (shown clearly as *not* granting access); deep duplicate (the copy, its sets and their rows are editable). A locked group's membership is an organisational snapshot: members can be neither added nor removed (membership grants no access, so there is nothing to narrow). |
| **Audit log** | Every recorded event, newest first, with filters, an event page showing who, where, why and the before and after, CSV/JSON exports and a "Who holds what" export. See [The Audit log](#the-audit-log). |
| **Settings** | Read-only view of every configuration option with a health summary, current vs default, and a copy-paste "How to change" snippet. Secrets are only shown as set/not set; lambdas only as default/custom. |

Available in English, Albanian and Macedonian; light, dark and auto themes.

### Built to stay out of your app's way

- **Served by the engine itself.** CSS, JS, logo and favicons come from `PermissionForge::AssetsController` (fingerprinted, cached forever). No Sprockets, Propshaft, importmap or npm needed, and nothing is added to your pipeline.
- **Fully namespaced.** Every class is `pf-*`, every data attribute `data-pf-*`, cookies `pf_*`, helpers `pf_*`. The two preference cookies (`pf_theme`, `pf_help`) are HttpOnly, SameSite=Lax, scoped to the mount path, and Secure when the admin is served over HTTPS. The admin renders in its own layout, so your app's CSS never applies and its CSS never leaks out.
- **Works under a strict CSP.** No inline scripts, inline styles or inline event handlers. The stylesheet and script tags carry your CSP nonce when you use one. The engine sets no Content-Security-Policy of its own: your app's policy applies.
- **Works without JavaScript.** Every drawer and dialog is also a normal page; filters are links; forms post normally. The small script only adds dialogs, live search and change counters.
- **Accessible.** Keyboard reachable, visible focus, ARIA roles on tabs, switches, radio groups and dialogs, and every state uses a glyph plus a word, never colour alone.

---

## Mounting the Engine

Add this to your `config/routes.rb`:

```ruby fragment
# config/routes.rb
Rails.application.routes.draw do
  mount PermissionForge::Engine, at: "/permissions"

  # ... your other routes
end
```

Now visit `http://localhost:3000/permissions` to open the admin.

### Choosing a Mount Path

| Path | Good for |
|------|----------|
| `/permissions` | Simple, direct access |
| `/admin/permissions` | Nested under an existing admin namespace |
| `/pf` | Short and sweet |

---

## Authentication

**HTTP Basic Auth is enabled by default** (same pattern as [Mission Control Jobs](https://github.com/rails/mission_control-jobs)). If you mount the engine without configuring credentials, all requests return **401 Unauthorized** — the UI is locked until you set credentials.

### Setting Credentials

The generated initializer has them commented under "Admin screens", Option A: uncomment the two lines and set `PF_ADMIN_USER` and `PF_ADMIN_PASSWORD` in the environment. Or read them from Rails encrypted credentials:

```ruby fragment
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.http_basic_auth_user     = Rails.application.credentials.dig(:permission_forge, :username)
  config.http_basic_auth_password = Rails.application.credentials.dig(:permission_forge, :password)
end
```

Store credentials in Rails encrypted credentials:

```bash fragment
EDITOR=vim rails credentials:edit
```

```yaml
permission_forge:
  username: admin
  password: your-secure-password
```

### Disabling HTTP Basic Auth

If you want to handle authentication yourself (via Devise, Warden, or custom logic), disable HTTP Basic and set a custom base controller:

```ruby fragment
PermissionForge.configure do |config|
  config.http_basic_auth_enabled = false
  config.base_controller_class = "::AdminController"  # Your auth'd controller
end
```

Now all PermissionForge admin controllers inherit from `AdminController` instead of `ActionController::Base`, and its callbacks (Devise `before_action :authenticate_user!`, Rails 8's `require_authentication`, your admin check) run before every admin page. One thing does not carry over: the engine is isolated, so a route helper called inside it resolves against the engine's routes, not your app's. A path the engine does not have (`new_session_path`) raises `ActionController::UrlGenerationError` (a 500), and one it has (`root_path`) points into the admin. Call your app's routes through `main_app` (`main_app.new_session_path`).

**With multi-tenancy on**, the base controller must also set the current tenant (or middleware must). A request that reaches the admin with no current tenant is refused with a 403 (plain text), recorded as `admin.auth_failed` with reason `tenant_missing`, unless `config.admin_tenantless_access = :allow` — which serves it across every tenant. See [multi-tenancy.md](multi-tenancy.md).

### Rails 8 authentication generator

Rails 8's `bin/rails generate authentication` puts `before_action :require_authentication` in your `ApplicationController`, and for a signed-out visitor its `request_authentication` redirects to `new_session_path`. Inside the engine that path does not resolve, so a signed-out `GET /permissions` is a 500. Inherit from a base controller that overrides it, and check that the signed-in user is an admin:

```ruby file=app/controllers/admin/base_controller.rb
# app/controllers/admin/base_controller.rb
class Admin::BaseController < ApplicationController
  before_action :require_permissions_admin

  private

  # Inside the mounted engine, route helpers resolve against the engine's
  # routes: send signed-out visitors to the app's sign-in page via main_app.
  def request_authentication
    session[:return_to_after_authenticating] = request.url
    redirect_to main_app.new_session_path
  end

  # Signed in is not enough: the admin can grant anything to anyone. A
  # signed-in person who is no admin goes back to your app, whose pages
  # render in your layout (an empty `head :forbidden` here would leave a
  # Turbo sign-in on the sign-in form).
  def require_permissions_admin
    return if Current.user&.admin? # an admin flag of your own

    redirect_to main_app.root_path, alert: 'The permissions admin is for administrators.'
  end
end
```

Why a redirect and not a 403 page: the engine's screens resolve route helpers against the engine's routes, so your layout (`session_path`, `new_session_path`) cannot render there, and a 403 without your layout's tracked assets is what Turbo does not show after a sign-in (see [Handling Denials](row-level-rules.md#rescuing-them-yourself)). Your root page is in your app: someone who may not open it gets your app's own 403 page, in your layout, from the handler. Show the `alert` in your layout if you want the reason on screen.

```ruby fragment
# config/initializers/permission_forge.rb
config.http_basic_auth_enabled = false
config.base_controller_class   = '::Admin::BaseController'
```

`require_authentication` runs first (it is declared in `ApplicationController`) and resumes the session, so `Current.user`, and with it `PermissionForge.current_user`, is the signed-in admin in the admin screens and in the lambdas that receive the controller (`admin_assignment_authorization`, `audit_log_authorization`). After signing in, the generated `SessionsController` returns the admin to the page they asked for (`return_to_after_authenticating`).

### Using Devise Route Constraints

```ruby fragment
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do
  mount PermissionForge::Engine, at: "/permissions"
end
```

### Authentication Flow Summary

| `http_basic_auth_enabled` | Credentials set? | Result |
|---------------------------|-----------------|--------|
| `true` (default) | Yes | HTTP Basic Auth challenge |
| `true` (default) | No | **401 Unauthorized** (locked) |
| `false` | N/A | No auth from gem — use `base_controller_class` or route constraints |

### API-only applications

An application generated with `rails new --api` (`config.api_only = true`) has no cookies, session or flash middleware, and its `ApplicationController` is an `ActionController::API`. The JSON [admin API](admin-api.md) works there as it is. The admin screens do not: they are plain Rails pages with forms, so every page raises until the three middlewares are back — first `NameError: undefined local variable or method 'flash'` (the flash's request methods are loaded with its middleware), then `ActionDispatch::Request::Session::DisabledSessionError` for the CSRF token. The boot says so (`[PermissionForge] The application is API-only … the admin screens need ActionDispatch::Cookies, ActionDispatch::Session::CookieStore, ActionDispatch::Flash …`) whenever the engine is mounted in such an app. Add them in `config/application.rb`, in this order:

```ruby fragment
# config/application.rb, inside the Application class
config.api_only = true
config.middleware.use ActionDispatch::Cookies
config.middleware.use ActionDispatch::Session::CookieStore
config.middleware.use ActionDispatch::Flash
```

Option A (HTTP Basic auth) then works as in any app, and so does Option B with a base controller of your own that inherits from `ActionController::Base` (not from your `ActionController::API` application controller: the admin renders views). Your own controllers stay API controllers; nothing else changes for them. The test suite drives this host (`test/support/docs_app.rb api_only`): the API answers, the admin names the middlewares, and behind them an admin page and a POST answer as in a full application.

---

## How It Works

```
PermissionForge::Engine (mounted at e.g. /permissions)
├── HomeController               → GET  /                       (needs attention)
├── PeopleController             → /people, /people/:id (+ remove_all, consent, erasure, refresh_cache)
├── AssignmentsController        → /assignments (assign drawer, end dates, keep, remove, undo)
├── PermissionSetsController     → /permission_sets (+ review/apply, duplicate, switch_mode, conditions)
│   ├── BulkAssignmentsController        → …/bulk_assignment
│   └── ResourcesController              → …/resources/:model (+ review/apply, sync)
│       ├── ResourceFieldsController     → …/fields/:column
│       ├── ResourceActionsController    → …/actions
│       └── PermissionSetRulesController → …/rules
├── PermissionSetGroupsController → /groups (+ members)
├── FieldLookupsController       → /field_lookup
├── AuditEventsController        → /audit (+ /audit/:uuid, /audit.csv, /audit.json, /audit/holdings)
├── SettingsController           → /settings (read-only)
├── PreferencesController        → /preferences (theme, dismissed helpers)
└── AssetsController             → /pf-assets/:file (CSS, JS, brand)
```

All screen controllers inherit from `PermissionForge::ApplicationController`, which:
- inherits from `base_controller_class` (default `ActionController::Base`), so your own sign-in runs first;
- includes `PermissionForge::BasicAuthentication`;
- refuses a request with no current tenant while tenancy is on (`PermissionForge::TenantRequired`, see above);
- suspends query auto-scoping for the request (`PermissionForge.without_permission_scope`), because the admin manages permissions for everyone;
- renders the `permission_forge/application` layout, or a bare fragment when the script loads a page into a drawer.

`AssetsController` deliberately inherits from `ActionController::Base` only, so host `before_action`s never block the stylesheet or script.

The screens are thin: the logic lives in `PermissionForge::Admin::*` read models and services (`EffectiveAccess`, `ChangeSet`, `AttentionItems`, `SettingsCatalog`, `ModelCatalog`, `ControllerCatalog`, `RuleForm`, `FieldRows`, `ActionRows`, `AuditTrail`, `PeopleDirectory`, …). `EffectiveAccess` mirrors `PermissionHashBuilder` exactly and is parity-tested against it.

Home lists what needs attention — the audit log not recording, rules that match nothing, rules on secret columns, fields masked with an unknown strategy, activation conditions nobody can judge, personal data in the clear, rules the app's queries skip, assignments ending, expired or due for review, sets to tidy up (`Admin::AttentionItems::CARDS`) — the same rows `rake permission_forge:audit` reports. The Settings page's health summary says how many items Home lists, so it never calls the setup good while Home warns.

`Admin::FieldDetail` (the field drawer), `Admin::AuditEventDetail` (one audit event) and `Admin::RuleBuilder` (the rule builder) hold the logic of the three heaviest pages; the templates only draw them.

### Accessibility and markup

**Phone width.** The admin holds at 360px. A grid too wide for the screen (the Permission Set matrix, the set, assignment and audit tables, a person's effective access) scrolls sideways inside its own frame — a region the Tab key reaches, named for a screen reader, with a shadow at the edge that has more — and never the page. A placeholder is a short hint; the sentence is under the control. Every bundled locale is measured in a browser before a release (`test/browser/layout_probe.js`, the `browser` CI job) and the structure is checked in every test run (`test/permission_forge/html/layout_lint_test.rb`). A host theme that overrides `.pf-scroll-x` keeps `position: relative` on it: an absolutely positioned descendant otherwise escapes the frame and widens the page.

- Every page has one `h1`: a drawer or confirmation title is the page's `h1` when it stands alone (an `h2` inside the dialog), and the Permission Set and Group pages carry a screen-reader-only `h1` with the name. Section headings go through `pf_section_heading` (`h2` standalone, `h3` in a dialog), so levels never skip.
- Filter chips that are links mark the current one with `aria-current`; links in footers and hints are underlined, so a link is never told apart by colour alone; every state has a glyph and a word.
- Markup is built with `tag`, `content_tag`, `safe_join` and `pf_attrs_when` (`tag.attributes`), never marked safe by hand: a test fails on `html_safe`, `safe_concat`, `<%==`, `SafeBuffer`, `render inline:` or `raw` in `app/` and `lib/`.
- `pf_admin.js` uses `const` and `let`, and builds no markup from strings: a fragment fetched for a drawer is parsed with `DOMParser` (inert, no scripts run) and inserted with `replaceChildren`. It sits under the strict CSP the pages already need (no inline `style=`, script or `on*=` handler).
- `html/admin_accessibility_test.rb` lints every admin page and fragment in English and Macedonian (one `h1`, heading order, names, labelled tables, live toasts). It does not check contrast or computed roles: run axe-core in headless Chrome over the same pages for those.

### The reason field

Every form that changes permission data has an optional, collapsed **Add a reason** field (assign, bulk assign, revoke, remove all, Review and save, every delete confirmation, switch mode, Keep, "This is intended" and Extend on Home, the person's Keep and change-end-date forms, the change-end menu in a Permission Set's assignments grid, the rule builder and the rule switch, action and field forms, conditions, new Permission Set and Duplicate, group create, edit, add and remove Permission Set and members, adding and syncing a Resource, the consent and erasure confirmations and the maintenance clean-up). It works without JavaScript, keeps what you typed when the page is shown again, and is limited to 255 characters. The reason is stored on every audit event of that request and, for an assignment or a group membership, on the row (the row shows the reason of its **last** change that had one). The API reads a `reason` parameter on any change.

### The Audit log

`<mount path>/audit` (sidebar entry "Audit log") is the read side of the [audit log](audit-log.md): read-only, nothing on it changes data.

- **List and filters.** Newest first, 50 per page, no cap. Filter by dates, event, category, actor type, actor, person, Permission Set and correlation id; invalid input answers 422 with one message per field. Dates are days in the application's time zone, and the page names the zone. Views of the log (`audit.viewed`) are hidden unless you tick "Include views of the log" or filter by an event or category.
- **One event.** The sentence, time (local and UTC), actor (type, id, "all events by this actor"), source, reason, request id and IP, the record and Permission Set with links to their other events, the person, the correlation id ("all events of this action"), the before/after table of a change, the snapshot of a created or deleted row, and any other data.
- **Exports.** CSV and JSON of the current filter (all columns, metadata block, streamed, no cap), and "Who holds what" (every assignment with who granted it, expiry and last review). Each export is itself recorded. Layouts: [audit-log.md](audit-log.md#exports).
- **Timelines.** The Audit tab of a Permission Set and of a person show the same events, 20 per page, with links into the log. The person tab shows the latest 100 records per type and says when it hit that limit; the CSV lists all.
- **"Last edited by"** in a record's footer comes from the latest change event (with a "History" link into the log) while auditing records; with auditing off it falls back to `updated_by` and `updated_at`.
- **"Created by"** in a footer, "by …" in a Permission Set's Assignments tab, "Assigned by" on a person's pages and the Created column of the audit tabs name the actor of the record's creation event (`permission_set.created`, `assignment.granted`, ...), as the audit log does — an HTTP Basic login reads "admin (password prompt)", not "System"; without an event they fall back to `created_by`.
- **Who can see it.** `config.audit_log_authorization` (nil: anyone who can reach the admin). A refusal is a 403 page, banner or empty body, and is recorded as `admin.auth_failed`; the other tabs of the Person and Permission Set pages stay available. The audit tabs and their CSVs count as the log.
- **When it is not recording** (`audit_events = false`, or no table) the pages say so; without the table the lists are empty, with recording switched off they still show earlier events. The note has three texts: switched off, table missing (nothing is recorded) and `audit_events = true` with the table missing (every change fails). Home gets a card with the same three texts (with the upgrade commands when the table is missing), and Settings shows the risk for `true` without the table.

### Changes apply immediately

Assignments (assign, remove, end date, bulk) apply on submit and show a toast with **Undo**. Edits to a Permission Set or Resource are batched and applied on **Review and save**, inside one transaction.

Records flagged `is_editable: false` are locked everywhere (controls disabled, server refuses changes, recorded as `admin.lock_refused`), together with what they hold: a locked Permission Set takes no new resources, fields, rules or actions, and a change to its holders passes when it narrows access and is refused when it widens it. On a granting set **removing holders and setting or shortening end dates always work** (Remove, Remove all, bulk revoke, Undo of an assign), while adding holders and clearing or extending end dates are refused. A Muting Permission Set takes access away, so on a locked one it is the other way round: adding holders (Assign, bulk assign, Undo of a removal) and clearing or extending end dates work, while removing holders or ending them sooner is refused. **Remove all access** keeps a person's locked Muting Permission Sets and says so. Offboarding never needs an unlock. Undo is offered only where it is allowed. The admin answers HTML whatever the `Accept` header asks for; only the exports (a person's changes and a set's audit tab as CSV, the audit log as CSV/JSON, who-holds-what) answer another format. A locked group keeps its name, members and list of sets (no moves in or out, no deleting a set in it). **Duplicate** makes an editable copy (outside a locked group, as the message says).

"Locked" has one definition for the whole admin (`Admin::EditableLock`): a record is locked when it, its Resource, its Permission Set or (a membership) its group is flagged, and every control the admin shows is one the lock permits for that record — the Locked badge on a resource, field or rule of a locked set, no Remove or bulk revoke for the holders of a locked Muting Permission Set (removing them would give access back), no Delete for a set in a locked group, no adding or removing members of a locked group. Duplicate and the access review's Keep are always offered.

---

## The Actions tab

A Resource's **Actions** tab holds its custom actions: the app-specific verbs (`export`, `archive`, `merge`) that are not Read / Create / Edit / Delete. Each row is a `ResourceAction` that is *Permitted* or not (in a muting set: *Blocked* or *Unchanged*). Your code checks it with `user.can?(:export, :Customer)`, or the [controller action guard](controller-actions.md) checks it for you.

By default you add an action by typing its key (**+ Add action**). That form stays, for actions your own code checks.

### Listing your controller actions

```ruby fragment
PermissionForge.configure do |config|
  config.controller_action_discovery = true
end
```

With discovery on, the tab reads your app's routes and also lists every controller action that maps to the resource. It uses the same mapping as the guard (`permission_forge_actions` on the controller, then `controller_action_resolver`, then the controller-name convention), so the list is exactly what the guard checks.

Not listed: REST actions (`index`, `show`, `create`, …), which follow the Read / Create / Edit / Delete toggles at the top of the page; Rails' own controllers and the admin itself; anything in `controller_discovery_exclude`; routes inside other mounted engines.

Every row then shows:

| On the row | Meaning |
|------------|---------|
| Verb, path and `controller#action` | Each route that runs the action. |
| **✓ Guarded** / **⚠ Not guarded** | Whether that controller includes `PermissionForge::Concerns::ControllerActionGuard` and has not switched it off for every action with `skip_before_action`. Without the guard, the row is only enforced where your code calls `can?`. When no controller runs it at all, the tab says so above the list. |
| **Right now** | What the saved configuration means for people with this set (table below). |
| **– Not linked to a controller action** | A configured key no controller action maps to. That is normal for an action your code checks with `can?`; otherwise the key is misspelled or its route is gone. |

| Right now | Meaning |
|-----------|---------|
| ✓ Permitted | This set permits the action. |
| – Not permitted | This set has a row that does not permit it. People need another set that does. |
| ⊘ Blocked | This muting set blocks it, whatever other sets permit. |
| – Unchanged | This muting set has a row that does not block it. |
| ○ Not managed — everyone can run it | No Permission Set has a row for it, and `unconfigured_action_strategy` is `:allow`. |
| ⊘ Not managed — blocked until a set permits it | No Permission Set has a row for it, and `unconfigured_action_strategy` is `:block`. |
| – Managed by other sets — not permitted here | Another set has a row for it, so only people whose sets permit it can run it, and this set is not one of them. The row names the sets that permit it. |

A row only counts while the row, its resource and its Permission Set are switched on.

The number on the **Actions** tab counts the rows the tab shows: configured actions plus, with discovery on, the controller actions that have no row yet.

### Adding a discovered action

On a discovered row choose *Add and permit* or *Add, not permitted* (in a muting set: *Add and block*), or use **Add all discovered actions** under the list. Then **Review and save**: nothing is saved until you confirm, like every other batched edit. **Details** on the row opens a drawer with the routes and the action in every Permission Set.

**Adding the first row for an action makes it managed for everyone.** From then on only people whose Permission Sets permit it can run it. Everyone else is refused, including people who could run it while no set managed it. The tab says so above the list, and the review page says it for each action, with the sets that already permit it:

```
Customer: Archive added and permitted (this makes it managed: from now on only people whose Permission Sets permit it can run it)
Customer: Export added, not permitted (already managed; sets that permit it: Sales rep)
```

Only keys that discovery lists for that resource can be added this way. Any other key goes through **+ Add action**, which offers the discovered keys as suggestions. Locked sets and resources (`is_editable: false`) list the discovered actions without the controls to add them, and the server refuses the change.

---

## Customization

### Admin options

```ruby fragment
PermissionForge.configure do |config|
  # Which models "Add a resource" offers (default: every app model with a table)
  config.admin_model_resolver = -> { [Customer, Invoice, Deal] }

  # Friendly names for session flags on the Conditions tab
  config.admin_session_flags = { 'mfa_verified' => 'Signed in with two-factor' }

  # Permanent assignments not reviewed for this long appear as "Stale" (default 90)
  config.admin_stale_assignment_days = 90

  # "← Back to <app>" link under the logo: app name (default: derived from your
  # Rails application) and target (default: your app's root route, or "/")
  config.admin_app_name = 'Acme CRM'
  config.admin_back_url = ->(view) { view.main_app.dashboard_path }   # or a String

  # Where Settings → "Configuration docs" links point
  config.admin_docs_url = 'https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md'
end
```

### People in lists and pickers

```ruby fragment
PermissionForge.configure do |config|
  # Which people appear (default: user_model.order(:id)), capped by user_list_limit (500)
  config.user_list_resolver = -> { User.active.order(:last_name, :first_name) }

  # How a person is labelled (default: name, full_name, display_name, first+last, email or email_address)
  config.user_label_formatter = ->(u) { "#{u.first_name} #{u.last_name}" }
end
```

People are searched by `name`, `email`, `email_address` (Rails 8's authentication generator), `full_name`, `display_name`, `first_name`, `last_name`, `firstname`, `lastname`, `username` and `login`, whichever of those columns exist; a query of digits also matches the id.

The people list is also the boundary of who can be reached by id: a person `user_list_resolver` leaves out cannot be opened, assigned, added to a group or erased from these screens (404). A set's Assignments tab still lists every holder of the set. With multi-tenancy on and a users table that is not tenant-scoped, scope the resolver to the current tenant's users.

A resolver that returns an Array instead of a relation is searched in Ruby and loads every user it returns on each lookup: see [How people are labelled and searched](configuration.md#how-people-are-labelled-and-searched).

### Theming

Every colour, radius and font is a `--pf-*` custom property on `.pf-root` (light and dark sets). To re-theme, override the empty partial `permission_forge/shared/_head_extra` in your app and link a stylesheet:

```erb fragment
<%# app/views/permission_forge/shared/_head_extra.html.erb %>
<link rel="stylesheet" href="<%= asset_path('permission_forge_theme.css') %>">
```

```css
/* permission_forge_theme.css */
.pf-root { --pf-accent: #7c3aed; --pf-accent-hover: #6d28d9; --pf-font: "Inter", system-ui, sans-serif; }
.pf-root[data-theme="dark"] { --pf-accent: #a78bfa; }
```

Main tokens: `--pf-bg`, `--pf-surface`, `--pf-surface-2`, `--pf-border`, `--pf-text`, `--pf-text-2`, `--pf-text-3`, `--pf-accent*`, and the semantic sets `--pf-grant*` (allowed), `--pf-block*` (blocked/destructive), `--pf-mask*` (masked), `--pf-restrict*` (muting sets), `--pf-warn*` (attention), plus `--pf-radius*` and `--pf-font` / `--pf-mono`. The admin uses the system font stack and never loads web fonts from third parties.

### Overriding views

Copy any view to your app at the same path and Rails uses yours:

```bash fragment
mkdir -p app/views/permission_forge/home
cp $(bundle show permission_forge)/app/views/permission_forge/home/index.html.erb app/views/permission_forge/home/
```

### Database columns

The privacy audit's **This is intended** button stores `resource_fields.sensitive_acknowledged_at`. A field marked so is left out of every report of personal data in the clear: Home, `rake permission_forge:audit_masks`, the `personal_data` check of `rake permission_forge:audit` and the boot warning. New installs get it; existing installs add it with:

```bash fragment
bin/rails generate permission_forge:upgrade
bin/rails db:migrate
```

Until then the button is simply hidden.

---

## FAQ

### Can I use this without the admin UI?

Yes. The admin UI is optional: if you don't mount the engine, its pages are not reachable. Its controllers are still loaded at boot when your app eager-loads (production), so `base_controller_class` and `api_base_controller_class` must name classes that exist — a misspelled name stops the boot with a `NameError`. You can manage everything via:
- Rails console
- Seeds
- Your own custom admin controllers
- The PermissionForge API (models + services)

### Will this conflict with my app's CSS/JS?

No. The admin renders in its own layout, serves its own namespaced CSS/JS (`pf-*` classes, `data-pf-*` attributes, `pf_*` cookies scoped to the mount path), and doesn't touch your asset pipeline.

### "Another request saved the same thing a moment ago."

Two admins (or an admin and the API) created the same Resource, field, assignment or group membership at the same moment; the database kept the first. You are sent back to the page the form was on with that message, and nothing of yours was changed — the page shows what is there now. (Through 0.14.1 this was an error page.)

### I'm getting 401 Unauthorized — what's wrong?

HTTP Basic Auth is **enabled by default**. You need to either:
1. Set `http_basic_auth_user` and `http_basic_auth_password` in your initializer, OR
2. Disable it with `config.http_basic_auth_enabled = false` and use your own auth
