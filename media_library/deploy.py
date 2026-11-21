#!/usr/bin/env python3
"""One-click build & deploy script for media_library backend and Web SPA."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

import paramiko

REPO_MEDIA_DIR = Path(__file__).resolve().parent
WEB_DIR = REPO_MEDIA_DIR / "web"
WEB_DIST_DIR = WEB_DIR / "dist"
LINUX_BIN_PATH = REPO_MEDIA_DIR / "dist-linux" / "media-library"

REMOTE_BIN = "/opt/media-library/media-library"
REMOTE_BIN_BAK = "/opt/media-library/media-library.bak"
REMOTE_BIN_TMP = "/tmp/media-library.new"
REMOTE_WEB_ROOT = "/opt/media-library/web"
REMOTE_WEB_TAR_TMP = "/tmp/web_dist.tar.gz"
SERVICE_NAME = "media-library"
HEALTH_URL = "http://127.0.0.1:8090/api/v1/health"


def run_local(cmd: list[str] | str, *, cwd: Path, env: dict[str, str] | None = None, shell: bool = False) -> None:
    """Run a local build/test command and abort on failure."""
    print(f"[local] ({cwd}) $ {cmd}")
    proc = subprocess.run(cmd, cwd=str(cwd), env=env, shell=shell, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed with exit code {proc.returncode}: {cmd}")


def build_artifacts(*, build_web: bool, build_backend: bool, proxy: str) -> None:
    """Build Web SPA and cross-compile Linux amd64 static Go binary."""
    if build_web:
        run_local("npm run build", cwd=WEB_DIR, shell=(os.name == "nt"))

    if build_backend:
        run_local(["go", "test", "./..."], cwd=REPO_MEDIA_DIR)
        proxy_url = proxy if "://" in proxy else f"http://{proxy}"
        env = os.environ.copy()
        env.update({
            "HTTP_PROXY": proxy_url,
            "HTTPS_PROXY": proxy_url,
            "CGO_ENABLED": "0",
            "GOOS": "linux",
            "GOARCH": "amd64",
        })
        LINUX_BIN_PATH.parent.mkdir(parents=True, exist_ok=True)
        run_local(
            ["go", "build", "-trimpath", "-ldflags=-s -w", "-o", str(LINUX_BIN_PATH), "./cmd/media-library"],
            cwd=REPO_MEDIA_DIR,
            env=env,
        )


def package_web_dist(tar_path: Path) -> None:
    """Archive media_library/web/dist into web_dist.tar.gz with top-level dist/."""
    if not (WEB_DIST_DIR / "index.html").is_file():
        raise FileNotFoundError(f"Missing Web SPA build output: {WEB_DIST_DIR / 'index.html'}")
    with tarfile.open(tar_path, "w:gz") as tf:
        tf.add(WEB_DIST_DIR, arcname="dist")


def read_credentials(cred_file: Path) -> tuple[str, str, str]:
    """Read (host, username, password) from credential file without echoing secrets."""
    lines = [line.strip() for line in cred_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(lines) < 3:
        raise ValueError(f"Expected 3 non-empty lines (host, user, password) in {cred_file}")
    host = lines[0].split(":")[0].strip()
    user, password = lines[1], lines[2]
    return host, user, password


def open_socks5_ssh(*, host: str, user: str, password: str, proxy: str, port: int = 22) -> paramiko.SSHClient:
    """Connect an SSH client to target host through a local SOCKS5 proxy."""
    proxy_host, proxy_port_str = proxy.rsplit(":", 1)
    sock = socket.create_connection((proxy_host, int(proxy_port_str)), timeout=15)
    try:
        sock.sendall(b"\x05\x01\x00")
        if sock.recv(2) != b"\x05\x00":
            raise RuntimeError("SOCKS5 greeting failed")
        sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(host) + struct.pack("!H", port))
        resp = sock.recv(10)
        if len(resp) < 2 or resp[:2] != b"\x05\x00":
            raise RuntimeError(f"SOCKS5 connect to {host}:{port} failed: {resp!r}")

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(host, port=port, username=user, password=password, sock=sock, timeout=15)
        return client
    except Exception:
        sock.close()
        raise


def exec_remote(client: paramiko.SSHClient, script: str) -> tuple[int, str, str]:
    """Execute a bash command remotely and return (exit_code, stdout, stderr)."""
    _, stdout, stderr = client.exec_command(f"bash -lc {shell_quote(script)}")
    exit_code = stdout.channel.recv_exit_status()
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    return exit_code, out, err


def shell_quote(value: str) -> str:
    """POSIX-single-quote an arbitrary string."""
    return "'" + value.replace("'", "'\"'\"'") + "'"


def deploy_remote(
    client: paramiko.SSHClient,
    *,
    deploy_backend: bool,
    deploy_web: bool,
    local_tar_path: Path | None,
) -> None:
    """Upload artifacts over SFTP, perform atomic remote swap, and verify health."""
    sftp = client.open_sftp()
    try:
        if deploy_backend:
            print(f"[upload] {LINUX_BIN_PATH} -> {REMOTE_BIN_TMP}")
            sftp.put(str(LINUX_BIN_PATH), REMOTE_BIN_TMP)
        if deploy_web:
            assert local_tar_path is not None
            print(f"[upload] {local_tar_path} -> {REMOTE_WEB_TAR_TMP}")
            sftp.put(str(local_tar_path), REMOTE_WEB_TAR_TMP)
    finally:
        sftp.close()

    web_swap_cmd = (
        f"mkdir -p {REMOTE_WEB_ROOT} && "
        f"rm -rf {REMOTE_WEB_ROOT}/dist && "
        f"tar -xzf {REMOTE_WEB_TAR_TMP} -C {REMOTE_WEB_ROOT} && "
        f"rm -f {REMOTE_WEB_TAR_TMP}"
    )

    if deploy_backend:
        cmds = [
            "set -euo pipefail",
            f"chmod +x {REMOTE_BIN_TMP}",
            f"systemctl stop {SERVICE_NAME}",
            f"if [ -f {REMOTE_BIN} ]; then cp {REMOTE_BIN} {REMOTE_BIN_BAK}; fi",
            f"mv {REMOTE_BIN_TMP} {REMOTE_BIN}",
        ]
        if deploy_web:
            cmds.append(web_swap_cmd)
        cmds.append(f"systemctl start {SERVICE_NAME}")
    else:
        cmds = ["set -euo pipefail", web_swap_cmd]

    code, out, err = exec_remote(client, "\n".join(cmds))
    if out.strip():
        print(out.strip())
    if code != 0:
        raise RuntimeError(f"Remote swap failed (exit {code}): {err.strip()}")

    code, active_out, active_err = exec_remote(client, f"systemctl is-active {SERVICE_NAME}")
    active_state = active_out.strip()
    print(f"[verify] systemctl is-active {SERVICE_NAME}: {active_state}")
    if code != 0 or active_state != "active":
        _, log_out, _ = exec_remote(client, f"journalctl -u {SERVICE_NAME} -n 30 --no-pager")
        raise RuntimeError(
            f"Service {SERVICE_NAME} not active ({active_state}): {active_err.strip()}\n{log_out}"
        )

    health_body = ""
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        h_code, h_out, _ = exec_remote(client, f"curl -sf {HEALTH_URL}")
        if h_code == 0 and '"status":"ok"' in h_out:
            health_body = h_out.strip()
            break
        time.sleep(0.5)
    if not health_body:
        _, log_out, _ = exec_remote(client, f"journalctl -u {SERVICE_NAME} -n 30 --no-pager")
        raise RuntimeError(f"Health check did not return status ok within 10s.\n{log_out}")
    print(f"[verify] health: {health_body}")

    _, js_out, _ = exec_remote(
        client,
        r"curl -s http://127.0.0.1:8090/ | grep -o 'index-[A-Za-z0-9_-]*\.js' | head -n 1",
    )
    print(f"[verify] web bundle: {js_out.strip()}")

    _, journal_out, _ = exec_remote(client, f"journalctl -u {SERVICE_NAME} -n 20 --no-pager")
    print("[verify] journalctl -n 20:")
    print(journal_out.rstrip())


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build and deploy media_library to play.ttai.net")
    parser.add_argument("--skip-build", action="store_true", help="Skip local npm/go build and upload existing artifacts")
    parser.add_argument("--web-only", action="store_true", help="Deploy only media_library/web/dist (no service restart)")
    parser.add_argument("--backend-only", action="store_true", help="Deploy only Linux Go binary")
    parser.add_argument("--cred-file", default=r"E:\SSH\47.76.108.192.txt", help="Path to SSH credential file")
    parser.add_argument("--proxy", default="127.0.0.1:7897", help="Local SOCKS5/HTTP proxy host:port")
    args = parser.parse_args(argv)
    if args.web_only and args.backend_only:
        parser.error("--web-only and --backend-only are mutually exclusive")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    include_web = not args.backend_only
    include_backend = not args.web_only

    if not args.skip_build:
        build_artifacts(build_web=include_web, build_backend=include_backend, proxy=args.proxy)

    if include_backend and not LINUX_BIN_PATH.is_file():
        raise FileNotFoundError(f"Missing Linux binary: {LINUX_BIN_PATH}")

    host, user, password = read_credentials(Path(args.cred_file))
    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    tar_path: Path | None = None
    client: paramiko.SSHClient | None = None
    try:
        if include_web:
            temp_dir = tempfile.TemporaryDirectory()
            tar_path = Path(temp_dir.name) / "web_dist.tar.gz"
            package_web_dist(tar_path)

        print(f"[ssh] connecting to {host}:22 via SOCKS5 {args.proxy}")
        client = open_socks5_ssh(host=host, user=user, password=password, proxy=args.proxy)
        deploy_remote(
            client,
            deploy_backend=include_backend,
            deploy_web=include_web,
            local_tar_path=tar_path,
        )
        print("[done] Deployment succeeded.")
        return 0
    finally:
        if client is not None:
            client.close()
        if temp_dir is not None:
            temp_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
