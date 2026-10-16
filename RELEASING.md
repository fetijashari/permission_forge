# Releasing PermissionForge

For maintainers. A release is published to RubyGems.org by the
[release workflow](.github/workflows/release.yml) when an annotated `vX.Y.Z` tag is pushed. It uses RubyGems.org
[Trusted Publishing](https://guides.rubygems.org/trusted-publishing/): GitHub Actions proves which repository, workflow
and environment it runs in, and RubyGems.org answers with a push key for this gem that expires after 15 minutes. No
RubyGems API key is stored in GitHub or anywhere else.

## What a release produces

- **The gem on RubyGems.org**, `permission_forge-X.Y.Z.gem`, pushed with its Sigstore signature
  (`gem push --attestation`): RubyGems.org verifies that this workflow signed it before accepting it, and serves it
  at `https://rubygems.org/api/v1/attestations/permission_forge-X.Y.Z.json`.
- **A build provenance attestation** (GitHub artifact attestation, SLSA provenance v1, signed through Sigstore) for the
  same file: it names the repository, `release.yml`, the tag and the commit. GitHub keeps it with the repository's
  attestations (`https://github.com/fetijashari/permission_forge/attestations`).
- **A GitHub Release** for the tag, titled `vX.Y.Z`, whose notes are that version's `CHANGELOG.md` section (taken by
  the `build` job, before the approval) followed by the gem's SHA-256. Attached:

  | File | What it is |
  |---|---|
  | `permission_forge-X.Y.Z.gem` | the file pushed to RubyGems.org, byte for byte |
  | `permission_forge-X.Y.Z.gem.sigstore.json` | its Sigstore bundle, the one RubyGems.org verified |
  | `permission_forge-X.Y.Z.gem.intoto.jsonl` | its build provenance attestation (a Sigstore bundle, one JSON line) |

  It is marked Latest only when it is the highest version released; a version with letters (`1.0.0.rc1`) is a
  prerelease. OpenSSF Scorecard's Signed-Releases check reads these file names (`*.sigstore.json` as a signature,
  `*.intoto.jsonl` as provenance).

## Verifying a release

With the GitHub CLI and the gem from either place (`gem fetch permission_forge -v X.Y.Z`, or
`gh release download vX.Y.Z -R fetijashari/permission_forge`):

```bash
sha256sum permission_forge-X.Y.Z.gem   # macOS: shasum -a 256; the SHA-256 in the release notes

# Build provenance. Without --bundle, gh reads GitHub's attestation store and needs
# `gh auth login`; with --bundle permission_forge-X.Y.Z.gem.intoto.jsonl it uses the attached file.
gh attestation verify permission_forge-X.Y.Z.gem --repo fetijashari/permission_forge \
  --signer-workflow fetijashari/permission_forge/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z

# Sigstore signature (the bundle RubyGems.org verified at push)
gem exec sigstore-cli:0.2.3 verify permission_forge-X.Y.Z.gem \
  --bundle permission_forge-X.Y.Z.gem.sigstore.json \
  --certificate-identity https://github.com/fetijashari/permission_forge/.github/workflows/release.yml@refs/tags/vX.Y.Z \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Both `verify` commands fail unless the file was signed by `release.yml` running for that tag in this repository.
Versions released before this workflow created GitHub Releases (0.14.1 and earlier) have no signature, attestation or
GitHub Release.

## Releasing a version

1. **Release pull request.** On a branch, one commit named `Release vX.Y.Z` that sets `VERSION` in
   `lib/permission_forge/version.rb` and turns `## [Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z] - YYYY-MM-DD`
   (with a new empty `## [Unreleased]` above it). Open the pull request against `main` and wait for CI: its `lint` job
   builds and checks the gem exactly as the release does (`.github/scripts/build_gem.sh`).
2. **Squash-merge** it into `main` once the other maintainer has approved it (every pull request needs one approval
   after its last push, from someone other than its author; nobody can bypass it).
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
   reviewer of the `rubygems` environment other than the person who pushed the tag ("prevent self-review"), so a
   release always takes two people. The reviewer opens the run under **Actions → Release** and, before choosing
   **Review deployments → Approve**, checks:

   - the run's commit is the squash commit of the Release pull request on `main`;
   - the run used the workflow file from `main`: `git fetch origin && git diff vX.Y.Z origin/main -- .github/` shows
     nothing, or only changes merged after the release commit (the run's **Workflow file** page shows the file it
     used);
   - the `build` job's summary shows the expected tag, commit, gem name and a SHA-256.

   The job then signs the gem (Sigstore), pushes it, and the version appears on
   https://rubygems.org/gems/permission_forge. With no further approval, the `provenance` job attests the gem and
   the `github-release` job creates the GitHub Release (https://github.com/fetijashari/permission_forge/releases).

### What protects a release

The workflow's checks catch mistakes; they are not a security boundary. A tag push runs `release.yml` as it is in the
tagged commit, so a tag on another commit could carry a copy of the workflow without them, and RubyGems.org only
matches the repository, the workflow file name and the environment. A release is protected by:

- **who can create a `v*` tag:** repository admins only (ruleset "release tag creation");
- **who can approve the `rubygems` environment:** one of its required reviewers who did not push the tag, with no
  administrator bypass. That approval is the last look at the commit and the workflow file before anything is pushed (the checklist above).

### What the workflow checks

The `build` job runs without any credentials and fails, so that nothing reaches the approval, when:

- the tag is not `v` followed by `PermissionForge::VERSION`;
- the tag is lightweight, or does not point to the commit being built;
- the tagged commit is not on `main`;
- `CHANGELOG.md` has no section for the version (`.github/scripts/release_notes.sh`, which also gives the GitHub
  Release its notes; CI's `lint` job runs it for `PermissionForge::VERSION` on every pull request);
- the built gem's name or version is wrong, a file in it is not mode `0644` (the gem is built from files written under
  `umask 022`), its file list differs from the gemspec's (`git ls-files` filtered to `lib/`, `app/`, `config/routes.rb`,
  `config/locales/*.yml`, `LICENSE.txt`, `CHANGELOG.md`, `README.md`), or a tracked file under `lib/` or `app/` is left
  out (`.github/scripts/verify_gem.rb`). CI runs the same build and checks on every pull request.

The `publish` job checks that the file it received is byte for byte the one the `build` job checked (SHA-256), signs
it with `sigstore-cli`, and pushes it with the signature (`gem push --attestation`). RubyGems.org verifies that the
signature was made by this workflow before it accepts the gem. `gem exec sigstore-cli:0.2.3` installs the signer's
dependencies at run time, in the job that can request OIDC tokens; `rubygems/release-gem`, the official action, does
the same. It also hands the signature bundle to the jobs below (as a workflow artifact) before pushing.

After the push, two jobs run without an approval and without checking out the repository:

- `provenance` (`contents: read`, `id-token: write`, `attestations: write`) checks the gem's SHA-256 again and records
  the build provenance attestation (`actions/attest`). It is not in the `rubygems` environment, so RubyGems.org would
  not accept its OIDC token.
- `github-release` (`contents: write`, the only job that has it) checks the gem's SHA-256 again, that the Sigstore
  bundle declares that digest (RubyGems.org verified the signature itself at the push) and that the provenance
  attestation verifies (`gh attestation verify`), adds the checksum to the notes the `build` job took, and runs
  `gh release create vX.Y.Z --verify-tag`: it refuses to run when the tag does not exist, and the token cannot create
  a `v*` tag anyway (ruleset "release tag creation").

The workflow never creates or pushes a tag or a branch.

### When a run fails

- **Before the approval** (a guard or a check): fix the cause in a new pull request and release the next version
  (`vX.Y.Z+1`). Release tags cannot be moved or deleted (ruleset "release tags", no bypass); only an admin
  temporarily disabling that ruleset could remove one, which is not the way to recover.
- **After the approval** (signing or push, for example a Trusted Publisher that does not match): fix the setting, then
  **Re-run all jobs** on the same run, never "Re-run failed jobs". GitHub allows a re-run for 30 days; the build is
  reproducible, so it builds the same file again and asks for the approval again. There is deliberately no manual
  trigger: a re-run publishes the same tag through the same checks.
- RubyGems.org refuses a version that already exists, so a run cannot publish the same version twice.
- **After the push** (`provenance` or `github-release` failed; the gem is on RubyGems.org): use **Re-run failed jobs**,
  the one case where "Re-run all jobs" is wrong (it would build again and stop at the push, as the version exists). A
  re-run of `github-release` finds the release it created and replaces its files (`gh release upload --clobber`). If
  the job cannot succeed for that tag (the workflow file is the tagged one), create the release by hand from the run's
  artifacts:

  ```bash
  # one artifact per command: given several names, gh puts each in its own directory
  for artifact in gem sigstore-bundle provenance release-notes; do
    gh run download <run-id> -R fetijashari/permission_forge -n "$artifact"
  done
  gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file release-notes.md -R fetijashari/permission_forge \
    permission_forge-X.Y.Z.gem permission_forge-X.Y.Z.gem.sigstore.json permission_forge-X.Y.Z.gem.intoto.jsonl
  ```

  (without the provenance file if `provenance` is the job that failed).

## Repository setup

In place on GitHub:

- **Environment `rubygems`** (Settings → Environments): required reviewers `fetijashari`, `abytyqi` and `robkurti`,
  "prevent self-review" on (the person who pushed the tag cannot approve its deployment); administrators cannot bypass it;
  deployment branches and tags: tags matching `v*` only; no secrets.
- **Rulesets on `refs/tags/v*`:** "release tags" blocks deletion, update and force-push, with no bypass; "release tag
  creation" blocks creation, with the Repository admin role as the only bypass. They are separate because a bypass
  applies to every rule of its ruleset.
- **Ruleset "main"**, with no bypass: pull request with one approval (a code owner, `.github/CODEOWNERS`; given after
  the last push; stale approvals dismissed; review threads resolved), squash merges only (linear history, signed
  commits: GitHub signs the squash commit), the CI checks required, and no open CodeQL alert of severity error or
  high security severity. Merge commits and rebase merges are off in the repository settings too.
- **Actions:** every action pinned to a full commit SHA (enforced), default `GITHUB_TOKEN` read-only, workflows from
  forks wait for an approval for every outside contributor.
- **Releases** need no setting. `gh release create` uploads the files to a draft and publishes it afterwards, so it
  also works with "Immutable releases" turned on; a published immutable release's files cannot be replaced by a
  re-run, which is only needed when the release was not published.

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
