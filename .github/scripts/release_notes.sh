#!/usr/bin/env bash
# Prints one version's section of CHANGELOG.md: the lines after its
# `## [VERSION]` heading, up to the next `## [` heading (or the link
# definitions at the end of the file), blank lines around it trimmed, without
# the `<!-- pin: test#name -->` comments that tie each bullet to its test (for
# the repository, not the release page). Fails when the section is missing or
# empty, or longer than a GitHub Release body can hold.
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
  found && /^[ \t]*<!-- pin:.*-->[ \t]*$/ { next }
  found { gsub(/[ \t]*<!-- pin:[^>]*-->/, "") }
  found && NF { if (started) for (; blanks > 0; blanks--) print ""; started = 1; blanks = 0; print; next }
  found { blanks++ }
' "$changelog")

# A here-string, not a pipe: grep -q stops at the first match, and under
# pipefail the writer of a long section (over a pipe buffer) would then fail
# with SIGPIPE and the section read as missing.
if ! grep -q '[^[:space:]]' <<<"$notes"; then
  echo "release_notes.sh: $changelog has no section for $version (a \`## [$version]\` heading with text under it)" >&2
  exit 1
fi
# A GitHub Release body holds 125,000 characters; the release job adds a short
# footer (the checksum and how to verify). Bytes count at least as many as
# characters, so this errs on the safe side — before the approval, not after
# the gem is out.
limit=124000
size=$(printf '%s\n' "$notes" | wc -c | tr -d ' ')
if [ "$size" -gt "$limit" ]; then
  echo "release_notes.sh: the $version section is $size bytes; a GitHub Release body takes at most $limit here (125,000 characters with the release footer): shorten it" >&2
  exit 1
fi
printf '%s\n' "$notes"
