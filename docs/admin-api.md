# Admin JSON API

PermissionForge includes a built-in RESTful JSON API for managing permissions programmatically. This is ideal for CRM frontends, mobile apps, or any client that needs to manage permissions without the HTML admin UI.

The API runs alongside the HTML admin UI — you can use both, either, or neither.

## 1. Enable the API

Add these settings to your initializer:

```ruby
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.api_enabled = true
  config.api_record_identifier = :uuid  # or :id — field used for record lookups in URLs
end
```

Then mount the engine (if not already mounted):

```ruby
# config/routes.rb
mount PermissionForge::Engine, at: '/permissions'
```

Your API is now available at `/permissions/api/...`.

## 2. Authentication

The API supports three authentication strategies. Choose the one that fits your app.

#### Option A: Lambda Auth (recommended for most apps)

Pass a lambda that receives the controller instance and returns `true`/`false`:

```ruby
PermissionForge.configure do |config|
  config.api_enabled = true
  config.api_auth = lambda { |_controller|
    PermissionForge.current_user&.has_role?(:admin)
  }
end
```

`PermissionForge.current_user` (here and in the examples below) is what your `current_user_resolver` returns: `Current.user` with Rails 8's authentication generator, or whatever you wired it to with Devise. It names someone only when your app's sign-in runs in the request, that is behind an `api_base_controller_class` that authenticates (Option B). On the default `::ActionController::Base` nothing signs the caller in, so it is `nil` and the lambda refuses (401): check a header instead, as in the key and token examples below. Rails 8's generated `request_authentication` redirects to `new_session_path`, which inside the engine does not resolve: override it in that base controller as shown in [Admin UI](admin-ui.md#rails-8-authentication-generator), or answer 401 there for JSON.

The lambda has full access to the controller, so you can check headers, tokens, roles, etc. When it returns a falsy value, the request gets **401 Unauthorized** with `{"error":{"status":401,"messages":"Not authenticated"}}` (recorded as `api.auth_failed`, reason `api_auth_denied`), so a client that refreshes its token on 401 does so. The gem sends no `WWW-Authenticate` challenge of its own, since only your app knows the scheme: set one in the lambda before refusing, e.g. `controller.response.headers['WWW-Authenticate'] = 'Bearer realm="permissions"'`, and it is kept. 403 is reserved for an authenticated caller that the authorization lambdas below refuse. Through 0.14.1 a refusing `api_auth` answered 403.

`api_auth` only proves who the caller is. Changes and assignments also need `api_action_authorization` and `api_assignment_authorization` (see [Security Considerations](#security-considerations)): until both are set they are refused with 403, and the message names the option that is missing.

```ruby
# Example: API key authentication
config.api_auth = lambda { |controller|
  api_key = controller.request.headers['X-API-Key']
  api_key.present? && ApiKey.active.exists?(key: api_key)
}

# Example: JWT token check
config.api_auth = lambda { |controller|
  token = controller.request.headers['Authorization']&.remove('Bearer ')
  token.present? && JwtService.valid?(token)
}
```

#### Option B: Base Controller Inheritance (recommended for apps with existing auth)

If your app already has an admin base controller with authentication built in (e.g., Devise + role checking), inherit from it:

```ruby
PermissionForge.configure do |config|
  config.api_enabled = true
  config.api_base_controller_class = '::Api::V1::Admin::BaseController'
  config.api_auth = ->(_controller) { true }  # Auth handled by base controller
end
```

Your `Api::V1::Admin::BaseController` handles authentication and authorization — PermissionForge's API controllers inherit from it directly. With multi-tenancy on, it must also set the current tenant (see [Tenancy](#tenancy)).

#### Option C: No Auth Configured (locked by default)

If `api_auth` is `nil` (the default), **all API requests return 401 Unauthorized** (no body). This is the safe default — the API is locked until you explicitly configure authentication.

```ruby
# This is the default — API routes exist but return 401
config.api_enabled = true
# config.api_auth = nil  # <- default, all requests get 401
```

#### Disabling the API entirely

When `api_enabled = false` (the default), all API routes return **404 Not Found** with no body. The routes are defined but guarded at runtime — no route leakage.

#### Who the audit log names for an API change

Every change made through the API is an [audit event](audit-log.md#who-did-it-actor-resolution). Its actor is the first of: `config.audit_actor_resolver` (called with the controller), the current user (`config.current_user_resolver`), else an anonymous `api` actor labelled **"API client"**. `api_auth` answers only yes or no, so it cannot name anyone by itself.

On the default `api_base_controller_class` (`::ActionController::Base`) your application's sign-in does not run in the API: the `Current.user` that the generated `current_user_resolver` reads is never set there, so even a request from a browser signed in to your app is recorded as "API client". Name the caller one of two ways:

- **Inherit your sign-in (Option B).** Set `api_base_controller_class` to an application controller that resumes the session (Rails 8's `Authentication` concern, Devise's `authenticate_user!`). `current_user_resolver` then names the signed-in user, for the audit log and for your authorization lambdas.
- **Resolve the actor from the credential `api_auth` verified.** For a token or key client, map that credential to who it belongs to:

  ```ruby
  config.audit_actor_resolver = ->(controller) {
    key = ApiKey.active.find_by(key: controller.request.headers['X-API-Key'])
    key && { type: 'api', id: key.id, label: key.name }  # or key.user, to name a person
  }
  ```

  Derive the actor from the same verified credential, never from a value the caller picks (an `X-User-Id` header, a `user_id` parameter): the gem itself never takes the actor from parameters or headers, and your resolver should not either. A resolver that answers `nil` falls back to the current user, then to "API client".

Changes made from a console, a runner or a job are not API requests: wrap them in `PermissionForge.with_audit_actor(user: admin) { … }` ([audit log](audit-log.md#who-did-it-actor-resolution)).

## Response Format

JSON responses use the envelope below. Some answers have no body: the 401 while `api_auth` is not set, the 404 while the API is disabled and the 204 of a delete.

**Success (single record):**
```json
{
  "data": {
    "id": 1,
    "uuid": "abc-123",
    "name": "Sales Team",
    "is_active": true,
    "created_at": "2026-03-10T12:00:00Z"
  }
}
```

**Success (collection):** every list endpoint is paginated and answers `meta.pagination` with its page:
```json
{
  "data": [
    { "id": 1, "uuid": "abc-123", "name": "Sales Team" },
    { "id": 2, "uuid": "def-456", "name": "Support Team" }
  ],
  "meta": {
    "pagination": {
      "page": 1,
      "per_page": 15,
      "total_count": 42
    }
  }
}
```

**Error (validation):**
```json
{
  "error": {
    "status": 422,
    "messages": {
      "name": ["can't be blank"]
    }
  }
}
```

**Error (not found):**
```json
{
  "error": {
    "status": 404,
    "messages": "Record not found"
  }
}
```

**Every 422 has this shape.** `messages` is always an object mapping a field to a list of messages: the model's attribute for a failed validation, the request parameter for input the API cannot read, and `base` when the error names no field:

```json
{ "error": { "status": 422, "messages": { "expires_at": ["is not an ISO 8601 date or time"] } } }
{ "error": { "status": 422, "messages": { "permission_set": ["is missing, empty or not an object"] } } }
{ "error": { "status": 422, "messages": { "bulk_action": ["must be assign or revoke"] } } }
{ "error": { "status": 422, "messages": { "user_ids": ["must name at least one user"] } } }
{ "error": { "status": 422, "messages": { "grant_all": ["must be true or false"] } } }
{ "error": { "status": 422, "messages": { "base": ["Could not generate fields for this resource"] } } }
```

The messages follow the request's locale. Through 0.14.1 an input error answered `messages` as one string (`"expires_at is not an ISO 8601 date or time"`, `"param is missing or the value is empty or invalid: permission_set"`). Other statuses (400, 401, 403, 404) keep a string.

**A body that cannot be parsed is a 400.** A request sent as `application/json` whose body is not valid JSON (`{"permission_set": {"name": "x"`) answers, in the envelope:

```json
{ "error": { "status": 400, "messages": "The request body could not be read. Send valid JSON with Content-Type application/json." } }
```

Nothing is changed. Rails parses the body before `api_auth` runs, so this 400 can come before a 401; while the API is disabled it stays a 404 without a body. The message follows the `Accept-Language` header (a `locale` parameter in the unreadable body cannot be read). Through 0.14.1 Rails answered its own `{"status":400,"error":"Bad Request"}`.

**What answers 422.** A failed validation (`messages` is the model's errors, as above), and input the API cannot read:

- a body section that is not an object (`"permission_set": "x"`), or one that is missing or empty (see below);
- an `expires_at` that is not one of the [ISO 8601 forms below](#expires_at-formats) (`"tuesday"`, `"2026-13-45"`, `"22/10/2026"`, a number);
- a `grant_all` that is not `true`, `false`, `1`, `0` or one of their strings (`"yes"`, `""`, `2`): see [generate_fields](#resources-nested-under-permission-set);
- a bulk assignment without `user_ids` (missing, `[]`, `""` or only blanks): see [Bulk User Assignment](#bulk-user-assignment);
- a blank name for a Permission Set, Permission Set Group, field or action, when it is created or renamed (a row whose name is already blank stays editable in its other attributes);
- a `permission_set_group_id` that names no group of the current tenant;
- a rule whose `field_name` is not a column of its model (`{"field_name": ["is not a column of Customer"]}`): see [Using the wrong field name](row-level-rules.md#using-the-wrong-field-name);
- a string longer than its column: `is too long (at most N characters)`. Only columns that declare a limit are checked — a `string` on MySQL is `varchar(255)` (counted in characters) and a `text` holds 65,535 bytes; on PostgreSQL and SQLite the install's `string` and `text` columns declare none, so nothing is checked there. A Permission Set name keeps its own 255-character rule on every database.

**A flat JSON body is accepted where Rails wraps parameters.** With JSON parameter wrapping on, which `config.load_defaults 7.0` and later turn on for every controller (`wrap_parameters_by_default`), Rails copies the keys of a JSON body that are attributes of the endpoint's model under the section name before the API reads it: `POST /api/permission_sets` with `{"name":"Flat payload"}` reads as `{"permission_set":{"name":"Flat payload"}}` and creates the set (201). Only a body sent as `application/json` is wrapped, never one that already has the section. A flat body with none of the model's attributes then gives an empty section, and without wrapping (older defaults, a form-encoded body, `wrap_parameters false` in your `api_base_controller_class`) a missing section stays missing: both answer 422 `{"permission_set": ["is missing, empty or not an object"]}`. Send the section explicitly to be independent of this setting.

NUL bytes are dropped from every attribute hash and name the API reads. A rule with `is_null` / `is_not_null` needs no `field_value` (it is stored as empty).

## Endpoints Reference

All URLs below assume the engine is mounted at `/permissions`. Replace with your mount path.

#### Dashboard Stats

The stats endpoint is closed to everyone `api_auth` admits until you say who may read it:

```ruby
config.api_stats_require_admin = true  # default
# Who may read GET /api/stats (called with the controller; truthy allows)
config.api_stats_authorization = ->(controller) { PermissionForge.current_user&.admin? }
# or, for a key-authenticated client:
config.api_stats_authorization = ->(controller) {
  ApiKey.active.exists?(key: controller.request.headers['X-API-Key'], scope: 'permissions:read')
}
```

While `api_stats_authorization` is not set the endpoint answers 403 with `"GET /api/stats needs config.api_stats_authorization, or config.api_stats_require_admin = false"`; a lambda that refuses answers 403 `"Forbidden"`. Both are recorded as `api.auth_failed` (reason `stats_not_authorized`, `hook` naming the option). `api_stats_require_admin = false` opens the stats to every caller `api_auth` admits.

Through 0.14.1 the only way in was an `api_auth` that set `@admin = true` on the controller (`controller.instance_variable_set(:@admin, true)`). That still works while `api_stats_authorization` is not set, with a deprecation warning, and is removed in 0.16.

```bash
# Get overview counts
GET /permissions/api/stats

curl http://localhost:3000/permissions/api/stats

# Response: 200 OK
{
  "data": {
    "permission_sets_count": 5,
    "active_sets_count": 3,
    "resources_count": 12,
    "rules_count": 8,
    "groups_count": 2,
    "users_count": 15
  }
}
```

#### Permission Sets

```bash
# List all permission sets
GET /permissions/api/permission_sets

curl http://localhost:3000/permissions/api/permission_sets

# Get a single permission set
GET /permissions/api/permission_sets/:uuid

curl http://localhost:3000/permissions/api/permission_sets/abc-123

# Create a permission set
POST /permissions/api/permission_sets

curl -X POST http://localhost:3000/permissions/api/permission_sets \
  -H "Content-Type: application/json" \
  -d '{
    "permission_set": {
      "name": "Sales Team",
      "description": "Permissions for sales users",
      "is_active": true
    }
  }'
# Response: 201 Created

# Update a permission set
PATCH /permissions/api/permission_sets/:uuid

curl -X PATCH http://localhost:3000/permissions/api/permission_sets/abc-123 \
  -H "Content-Type: application/json" \
  -d '{
    "permission_set": {
      "name": "Sales Team (Updated)",
      "is_active": false
    }
  }'
# Response: 200 OK
# Move the set into a group with "permission_set_group_id": the group's uuid (as
# the API returns it) or its numeric id; null or "" takes it out of its group.
# Under api_record_identifier = :id only the numeric id is read. A value that names
# no group of the current tenant is a 422 {"permission_set_group_id": [...]}.

# Delete a permission set
DELETE /permissions/api/permission_sets/:uuid

curl -X DELETE http://localhost:3000/permissions/api/permission_sets/abc-123
# Response: 204 No Content

# Clone a permission set (deep clone: resources, fields, actions, rules)
POST /permissions/api/permission_sets/:uuid/clone

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/clone \
  -H "Content-Type: application/json" \
  -d '{ "name": "Sales Team (copy)" }'
# Response: 201 Created — returns the cloned permission set
# The copy and its rows are editable, like the admin's Duplicate. A copy of a
# set in a locked group is created outside the group (permission_set_group_id: null).
# Without "name" (or with one that is not text), the copy is named as the
# admin's Duplicate names it: "<name> (copy)" in the request's locale,
# numbered when taken ("<name> (copy) 2"). Through 0.14.1: "<name> (Copy)".
```

#### Resources (nested under permission set)

```bash
# List resources for a permission set
GET /permissions/api/permission_sets/:ps_uuid/resources

curl http://localhost:3000/permissions/api/permission_sets/abc-123/resources

# Get a single resource
GET /permissions/api/permission_sets/:ps_uuid/resources/:uuid

# Create a resource
POST /permissions/api/permission_sets/:ps_uuid/resources

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/resources \
  -H "Content-Type: application/json" \
  -d '{
    "resource": {
      "name": "Customer",
      "read_access": true,
      "create_access": true,
      "edit_access": true,
      "delete_access": false,
      "view_all": false,
      "modify_all": false
    }
  }'
# Response: 201 Created
# "name" must have the shape of a Ruby constant path (e.g. "Customer" or "Admin::Report") —
# other names return 422. Only the format is checked: a name that names no model
# is accepted. Duplicate names within a permission set also return 422.

# Update a resource
PATCH /permissions/api/permission_sets/:ps_uuid/resources/:uuid

curl -X PATCH http://localhost:3000/permissions/api/permission_sets/abc-123/resources/def-456 \
  -H "Content-Type: application/json" \
  -d '{ "resource": { "delete_access": true } }'

# Delete a resource
DELETE /permissions/api/permission_sets/:ps_uuid/resources/:uuid

# Auto-generate fields from model columns
POST /permissions/api/permission_sets/:ps_uuid/resources/:uuid/generate_fields

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/resources/def-456/generate_fields \
  -H "Content-Type: application/json" \
  -d '{ "grant_all": true }'
# Response: 201 Created — returns array of generated fields
# grant_all: true, "true", 1 or "1" grants; false, "false", 0, "0", null or no
# grant_all does not. Anything else ("yes", "", 2) is a 422
# {"grant_all": ["must be true or false"]} and creates nothing. Through 0.14.1
# only "true" and "1" granted: a JSON true created fields without edit.
# With grant_all every field is readable and editable, unmasked — also the
# personal-data columns under gdpr_defaults (their recommended mask_strategy
# is returned, mask_access is false). Without it, under gdpr_defaults, those
# columns come back readable and masked and the others without access.
# A mutation like any other: gated by api_action_authorization (action
# :generate_fields) and refused with 403 when the resource or its permission
# set is locked
# On failure: 422 with a generic message — the underlying exception is logged
# server-side, never returned to the client
```

#### Resource Fields (nested under resource)

```bash
# List fields for a resource
GET /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/fields

# Get a single field
GET /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/fields/:uuid

# Create a field (with masking)
POST /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/fields

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/resources/def-456/fields \
  -H "Content-Type: application/json" \
  -d '{
    "resource_field": {
      "name": "email",
      "label": "Email Address",
      "read_access": true,
      "edit_access": false,
      "mask_access": true,
      "mask_strategy": "email"
    }
  }'
# Response: 201 Created
# "label" is what the admin shows; a missing or blank label defaults to the
# humanized name ("email_address" → "Email address")
# mask_strategy options: "full", "email", "last4", "first1_last4",
#                        plus any keys from config.custom_mask_strategies
# Duplicate field names within a resource return 422

# Update a field
PATCH /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/fields/:uuid

# Delete a field
DELETE /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/fields/:uuid
```

#### Resource Actions (nested under resource)

Custom actions beyond CRUD (e.g., sync, export, approve):

```bash
# List actions for a resource
GET /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/actions

# Create a custom action
POST /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/actions

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/resources/def-456/actions \
  -H "Content-Type: application/json" \
  -d '{
    "resource_action": {
      "name": "export",
      "label": "Export to CSV",
      "is_permitted": true
    }
  }'

# Update an action
PATCH /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/actions/:uuid

# Delete an action
DELETE /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/actions/:uuid
```

**Action names.** `name` is the key your code and the [controller action guard](controller-actions.md) look the action up by, so it must be a valid action key: lowercase letters, digits and `_`, starting with a letter, at most 63 characters (`export`, `export_csv`). The name is not normalized for you. Creating an action under any other name (`Export`, `archive ` with a trailing space, `export-csv`), or renaming one to it, returns 422:

```json
{ "error": { "status": 422, "messages": { "name": ["Use lowercase letters, numbers and underscores, starting with a letter (for example export)."] } } }
```

A row that already carries such a name (created before this rule) can still be read, updated without renaming it, cloned and deleted. `rake permission_forge:audit` lists those rows as `invalid_action_keys`.

#### Permission Set Rules (nested under resource)

Row-level query rules:

```bash
# List rules for a resource
GET /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/rules

# Create a rule
POST /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/rules

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/resources/def-456/rules \
  -H "Content-Type: application/json" \
  -d '{
    "permission_set_rule": {
      "name": "Own records only",
      "field_name": "owner_id",
      "field_value": "current_user",
      "operator": "equal",
      "include_nulls": false,
      "failure_message": "You can only view your own records"
    }
  }'
# Operator options: "equal", "not_equal", "less_than", "greater_than",
#                   "less_than_or_equal", "greater_than_or_equal", "in", "not_in",
#                   "contains", "not_contains", "starts_with", "ends_with",
#                   "between", "is_null", "is_not_null"
# "is_null" / "is_not_null" take no field_value (it is stored as empty)
# include_nulls defaults to TRUE (the column default): a rule created without
# it also lets through the rows whose field is NULL, for "equal", "not_equal",
# "in" and "not_in". Send "include_nulls": false to keep them out.

# Update a rule
PATCH /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/rules/:uuid

# Delete a rule
DELETE /permissions/api/permission_sets/:ps_uuid/resources/:r_uuid/rules/:uuid
```

**Rule attributes** (`permission_set_rule`): `name`, `field_name`, `field_value`, `operator`, `join_type`, `field_accessor_path`, `include_nulls` (default **`true`**: NULL rows pass an `equal`, `not_equal`, `in` or `not_in` rule unless you send `false`; see [The `include_nulls` Flag](row-level-rules.md#the-include_nulls-flag)), `is_active`, `is_editable`, `failure_message`.

A `field_value` is compared in the type of the column the rule names; a value that column cannot hold (`"5_id"` on an integer column) is accepted and makes the rule match nothing. See [How Values Are Compared](row-level-rules.md#how-values-are-compared).

Rule `field_value`s can contain sensitive data (user IDs, account numbers, business logic values). Set `config.api_redact_rule_field_values = true` (default: `false`) to have API responses replace `field_value` with `"[REDACTED]"` — useful for GDPR/HIPAA environments.

#### Permission Set Users (assign users to sets)

```bash
# List users in a permission set
GET /permissions/api/permission_sets/:ps_uuid/users

# Assign a user to a permission set
POST /permissions/api/permission_sets/:ps_uuid/users

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/users \
  -H "Content-Type: application/json" \
  -d '{ "user_id": 42, "expires_at": "2026-12-31T23:59:00Z" }'
# Response: 201 Created — expires_at is optional (time-bound assignment)
# Assigning a user who is already in the set returns 422 (uniqueness validation)
# A user_id outside config.user_list_resolver returns 404, as an unknown one does
# An expires_at that is not ISO 8601 (see below), or not after now, returns 422 and assigns nobody

# Remove a user from a permission set (:uuid is the assignment's identifier)
DELETE /permissions/api/permission_sets/:ps_uuid/users/:uuid
```

##### `expires_at` formats

`expires_at` (on `POST …/users` and `POST …/users/bulk`) is read as ISO 8601, and only in these forms:

| Form | Example | Means |
|------|---------|-------|
| a date | `2026-10-22` | the **end** of that day (23:59:59.999999) in the application's `Time.zone`: the assignment grants through that whole day, as an end date picked in the admin does. Through 0.14.1 a date meant the beginning of the day |
| a date and a time of day | `2026-10-22T10:00`, `2026-10-22T10:00:00`, `2026-10-22T10:00:00.5` | that moment in `Time.zone` |
| the same with an offset | `2026-10-22T10:00:00Z`, `2026-10-22T10:00+02:00` | that moment at that offset (`Z` = UTC) |

Hours and minutes are required once there is a time; seconds and a fraction (up to 9 digits; the database keeps what its column holds, microseconds on most) are optional. The date and the time are separated by `T` or by one space (`2026-10-22 10:00`). An offset is `Z` or `±HH:MM`, written right after the time. Every field must exist on the calendar and on the clock: `2026-02-30`, `24:00` and a leap second (`:60`) are refused. Surrounding white space is ignored; a missing, `null` or empty `expires_at` means the assignment does not end.

Anything else is a 422 and nothing is assigned: `"tuesday"`, `"next tuesday-ish"`, `"2026-13-45"`, `"22/10/2026"`, `"2026-10-22T10"` (no minutes), `"2026-10-22 10:00 +0200"` (an offset needs its colon and no space), week or ordinal dates (`2026-W43-4`), the basic format without separators (`20261022`) and numbers (epoch seconds). Through 0.14.1 any text with a recognisable fragment was read (`"tuesday"` became today 00:00, an assignment that had already ended).

**The end must be after now.** An assignment whose end has passed grants nothing, so a readable `expires_at` that is not after the moment of the request (`"2020-01-01"`, yesterday's date, a time a minute ago) is refused too: `422 {"expires_at": ["must be in the future"]}`, on `POST …/users` and on a bulk `assign`, and nobody is assigned. Today's date is accepted (it means the end of today). A bulk `revoke` ignores `expires_at`. Through 0.14.1 such an assignment was created (201). The admin's Undo after a removal is not a new grant: it restores the assignment with the end it had, also one that has passed.

`GET …/users` lists every holder of the set (each row carries its `user_id`), including people outside `user_list_resolver`: the resolver bounds who can be reached by id, not who is listed.

#### Bulk User Assignment

```bash
# Bulk assign users to a permission set
POST /permissions/api/permission_sets/:ps_uuid/users/bulk

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/users/bulk \
  -H "Content-Type: application/json" \
  -d '{
    "user_ids": [1, 2, 3, 4, 5],
    "bulk_action": "assign",
    "expires_at": "2026-12-31T23:59:00Z"
  }'
# Response: 200 OK — expires_at is optional (time-bound assignments; same formats
# as above, an unreadable one is a 422 and changes nothing)
# { "data": { "assigned": 3, "revoked": 0, "invalidated": 3, "skipped": [99] } }
# Ids outside config.user_list_resolver (or naming nobody) are skipped and listed
# in "skipped" (cast to the user key type, else as sent; [] when none), on assign
# and revoke alike: someone outside the resolver and an unknown id read the same.
# "invalidated" counts the users whose assignment changed and whose cached
# permissions were cleared; a user who already held the set is not counted.
# A request that names nobody (no user_ids, [], "" or only blanks) is a 422
# {"user_ids": ["must name at least one user"]} on assign and revoke, and
# changes nothing (through 0.14.1: 200 with nothing done). Like the other
# 422s it records no audit event.

# Bulk revoke users from a permission set
POST /permissions/api/permission_sets/:ps_uuid/users/bulk

curl -X POST http://localhost:3000/permissions/api/permission_sets/abc-123/users/bulk \
  -H "Content-Type: application/json" \
  -d '{
    "user_ids": [1, 2, 3],
    "bulk_action": "revoke"
  }'
# Response: 200 OK
# A revoke ignores expires_at, also one that is not ISO 8601: it removes the
# assignments whatever their end.
```

#### Permission Set Groups

```bash
# List all groups
GET /permissions/api/permission_set_groups

# Create a group
POST /permissions/api/permission_set_groups

curl -X POST http://localhost:3000/permissions/api/permission_set_groups \
  -H "Content-Type: application/json" \
  -d '{
    "permission_set_group": {
      "name": "Admin Groups",
      "description": "Groups for admin users"
    }
  }'

# Get / Update / Delete a group
GET    /permissions/api/permission_set_groups/:uuid
PATCH  /permissions/api/permission_set_groups/:uuid
DELETE /permissions/api/permission_set_groups/:uuid

# Clone a group (deep clone: permission sets, resources, fields, actions, rules)
POST /permissions/api/permission_set_groups/:uuid/clone

curl -X POST http://localhost:3000/permissions/api/permission_set_groups/abc-123/clone \
  -H "Content-Type: application/json" \
  -d '{ "name": "Admin Groups (copy)" }'
# Response: 201 Created — returns the cloned group
# The copied group, its sets and their rows are editable. Without "name", the
# group is named "<name> (copy)" in the request's locale, as the admin's
# Duplicate names it (through 0.14.1: "<name> (Copy)").
```

#### Permission Set Group Users (group membership — grants nothing)

**Membership is organisational: it grants no access.** Adding someone to a group does not give them the group's Permission Sets; permissions come only from assignments (`POST …/permission_sets/:uuid/users`, above). A 201 here means "now listed as a member", not "can now do what the group's sets allow". To give someone a group's access, assign each of its sets. See [Permission Set Groups](permission-set-groups.md).

```bash
# List the members of a group
GET /permissions/api/permission_set_groups/:group_uuid/users

# Add a member (organisational only: assigns none of the group's sets)
POST /permissions/api/permission_set_groups/:group_uuid/users
# Body: { "user_id": 42 }
# A user_id outside config.user_list_resolver returns 404

# Remove a user from a group
DELETE /permissions/api/permission_set_groups/:group_uuid/users/:uuid
```

#### Audit Events (read-only)

The [audit log](audit-log.md) over the API. `GET` only: no route writes, updates or deletes an event. It needs `api_enabled`, passes `api_auth`, and then `config.audit_log_authorization`: when it is set, only an exact `true` allows (anything else, or an error, is **403** and an `api.auth_failed` event with reason `audit_log_not_authorized`); when it is not set (the default), anyone who passes `api_auth` can read the whole log. Each call that returns 2xx is recorded as `audit.viewed` (`scope: api`).

```bash
# A page of events, newest first
GET /permissions/api/audit_events?event=assignment.revoked&from=2026-07-01&to=2026-09-30&page=1&per_page=100

# One event, by uuid (or by id when api_record_identifier is :id)
GET /permissions/api/audit_events/:identifier
```

```json
{
  "data": [
    {
      "id": 481, "uuid": "5c1e...", "occurred_at": "2026-09-14T08:12:44.120391Z",
      "event": "assignment.revoked", "category": "change",
      "actor_type": "user", "actor_id": "7", "actor_label": "Ada Admin", "source": "admin_ui",
      "record_type": "PermissionForge::PermissionSetUser", "record_id": "93", "record_uuid": "a77f...", "record_label": "Bo Brandt",
      "permission_set_id": 12, "permission_set_uuid": "d2b4...", "subject_user_id": "31",
      "data": { "snapshot": { "user_id": 31, "expires_at": null } },
      "reason": "left the team", "request_id": "6f1b...", "ip": "203.0.113.9", "correlation_id": "0b8c...",
      "created_at": "2026-09-14T08:12:44.121002Z"
    }
  ],
  "meta": { "pagination": { "page": 1, "per_page": 100, "total_count": 1 } }
}
```

Every column is returned except the tenant column; `data` is an object. Filters (all optional):

| Parameter | Meaning |
|---|---|
| `from`, `to` | ISO 8601 timestamp or `YYYY-MM-DD`; without an offset UTC; a bare `to` date is the end of that day, inclusive. Impossible dates and years outside 0001-9999 answer 422. |
| `event` | A name, an array, or a comma list; each must be in the event catalogue. |
| `category`, `actor_type` | A known value. |
| `actor_id`, `subject_user_id`, `correlation_id` | Exact match. |
| `record_type` with `record_id` or `record_uuid` | `record_id` matches the `record_id` column only and `record_uuid` the `record_uuid` column only; either needs `record_type`, otherwise 422; `record_type` alone is also a filter. |
| `permission_set` | A uuid, or a numeric id. |

An invalid value answers `422 {"error":{"status":422,"messages":{"from":["is invalid"]}}}`; an array or hash for a scalar filter parameter, or a NUL byte in a value, is a 422 too (`page` and `per_page` are not filter parameters: an array or hash there reads as 1, the first page or a page size of 1). Unknown parameters are ignored. Order is `occurred_at desc, id desc`; page size follows `api_default_per_page` / `api_max_per_page`. **A `page` beyond 2,147,483,647 is clamped** (on every paginated endpoint) instead of failing in the database. With tenancy on, a request with no tenant set is refused (403, see [Tenancy](#tenancy)); under `admin_tenantless_access = :allow` it lists the events of every tenant, as the other endpoints do for their records.

Writes through the API record their own events: the API sets the actor (`audit_actor_resolver`, else the current user, else an anonymous `api` actor), source `api`, the request id and IP, and reads an optional `reason` (a request parameter or JSON key, at most 255 characters) from any request that changes something.

## Serializer Overrides (AMS Support)

The API ships with lightweight built-in serializers (no dependencies). If your app uses ActiveModel::Serializer (AMS), you can override any serializer:

```ruby
PermissionForge.configure do |config|
  config.api_serializer_overrides = {
    permission_set: MyApp::PermissionSetSerializer,
    resource: MyApp::ResourceSerializer,
    resource_field: MyApp::ResourceFieldSerializer
  }
end
```

The base controller auto-detects AMS serializers and renders them with `render json: record, serializer: ..., root: :data` (collections also pass `meta:` with the pagination). Built-in serializers use plain Ruby `as_json`.

AMS 0.10's default adapter (`:attributes`) ignores `root:` and `meta:`: the response is the bare serialized record or array, without the `data` envelope or the pagination metadata. Set `ActiveModelSerializers.config.adapter = :json` to keep the envelope.

**Available override keys:** `permission_set`, `resource`, `resource_field`, `resource_action`, `permission_set_rule`, `permission_set_user`, `permission_set_group`, `permission_set_group_user`, `audit_event`

## Pagination

All collection endpoints are paginated by default with a built-in LIMIT/OFFSET paginator. The `per_page` parameter is hard-capped at `api_max_per_page` (default: 100) to prevent DoS via large result sets.

```ruby
PermissionForge.configure do |config|
  config.api_max_per_page = 100     # Hard cap — clients cannot exceed this
  config.api_default_per_page = 15  # Default when per_page param is omitted
end
```

To use a custom pagination handler (e.g., Kaminari, will_paginate):

```ruby
# With Kaminari
config.api_pagination_handler = ->(scope, page, per_page) { scope.page(page).per(per_page) }

# With will_paginate
config.api_pagination_handler = ->(scope, page, per_page) { scope.paginate(page: page, per_page: per_page) }
```

The pagination metadata reads `total_count` from what the handler returns (Kaminari answers it). will_paginate's collections answer `total_entries` instead, which is not read: `total_count` then falls back to the size of the page. Return an object that answers `total_count`, for example:

```ruby
config.api_pagination_handler = lambda { |scope, page, per_page|
  records = scope.paginate(page: page, per_page: per_page)
  records.define_singleton_method(:total_count) { records.total_entries }
  records
}
```

**Note:** Even with a custom handler, `per_page` is clamped to `[1, api_max_per_page]` before being passed to the handler. A request with `per_page=999999` will be silently clamped.

Pass `page` and `per_page` query params:

```bash
curl "http://localhost:3000/permissions/api/permission_sets?page=2&per_page=10"
```

The response always includes pagination metadata:

```json
{
  "data": [...],
  "meta": {
    "pagination": {
      "page": 2,
      "per_page": 10,
      "total_count": 42
    }
  }
}
```

## Security Considerations

### Base Controller Class

`api_base_controller_class` defaults to `ActionController::Base`. This means API controllers do **NOT** inherit your app's authentication chain (Devise, Warden, etc.) by default. You should override this to inherit your auth stack:

```ruby
config.api_base_controller_class = '::Api::BaseController'
```

### Action Authorization (Mutation Protection)

`api_action_authorization` decides which creates, updates, destroys, clones and field generations a caller may make. Until it is set, every one of them is refused with 403 (`api_require_authorization`, below):

```ruby
config.api_action_authorization = ->(controller, action, record) {
  PermissionForge.current_user&.admin?
}
```

The lambda receives the controller instance, action name (`:create`, `:update`, `:destroy`, `:clone`, or `:generate_fields`), and the record being acted on (for a create, the unsaved record). A falsy answer denies (403, recorded as `api.auth_failed`).

### Assignment Authorization (Privilege Escalation Protection)

`api_assignment_authorization` decides who may change who holds a Permission Set or belongs to a group. Until it is set, every assignment endpoint is refused with 403:

```ruby
config.api_assignment_authorization = ->(controller, target, user_ids) {
  PermissionForge.current_user&.admin?
}
```

When nothing signs a user in (no authenticating base controller), decide from the authenticated client instead, for example a key with its own scope:

```ruby
config.api_action_authorization = ->(controller, _action, _record) {
  ApiKey.active.exists?(key: controller.request.headers['X-API-Key'], scope: 'permissions:write')
}
config.api_assignment_authorization = ->(controller, _target, _user_ids) {
  ApiKey.active.exists?(key: controller.request.headers['X-API-Key'], scope: 'permissions:assign')
}
```

`target` is the `PermissionSet`, or the `PermissionSetGroup` on the group-member endpoints. `user_ids` is an Array cast to the user model's key type (Integers for integer keys) on every endpoint. A falsy answer denies (403). This protects single assignments (`POST .../users`), single revokes (`DELETE .../users/:uuid`), bulk operations (`POST .../users/bulk`), and group membership changes (`POST`/`DELETE .../permission_set_groups/:uuid/users`). `config.admin_assignment_authorization`, when set, is asked after it (see [configuration.md](configuration.md#admin_assignment_authorization)).

### Requiring Authorization Lambdas

`api_auth` proves identity, not admin rights. So by default the API refuses changes until both lambdas are set:

```ruby
config.api_require_authorization = true  # default
```

While it is `true`, mutation and assignment endpoints return 403 (`api.auth_failed`, `hook: api_require_authorization`) whenever the corresponding lambda (`api_action_authorization` / `api_assignment_authorization`) is unset. The 403 says so (`"API changes need config.api_action_authorization; …"`), unlike a lambda's refusal (`"Action not authorized"`), so the missing configuration is visible from the response. Setting it to `false` lets every caller that passes `api_auth` create permission sets and assign them to anyone; a boot warning is logged and `rake permission_forge:audit` reports `api_mutations_unguarded` (high) while a lambda is missing.

### Non-Editable Records

Records flagged `is_editable: false` are locked, and so is what they hold: a change is refused (403, recorded as `admin.lock_refused`) when the record, its Resource, its Permission Set, or — for a membership — its Permission Set Group is locked. That covers creating a resource, field, rule or action under a locked parent, `generate_fields`, assigning holders (single and bulk `assign`), adding and removing group members, moving a set into or out of a locked group (`permission_set_group_id`) and deleting a set that is in a locked group. Records with a `nil`/`true` flag are unaffected.

**Narrowing access is never refused, widening always is — and which is which depends on the set.** On a locked granting set `DELETE …/users/:uuid` and bulk `revoke` work, while `POST …/users` and bulk `assign` are refused. A Muting Permission Set takes access away from its holders, so on a locked one it is the other way round: `POST …/users` and bulk `assign` work, while `DELETE …/users/:uuid` and bulk `revoke` are refused (403, `admin.lock_refused`). `DELETE …/permission_sets/:id/users/:uuid` and `DELETE …/permission_set_groups/:id/users/:uuid` answer 404 for a person `config.user_list_resolver` leaves out, like `POST …/users`. A locked group does not lock the content of its sets. `ResourceAction` has no flag of its own (it follows its Resource and set). Locking is one-way through the API (`PATCH { "is_editable": true }` on a locked record is refused); `POST …/clone` makes an editable copy (outside a locked group).

### Tenancy

With `tenant_model` set, a request that has no current tenant is refused with 403 (`api.auth_failed`, reason `tenant_missing`). Set the tenant in `api_base_controller_class` (or in middleware). `config.admin_tenantless_access = :allow` serves such requests instead: they read, edit and delete existing records of **every** tenant, and a create is refused (422) because the new row needs a tenant. See [multi-tenancy.md](multi-tenancy.md).

### CSRF Posture

API controllers use `protect_from_forgery with: :null_session, prepend: true`: the forgery check is the first callback of the chain, before `api_auth` and before your `api_base_controller_class`'s own callbacks. A mutating request without a valid CSRF token gets an empty session (`request.session`) and an empty cookie jar (`cookies` / `request.cookie_jar`) — and so does everything that reads them during the request, such as a Warden/Devise `current_user` loaded inside the controller. A cross-site form post from a signed-in admin's browser therefore reaches `api_auth` with no session, and an `api_auth` that derives identity from the session or the cookie jar refuses it (401, `api.auth_failed`).

On Rails 8.2 and later, Rails can verify a request by the browser's `Sec-Fetch-Site` header instead of the token, and `config.load_defaults 8.2` selects `:header_only`, under which a plain-HTTP request without that header is not checked at all. The admin screens and the API always use `:header_or_legacy_token`, whatever your application sets: a same-origin or same-site request passes on the header without a token (same-site includes your other subdomains: a page on one can post to the admin on another), a cross-site one is refused, and a request without the header needs the CSRF token, as on earlier Rails versions.

What `:null_session` does **not** empty — an `api_auth` that relies on any of these is still forgeable from another site: the raw `Cookie` header and Rack's `request.cookies`; anything a Rack middleware computed before the controller (an identity in `request.env`, a Warden user a middleware already loaded); credentials the browser attaches on its own (HTTP Basic it has cached, client certificates); the client IP. Authenticate API clients with a header the browser does not send by itself (a bearer token, an API key), or read identity from the session or cookie jar in `api_auth`.

If your base controller declares `protect_from_forgery with: :exception`, the API controllers replace it with `:null_session` (same callback, prepended): a forged request reaches your own authentication callbacks with an empty session, and they answer with your own 401 or redirect. Same-origin JavaScript that uses the session must send `X-CSRF-Token` (on Rails 8.2, a request the browser marks `Sec-Fetch-Site: same-origin` passes without it). With an `ActionController::API` base there is no forgery protection and, unless you add them, no cookies or session; authenticate with a header. If your API base adds cookies or a session (`include ActionController::Cookies`, a session store), it also needs forgery protection: `include ActionController::RequestForgeryProtection` in it, or authenticate with a header the browser does not send by itself.

## Full Configuration Example

```ruby
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  # Core settings
  config.user_class = 'User'
  config.current_user_resolver = -> { Current.user }  # your own resolver; assumes a CurrentAttributes class
  config.cache_backend = :rails_cache

  # JSON Admin API
  config.api_enabled = true
  config.api_base_controller_class = '::Api::V1::Admin::BaseController'
  config.api_auth = ->(_controller) { PermissionForge.current_user&.has_role?(:admin) }
  config.api_pagination_handler = ->(scope, page, per_page) { scope.page(page).per(per_page) }
  config.api_record_identifier = :uuid
  config.api_action_authorization = ->(controller, action, record) { PermissionForge.current_user&.admin? }
  config.api_assignment_authorization = ->(controller, target, user_ids) { PermissionForge.current_user&.admin? }
  config.api_require_authorization = true  # the default: deny mutations while an authorization lambda is unset

  # HTML Admin UI (runs alongside the API)
  config.http_basic_auth_user = Rails.application.credentials.dig(:permission_forge, :username)
  config.http_basic_auth_password = Rails.application.credentials.dig(:permission_forge, :password)
end
```

## Automatic Cache Invalidation

PermissionForge invalidates affected users' cached permissions whenever a permission-related record is created, updated, or destroyed, after the commit. Each user's hash is rebuilt on their next permission check, so changes made through the API (or HTML UI, console, or seeds) apply from the next check on — no manual cache rebuild required.

**How it works:** All permission models include the `PermissionsRegenerator` concern, which registers `after_commit` callbacks. (This is cache invalidation, not auditing; the audit events are written by a separate concern inside the change's transaction, see [audit-log.md](audit-log.md).) After a successful database commit, the concern identifies affected users (via their PermissionSetUser assignments) and invalidates each one's cached permissions; the hash is rebuilt on the next read.

**Models that invalidate:**

| Model | Triggers on | Affected users |
|-------|-------------|----------------|
| `PermissionSet` | create/update/destroy | Users assigned to this set |
| `Resource` | create/update/destroy | Users on the parent permission set |
| `ResourceField` | create/update/destroy | Users on the parent permission set |
| `ResourceAction` | create/update/destroy | Users on the parent permission set |
| `PermissionSetRule` | create/update/destroy | Users on the parent permission set |
| `PermissionSetGroup` | create/update/destroy | Users across all active sets in the group |
| `PermissionSetUser` | create/update/destroy | The assigned user (and the previous one when an assignment moves to another user) |

**Example:** Disabling a resource via the API immediately revokes access for all affected users:

```bash
# Before: user can read Customer
curl -X PATCH /permissions/api/permission_sets/abc/resources/def \
  -d '{ "resource": { "is_active": false } }'
# After: user.can_read?(:Customer) returns false — no manual action needed
```
