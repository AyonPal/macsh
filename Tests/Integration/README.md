# Integration tests

Per Phase 1, the integration test uses the host Mac's own `sshd` (Remote Login)
as the SFTP target — no Docker, no remote servers, nothing leaves the machine.

Run `./sftp_mount_test.sh` from a Mac with the macsh app built and Remote Login
enabled. Follow on-screen steps; the script just sets up a fixture directory and
walks you through the manual mount/read/write/unmount roundtrip.

A future Docker-based fixture for headless CI is deferred to Phase 2.
