#!/usr/bin/env bash
# Builds pkg/permission_forge-<VERSION>.gem the way a release is built, then
# checks it (.github/scripts/verify_gem.rb). Used by the release workflow and by
# CI, so a pull request fails before a tag exists. Run from the repository root.
set -euo pipefail

# The gem keeps each file's mode on disk, so the tracked files are written
# again under umask 022 (0644, 0755 for executables). That would drop unstaged
# edits in a working copy, so it refuses to run with any.
if ! git diff --quiet; then
  echo "build_gem.sh: unstaged changes; commit or stash them first" >&2
  exit 1
fi
umask 022
git ls-files -z | xargs -0 rm -f
git checkout-index --all --force

version=$(ruby -e 'require "./lib/permission_forge/version"; print PermissionForge::VERSION')
gem="pkg/permission_forge-$version.gem"
mkdir -p pkg
gem build --strict permission_forge.gemspec --output "$gem"
ruby .github/scripts/verify_gem.rb "$gem" "$version"
