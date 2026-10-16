# PermissionForge — Performance Benchmarks

## Overview

PermissionForge adds work at these points of a request:

1. **Read path** (`FiltersResponseAttributes`, `MaskedAttributes`): once per serialized record, filters fields by `read_access` and applies mask strategies.
2. **Write path** (`PermitsAttributes`): once per create/update, filters incoming params by `edit_access`.
3. **Row-level rules** (`PermissionScopedFindable`): on `Model.find_by` / `find_by!` and `permission_scoped` (and every query under `auto_query_scoping`). The allow path is a single existence check whatever the number of rules; per-rule queries run only when access is denied, to name the rule that denied it.
4. **Permission checks** (`can_read?`, `field_permissions`, …) on the user: they read the user's permission hash.

The permission hash lives in a configurable cache (`:memory`, `:null`, or `:rails_cache` over any Rails cache store: Redis, Solid Cache, Memcached, file). It is built read-through on the first read after a change, and each user instance keeps the hash it read: later checks on the same instance do not read the store again until an invalidation in the process retires it. Changes invalidate the affected users; nothing is rebuilt eagerly.

All figures below are microbenchmarks on one machine, against in-memory SQLite and a local Redis. A networked database or cache adds its latency to every query and round trip; the counts (queries, round trips) carry over, the times do not.

## How to Run

```bash fragment
cd /path/to/permission_forge

# All nine scripts, each in its own process
bundle exec rake benchmark

# One script
bundle exec ruby test/benchmarks/filters_response_attributes_benchmark.rb
bundle exec ruby test/benchmarks/permits_attributes_benchmark.rb
bundle exec ruby test/benchmarks/permissioned_user_benchmark.rb
bundle exec ruby test/benchmarks/mask_value_benchmark.rb
bundle exec ruby test/benchmarks/permission_hash_builder_benchmark.rb
bundle exec ruby test/benchmarks/permission_scoped_findable_benchmark.rb
bundle exec ruby test/benchmarks/cache_backends_benchmark.rb
bundle exec ruby test/benchmarks/audit_instrument_benchmark.rb
bundle exec ruby test/benchmarks/runtime_decision_events_benchmark.rb
```

`test/benchmarks/` holds these nine scripts and a shared `benchmark_helper.rb`. Run each script in its own process (the rake task does): scripts loaded into one process share constants and database/cache state and skew each other.

The tables marked **probe** (memo hit vs store read, conditional sets, rebuild query counts, invalidation of many holders) come from release-verification scripts that are not part of the repository. Their setup and what they count are described with each table.

## Method

- **Version:** PermissionForge 0.14 (unreleased; `lib/permission_forge/version.rb` still reads 0.13.0), commit `6503c91` (the runs started at `642763e`; the commits between them change no code on a measured path). The invalidation table was measured afterwards, by the cache stream on the final fix round's invalidation code (see that table). The rest of the final fix round was not re-measured: on the paths measured here it renames private methods, checks `masked_attributes_nil_user_strategy` on reads with no user, compares one Integer per memo hit for a user with an expiring assignment, and lets the muting phase reach STI subclass entries.
- **Ruby** 3.4.5, **Rails** 8.1.4.
- **Hardware:** Apple M5 Max, 48 GB RAM, macOS 27.0.1.
- **Captured:** 2026-10-13.
- **Database:** SQLite in memory (the dummy app's test database). **Redis:** local server, `127.0.0.1:6379`, through `ActiveSupport::Cache::RedisCacheStore` (`pool: false`).
- **Scripts in `test/benchmarks/`:** every script run 5 times, each run in its own process, the five passes interleaved. Tables give the median of the 5 runs. Inside a run, the timed block runs with GC disabled (`measure_without_gc`), except `audit_instrument_benchmark.rb` (GC on, one timed loop) and `runtime_decision_events_benchmark.rb` (GC on, `GC.start` before each of 7 rounds, median of the rounds). Configuration from `benchmark_helper.rb`: `MemoryCache`, no table prefix, no tenancy. Most figures varied by a few percent between runs; single runs were up to a third slower for row-level lookups, rebuilds and `FileStore` writes, and the nanosecond-scale `Audit.instrument` figures varied up to 2x (GC on). The median is not moved by one such run.
- **Probes:** setup like `test/test_helper.rb` (tenancy on, empty prefix, auditing on, SQL logging off), `MemoryCache` unless the table names another store. Each probe was run in 3 processes; a figure is the median of the 3. Inside a process, the read and rebuild probes take the median of 3 or 5 rounds with GC disabled; the invalidation probes time one edit with GC on. Allocations from `GC.stat(:total_allocated_objects)`. Counted: SQL statements through `sql.active_record` (schema queries and query-cache hits excluded, transaction statements included); gem-level cache calls through a delegating wrapper around the cache backend; store calls through the `cache_*.active_support` notifications; Redis round trips through a `redis-client` middleware (one command, or one pipeline, is one round trip).
- Times are wall-clock. Data is created before timing starts.

---

## Results

### Read path: FiltersResponseAttributes

1,000 attribute hashes per scenario, one `FiltersResponseAttributes.call` per record. Baseline: the same loop copying the hash, no permission logic.

| Scenario (15 fields) | Baseline | With PermissionForge | Overhead per record |
|----------------------|----------|----------------------|---------------------|
| A. Mixed: 60% readable, 20% masked, 20% hidden | 1.2 µs | 4.8 µs | +3.6 µs |
| B. Filtering only: 12 readable, 3 hidden | 1.2 µs | 3.3 µs | +2.1 µs |
| C. Masking only: 5 masked, 10 plain | 1.2 µs | 5.4 µs | +4.2 µs |

Scenario D, mixed access, 100 records each:

| Fields | Overhead per record |
|--------|---------------------|
| 5 | +2.3 µs |
| 15 | +3.8 µs |
| 30 | +5.9 µs |
| 50 | +8.7 µs |

Takeaway: overhead grows linearly with field count; a 100-record response with 15 fields costs about 0.4 ms. The user's hash is read once per instance (memoized), so the per-record cost is the field logic and masking, not a cache read.

**Compared with 0.13.** Model-level masked reads are about 8–10% slower than in v0.13.0 and allocate more: a guarded getter 2.3 µs against 2.1 µs, `as_json` of a masked record about 34 µs against 31 µs (+16 allocations), 1,000 × `as_json` 34 ms against 31 ms. Measured interleaved (v0.13.0, the release candidate and the final code, two rounds each) by the pre-release performance review on 2026-10-13. Permission checks on a loaded user are at parity (0.9 µs memo hit, 1.0 µs `can_read?`).

### Write path: PermitsAttributes

1,000 param hashes, 15 fields, 9 editable. Baseline: the same filter with a `Set` lookup.

| Scenario | Per call |
|----------|----------|
| Baseline (Set filter) | 0.7 µs |
| `PermitsAttributes.call` | 4.5 µs (+3.8 µs) |

Takeaway: a few microseconds per create or update.

### Permission checks on a loaded user

`permissioned_user_benchmark.rb`: 10,000 calls per method on one user instance (1 resource, 15 fields, `MemoryCache`). After the first call the hash is memoized, so every timed call is a memo hit.

| Method | Per call |
|--------|----------|
| `can_read?(:Customer)` | 0.53 µs |
| `can_edit?(:Customer)` | 0.54 µs |
| `can?(:read, :Customer)` | 0.62 µs |
| `permissions_hash_for(:Customer)` | 0.49 µs |
| `field_permissions(:Customer, :email)` | 0.53 µs |
| `masked_field?(:Customer, :email)` | 0.55 µs |
| `permissions_hash` | 0.42 µs |

Takeaway: a check on a user instance that has read its hash is under a microsecond and touches no store.

#### Memo hit vs store read (probe)

A memo hit is a repeated call on the same instance (100,000 calls per round, 5 rounds). A store read is the first `can_read?` on each of 2,000 fresh instances (200 for the large hash), loaded with `User.find` before the clock starts, so the time is the store read plus the check. "Small": 1 resource × 15 fields; "large": 10 resources × 30 fields. The probe runs with tenancy on, which adds the tenant cache-key lookup to every call (hence about 0.9 µs here against 0.4–0.6 µs in the table above).

| Backend | Hash | `permissions_hash`, memo hit | `can_read?`, memo hit | `can_read?`, fresh instance | Store reads / Redis round trips per fresh instance |
|---------|------|------------------------------|-----------------------|-----------------------------|-------------------------------------|
| MemoryCache | small | 0.94 µs | 1.04 µs | 24.8 µs (190 allocs) | 1 / – |
| MemoryCache | large | 0.93 µs | 1.05 µs | 337 µs (2,803 allocs) | 1 / – |
| RailsCache (MemoryStore) | small | 0.93 µs | 1.04 µs | 30.4 µs (271 allocs) | 1 / – |
| RailsCache (MemoryStore) | large | 0.93 µs | 1.04 µs | 278 µs (2,872 allocs) | 1 / – |
| RailsCache (RedisCacheStore, local) | small | 0.92 µs | 1.05 µs | 77.0 µs (297 allocs) | 1 / 1 |
| RailsCache (RedisCacheStore, local) | large | 0.93 µs | 1.05 µs | 378 µs (2,898 allocs) | 1 / 1 |

Memo hits allocate 2 objects and run no SQL and no store call. Fresh instances run no SQL (the entry is in the store).

Takeaway: the first check on a user instance pays one store read, whose cost grows with the size of the hash (deserialization and key symbolization) plus, on Redis, one network round trip; every later check on that instance costs about a microsecond. Load the current user once per request and reuse the instance.

### Conditional permission sets (probe)

A user holding one unconditional set (1 resource × 15 fields), compared with a user holding the same plus 2 conditional sets (one `requires_session_flag: 'mfa'`, one `allowed_ips: '10.0.0.0/8'`, each with 1 resource × 3 fields). `config.request_context_resolver` returns either one frozen Hash (constant) or a new Hash on every call (fresh); both carry an IP and the flag, so both conditional sets pass.

Warm memo, 100,000 calls on one instance, `MemoryCache`:

| User | `permissions_hash` | `can_read?` | Allocations per call |
|------|--------------------|-------------|----------------------|
| No conditional sets | 0.94 µs | 1.05 µs | 2 |
| 2 conditional sets, constant context | 3.03 µs | 3.17 µs | 11 |
| 2 conditional sets, fresh context Hash | 3.09 µs | 3.24 µs | 13 |

First `can_read?` on each of 2,000 fresh instances:

| User | MemoryCache | RailsCache (MemoryStore) | RailsCache (RedisCacheStore, local) | Store reads (Redis round trips) |
|------|-------------|--------------------------|-------------------------------------|---------------------------------|
| No conditional sets | 24.7 µs | 30.5 µs | 80.8 µs | 1 (1) |
| 2 conditional sets, both pass | 75.5 µs | 95.5 µs | 194 µs | 2 (2): base entry + variant |
| 2 conditional sets, none passes | 36.8 µs | 42.0 µs | 97.6 µs | 1 (1): base entry |

Takeaway: a user without conditional sets pays nothing for them. With conditional sets, every read calls the resolver and checks the context against the memoized selection (about 2 µs per call), and the first read on an instance needs a second store read when a conditional set passes. Keep the resolver cheap.

### MaskValue

100,000 calls per strategy.

| Strategy | Per call |
|----------|----------|
| `full` | 0.30 µs |
| `email` | 0.51 µs |
| `last4` | 0.36 µs |
| `first1_last4` | 0.39 µs |
| All four, mixed | 0.45 µs |

Takeaway: masking costs well under a microsecond per value.

### Rebuild: PermissionHashBuilder

`permission_hash_builder_benchmark.rb`: `user.regenerate_permissions` on one user with one Permission Set (query the rows, build the hash, store it in `MemoryCache`, verify against the invalidation stamp).

| Scenario | Per rebuild |
|----------|-------------|
| Small (1 resource, 5 fields) | 0.98 ms |
| Medium (3 resources, 15 fields) | 1.50 ms |
| Large (5 resources, 30 fields) | 2.55 ms |
| XL (9 resources, 30 fields) | 3.91 ms |

#### Queries per rebuild, by size (probe)

`regenerate_permissions` on a fresh `User.find` instance (the find is inside the timing, not in the SQL count). Time: median of 3 rounds of 20 rebuilds (5 for L), GC off; median of 3 processes.

| Scenario | Rows | SQL | Cache calls | Time | Allocations |
|----------|------|-----|-------------|------|-------------|
| S | 1 set × 1 resource × 5 fields | 7 | 3 `read_fresh`, 2 `write` | 1.16 ms | 2,918 |
| M | 3 sets × 5 resources × 15 fields, 2 actions and 1 rule per resource | 7 | same | 4.41 ms | 13,706 |
| L | 10 sets × 20 resources × 30 fields, 3 actions and 2 rules per resource, plus 1 Muting Permission Set (5 resources × 10 fields) | 7 | same | 62.5 ms | 215,641 |
| T | 10 sets × 2 resources × 3 fields, `audit_trail_enabled`, assignments with `created_by_id` | 8 (the 7 + `users`) | same | 3.22 ms | 10,687 |

The 7 statements: `permission_set_users` (2), `permission_sets`, `resources`, `resource_fields`, `resource_actions`, `permission_set_rules`. Scenario L grew the process RSS by about 3 MB. Splitting S over 200 rebuilds × 5 rounds: 1.03 ms for the whole rebuild, of which 0.64 ms (1,749 allocations) is `PermissionHashBuilder` with its queries.

Takeaway: a rebuild runs a fixed number of queries whatever the number of sets, resources and fields; its time grows with the rows it reads. It runs on the first read after a change, not on every request.

### Invalidating a set's holders (probe)

One `ResourceField#update!` in a Permission Set with 10,000 holders, timed from the update to the end of the after-commit invalidation. The holders are invalidated by id in slices of 500: per slice, one multi-key stamp write and one multi-key removal (`write_multi` with entries that expire at once); nothing is read, and per-context variants are not removed (they are unreachable once the base entry is gone). Cached for every holder: a real permission hash (S 836 B, M 3.5 KB, L 24 KB, Marshal) and, with conditional sets, an index entry (the worst case: every holder had a variant stored).

Measured on 2026-10-14 by the cache stream (the same Apple M5 Max, Ruby 3.4.5, Rails 8.1.4, in-memory SQLite, local Redis), interleaved cell by cell with the code before the change (which read the index entries and removed 2^n − 1 variant keys per base key), one process per cell, GC on; an independent review reproduced it within 10%.

| Store | Conditional sets per holder | Before (S / M / L) | 0.14 (S / M / L) | 0.14 RSS |
|-------|-----------------------------|--------------------|------------------|----------|
| MemoryCache | 0 | 88 / 77 / 79 ms | 70 / 65 / 73 ms | +24 to +44 MB |
| MemoryCache | 2 | 160 / 191 / 166 ms | 71 / 77 / 70 ms | +34 to +44 MB |
| MemoryCache | 6 | 1,033 / 1,128 / 1,717 ms | 76 / 67 / 67 ms | +26 to +40 MB |
| RailsCache (RedisCacheStore, local) | 0 | 492 / 482 / 627 ms | 457 / 492 / 538 ms | about +6 MB |
| RailsCache (RedisCacheStore, local) | 2 | 969 / 981 / 1,059 ms | 436 / 445 / 512 ms | about +6 MB |
| RailsCache (RedisCacheStore, local) | 6 | 7,477 / 7,874 / 8,468 ms | 444 / 458 / 497 ms | about +6 MB (was +140–200 MB) |

Every 0.14 cell: 10 SQL statements (the whole edit: the update, its audit event, the transaction statements and one holder lookup); on Redis 40 round trips (40 `write_multi`; 60 before, with 20 `read_multi`). After each run no holder had an entry left. v0.13.0 made one round trip per key on Redis (about 40,000 for 10,000 holders).

In short: about 0.07 s in process and 0.45–0.55 s on local Redis, whatever the size of the cached hashes and the number of conditional sets per holder.

Takeaway: the time depends on the number of holders only. Each holder costs 5 keys (the stamp, and the tenant and tenant-agnostic entry keys in this and the previous key namespace). The round trips are 2 per slice of 500. Only stores that implement `write_multi` (in Rails, `RedisCacheStore`; Solid Cache) get one round trip per call; any other store (`MemCacheStore`, `FileStore`, `MemoryStore`) is written one key per call.

The removal of the variants costs where it happens: `DataSubjectErasure` of one user with a variant cached takes 5–14 ms (memory and Redis, 2 and 6 conditional sets), as before. `rake permission_forge:cache:clear` on a store without key patterns (10,000 users, 20,000 visits, every user with an index entry) takes 0.5 / 4.2 / 4.1 s in memory and 0.9 / 7.5 / 6.9 s on Redis at 0 / 2 / 6 conditional sets (it removes the 63 slots of each base key with an index entry; 0.7 / 1.2 s at 2 sets before). With key patterns (Redis, memory, file stores) the clear is one call per namespace.

Assignment changes through `BulkPermissionSetAssignment` go through the models (callbacks and one audit event per row) and invalidate user by user, after the commit: on Redis that is 3 round trips per assigned or revoked user, not the batched path above. `MemoryCache`:

| Operation (1,000 users) | Time | SQL |
|-------------------------|------|-----|
| assign | 981 ms | 8,004 |
| revoke | 495 ms | 5,003 |
| `PermissionSet#destroy!` with 1,000 assignments | 494 ms | 5,019 |

### Row-level rules: PermissionScopedFindable

100 `Customer.find_by(uuid:)` lookups over 1,000 rows (SQLite; the dummy `customers` table has no indexes). Every lookup passes every rule: this is the allow path.

| Scenario | Per lookup | Overhead vs baseline |
|----------|------------|----------------------|
| Baseline (no current user) | 100 µs | – |
| With user, 0 rules | 93 µs | none measurable |
| 1 rule | 208 µs | +108 µs |
| 2 rules | 233 µs | +133 µs |
| 3 rules | 266 µs | +166 µs |

Takeaway: the first rule adds one existence-check query; each further rule only grows its WHERE clause (about 25–33 µs here). Per-rule queries run only on denial. Index the columns your rules filter on.

### Cache backends

`cache_backends_benchmark.rb`: a permission hash of 2 resources (17 fields, actions, a rule), 5,000 writes then 5,000 reads over 100 keys, called directly on the backend (no memo).

| Backend | Write | Read |
|---------|-------|------|
| MemoryCache | 15.1 µs | 27.0 µs |
| RailsCache (MemoryStore) | 10.8 µs | 23.5 µs |
| RailsCache (FileStore) | 290 µs (256–364 across runs) | 56.9 µs |
| NullCache (no-op) | 0.08 µs | 0.06 µs |

`MemoryCache` deep-copies the value on write and on read (and symbolizes keys on read), so no caller can change what is cached; `RailsCache` goes through the store's own serialization. For Redis, see the store reads in [Memo hit vs store read](#memo-hit-vs-store-read-probe).

Takeaway: in-process backends read a small hash in 25–30 µs; with the per-instance memo that cost is paid once per user instance, not per check.

---

## Audit events: attribute reads and row lookups

`audit_instrument_benchmark.rb`: `Audit.instrument` of a runtime event that nobody listens to and whose group is not stored, 200,000 calls.

| Call | Per call |
|------|----------|
| Baseline: a no-op method call | 126 ns |
| `instrument` (eager payload) | 267 ns |
| `instrument` (payload block) | 260 ns |
| `instrument?` only | 129 ns |
| Stored group, `audit_events = false` | 548 ns |

`runtime_decision_events_benchmark.rb`: the hot paths that publish runtime decision events, with no subscriber and the default `audit_runtime_events` (`[:denied]`). `Customer` with `MaskedAttributes`, 8 configured fields and one row-level rule; 50,000 reads (5,000 for `attributes` / `as_json`), 2,000 lookups. "Hook set": only the legacy `on_field_filtered` and `on_rule_bypass` hooks set.

| Scenario | ns per operation |
|----------|------------------|
| getter, readable field | 1,759 |
| getter, masked field | 2,505 |
| getter, hidden field | 1,803 |
| `record[:email]` | 2,489 |
| `attributes` (9 columns) | 15,011 |
| `as_json` (9 columns) | 25,535 |
| `find_by`, rule allows | 189,633 |
| `permission_scoped.where.first` | 136,111 |
| `find_by`, view_all bypass | 83,324 |
| auto-scope, view_all bypass | 24,478 |
| auto-scope, filter rule | 42,664 |
| hook set: getter, masked field | 3,316 |
| hook set: `as_json` (9 columns) | 32,229 |
| hook set: `find_by`, view_all bypass | 89,440 |

In the same runs, setting the legacy hooks made a masked getter 1.32x as slow, `as_json` 1.26x and a `find_by` with a view_all bypass 1.07x.

Takeaway: an unheard runtime event costs about 0.14 µs over a plain method call; the legacy hooks, when set, are the measurable cost.

**Historical (0.13 capture, not re-measured for 0.14):** when the runtime events were added, this script was run on the commit before them and on the commit with them, alternately (median of 3 runs × 9 rounds, Ruby 3.4.5, Rails 8.1.4). With nothing listening, reads through the model were not slower (`attributes` and `as_json` about 0.82x, every other scenario 0.96x–1.00x); with only the legacy hooks set, a masked getter took 1.24x and `find_by` with a view_all bypass 1.08x as long as before.

## Historical: v0.5.0 Security Audit Impact

The v0.5.0 before/after comparison that used to be here was captured on Ruby 3.2.5 / Rails 8.0.4 on other hardware and has been removed; it is in the history of this file.

---

## Production Considerations

### Cache backend

| Use case | Backend | Why |
|----------|---------|-----|
| Single process, development | `MemoryCache` or `RailsCache` over `MemoryStore` | No network hop |
| Several processes, production | `RailsCache` over a shared store (`RedisCacheStore`, Solid Cache) | An invalidation reaches every process; invalidating many holders is batched per 500 users on stores with `write_multi` |
| Tests | `MemoryCache` or `NullCache` | No external dependency |

### Rules of thumb from these numbers

| What | Measured here |
|------|---------------|
| A permission check on a loaded user | 0.4–1 µs (about 3 µs with conditional sets) |
| The first check on a new user instance | one store read: 25–80 µs for a 15-field hash locally, 0.3–0.4 ms for 300 fields; add your store's round-trip time |
| Response filtering | 2–9 µs per record for 5–50 fields |
| A rebuild | 7 queries (8 with assignment grantors); 1–4 ms for one set, 62 ms for 10 sets × 20 resources × 30 fields |
| An edit to a set with 10,000 holders | 40 round trips on Redis; about 0.07 s in process, 0.45–0.55 s on local Redis, whatever the size of the cached hashes and the number of conditional sets per holder |
| A row-level lookup with rules | one existence-check query, plus 25–33 µs per further rule on SQLite |

These were measured against SQLite in memory. On PostgreSQL or MySQL over a network each query pays a round trip, which these numbers do not include; the query counts are the same.

---

## Key Findings

1. **Checks on a loaded user are cheap and do not touch the store**: about half a microsecond (0.9 µs with tenancy). Reuse the user instance within a request; the first check on a new instance pays one store read.
2. **The read path costs 2–9 µs per record** for 5–50 fields; a 100-record page with 15 fields adds about 0.4 ms.
3. **Masking is under a microsecond per value.**
4. **A rebuild runs 7 queries whatever the size**; its time grows with the rows read (1 ms for 5 fields, 62 ms for 6,000 field rows over 10 sets).
5. **Invalidating 10,000 holders takes 40 round trips on Redis and about 0.45–0.55 s, whatever the size of their cached hashes and the number of conditional sets they hold**: an invalidation leaves per-context variants to their TTL (unreachable without the base entry); only erasure and `cache:clear` remove them.
6. **Conditional sets cost nothing for users who do not hold one.** For those who do, each read calls the resolver (about 2 µs more per check), and the first read on an instance reads the store twice when a conditional set passes.
7. **Row-level rules**: the first rule adds one query to a lookup; further rules extend its WHERE clause.
8. **Unheard audit events cost about 0.14 µs per call**; the legacy hooks, when set, add 7–32% to the paths they run on.
