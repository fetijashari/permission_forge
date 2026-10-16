# Activation Conditions

## Overview

Permission sets can have **activation conditions** — runtime requirements that must be met for the set to contribute to a user's permissions. This implements three Salesforce-inspired features:

1. **Session-Based Permissions** — set only activates when a session flag is present (e.g., after MFA step-up)
2. **IP Range Restrictions** — set only activates from allowed IP addresses
3. **Login Hour Restrictions** — set only activates during allowed time windows

Conditions are evaluated on **every permission read**, against the request that reads, through a configurable `request_context_resolver` lambda. They are never evaluated once at build time and then reused: the cache keeps one base entry per user (the unconditional sets) plus one variant per combination of conditional sets that a request context selects (see [What Is Cached](#what-is-cached)). Two sessions, two IP addresses, or a session and a job of the same user therefore never share a conditional grant or a conditional lockdown.

When no resolver is configured, the context is blank and every conditional set applies as if its conditions held (backward compatible; a boot warning flags it). Enable [Strict Mode](#strict-mode) to fail closed instead.

## Configuration

```ruby fragment
PermissionForge.configure do |config|
  config.request_context_resolver = lambda {
    {
      ip: Current.ip_address,                    # Request IP
      session_flags: Current.session_flags || [], # Array of session flags
      time: Time.current                          # Current time (for hour checks)
    }
  }
end
```

What the resolver must do:

- **It is called on every permission read of a user who holds a conditional set** — every `permissions_hash` call, so every `can_*?` check and every `MaskedAttributes` getter, memoized or not. It is never called for a user without conditional sets. Keep it cheap: read values your app already holds (`Current` attributes), no queries.
- **Where there is no request** (a job, the console, a rake task), return `{}` or a context without `:ip` and `:session_flags`. A resolver that raises there raises on every read of such a user. Return a Hash.
- **It must not read the permissions of the user it resolves for** — a masked attribute of `Current.user`, a `can_*?` check. Such a read raises `PermissionForge::ConfigurationError` (it would otherwise be answered a hash from another context, or an empty one).
- `:ip` is a String or an `IPAddr`. `:session_flags` is an Array of Strings; a set's `requires_session_flag` must be one of them exactly.
- `:time` is optional (default `Time.current`). It is fixed once per read, and the conditions compare its hour.

If it returns `{}` or isn't configured, every conditional set applies by default — enable `config.conditional_sets_strict_mode` to fail closed instead (see [Strict Mode](#strict-mode)).

## Session-Based Permissions

Use `requires_session_flag` to restrict a set to users who have completed a specific step (e.g., MFA verification).

```ruby run
ps = PermissionForge::PermissionSet.create!(
  name: 'Admin After MFA',
  requires_session_flag: 'mfa_verified'
)
```

**Flow:**
1. User logs in → gets basic permissions (hash built read-through on first access)
2. User completes MFA → your app records the flag in the session, and the resolver returns it (`Current.session_flags = ['mfa_verified']`). No invalidation is needed.
3. The "Admin After MFA" set contributes on the next permission read in that session. The user's other sessions, which have no flag, keep their permissions without it. When the flag leaves the session (sign-out, step-up expiry), the next read in that session no longer includes the set.

## IP Range Restrictions

Use `allowed_ips` to restrict a set to specific IP ranges (CIDR notation, comma-separated).

```ruby run
ps = PermissionForge::PermissionSet.create!(
  name: 'Office Only',
  allowed_ips: '192.168.1.0/24, 10.0.0.0/8'
)
```

- Entries are IP addresses or CIDR ranges (`/24`, `/32`, IPv6 too), written with commas, newlines or spaces between them; the row stores them with commas (`PermissionSet#allowed_ip_list` reads them back as an Array).
- Through the API, `allowed_ips` is a String as above or an Array of Strings (`["10.0.0.0/8", "192.168.0.0/16"]`); any other shape is a 422 keyed `allowed_ips`.
- An entry that is not an address is refused when the row is new or the list changes (`contains "office", which is not an IP address or CIDR range`). A list stored before the check that holds one (or holds no entry at all) **cannot be judged**: a granting set never passes on it, a muting set applies to every request, in every mode and with or without a request context. `rake permission_forge:audit` lists such rows under `incomplete_conditions`.
- When `ip` is missing from the context, the condition fails (a muting set applies in [strict mode](#strict-mode)).

## Login Hour Restrictions

Use `allowed_hours_start` and `allowed_hours_end` to restrict a set to specific hours of the day.

```ruby run
ps = PermissionForge::PermissionSet.create!(
  name: 'Business Hours Only',
  allowed_hours_start: 9,   # 9:00 AM
  allowed_hours_end: 17     # 5:00 PM (exclusive — 4:59 PM is last valid minute)
)
```

- Hours are 0–23 (24-hour format); start is inclusive, end exclusive.
- **Supports midnight wrap**: `allowed_hours_start: 22, allowed_hours_end: 6` = 10 PM to 5:59 AM.
- Uses `Time.current` when no `:time` is in the context (respects `Time.zone`).
- Both hours or none. A new row (or a changed hour) with one hour of the two, or with `start == end` (an empty window), is refused. A window stored before the check in one of those shapes, or with an hour outside 0–23, **cannot be judged**: a granting set never passes on it (one hour of the two used to pass), a muting set applies to every request. `rake permission_forge:audit` lists such rows under `incomplete_conditions`; the admin's condition sentence names the window as one nobody can judge.

## Combined Conditions

All conditions on a set must pass (AND logic). A nil/blank condition always passes.

```ruby run
ps = PermissionForge::PermissionSet.create!(
  name: 'Sensitive Access',
  requires_session_flag: 'mfa_verified',
  allowed_ips: '10.0.0.0/8',
  allowed_hours_start: 9,
  allowed_hours_end: 17
)
# Only active: during business hours + from office IP + after MFA
```

## Cache TTL for Conditional Sets

The conditional sets that apply are selected on every read, so an IP change or an hour rollover takes effect on the next read without waiting for a TTL. The TTL is a backstop for the cached entries themselves (the base entry and its variants): when any of a user's sets is conditional, it is clamped to `conditional_set_cache_ttl`:

```ruby fragment
PermissionForge.configure do |config|
  config.cache_ttl = 3600                  # Baseline TTL in seconds (default: 3600 = 1 hour)
  config.conditional_set_cache_ttl = 300   # Clamp when conditional sets exist (default: 300 = 5 minutes)
end
```

The effective TTL is `min(cache_ttl, conditional_set_cache_ttl)`, and no later than the user's soonest assignment `expires_at`. Set `conditional_set_cache_ttl` to `nil` to disable the clamp. TTL expiry triggers a transparent rebuild on the next read (read-through) — it never leaves a user without permissions.

## What Is Cached

- **The base entry**, under `user.permission_cache_key`: `v2:user_<id>` (`v2:tenant_<tenant id>_user_<id>` with tenancy), stored as `pf:v2:user_<id>` with the default `cache_key_prefix`. It is built from the user's unconditional sets. For a user who holds conditional sets it also carries them under `:conditional_sets`: each set's id, whether it mutes, and its four conditions (not its grants), plus a token minted at that build. For a user with an assignment that ends it also carries `:assignments_expire_at` (epoch seconds of the soonest `expires_at`).
- **One variant per combination of conditional sets a context selects**, in a slot of the base key: the base key plus `_c_<n>`, where `n` (1–63) is the bitmask of the selected sets among the user's conditional sets, sorted by id. A variant is built from the unconditional sets and the selected ones, read from the store or built read-through, and checked against the user's invalidation stamp like the base entry. It carries `variant_of`, a digest of the base entry's token and the selected set ids: a read serves it only when that digest matches the current base entry, so the variant of a base entry that is gone is a miss, rebuilt and written over.
- **An index entry** under the base key plus `_c_index`, written before a variant is stored (after the variant's rebuild read the user's stamp): it only says that variants may be stored under the base key (no grants, no profile). `cache:clear` finds the variants through it on stores without key patterns. A variant whose index entry cannot be written is not stored.
- `permissions_hash` always returns the public format (`profile`, `preferences`, `permissions`), never `:conditional_sets`. `regenerate_permissions` builds the base entry and, when the context selects conditional sets, the variant, and returns the hash for the current context.
- **Cost:** a user without conditional sets costs what it did before: one store read per request, no resolver call. A user with conditional sets costs one store read when none passes and two when a set passes, plus one resolver call per read.
- **Invalidation** (`invalidate_permissions`, the bulk invalidation of a changed set's holders, the settlement after a transaction) removes the base entries and reads nothing. The variants are left in the store: no read can reach them once the base entry that carries their token is gone, and they expire with `conditional_set_cache_ttl` (300 s by default) or are written over by the next variant of their slot. An edit to a set therefore costs the same whatever the number of conditional sets its holders hold (10,000 holders: about 0.45–0.55 s on local Redis at 0, 2 or 6 conditional sets each; see [benchmarks.md](benchmarks.md#invalidating-a-sets-holders-probe)).
- **Erasure and `cache:clear` remove the variants** (they hold the profile: id, uuid, name, email). `DataSubjectErasure` removes the index entry and every slot of each of the person's base keys (up to 192 keys in one multi-key call) without reading anything, whatever base entry the variants were built for; inside a caller's transaction it does so once the transaction has committed. `rake permission_forge:cache:clear` removes them by key pattern on Redis, memory and file stores; on stores without key patterns (Solid Cache, Memcached) it reads each user's index entries and removes the 64 keys of each base key that has one.
- **With no TTL** (`cache_ttl = nil` and `conditional_set_cache_ttl = nil`, not recommended) the variants an invalidation leaves are not reachable but stay in the store until their slot is written over, an erasure or `cache:clear` (at most 63 per base key).
- **More than 6 conditional sets** (`ConditionalSets::MAX_CACHED_SETS`): the variants are built per request, kept on the user instance only, and never stored. Expect one rebuild per request for such a user.
- **What can outlive an erasure:** a variant written by a request that was still building it when the erasure ran and read the user's stamp after it. It cannot be reached and expires with its TTL (`conditional_set_cache_ttl`); its grants were built from the rows after the erasure, but its profile comes from that request's user instance, which may predate the erasure.
- **A pre-release 0.14 build running beside this one** (a host pinned to a git ref) stores its variants under other keys (`_c_<32 hex>`): each build serves only its own, an erasure here does not remove the other build's, and that build's invalidation removes this build's `_c_index` entry, so `cache:clear` may miss the variants it named. All of them are unreachable and expire with `conditional_set_cache_ttl`.
- After upgrading from 0.13, clear the cache once: see [the migration guide](migration-guide.md#after-the-deploy-clear-the-permission-cache-once).

## Strict Mode

By default, every conditional set is treated as **active** when `request_context_resolver` returns a blank context (`{}`, `nil`) — backward compatible, but an unwired resolver skips IP, hours and session-flag enforcement. A boot-time security warning is logged when conditional sets exist and the resolver returns an empty context at boot, and `rake permission_forge:audit` reports it (`conditional_sets_lenient`). Enable strict mode to fail closed:

```ruby fragment
config.conditional_sets_strict_mode = true   # default: false
```

How each context is treated:

| Context | Strict mode on | Strict mode off (default) |
|---|---|---|
| An IP or session flags | Each set evaluated; a conditional muting set whose condition cannot be judged (no IP for an IP allowlist, no `:session_flags` key for a flag) applies | Each set evaluated |
| No request context: blank, or neither an IP nor session flags (a job, the console; the time alone is not a request context) | Conditional **granting** sets dropped; conditional **muting** sets applied, whatever their conditions | Blank: every conditional set applies, except a granting set whose condition cannot be judged. Not blank (for example `{ ip: nil, session_flags: [], time: }`): each set evaluated |

- With strict mode on and no request context, a lockdown still applies and nothing is granted on a condition: a job cannot pick up an MFA-, IP- or hours-gated grant, nor lose a conditional muting set.
- A context with session flags but no IP is a request context: each set is evaluated, and an IP condition fails without an IP — except, in strict mode, a conditional **muting** set whose condition cannot be judged: an IP allowlist with no IP, or a session flag when the context has no `:session_flags` at all. That lockdown applies (a missing context must never lift one).
- Each set evaluated means: a session-flag condition fails without that flag, an IP condition fails without an IP, the hours are checked against `:time`.

We recommend strict mode where conditional sets are used.

## Conditional Muting Sets

Muting sets can also have conditions. A conditional muting set is evaluated per request like a granting one, and revokes permissions only for the requests whose context meets its conditions. In strict mode it also applies with no request context (see [Strict Mode](#strict-mode)):

```ruby run
muting = PermissionForge::PermissionSet.create!(
  name: 'Lockdown Mode',
  is_muting: true,
  requires_session_flag: 'lockdown'
)
# Revokes in the sessions whose flags include 'lockdown' (and, in strict mode, in jobs and the console)
```

A conditional muting set whose condition cannot be judged — an IP entry that is not an address, one hour of the two, the same hour twice — applies to every request, whether or not strict mode is on: a lockdown that never locked is the defect. A granting set with such a condition never applies, not even with a blank context. Fix the condition on the set's Conditions tab.

## Model Methods & Scopes

```ruby run
ps.conditional?    # true if any condition is set
ps.unconditional?  # true if no conditions

PermissionForge::PermissionSet.conditional    # Sets with any condition
PermissionForge::PermissionSet.unconditional  # Sets with no conditions

ps.allowed_ip_list    # => ["10.0.0.0/8"] — the entries as the engine reads them
ps.hours_window       # the window as data: set?, wraps?, broken?, include?(hour)
ps.condition_problems # => [] — or [[:ip_entry, "office"], [:hours_equal, window]] for a row the validation refuses
ps.conditions_broken? # true when a condition cannot be judged (see above)
```

`conditional?` and the `conditional` / `unconditional` scopes agree: a text of blanks is no condition; one hour of the two is one.

## Backward Compatibility

- Default `request_context_resolver` returns `{}` — **no filtering occurs**
- Existing apps without a resolver continue to work exactly as before
- Conditional sets with no resolver configured are always included (conditions ignored) — unless `conditional_sets_strict_mode` is enabled; a boot-time security warning flags this fail-open state. With a resolver, they are selected per request (since 0.14; before, the context of whichever request built the cached hash was used for every request of that user until the entry expired)
- All condition columns are nullable with no defaults — existing records are unconditional

## Evaluator Service

For advanced use cases, you can evaluate conditions directly:

```ruby run
PermissionForge::Services::PermissionSetConditionEvaluator.call(
  permission_set: ps,
  context: { ip: '192.168.1.5', session_flags: ['mfa_verified'], time: Time.current }
)
# => true or false   (:ip may also be an IPAddr)
```

`PermissionSetConditionEvaluator.broken?(permission_set:)` says whether the set holds a condition nobody can judge (such a set never passes); `unjudgeable?(permission_set:, context:)` adds the conditions the context cannot answer.
