#!/usr/bin/env bash
# Prints one version's section of CHANGELOG.md: the lines after its
# `## [VERSION]` heading, up to the next `## [` heading (or the link
# definitions at the end of the file), blank lines around it trimmed. Fails
# when the section is missing or empty.
#
# The release workflow's `build` job takes the GitHub Release notes from it,
# before the approval (after the push, a missing section could no longer be
# fixed: the tag cannot move); CI's `lint` job runs it for
# PermissionForge::VERSION on every pull request.
#
# Usage: .github/scripts/release_notes.sh VERSION [CHANGELOG.md] > notes.md
set -euo pipefail

version=${1:?usage: release_notes.sh VERSION [CHANGELOG.md]}
changelog=${2:-CHANGELOG.md}

# index() rather than a regex: the dots of a version are literal, and the
# closing bracket keeps 0.14.1 from matching 0.14.10.
notes=$(awk -v head="## [$version]" '
  index($0, "## [") == 1 { if (found) exit; found = (index($0, head) == 1); next }
  found && /^\[[^]]+\]: / { exit }
  found && NF { if (started) for (; blanks > 0; blanks--) print ""; started = 1; blanks = 0; print; next }
  found { blanks++ }
' "$changelog")

if ! printf '%s' "$notes" | grep -q '[^[:space:]]'; then
  echo "release_notes.sh: $changelog has no section for $version (a \`## [$version]\` heading with text under it)" >&2
  exit 1
fi
printf '%s\n' "$notes"
