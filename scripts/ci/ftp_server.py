#!/usr/bin/env python3
"""Plain FTP server for integration tests with a full-permission user (pyftpdlib's CLI
gives `-u` users read-only access). Usage: ftp_server.py PORT USER PASSWORD ROOT_DIR"""
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

port, user, password, root = int(sys.argv[1]), *sys.argv[2:5]
authorizer = DummyAuthorizer()
authorizer.add_user(user, password, root, perm="elradfmwMT")
handler = FTPHandler
handler.authorizer = authorizer
FTPServer(("127.0.0.1", port), handler).serve_forever()
