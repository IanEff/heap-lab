#!/usr/bin/env python3
# heap-lab instrument, not Heap: serves the bare repos under /srv/heap-lab-git
# over git's smart HTTP, read-only, so Argo CD in the lab can sync the lab's
# copy of heap-k8s. scripts/argo.sh pushes to it over ssh and installs this as
# heap-lab-git.service on broome.
import http.server
import subprocess
import sys

ROOT = "/srv/heap-lab-git"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8418


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.backend()

    def do_POST(self):
        self.backend()

    def backend(self):
        path, _, query = self.path.partition("?")
        # Fetch only: refuse receive-pack in both its forms.
        if "git-receive-pack" in path or "service=git-receive-pack" in query:
            self.send_error(403)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = {
            "PATH": "/usr/bin:/bin",
            "GIT_PROJECT_ROOT": ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "REQUEST_METHOD": self.command,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_ADDR": self.client_address[0],
        }
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        if self.headers.get("Git-Protocol"):
            env["GIT_PROTOCOL"] = self.headers["Git-Protocol"]
        out = subprocess.run(
            ["git", "http-backend"], input=body, env=env, capture_output=True
        ).stdout
        sep = b"\r\n\r\n" if b"\r\n\r\n" in out else b"\n\n"
        head, _, rest = out.partition(sep)
        status, headers = 200, []
        for line in head.decode("latin-1").splitlines():
            key, _, value = line.partition(":")
            if key.lower() == "status":
                status = int(value.split()[0])
            elif key:
                headers.append((key, value.strip()))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
