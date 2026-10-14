# Releasing PermissionForge

For maintainers. A release is published to RubyGems.org by the
[release workflow](.github/workflows/release.yml) when an annotated `vX.Y.Z` tag is pushed. It uses RubyGems.org
[Trusted Publishing](https://guides.rubygems.org/trusted-publishing/): GitHub Actions proves which repository, workflow
and environment it runs in, and RubyGems.org answers with a push key that is valid for a few minutes. No RubyGems API
key is stored in GitHub or anywhere else.

## Releasing a version

1. **Release pull request.** On a branch, one commit named `Release vX.Y.Z` that sets `VERSION` in
   `lib/permission_forge/version.rb` and turns `## [Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z] - YYYY-MM-DD`
   (with a new empty `## [Unreleased]` above it). Open the pull request against `main` and wait for CI.
2. **Squash-merge** it into `main`.
3. **Tag the squash commit** with an annotated tag and push the tag:

   ```bash
   git switch main && git pull --ff-only
   git tag -a vX.Y.Z -m vX.Y.Z   # annotated: -a (or -s); a lightweight tag is refused
   git push origin vX.Y.Z
   ```

   Tags matching `v*` cannot be moved or deleted once pushed (the "release tags" ruleset), so check the commit first.
4. **Approve the deployment.** The workflow's `build` job checks the tag and builds the gem (below). The `publish` job
   then waits for a reviewer of the `rubygems` environment: open the run under **Actions → Release** and choose
   **Review deployments → Approve**. It signs the gem (Sigstore), pushes it, and the version appears on
   https://rubygems.org/gems/permission_forge.

### What the workflow checks before publishing

The `build` job runs without any credentials and fails, so that nothing reaches the approval, when:

- the tag is not `v` followed by `PermissionForge::VERSION`;
- the tag is lightweight, or does not point to the commit being built;
- the tagged commit is not on `main`;
- the built gem's name or version is wrong, a file in it is not mode `0644` (the gem is built from files written under
  `umask 022`), its file list differs from the gemspec's (`git ls-files` filtered to `lib/`, `app/`, `config/routes.rb`,
  `config/locales/*.yml`, `LICENSE.txt`, `CHANGELOG.md`, `README.md`), or a tracked file under `lib/` or `app/` is left
  out (`.github/scripts/verify_gem.rb`).

The `publish` job checks that the file it received is byte for byte the one the `build` job checked (SHA-256), signs
it with `sigstore-cli`, and pushes it with the signature (`gem push --attestation`). RubyGems.org verifies that the
signature was made by this workflow before it accepts the gem. The workflow never creates or pushes a tag or a branch.

### When a run fails

- **Before the approval** (a guard or a check): fix the cause in a new pull request. The tag cannot be moved, so a
  wrong tag means releasing the next version (`vX.Y.Z+1`) instead.
- **After the approval** (signing or push, for example a Trusted Publisher that does not match): fix the setting below,
  then **Re-run all jobs** on the same run (GitHub allows it for 30 days; the build is reproducible, so it builds the
  same file again and asks for the approval again). There is deliberately no manual trigger: a re-run publishes the
  same tag through the same checks.
- RubyGems.org refuses a version that already exists, so a run cannot publish the same version twice.

## One-time setup (owner)

Done once, by hand, before the first release through the workflow. Both values must match the workflow exactly.

**On RubyGems.org** (as an owner of the gem):

1. Open https://rubygems.org/gems/permission_forge and choose **Trusted publishers** in the sidebar (or go to
   https://rubygems.org/gems/permission_forge/trusted_publishers).
2. **Create**, publisher type **GitHub Actions**, with:
   - Repository owner: `fetijashari`
   - Repository name: `permission_forge`
   - Workflow filename: `release.yml`
   - Environment: `rubygems`
   - Workflow repository owner / name: leave empty (the workflow lives in this repository)
3. Optional, once a release went through the workflow: remove any RubyGems API key that was used for pushing this gem.

**On GitHub** (repository **Settings → Environments**):

1. **New environment** named `rubygems`.
2. **Required reviewers**: add the maintainers who approve releases (yourself at least). Leave **Prevent self-review**
   off if you are the only maintainer, or no one can approve your own tag.
3. **Deployment branches and tags** → **Selected branches and tags** → **Add deployment branch or tag rule** → type
   **Tag**, pattern `v*`. Only a run for a `v*` tag can then use the environment.
4. Add no secrets to the environment: the workflow needs none.
