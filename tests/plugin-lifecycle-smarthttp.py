#!/usr/bin/env python3
"""Serve throwaway Git repositories through git-http-backend."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class GitHandler(BaseHTTPRequestHandler):
    server: GitHTTPServer

    def serve_git(self, method: str) -> None:
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        environment = os.environ | {
            "GIT_PROJECT_ROOT": str(self.server.project_root),
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": method,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "REMOTE_USER": "",
            "REMOTE_ADDR": "127.0.0.1",
        }
        if length:
            environment["CONTENT_LENGTH"] = str(length)
        git_protocol = self.headers.get("Git-Protocol")
        if git_protocol:
            environment["HTTP_GIT_PROTOCOL"] = git_protocol
        response = subprocess.run(  # noqa: S603 -- Executes Git's resolved HTTP backend, no shell.
            [str(self.server.backend)],
            input=self.rfile.read(length) if length else b"",
            capture_output=True,
            check=False,
            env=environment,
        )
        headers, separator, payload = response.stdout.partition(b"\r\n\r\n")
        if response.returncode or not separator:
            self.send_error(500, "git http-backend failed")
            return
        self.send_response(200)
        for line in headers.split(b"\r\n"):
            if b":" in line:
                key, value = line.split(b":", 1)
                self.send_header(key.decode(), value.decode().strip())
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        self.serve_git("GET")

    def do_POST(self) -> None:
        self.serve_git("POST")

    def log_message(self, _format: str, *args: object) -> None:
        pass


class GitHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    project_root: Path
    backend: Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} PROJECT_ROOT PORT_FILE", file=sys.stderr)
        return 2
    git = shutil.which("git")
    if git is None:
        print("plugin-lifecycle-smarthttp: git is missing from PATH", file=sys.stderr)
        return 127
    backend = (
        Path(
            subprocess.run(  # noqa: S603 -- Reads configuration from the resolved Git executable.
                [git, "--exec-path"],
                capture_output=True,
                check=True,
                text=True,
            ).stdout.strip()
        )
        / "git-http-backend"
    )
    server = GitHTTPServer(("127.0.0.1", 0), GitHandler)
    server.project_root = Path(sys.argv[1]).resolve()
    server.backend = backend
    Path(sys.argv[2]).write_text(f"{server.server_port}\n", encoding="ascii")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
