#!/usr/bin/env python3
"""pvedash web server: serves the dashboard page and stats.json, read-only, to the
local network only. Runs unprivileged."""
import ipaddress
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ["PVEDASH_BIND"]
PORT = int(os.environ["PVEDASH_PORT"])
ALLOWED = [ipaddress.ip_network(n) for n in os.environ["PVEDASH_ALLOW"].split(",")]
STATS = os.environ["PVEDASH_STATS"]
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")


class Handler(BaseHTTPRequestHandler):
    server_version = "pvedash"
    sys_version = ""

    def do_GET(self):
        ip = ipaddress.ip_address(self.client_address[0])
        if not any(ip in n for n in ALLOWED):
            return self.send_error(403)
        # Never answer a request forwarded from a Cloudflare public hostname.
        if any(h.lower().startswith("cf-") for h in self.headers.keys()):
            return self.send_error(403)

        path = self.path.split("?", 1)[0]
        if path == "/stats.json":
            src, ctype = STATS, "application/json"
        elif path in ("/", "/index.html"):
            src, ctype = PAGE, "text/html; charset=utf-8"
        else:
            return self.send_error(404)
        try:
            with open(src, "rb") as f:
                body = f.read()
        except OSError:
            return self.send_error(503, "stats not ready")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
