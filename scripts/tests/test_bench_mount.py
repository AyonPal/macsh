import importlib.util
import os
import pathlib
import tempfile
import unittest

_spec = importlib.util.spec_from_file_location(
    "bench_mount", pathlib.Path(__file__).resolve().parents[1] / "bench-mount.py")
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)

MOUNT = """\
/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
127.0.0.1:/ on /Users/fco/macsh/DevEnv (nfs, nodev, nosuid, mounted by fco)
http://127.0.0.1:49165/Docs/ on /Volumes/Docs (webdav, nodev, nosuid, mounted by fco)
192.168.1.5:/export on /Users/fco/macsh/Nas (nfs, nodev, nosuid, mounted by fco)
"""

NFSSTAT = """\
/Users/fco/macsh/DevEnv from 127.0.0.1:/
  -s sys
  NFS parameters: vers=3,tcp,port=54924,mountport=54924,soft,noresvport,nolocks
/Users/fco/macsh/Other from 127.0.0.1:/
  NFS parameters: vers=3,tcp,port=55300,mountport=55300,soft
"""


class FindMountTests(unittest.TestCase):
    def test_finds_nfs_and_webdav_mounts(self):
        self.assertEqual(bench.find_mount(MOUNT, "/Users/fco/macsh/DevEnv"), ("127.0.0.1:/", "nfs"))
        self.assertEqual(bench.find_mount(MOUNT, "/Volumes/Docs"),
                         ("http://127.0.0.1:49165/Docs/", "webdav"))

    def test_unknown_path_is_not_a_mount(self):
        self.assertIsNone(bench.find_mount(MOUNT, "/Users/fco/macsh/nope"))
        self.assertIsNone(bench.find_mount(MOUNT, "/Users/fco"))


class ServerPortTests(unittest.TestCase):
    def test_webdav_port_comes_from_the_url(self):
        self.assertEqual(bench.server_port("http://127.0.0.1:49165/Docs/", "webdav", "/Volumes/Docs", ""), 49165)

    def test_nfs_port_comes_from_nfsstat_for_the_right_mount(self):
        self.assertEqual(bench.server_port("127.0.0.1:/", "nfs", "/Users/fco/macsh/DevEnv", NFSSTAT), 54924)
        self.assertEqual(bench.server_port("127.0.0.1:/", "nfs", "/Users/fco/macsh/Other", NFSSTAT), 55300)

    def test_remote_nfs_and_unknown_cases_have_no_port(self):
        self.assertIsNone(bench.server_port("192.168.1.5:/export", "nfs", "/Users/fco/macsh/Nas", NFSSTAT))
        self.assertIsNone(bench.server_port("127.0.0.1:/", "nfs", "/Users/fco/macsh/Missing", NFSSTAT))
        self.assertIsNone(bench.server_port("https://example.com/", "webdav", "/Volumes/x", ""))
        self.assertIsNone(bench.server_port("x", "hfs", "/Volumes/x", ""))


class NettopTests(unittest.TestCase):
    def test_parses_the_counter_row(self):
        out = ",bytes_in,bytes_out,\nrclone.22581,66234,49851,\n"
        self.assertEqual(bench.parse_nettop(out), (66234, 49851))

    def test_rejects_output_without_counters(self):
        for bad in ("", ",bytes_in,bytes_out,\n", "nettop: no such process"):
            with self.assertRaises(ValueError):
                bench.parse_nettop(bad)


class UploadFinishedTests(unittest.TestCase):
    MB = 1 << 20

    def test_not_finished_while_bytes_still_flow(self):
        s = [0, 10 * self.MB, 25 * self.MB, 40 * self.MB, 55 * self.MB]
        self.assertFalse(bench.upload_finished(s, 150 * self.MB))

    def test_finished_after_enough_bytes_and_a_quiet_tail(self):
        s = [0, 50 * self.MB, 100 * self.MB, 150 * self.MB, 150 * self.MB + 10, 150 * self.MB + 20,
             150 * self.MB + 30, 150 * self.MB + 40]
        self.assertTrue(bench.upload_finished(s, 150 * self.MB))

    def test_quiet_but_far_too_little_sent_is_not_finished(self):
        # e.g. write-back has not started yet
        s = [0, 1000, 2000, 3000, 4000, 5000]
        self.assertFalse(bench.upload_finished(s, 150 * self.MB))

    def test_needs_enough_samples(self):
        self.assertFalse(bench.upload_finished([0, 150 * self.MB], 150 * self.MB))


class MathTests(unittest.TestCase):
    def test_mbps(self):
        self.assertAlmostEqual(bench.mbps(50 * (1 << 20), 5), 10.0)
        self.assertEqual(bench.mbps(100, 0), 0.0)

    def test_cache_hits_are_flagged(self):
        size = 50 * (1 << 20)
        self.assertTrue(bench.served_from_cache(size, 0))
        self.assertTrue(bench.served_from_cache(size, size // 4))
        self.assertFalse(bench.served_from_cache(size, size))


class EvictTests(unittest.TestCase):
    def test_removes_only_the_bench_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            vfs, meta = os.path.join(tmp, "vfs"), os.path.join(tmp, "vfsMeta")
            keep = []
            for root in (vfs, meta):
                d = os.path.join(root, "r{abc}", "macsh-bench-1")
                os.makedirs(d)
                for name in ("a.bin", "b.bin", "other.txt"):
                    open(os.path.join(d, name), "w").close()
                keep.append(os.path.join(d, "other.txt"))
                other = os.path.join(root, "r{abc}", "unrelated")
                os.makedirs(other)
                open(os.path.join(other, "a.bin"), "w").close()
                keep.append(os.path.join(other, "a.bin"))
            removed = bench.evict_cached_files([vfs, meta], "macsh-bench-1", ["a.bin", "b.bin"])
            self.assertEqual(removed, 4)
            self.assertTrue(all(os.path.exists(p) for p in keep))

    def test_missing_cache_is_not_an_error(self):
        self.assertEqual(bench.evict_cached_files(["/nonexistent/path"], "f", ["x"]), 0)


if __name__ == "__main__":
    unittest.main()
