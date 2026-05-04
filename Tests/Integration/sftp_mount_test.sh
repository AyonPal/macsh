#!/usr/bin/env bash
# Manual integration test: prove macsh can mount the host's own sshd as a WebDAV volume.
#
# This script uses LOCALHOST sshd (no Docker, nothing leaves the machine).
# Run on the Mac the macsh app is built on.
#
# Prerequisites:
#   1. "Remote Login" enabled in System Settings → General → Sharing.
#      (Equivalent to: sudo systemsetup -setremotelogin on)
#   2. Your account password handy (or an SSH key in ~/.ssh/).
#   3. macsh.app built and runnable from Xcode.
set -euo pipefail

cd "$(dirname "$0")"

FIXTURE_DIR="$HOME/macsh-sftp-fixture"
mkdir -p "$FIXTURE_DIR"
echo "phase1-roundtrip-marker $(date -u +%FT%TZ)" > "$FIXTURE_DIR/marker.txt"

echo
echo "=== macsh Phase 1 manual integration test ==="
echo
echo "Fixture directory:  $FIXTURE_DIR"
echo "Local sshd port:    22 (verify: 'sudo systemsetup -getremotelogin')"
echo "Local user:         $USER"
echo
echo "1. In macsh, click 'Add remote…' and enter:"
echo "     Display name : phase1-test"
echo "     Host         : 127.0.0.1"
echo "     Port         : 22"
echo "     User         : $USER"
echo "     Auth         : Password (or Key file ~/.ssh/id_*)"
echo "     Remote path  : $FIXTURE_DIR"
echo "     Auto-mount   : off (we trigger manually)"
echo
echo "2. Click 'Save', then click the new remote in the menu to mount."
echo "   Status dot should go ◐ → ●."
echo
echo "3. Verify:"
echo "     ls /Volumes/phase1-test"
echo "     # expect: marker.txt"
echo "     cat /Volumes/phase1-test/marker.txt"
echo "     # expect: matches $FIXTURE_DIR/marker.txt"
echo
echo "4. Round-trip write:"
echo "     echo 'from-finder' > /Volumes/phase1-test/finder-write.txt"
echo "     cat $FIXTURE_DIR/finder-write.txt"
echo "     # expect: 'from-finder'"
echo
echo "5. Click the remote again in the menu to unmount."
echo "   Status dot returns to ○. /Volumes/phase1-test disappears."
echo
echo "6. Cleanup (optional): rm -rf $FIXTURE_DIR"
echo
read -r -p "Press enter when done..."
