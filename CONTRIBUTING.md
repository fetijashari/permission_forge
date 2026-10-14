# Contributing to PermissionForge

Thanks for helping. PermissionForge decides who sees and changes data in the apps that embed it, so changes are held to
a high bar: a failing test first, behaviour that holds on the shipped defaults, and documentation that says exactly what
the code does.

- **Security problems:** do not open an issue or a pull request. Follow [SECURITY.md](SECURITY.md).
- **Bugs and features:** open an issue first for anything larger than a small fix, so we can agree on the approach.
- **Conduct:** this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

You need Ruby 3.2 or newer (`.ruby-version` pins the version the maintainers use) and Bundler.

```bash
git clone https://github.com/fetijashari/permission_forge.git
cd permission_forge
bundle install
bundle exec rake test
```

The default suite runs on in-memory SQLite against the dummy Rails app in `test/dummy/` and needs no database server.

## Test suites

| What | Command |
|---|---|
| Full suite, SQLite | `bundle exec rake test` |
| Full suite, SQLite, one process | `PARALLEL_WORKERS=1 bundle exec rake test` (the default runs 8 forked workers on Rails 8.1) |
| Rails-internals canary | `bundle exec ruby -Itest test/permission_forge/rails_internals_canary_test.rb`; on Rails `main`: `BUNDLE_GEMFILE=gemfiles/rails_main.gemfile` with `-e 'require "test_helper"; SimpleCov.minimum_coverage(0); require "./test/permission_forge/rails_internals_canary_test.rb"'` |
| Public API docs | `bundle exec rake yard:check` (CI runs it); `bundle exec yard server` and `yard stats --list-undoc --hide-api private` to browse and list what is undocumented |
| One file | `bundle exec ruby -Itest test/permission_forge/models/permission_set_test.rb` |
| Full suite, PostgreSQL | `DB=postgres bundle exec rake test` (reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`; database `permission_forge_test`) |
| Row-Level Security policies, PostgreSQL | `bundle exec rake test:rls` (sets `DB=postgres` itself) |
| Full suite, MySQL | `DB=mysql BUNDLE_GEMFILE=gemfiles/mysql.gemfile bundle exec rake test` (reads `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`; database `permission_forge_test`) |
| Another Rails version | `BUNDLE_GEMFILE=gemfiles/rails_7.1.gemfile bundle exec rake test` (also `rails_7.2`, `rails_8.0`, `rails_8.1`) |
| Every local check | `bin/ci` (RuboCop, Reek, the SQLite suite, bundler-audit, Brakeman, i18n-tasks) |

Run `bundle install` once with the same `BUNDLE_GEMFILE` before using another gemfile. Create the PostgreSQL or MySQL
database yourself; the suite loads the schema. Two PostgreSQL runs against the same database at the same time drop
each other's tables, so run one at a time. The SQLite suite runs in forked workers; PostgreSQL, MySQL and Rails < 8.1 runs
are serial. Each run reports its own coverage (`test_helper` deletes `coverage/.resultset.json` at start).

CI runs the SQLite suite on Ruby 3.2 to 3.4 with Rails 7.1 to 8.1, the full suite on MySQL 8.4, the RLS suite on
PostgreSQL 17, RuboCop, Reek, Brakeman and bundler-audit.

When you change a generator, a migration template, a default, boot behaviour or the cache path, also run the tests that
install the gem into a freshly generated app:

```bash
bundle exec ruby -Itest test/permission_forge/install/fresh_install_test.rb
bundle exec ruby -Itest test/permission_forge/audit_integration/install_upgrade_e2e_test.rb
```

The suite itself runs on a non-default configuration (no table prefix, memory cache, tenancy on); these tests cover the
shipped defaults.

## How we work

1. **Test first.** Reproduce the bug or describe the feature in a Minitest test that fails, then make it pass.
2. **Hold the shipped defaults.** A fix must work with the defaults a new install gets, not only with the suite's
   configuration.
3. **Keep commits focused.** One change per commit, with a subject line and a wrapped body. For a fix, say what input
   failed, why, and what changed.
4. **Update the docs and the CHANGELOG.** Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md). A
   changed default goes under **Changed**, with how to keep the old behaviour. Update the guide in `docs/` that
   describes the behaviour.
5. **Run `bin/ci`** (or at least the suite, `bundle exec rubocop --parallel` and `bundle exec reek app lib`) before
   opening the pull request.

## Rules the code follows

[CLAUDE.md](CLAUDE.md) holds the full architecture notes and invariants (it is written for AI coding assistants and
humans alike). The ones you are most likely to meet:

- **The permission hash format is a public contract.** Host apps read it; never change its structure.
- **Every write to the eight permission models runs callbacks.** No `update_all`, `delete_all`, `update_column(s)`,
  `insert_all`, `upsert_all`, `touch` or raw SQL on them in `app/`, `lib/` or rake tasks: each would be an unaudited
  change and would skip cache invalidation. A guard test enforces it.
- **One emitter for audit events:** `Audit.record` and `Audit.instrument`. A new event is one `EventCatalog.register`
  entry plus one sentence key in each locale.
- **No hard dependencies.** Integration with the host app (current user, tenant, authorization) goes through lambdas
  in the configuration.
- **One definition per concept.** For example: `Operators::ValueTyping` types every rule value, `ResourceChain`
  resolves the Resource entries a model answers to, `OpenTransaction` answers whether a transaction is open,
  `Resource.in_effect` decides what counts as managed. Reuse these instead of re-deriving them.
- **Extend through registries, not conditionals.** Operators, mask strategies, value casters and unconfigured-field
  strategies are registry entries; adding one should not require editing a `case`.
- **Renamed or removed public API is deprecated first.** It goes through `PermissionForge.deprecator` for at least one
  minor version: the old name calls the new one (`deprecator.deprecate_methods`, `deprecator.warn` or
  `PermissionForge::Deprecation.warn`), and the CHANGELOG lists it under **Deprecated**. `Deprecation::HORIZON` is the
  version that removes it; a test fails when `VERSION` reaches it. Never `alias_method` on `Configuration`: it skips the
  writers `Configuration` prepends.
- **Library defaults do not change silently.** A new fail-open option gets a README hardening-checklist row and a
  `Configuration::Presets` entry (`STRICT`/`COMPAT`, or `OPT_IN`) in the same change; `configuration_presets_test.rb`
  parses the README table.
- **A new reliance on a private Rails API needs a canary.** Anything `:nodoc:`, private (`send`,
  `instance_variable_get`), undocumented, or a prepend onto a Rails class goes in
  `test/permission_forge/rails_internals_canary_test.rb` as a `canary_test :key` with a `TOUCH_POINTS` entry (the code
  that relies on it) and a `FIXES` entry (what to change). Remove the canary with the reliance.
- **Per-execution state goes through `PermissionForge::ExecutionState`**, never `Thread.current`, `Fiber[]` or
  `IsolatedExecutionState` directly (a guard test enforces it). A new slot is one `KEYS` entry.
- **Say which classes are public.** Every class and module under `PermissionForge::` has `@api public` or
  `@api private` in the comment above it (`test/permission_forge/api_boundary_test.rb`); a public method has a YARD
  docstring. The floor in the `Rakefile` (`YARD_UNDOCUMENTED_FLOOR`) is lowered, never raised.
- **The models are autoloaded by the host.** No model constant at require time, and no engine initializer may
  reference one.
- **Fail closed.** An unexpected value, a misconfiguration or an error on an authorization path must deny or raise,
  never allow.
- **Tables are named by a method** (`def self.table_name`), never `self.table_name =`, so the prefix stays
  configurable.
- **PostgreSQL RLS policies select what the Ruby rules select, never more.** Changing what a rule compiles to needs a
  `RlsPolicyGenerator::GENERATOR_VERSION` bump.

### Admin UI

- Assets are served by the engine from `app/frontend/`; never add files to `app/assets` or depend on the host's asset
  pipeline.
- Namespace everything: `pf-*` CSS classes, `data-pf-*` attributes, `pf_*` helpers and cookies.
- It must work under a strict Content Security Policy: no inline `style=`, no inline `<script>`, no `on*=` handlers.
- Every flow works without JavaScript; `pf_admin.js` only enhances.
- Never show a state by colour alone: pair it with a glyph and a word.
- Build markup with `tag`, `content_tag`, `safe_join` and `pf_attrs_when`; never `html_safe`, `raw`, `safe_concat` or
  `<%==` (a test fails). Keep one `h1` per page and heading levels in order (`html/admin_accessibility_test.rb`).
  `pf_admin.js` uses `const`/`let` and builds no markup from strings.

### Translations

Every user-facing string goes through `t()`. Add each new key to all three locale files (`en`, `sq`, `mk`) under
`config/locales/`, keep keys sorted, and run `bundle exec i18n-tasks health` (no missing and no unused keys). If you do
not speak Albanian or Macedonian, say so in the pull request and we will help.

### Tests

- Use the helpers in `test/test_helper.rb` (`create_user`, `create_permission_set`, `create_resource`, ...).
- Creating a `Resource` row named after a real model mixes masking into that class for the rest of the run: use
  `Customer`, `Supplier` or the dedicated `Pf*` test models, never `User` or `Account`.
- Auditing is on for the whole suite. Never assert an absolute `AuditEvent.count`; use `assert_difference`,
  `assert_audit_event` and `audit_events_for`.
- The configuration is restored from a snapshot before and after every test (`ConfigurationSnapshot`), so a test may
  change an option without restoring it by hand. A new suite-wide setting goes in `test_helper.rb`'s `configure` block.
- Swap a method with `replace_singleton_method` / `replace_method` (`test/support/method_stubs.rb`), never by defining
  over it. No wall-clock `sleep`: use `travel_to`, or wait for a condition.

### Documentation

Every sentence about behaviour needs code behind it. For audit, logging and regulations, say what the gem "supports
evidence for", name the event or feature, and say what the host must add. Never claim compliance or certification.

## Pull requests

Fill in the pull request template. A maintainer reviews every change; security-relevant changes may get a second
review. By contributing, you agree that your work is released under the [MIT License](LICENSE.txt).
