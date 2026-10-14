## What and why

<!-- What does this change, and why? For a fix: the input that failed, the cause, the fix. Link the issue. -->

## Checklist

- [ ] A test that failed before this change and passes after it
- [ ] `bin/ci` passes (or: the suite, `bundle exec rubocop --parallel`, `bundle exec reek app lib`)
- [ ] Holds on the shipped defaults; if a generator, default, boot step or the cache path changed, the fresh-install
      tests pass
- [ ] CHANGELOG entry under `## [Unreleased]` (a changed default under **Changed**, with its opt-out)
- [ ] Docs in `docs/` updated; every new sentence about behaviour matches the code
- [ ] New UI strings in all three locales (`en`, `sq`, `mk`), `bundle exec i18n-tasks health` clean
- [ ] No change to the permission hash format; no callback-skipping writes on the permission models

<!-- Security vulnerabilities: do not open a pull request. See SECURITY.md. -->
