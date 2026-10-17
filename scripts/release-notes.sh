#!/usr/bin/env bash
# Prints a markdown bullet list of the commits in (<from-ref>, <to-ref>].
#
# Usage: scripts/release-notes.sh [<from-ref>] [<to-ref>]
#
# If <from-ref> is empty, unknown, or not an ancestor of <to-ref> (e.g. after a
# force-push), falls back to the 20 most recent commits so the notes are never empty.
set -euo pipefail

from="${1:-}"
to="${2:-HEAD}"

if [[ -n "$from" ]] \
    && git cat-file -e "${from}^{commit}" 2>/dev/null \
    && git merge-base --is-ancestor "$from" "$to" 2>/dev/null; then
    range=("${from}..${to}")
else
    range=(-n 20 "$to")
fi

notes="$(git log --no-merges --pretty='- %s (%h)' "${range[@]}")"
if [[ -z "$notes" ]]; then
    notes="- No code changes."
fi
printf '%s\n' "$notes"
