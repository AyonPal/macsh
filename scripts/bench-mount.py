#!/usr/bin/env python3
"""Benchmark a mounted macsh remote: listing latency, upload and cold-read throughput.

    scripts/bench-mount.py MOUNTPOINT [--files 3] [--size-mb 50] [--keep] [--json]

Writes N random files into a fresh `macsh-bench-<timestamp>/` folder on the mount, so use a
remote you are happy to write to. Needs only the Python standard library plus the macOS tools
`mount`, `nfsstat` and `nettop`.

* listing: time to list the mount root and the bench folder.
* upload:  the mount acknowledges writes at once (rclone uploads in the background), so the
           time is measured on the wire: rclone's `bytes_out` (nettop) until it goes quiet.
* cold read: the files' cached copies are evicted from rclone's VFS cache, then read back;
           `bytes_in` shows how much really came over the network. A read served from the
           cache is flagged, because it says nothing about the remote.
"""
import argparse
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

MB = 1 << 20
F_NOCACHE = 48          # macOS fcntl: don't keep this file's data in the kernel cache


# ---- pure helpers (unit tested in scripts/tests/test_bench_mount.py) -------------------------

def find_mount(mount_output, mountpoint):
    """(source, fstype) of the mount whose target is `mountpoint`, else None."""
    target = os.path.realpath(mountpoint)
    for line in mount_output.splitlines():
        m = re.match(r"^(.*?) on (.*?) \(([^,)]+)", line)
        if m and os.path.realpath(m.group(2)) == target:
            return m.group(1), m.group(3)
    return None


def server_port(source, fstype, mountpoint, nfsstat_output):
    """Port of the local `rclone serve` behind a mount: from the URL (webdav) or `nfsstat -m`."""
    if fstype == "webdav":
        m = re.match(r"http://127\.0\.0\.1:(\d+)/", source)
        return int(m.group(1)) if m else None
    if fstype == "nfs" and source.startswith("127.0.0.1:"):
        current = None
        target = os.path.realpath(mountpoint)
        for line in nfsstat_output.splitlines():
            if " from " in line:
                current = os.path.realpath(line.split(" from ")[0].strip())
            elif current == target:
                m = re.search(r"(?<![a-z])port=(\d+)", line)
                if m:
                    return int(m.group(1))
    return None


def parse_nettop(output):
    """(bytes_in, bytes_out) from `nettop -P -L 1 -J bytes_in,bytes_out` for one process."""
    for line in reversed(output.strip().splitlines()):
        parts = line.split(",")
        if len(parts) >= 3 and parts[1].isdigit() and parts[2].isdigit():
            return int(parts[1]), int(parts[2])
    raise ValueError("no byte counters in nettop output")


def upload_finished(samples, total_bytes, quiet_samples=4, quiet_bytes=100_000, min_fraction=0.9):
    """True once cumulative `bytes_out` samples show the upload is done: at least
    `min_fraction` of `total_bytes` sent, then `quiet_samples` samples with almost no growth."""
    if len(samples) < quiet_samples + 1 or samples[-1] - samples[0] < total_bytes * min_fraction:
        return False
    tail = samples[-(quiet_samples + 1):]
    return all(b - a < quiet_bytes for a, b in zip(tail, tail[1:]))


def mbps(num_bytes, seconds):
    return (num_bytes / MB) / seconds if seconds > 0 else 0.0


def served_from_cache(size_bytes, bytes_in):
    """A read that pulled less than half the file over the network came from the local cache."""
    return bytes_in < size_bytes * 0.5


def evict_cached_files(cache_roots, folder, names):
    """Delete rclone VFS cache entries (data + metadata) of `folder/names`. Returns the count."""
    removed = 0
    for root in cache_roots:
        for name in names:
            for path in glob.glob(os.path.join(root, "*", folder, name)):
                os.remove(path)
                removed += 1
    return removed


# ---- the benchmark --------------------------------------------------------------------------

def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def net_bytes(pid):
    return parse_nettop(sh("nettop", "-P", "-p", str(pid), "-L", "1", "-J", "bytes_in,bytes_out"))


def timed_listing(path):
    start = time.time()
    os.listdir(path)
    return time.time() - start


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mountpoint")
    ap.add_argument("--files", type=int, default=3)
    ap.add_argument("--size-mb", type=int, default=50)
    ap.add_argument("--keep", action="store_true", help="leave the bench folder on the remote")
    ap.add_argument("--json", action="store_true", help="print results as JSON")
    args = ap.parse_args(argv)

    mount = find_mount(sh("/sbin/mount"), args.mountpoint)
    if not mount:
        sys.exit(f"{args.mountpoint} is not a mount point")
    source, fstype = mount
    port = server_port(source, fstype, args.mountpoint, sh("/usr/bin/nfsstat", "-m"))
    pid = sh("pgrep", "-f", f"rclone serve .*--addr 127.0.0.1:{port}").split()[:1] if port else []
    if not pid:
        sys.exit("this does not look like a macsh mount (no local rclone server found)")
    pid = pid[0]

    folder = f"macsh-bench-{time.strftime('%Y%m%d-%H%M%S')}"
    root = os.path.join(args.mountpoint, folder)
    names = [f"bench_{args.size_mb}MB_{i + 1}.bin" for i in range(args.files)]
    size = args.size_mb * MB
    result = {"mount": args.mountpoint, "fstype": fstype, "port": port, "size_mb": args.size_mb}

    result["list_root_s"] = round(timed_listing(args.mountpoint), 3)
    os.mkdir(root)

    # upload, measured on the wire
    _, out0 = net_bytes(pid)
    start = time.time()
    for name in names:
        with open(os.path.join(root, name), "wb") as f:
            for _ in range(args.size_mb):
                f.write(os.urandom(MB))
    result["write_returned_s"] = round(time.time() - start, 1)
    samples = [out0]
    while time.time() - start < 900:
        time.sleep(2)
        samples.append(net_bytes(pid)[1])
        if upload_finished(samples, size * args.files):
            break
    done = len(samples) - 4                      # the quiet tail is not upload time
    seconds = max(done * 2, 1)
    sent = samples[-1] - samples[0]
    result["upload_mb_s"] = round(mbps(sent, seconds), 1)
    result["upload_sent_mb"] = round(sent / MB)

    result["list_bench_dir_s"] = round(timed_listing(root), 3)

    # cold reads
    caches = [os.path.expanduser("~/Library/Caches/rclone/vfs"), os.path.expanduser("~/Library/Caches/rclone/vfsMeta")]
    result["evicted_cache_entries"] = evict_cached_files(caches, folder, names)
    reads = []
    for name in names:
        in0, _ = net_bytes(pid)
        start = time.time()
        with open(os.path.join(root, name), "rb") as f:
            # Without this the macOS NFS/WebDAV client answers from its own cache after the
            # write, and the read never reaches rclone.
            fcntl.fcntl(f.fileno(), F_NOCACHE, 1)
            while f.read(MB):
                pass
        seconds = time.time() - start
        got = net_bytes(pid)[0] - in0
        reads.append({"file": name, "seconds": round(seconds, 1), "mb_s": round(mbps(size, seconds), 1),
                      "network_mb": round(got / MB), "from_cache": served_from_cache(size, got)})
    result["cold_reads"] = reads

    if not args.keep:
        shutil.rmtree(root, ignore_errors=True)

    if args.json:
        print(json.dumps(result, indent=2))
        return
    print(f"{args.mountpoint}  ({fstype}, rclone port {port})")
    print(f"  list root:      {result['list_root_s']}s   list bench folder: {result['list_bench_dir_s']}s")
    print(f"  upload:         {result['upload_mb_s']} MB/s  ({result['upload_sent_mb']} MB on the wire; "
          f"the mount returned after {result['write_returned_s']}s)")
    for r in reads:
        note = "  <- served from cache, not a network read" if r["from_cache"] else ""
        print(f"  cold read:      {r['file']}  {r['mb_s']} MB/s  ({r['seconds']}s, {r['network_mb']} MB from network){note}")
    if not args.keep:
        print(f"  (removed {folder}/ from the remote)")


if __name__ == "__main__":
    main()
