#!/usr/bin/env bash
# Publishes the current commit as a "nightly-YYYYMMDD-<sha>" pre-release with the DMGs in dist/.
#
# Why one release per commit: with GitHub's "immutable releases" a tag name can never be reused,
# so the old "delete and recreate the `nightly` release" approach fails from the second build on.
# Change history is carried forward from the previous nightly's notes, and only the newest
# KEEP_NIGHTLIES (default 1, the newest) release is kept; its notes hold the full history. Deleted
# releases leave their tags behind, which is harmless.
#
# Needs: gh (authenticated via GH_TOKEN), GITHUB_SHA, a full git checkout, dist/*.dmg.
set -euo pipefail

KEEP_NIGHTLIES="${KEEP_NIGHTLIES:-1}"
sha="${GITHUB_SHA:?GITHUB_SHA is required}"
short="${sha:0:7}"
day="$(date -u +%Y-%m-%d)"
tag="nightly-${day//-/}-${short}"

if gh release view "$tag" >/dev/null 2>&1; then
  echo "Release $tag already exists (re-run of the same commit); nothing to publish."
  exit 0
fi

# Newest existing nightly release (by creation time), if any.
nightlies() {
  gh release list --limit 100 --json tagName,createdAt \
    --jq '[.[] | select(.tagName | startswith("nightly-"))] | sort_by(.createdAt) | reverse | .[].tagName'
}
prev_tag="$(nightlies | head -n 1 || true)"

prev_body=""
if [ -n "$prev_tag" ]; then
  prev_body="$(gh release view "$prev_tag" --json body --jq .body 2>/dev/null || true)"
fi
prev_sha="$(printf '%s\n' "$prev_body" | sed -n 's/.*nightly-sha: \([0-9a-f]\{40\}\).*/\1/p' | head -n 1)"
prev_history="$(printf '%s\n' "$prev_body" | sed -n '/<!-- history -->/,$p' | tail -n +2)"
if [ -z "$prev_sha" ]; then
  prev_sha="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
fi

{
  echo "Automated build of \`main\` from ${day}, commit ${short} (${sha}). Unsigned and unstable; use a tagged release unless you want the latest changes."
  echo "<!-- nightly-sha: ${sha} -->"
  echo
  echo "## Changes (newest first)"
  echo "<!-- history -->"
  echo "### ${day} (${short})"
  "$(dirname "$0")/release-notes.sh" "$prev_sha" "$sha"
  if [ -n "$prev_history" ]; then
    echo
    printf '%s\n' "$prev_history"
  fi
} | head -c 100000 > notes.md

# Nightly file names carry the date and commit, not the version of the last release:
# macsh-nightly-<date>-<sha>.dmg, macsh-lite-nightly-<date>-<sha>.dmg.
for f in dist/*.dmg; do
  case "$(basename "$f")" in
    macsh-lite-*) flavor=macsh-lite ;;
    *) flavor=macsh ;;
  esac
  mv "$f" "dist/${flavor}-nightly-${day}-${short}.dmg"
done

gh release create "$tag" dist/*.dmg \
  --target "$sha" \
  --prerelease \
  --title "Nightly" \
  --notes-file notes.md

# Keep only the newest nightlies.
nightlies | tail -n +"$((KEEP_NIGHTLIES + 1))" | while read -r old; do
  [ -n "$old" ] && gh release delete "$old" --yes || true
done
