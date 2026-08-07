#!/usr/bin/env python3
"""Simple HTTP server with COOP/COEP headers for SharedArrayBuffer support."""
import http.server
import os

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # NOTE: the wasm build is single-threaded — nothing here uses
        # SharedArrayBuffer/Atomics — so full cross-origin isolation is NOT
        # needed. Sending "COOP: same-origin" actively breaks the Google Drive
        # sign-in popup: it severs the popup<->opener channel GIS uses to hand
        # the token back, so sign-in always reports "cancelled". Use
        # "same-origin-allow-popups" (keeps opener for popups we open) and drop
        # COEP. If a threaded build is ever added, this has to be revisited
        # alongside a non-popup auth flow (see docs on OAuth + COOP).
        self.send_header("Cross-Origin-Opener-Policy", "same-origin-allow-popups")
        # Dev server: forbid browser caching outright. Safari's heuristic
        # cache otherwise keeps long-unchanged files (styles/index) for hours
        # while picking up a freshly rebuilt em.js/em.wasm — mismatched
        # frontend/wasm pairs render wrong. Production sets its own headers.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):
        # Worktree-only: the bench page reports its result by requesting
        # /__benchresult?<payload>, which is how a browser that cannot be
        # driven from the shell (Safari) delivers numbers. Keep the log.
        super().log_message(format, *args)

os.chdir(os.path.dirname(os.path.abspath(__file__)))
httpd = http.server.HTTPServer(("", 8765), Handler)
print("Serving at http://localhost:8765")
httpd.serve_forever()
