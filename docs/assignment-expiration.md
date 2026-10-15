# Assignment Expiration

## Overview

Permission set assignments can be time-bound via the `expires_at` column on `PermissionSetUser`. When an assignment expires, it is automatically excluded from the user's permission hash on the next rebuild — and the cache TTL is clamped to the soonest assignment `expires_at`, so the shared cache entry never outlives the assignment. A user instance that has already memoized its hash stops granting from it at the same moment: the memo is retired at the soonest `expires_at`. The `ExpiredAssignmentCleaner` service removes stale records and invalidates affected users' cached permissions in bulk.

## Creating Time-Bound Assignments

### Via Code

```ruby
# Assign with expiration
PermissionForge::PermissionSetUser.create!(
  user: user,
  permission_set: permission_set,
  expires_at: 1.week.from_now
)

# Permanent assignment (default)
PermissionForge::PermissionSetUser.create!(
  user: user,
  permission_set: permission_set
  # expires_at: nil (default — never expires)
)
```

> **Note:** A user can only be assigned to a permission set once — a repeat assignment fails validation (`ActiveRecord::RecordInvalid`; the admin API returns 422) instead of raising a database uniqueness error.

### Via API

```bash
# Assign with expiration
POST /api/permission_sets/:identifier/users
{ "user_id": 42, "expires_at": "2026-04-01T00:00:00Z" }

# Bulk assign with expiration
POST /api/permission_sets/:identifier/users/bulk
{ "user_ids": [1, 2, 3], "bulk_action": "assign", "expires_at": "2026-04-01T00:00:00Z" }
```

`expires_at` is ISO 8601: a date (`2026-04-01`, the beginning of that day in `Time.zone`) or a date and time with an optional offset (`2026-04-01T00:00:00Z`). Anything else is a 422 — see [`expires_at` formats](admin-api.md#expires_at-formats).

### Via Admin UI

- **Assign a Permission Set** (from Home, People, a person's page or a set's Assignments tab) offers end-date presets: *1 day*, *1 week*, *30 days*, *End of month*, *Custom date* or *No expiry*. Dates are calendar days; access lasts through the end of the chosen day.
- Each assignment has a **Change end date** menu (1 week, 30 days, end of month, no expiry) on the person's Access tab and the set's Assignments tab.
- **Home → Access ending this week** lists assignments ending in the next 7 days with *Extend 30 days*; **Clean up expired assignments** removes expired rows after a dry run.
- **Bulk assign** applies one end date to everyone it assigns.

## How Expiration Works

### On Permission Hash Rebuild

Whenever the permission hash is built (read-through on cache miss, or an explicit `regenerate_permissions`), the `PermissionCacheAccessor` filters out expired assignments before passing permission sets to the `PermissionHashBuilder`:

```ruby
# Only active (non-expired) assignments are used
permission_set_users.active_assignments  # WHERE expires_at IS NULL OR expires_at >= NOW()
```

This means:
- **Expired assignments are excluded** from the permission hash immediately on rebuild
- **No background job is required** for expiration to take effect — the cache TTL is clamped to the soonest assignment `expires_at`, so the cached hash expires no later than the assignment and is rebuilt transparently (read-through) without it on the next read by a freshly loaded user
- **The `PermissionSetUser` record still exists** until cleaned up — it just doesn't contribute to permissions

### Cleaning Up Expired Records

Use `ExpiredAssignmentCleaner` to remove stale records and invalidate affected users' cached permissions (each hash is rebuilt read-through on the user's next access):

```ruby
# Remove expired assignments and invalidate affected users' caches
result = PermissionForge::Services::ExpiredAssignmentCleaner.call
# => { removed: 5, invalidated: 3 }  # :invalidated = users whose cache was invalidated

# Dry run (inspect without removing)
result = PermissionForge::Services::ExpiredAssignmentCleaner.call(dry_run: true)
# => { removed: 0, invalidated: 0, expired_count: 5, affected_user_ids: [1, 2, 3] }
```

### Rake Tasks

```bash
# Dry run — see what's expired without removing
rake permission_forge:expired_assignments

# Remove expired assignments and invalidate the affected users' cached permissions
rake permission_forge:cleanup_expired_assignments

# Say who ran it and why (recorded on the audit events)
ACTOR="Ops nightly" REASON="TCK-88" rake permission_forge:cleanup_expired_assignments
```

Unless a reason is given (`REASON=`, `reason:` or `with_audit_actor(reason:)`), the events of the run carry the reason `expired`, and the sentence for each removal says the assignment was removed after it expired. Without `ACTOR=` the actor is recorded as `rake permission_forge:cleanup_expired_assignments` and a warning is printed on stderr. The dry-run task (`expired_assignments`) changes nothing; it records a `report.generated` event.

### What the cleaner records

Every removed assignment is destroyed through its callbacks, so each one is an `assignment.revoked` event with a snapshot of the row (person, Permission Set, `expires_at`), the actor you gave and the source (`rake`, `service`, `job` or `console`). When at least one row was removed the run also writes one `cleanup.expired_assignments` event under the same correlation id: `removed`, `invalidated` (users whose cache invalidation the store confirmed), `affected_user_count`, `affected_user_ids` (at most 100; `affected_user_ids_truncated` is true when there were more), `set_uuids` and `set_names`. A run that removes nothing, and `dry_run: true`, write no event.

The cleaner re-reads each selected assignment under a row lock before destroying it: an assignment renewed (given a later `expires_at`) or removed since the run selected it is left alone, and the `assignment.revoked` snapshot is the row as it was at that moment.

```ruby
PermissionForge::Services::ExpiredAssignmentCleaner.call(actor: 'nightly job', reason: 'daily cleanup')
```

`actor:` is a user, an `Audit::Actor` or a label String (stored as a `system` actor); `nil` keeps whoever the context names. This answers "did an expired assignment ever exist?" from the log: its `assignment.granted` event, its `expires_at`, and its `assignment.revoked` by the cleaner. See the [audit log guide](audit-log.md).

## Reviewing permanent assignments

An assignment without `expires_at` is permanent. The Stale list on Home, the person page and `StaleAssignmentAuditor` flag permanent assignments that were not reviewed for `admin_stale_assignment_days` (default 90):

- **Review means "Keep"** in the admin (Home, or the person's Access tab). It sets `reviewed_at` and `reviewed_by_id` and writes one `assignment.reviewed` event with the reviewer, the date and the optional reason.
- **The clock starts at the last review, else at the grant** (`COALESCE(reviewed_at, created_at)`). Editing an assignment (changing its end date, say) is **not** a review any more: before 0.13 the staleness clock was `updated_at`, so any edit reset it. Rows are not backfilled by the upgrade, so after upgrading every permanent assignment counts from its grant date.
- The labels read "Reviewed by *person* on *date*", "Reviewed on *date*" (the reviewer is not a record, for example under Basic auth) or "Never reviewed".
- `StaleAssignmentAuditor.call(threshold_days: 90)` rows carry `last_reviewed_at` and `reviewed_by_id`; `days_stale` is counted from the last review; the `last_updated` key is kept for compatibility.
- A host can forbid reviewing your own access with `admin_assignment_authorization` (action `:review`).

### Scheduling Cleanup (Recommended)

The shared cache cannot outlive an assignment — the cache TTL is clamped to the soonest `expires_at`, so an expired assignment stops granting no later than its expiry for any user loaded after it. The cleaner is housekeeping: it removes stale `PermissionSetUser` rows (keeping assignment listings and audits clean) and invalidates affected users' caches.

**You should still schedule the cleaner to run periodically** (daily or hourly depending on your needs):

```ruby
# Sidekiq + sidekiq-cron
class ExpiredAssignmentCleanupJob
  include Sidekiq::Job

  def perform
    PermissionForge::Services::ExpiredAssignmentCleaner.call
  end
end
# In sidekiq.yml or initializer: run every hour

# GoodJob
class ExpiredAssignmentCleanupJob < ApplicationJob
  self.good_job_concurrency = { total_limit: 1 }
  def perform
    PermissionForge::Services::ExpiredAssignmentCleaner.call
  end
end
# Schedule via GoodJob cron

# Whenever gem (cron)
every 1.hour do
  rake 'permission_forge:cleanup_expired_assignments'
end
```

## Scopes

```ruby
PermissionForge::PermissionSetUser.active_assignments  # Non-expired (nil or future)
PermissionForge::PermissionSetUser.expired              # Past expires_at
```

## Instance Methods

```ruby
psu.expired?           # true if expires_at is present and in the past
psu.active_assignment? # true if not expired (nil or future)
```

## Interaction with Muting Sets

Expiration applies to muting sets the same way as granting sets:
- An **expired muting assignment** does NOT revoke permissions (the muting set is excluded)
- An **active muting assignment** with future `expires_at` continues to revoke normally

## Timezone Handling

All `expires_at` comparisons use `Time.current` (respects `Time.zone`). The database stores datetimes in UTC. Rails handles conversion automatically — no special timezone configuration needed.

## Cache Behavior

- Expired assignments are filtered out **at rebuild time** — and the effective cache TTL is clamped to the soonest assignment `expires_at`, so a cached hash (a per-context variant included) expires no later than the assignment itself
- A user instance memoizes its hash (one store read per instance). The memo is retired at the soonest assignment `expires_at` that went into it, so an instance kept across requests (a long-running job, the console) stops granting from an expired assignment too. Other changes reach a kept instance only through an invalidation in its own process or `reload` (see [architecture.md](architecture.md)).
- On the first read after expiry, the hash is rebuilt transparently (read-through) without the expired assignment — no manual `regenerate_permissions` call or background job is needed for access to lapse
- `ExpiredAssignmentCleaner` **invalidates** affected users' cached permissions rather than eagerly regenerating them — the base entry is removed (a user's per-context variants cannot be reached without it and expire with `conditional_set_cache_ttl`), and the hash is rebuilt read-through on the user's next access (see [activation-conditions.md](activation-conditions.md#what-is-cached))
- Scheduling the cleaner keeps the assignments table free of stale rows; it is not required for access revocation
