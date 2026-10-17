#!/usr/bin/env bash
# Prints the GitHub release notes for a tagged release: what users get (new features, then
# fixes) from the CHANGELOG.md section of that version, and the commit list folded into a
# collapsed "For developers" block.
#
# Usage: scripts/release-body.sh <tag> [<prev-tag>]     (run from the repo root)
#
# CHANGELOG.md sections up to "### For developers" are shown as-is; "### For developers" goes
# inside the fold. Without a CHANGELOG section the commit list alone is shown.
set -euo pipefail

tag="${1:?tag required}"
prev="${2:-}"
version="${tag#v}"
here="$(dirname "$0")"

section="$(awk -v v="$version" '
  /^## \[/ { if (on) exit; on = index($0, "[" v "]") > 0; next }
  on { print }
' CHANGELOG.md 2>/dev/null || true)"
# Trim leading/trailing blank lines.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

user="$section"
dev=""
if printf '%s\n' "$section" | grep -q '^### For developers'; then
  user="$(printf '%s\n' "$section" | sed '/^### For developers/,$d')"
  dev="$(printf '%s\n' "$section" | sed '1,/^### For developers/d')"
fi

if [ -n "$section" ]; then
  echo "## What's new in ${version}"
  echo
  printf '%s\n' "$user" | sed -e '/./,$!d'
  echo
fi

echo "<details>"
echo "<summary>For developers</summary>"
echo
if [ -n "$dev" ]; then
  printf '%s\n' "$dev" | sed -e '/./,$!d'
  echo
fi
echo "#### Commits${prev:+ since ${prev}}"
echo
"$here/release-notes.sh" "$prev" "$tag"
if [ -n "$prev" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  echo
  echo "**Full diff:** https://github.com/${GITHUB_REPOSITORY}/compare/${prev}...${tag}"
fi
echo
echo "</details>"
