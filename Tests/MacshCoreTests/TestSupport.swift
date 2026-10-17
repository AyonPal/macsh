import Foundation
import XCTest
@testable import MacshCore

/// A stand-in for the rclone binary: a python script that records its arguments and the
/// RCLONE_CONFIG_* environment, answers `obscure`, and (for `serve`) listens on `--addr`.
struct FakeRclone {
    let binary: URL
    let argsFile: URL

    static func make(in dir: URL) throws -> FakeRclone {
        let argsFile = dir.appendingPathComponent("fake-rclone-args.txt")
        let script = """
        #!/usr/bin/env python3
        import os, socket, sys, time
        args = sys.argv[1:]
        if args and args[0] == "obscure":
            print("OBS-" + args[1])
            sys.exit(0)
        if args and args[0] == "reveal":
            if args[1].startswith("OBS-"):
                print(args[1][4:])
                sys.exit(0)
            sys.stderr.write("Failed to reveal: input too short when revealing password\\n")
            sys.exit(1)
        here = os.path.dirname(os.path.abspath(__file__))
        if args and args[0] == "authorize":
            lines = list(args) + ["ENV:RCLONE_DRIVE_SCOPE=" + os.environ.get("RCLONE_DRIVE_SCOPE", "")]
            with open("\(argsFile.path)", "w") as f:
                f.write("\\n".join(lines))
            mode = open(os.path.join(here, "authorize-mode.txt")).read().strip() if os.path.exists(os.path.join(here, "authorize-mode.txt")) else "ok"
            if mode == "fail":
                sys.stderr.write("Failed to authorize: access denied\\n")
                sys.exit(1)
            if mode == "hang":
                import time
                time.sleep(60)
            print("Waiting for code...")
            print("Paste the following into your remote machine --->")
            print('{"access_token":"AT","token_type":"Bearer","refresh_token":"RT","expiry":"2030-01-01T00:00:00Z"}')
            print("<---End paste")
            sys.exit(0)
        lines = list(args)
        # Simulate rclone refreshing an OAuth token: rewrite the --config file like rclone does.
        refresh = os.path.join(here, "refresh-token.txt")
        if "serve" in args and "--config" in args and os.path.exists(refresh):
            with open(args[args.index("--config") + 1], "a") as cf:
                cf.write("token = " + open(refresh).read().strip() + "\\n")
        for k in sorted(os.environ):
            if k.startswith("RCLONE_CONFIG_") or k == "MACSH_TEST_ENV":
                lines.append("ENV:%s=%s" % (k, os.environ[k]))
        with open("\(argsFile.path)", "w") as f:
            f.write("\\n".join(lines))
        if args and args[0] == "lsf":
            mode_file = os.path.join(here, "lsf-mode.txt")
            if os.path.exists(mode_file):
                parts = open(mode_file).read().split("\\n", 1)
                code = int(parts[0])
                if code == 124:
                    time.sleep(60)
                if code != 0:
                    sys.stderr.write(parts[1] if len(parts) > 1 else "")
                    sys.exit(code)
            print("a.txt")
            print("sub/")
            sys.exit(0)
        if "--addr" in args:
            host, port = args[args.index("--addr") + 1].rsplit(":", 1)
            s = socket.socket()
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((host, int(port)))
            s.listen(5)
            while True:
                c, _ = s.accept()
                c.close()
        """
        let url = dir.appendingPathComponent("fake-rclone")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return FakeRclone(binary: url, argsFile: argsFile)
    }

    static func requirePython() throws {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        if !candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            throw XCTSkip("python3 not available")
        }
    }

    /// Lines the fake wrote (args, then ENV:... lines). Waits for the script to start.
    func recordedLines(timeout: TimeInterval = 10) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: argsFile, encoding: .utf8), !text.isEmpty {
                return text.components(separatedBy: "\n")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return []
    }
}

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macsh-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeRemote(
    name: String = "test-remote",
    backend: Backend,
    proto: MountProtocol = .webdav,
    autoMount: Bool = false,
    liveUpdates: Bool = true
) -> Remote {
    Remote(id: UUID(), name: name, backend: backend, mountProtocol: proto,
           autoMount: autoMount, liveUpdates: liveUpdates)
}

func sftpBackend(auth: SFTPAuthKind = .password) -> Backend {
    .sftp(SFTPConfig(host: "example.com", port: 22, user: "alice", remotePath: "/data", authKind: auth))
}

func s3Backend(prefix: String = "pre") -> Backend {
    .s3(S3Config(provider: .aws, region: "us-east-1", endpoint: nil, bucket: "bkt", prefix: prefix))
}

func ftpBackend() -> Backend {
    .ftp(FTPConfig(host: "ftp.example.com", port: 21, user: "bob", remotePath: "/pub", tlsMode: .explicit))
}

func webdavBackend(remotePath: String = "docs") -> Backend {
    .rclone(BackendDescriptor.webdav.makeConfig(
        values: ["url": "https://cloud.example.com/remote.php/dav/files/bob/", "vendor": "nextcloud", "user": "bob", "pass": ""],
        remotePath: remotePath))
}

func driveBackend(remotePath: String = "", clientID: String = "") -> Backend {
    .rclone(BackendDescriptor.googleDrive.makeConfig(
        values: ["scope": "drive", "token": "", "client_id": clientID, "client_secret": ""],
        remotePath: remotePath))
}
