# Releasing PermissionForge

For maintainers. A release is published to RubyGems.org by the
[release workflow](.github/workflows/release.yml) when an annotated `vX.Y.Z` tag is pushed. It uses RubyGems.org
[Trusted Publishing](https://guides.rubygems.org/trusted-publishing/): GitHub Actions proves which repository, workflow
and environment it runs in, and RubyGems.org answers with a push key for this gem that expires after 15 minutes. No
RubyGems API key is stored in GitHub or anywhere else.

## Releasing a version

1. **Release pull request.** On a branch, one commit named `Release vX.Y.Z` that sets `VERSION` in
   `lib/permission_forge/version.rb` and turns `## [Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z] - YYYY-MM-DD`
   (with a new empty `## [Unreleased]` above it). Open the pull request against `main` and wait for CI: its `lint` job
   builds and checks the gem exactly as the release does (`.github/scripts/build_gem.sh`).
2. **Squash-merge** it into `main`.
3. **Tag the squash commit** with an annotated tag, from a terminal, and push the tag:

   ```bash
   git switch main && git pull --ff-only
   git log -1 --format='%H %s'    # the squash commit of the Release pull request
   git tag -a vX.Y.Z -m vX.Y.Z    # annotated (-a or -s); a lightweight tag is refused
   git push origin vX.Y.Z
   ```

   Never create the tag from the GitHub Releases page: it can create a lightweight tag, which the workflow refuses,
   and the tag cannot then be moved or deleted. Only a repository admin can create a `v*` tag.
4. **Approve the deployment.** The `build` job checks the tag and builds the gem; the `publish` job then waits for a
   reviewer of the `rubygems` environment. Open the run under **Actions → Release** and, before choosing
   **Review deployments → Approve**, check:

   - the run's commit is the squash commit of the Release pull request on `main`;
   - the run used the workflow file from `main`: `git fetch origin && git diff vX.Y.Z origin/main -- .github/` shows
     nothing, or only changes merged after the release commit (the run's **Workflow file** page shows the file it
     used);
   - the `build` job's summary shows the expected tag, commit, gem name and a SHA-256.

   The job then signs the gem (Sigstore), pushes it, and the version appears on
   https://rubygems.org/gems/permission_forge.

### What protects a release

The workflow's checks catch mistakes; they are not a security boundary. A tag push runs `release.yml` as it is in the
tagged commit, so a tag on another commit could carry a copy of the workflow without them, and RubyGems.org only
matches the repository, the workflow file name and the environment. A release is protected by:

- **who can create a `v*` tag:** repository admins only (ruleset "release tag creation");
- **who can approve the `rubygems` environment:** its required reviewer, with no administrator bypass. That approval
  is the last look at the commit and the workflow file before anything is pushed (the checklist above).

### What the workflow checks

The `build` job runs without any credentials and fails, so that nothing reaches the approval, when:

- the tag is not `v` followed by `PermissionForge::VERSION`;
- the tag is lightweight, or does not point to the commit being built;
- the tagged commit is not on `main`;
- the built gem's name or version is wrong, a file in it is not mode `0644` (the gem is built from files written under
  `umask 022`), its file list differs from the gemspec's (`git ls-files` filtered to `lib/`, `app/`, `config/routes.rb`,
  `config/locales/*.yml`, `LICENSE.txt`, `CHANGELOG.md`, `README.md`), or a tracked file under `lib/` or `app/` is left
  out (`.github/scripts/verify_gem.rb`). CI runs the same build and checks on every pull request.

The `publish` job checks that the file it received is byte for byte the one the `build` job checked (SHA-256), signs
it with `sigstore-cli`, and pushes it with the signature (`gem push --attestation`). RubyGems.org verifies that the
signature was made by this workflow before it accepts the gem. `gem exec sigstore-cli:0.2.3` installs the signer's
dependencies at run time, in the job that can request OIDC tokens; `rubygems/release-gem`, the official action, does
the same. The workflow never creates or pushes a tag or a branch.

### When a run fails

- **Before the approval** (a guard or a check): fix the cause in a new pull request and release the next version
  (`vX.Y.Z+1`). Release tags cannot be moved or deleted (ruleset "release tags", no bypass); only an admin
  temporarily disabling that ruleset could remove one, which is not the way to recover.
- **After the approval** (signing or push, for example a Trusted Publisher that does not match): fix the setting, then
  **Re-run all jobs** on the same run, never "Re-run failed jobs". GitHub allows a re-run for 30 days; the build is
  reproducible, so it builds the same file again and asks for the approval again. There is deliberately no manual
  trigger: a re-run publishes the same tag through the same checks.
- RubyGems.org refuses a version that already exists, so a run cannot publish the same version twice.

## Repository setup

In place on GitHub:

- **Environment `rubygems`** (Settings → Environments): required reviewer `fetijashari`; administrators cannot bypass
  it; deployment branches and tags: tags matching `v*` only; no secrets. "Prevent self-review" is off while there is
  a single maintainer: turn it on once there is a second.
- **Rulesets on `refs/tags/v*`:** "release tags" blocks deletion, update and force-push, with no bypass; "release tag
  creation" blocks creation, with the Repository admin role as the only bypass. They are separate because a bypass
  applies to every rule of its ruleset.
- **Ruleset "main":** pull request required, linear history (squash or rebase), the CI checks required.

The environment must exist before `release.yml` is on `main`: a workflow that names a missing environment creates it,
without any protection.

### One-time step on RubyGems.org (owner)

After the environment above exists, as an owner of the gem:

1. Open https://rubygems.org/gems/permission_forge/trusted_publishers (the "Trusted publishers" link in the gem's
   sidebar) and choose **Create**.
2. Publisher type **GitHub Actions**, with:
   - Repository owner: `fetijashari`
   - Repository name: `permission_forge`
   - Workflow filename: `release.yml`
   - Environment: `rubygems`
   - Workflow repository owner / name: leave empty (the workflow lives in this repository)
3. Optional, once a release went through the workflow: remove any RubyGems API key that was used for pushing this gem.
