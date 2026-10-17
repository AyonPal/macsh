#!/usr/bin/env python3
"""Tiny SFTP server for integration tests: password and public-key auth, serves the real
filesystem as the current user. (macOS PAM refuses throwaway users on CI runners, so we
don't use sshd.)  Usage: sftp_server.py PORT USER PASSWORD HOSTKEY AUTHORIZED_KEYS"""
import asyncio
import sys

import asyncssh

port, user, password, host_key, authorized_keys = int(sys.argv[1]), *sys.argv[2:6]


class Server(asyncssh.SSHServer):
    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, pw):
        return username == user and pw == password

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        if username != user:
            return False
        # Re-read on every attempt: tests append keys while the server runs.
        with open(authorized_keys) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    if asyncssh.import_public_key(line).public_data == key.public_data:
                        return True
                except (asyncssh.KeyImportError, ValueError):
                    continue
        return False


async def main():
    await asyncssh.listen("127.0.0.1", port, server_factory=Server,
                          server_host_keys=[host_key], sftp_factory=True)
    await asyncio.Event().wait()


asyncio.run(main())
