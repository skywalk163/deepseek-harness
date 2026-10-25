#!/usr/bin/env python3
"""port_push.py — upload the real port tree to /tmp/dsh-port on the box via SFTP.

Avoids the giant heredoc approach (4.8MB plist inlined into a shell script that
timed out on the exec channel). Uses sftp.put() for each real file and a
stat-free recursive mkdir.

Usage: python port_push.py [--host 192.168.1.5]
"""
import argparse
import errno
import os
import sys
from pathlib import Path

import paramiko

ENV_PATH = Path(__file__).resolve().parent.parent.parent / ".env"
PORT_DIR = Path(__file__).resolve().parent.parent / "devel" / "deepseek-harness"
REMOTE_ROOT = "/tmp/dsh-port/devel/deepseek-harness"

# (local relative path, remote relative path)
FILES = [
    ("Makefile", "Makefile"),
    ("distinfo", "distinfo"),
    ("pkg-descr", "pkg-descr"),
    ("pkg-plist", "pkg-plist"),
    ("files/dsh.in", "files/dsh.in"),
    ("files/dsh_web.in", "files/dsh_web.in"),
    ("files/pkg-message.in", "files/pkg-message.in"),
]


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def makedirs(sftp, path: str) -> None:
    parts = [p for p in path.split("/") if p]
    cur = ""
    for p in parts:
        cur = cur + "/" + p if cur else p
        try:
            sftp.mkdir(cur)
        except IOError as e:
            if getattr(e, "errno", None) == errno.EEXIST:
                pass
            else:
                raise


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=None)
    args = ap.parse_args()

    env = load_env(ENV_PATH)
    host = args.host or env["SSH_HOST"]
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=host,
        username=env["SSH_USER_WORKBUDDY"],
        password=env["SSH_PASS_WORKBUDDY"],
        timeout=20, banner_timeout=30, auth_timeout=30,
        look_for_keys=False, allow_agent=False,
    )
    try:
        # Create the remote tree via the shell (SFTP mkdir is unreliable here).
        client.exec_command(f"rm -rf {REMOTE_ROOT}; mkdir -p {REMOTE_ROOT}/files")
        sftp = client.open_sftp()
        for local_rel, remote_rel in FILES:
            local = PORT_DIR / local_rel
            remote = REMOTE_ROOT + "/" + remote_rel
            sftp.put(str(local), remote)
            if remote_rel.startswith("files/"):
                sftp.chmod(remote, 0o755)
            print(f"put {local_rel} -> {remote} ({local.stat().st_size} bytes)")
        sftp.close()
        print("PORT-PUSH-DONE")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
