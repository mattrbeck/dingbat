#!/usr/bin/env python3
"""Serve web/ for development.

Plain:  python3 web/serve.py                 http://localhost:8765
LAN:    python3 web/serve.py --dev --https --host 0.0.0.0 --port 8443 \\
            --cert CERT.pem --key KEY.pem    (tools/serve_nds_dev.sh does this)

--dev pairs every page with the wasm builds on disk: index.html loads
em.js?v=<em.wasm mtime>, em.js fetches em.wasm with the same stamp, and
window.DINGBAT_ASSET_V carries the DS core's (index.js adds it to
nds/nds.js and nds.wasm). It also serves a sw.js that clears the caches and
unregisters itself, so no service worker left on the origin can hand out a
stale em.js or nds.js. Every response is no-store.
"""
import argparse
import http.server
import os
import ssl

WEB = os.path.dirname(os.path.abspath(__file__))

# A worker that removes itself and every cache the real one filled. It does
# not claim or navigate: a page it was controlling simply ends up
# uncontrolled (index.js reloads once on the controller change).
SELF_DESTRUCT_SW = b"""// web/serve.py --dev: no service worker on a dev origin.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil((async () => {
  for (const key of await caches.keys()) await caches.delete(key);
  await self.registration.unregister();
})()));
"""


def stamp(path):
    try:
        return str(int(os.stat(os.path.join(WEB, path)).st_mtime))
    except OSError:
        return "0"


class Handler(http.server.SimpleHTTPRequestHandler):
    dev = False
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".mjs": "text/javascript",
                      ".webmanifest": "application/manifest+json"}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB, **kwargs)

    def end_headers(self):
        # The wasm build is single-threaded (no SharedArrayBuffer), so no COEP.
        # COOP must stay same-origin-allow-popups: same-origin severs the
        # popup<->opener channel the Google sign-in uses to hand back the token.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin-allow-popups")
        # no-store: Safari's heuristic cache otherwise pairs a stale
        # styles/index with a freshly rebuilt em.js/em.wasm.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_bytes(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def rewritten(self, path):
        """The body of a file --dev rewrites, or None."""
        em, nds = stamp("em.wasm"), stamp("nds/nds.wasm")
        if path in ("/", "/index.html"):
            with open(os.path.join(WEB, "index.html"), "rb") as f:
                html = f.read()
            html = html.replace(b'<script src="em.js"></script>',
                                b'<script src="em.js?v=' + em.encode() + b'"></script>')
            html = html.replace(b'href="em.wasm"', b'href="em.wasm?v=' + em.encode() + b'"')
            tag = ('<script>window.DINGBAT_ASSET_V = {em: "%s", nds: "%s"};</script>'
                   % (em, nds)).encode()
            return html.replace(b"<head>", b"<head>\n    " + tag, 1), "text/html"
        if path == "/em.js":
            with open(os.path.join(WEB, "em.js"), "rb") as f:
                js = f.read()
            return js.replace(b'"em.wasm"', b'"em.wasm?v=' + em.encode() + b'"'), "text/javascript"
        if path == "/sw.js":
            return SELF_DESTRUCT_SW, "text/javascript"
        return None

    def do_GET(self):
        if self.dev:
            path = self.path.split("?", 1)[0]
            try:
                out = self.rewritten(path)
            except OSError:
                out = None
            if out:
                self.send_bytes(*out)
                return
        super().do_GET()

    def do_HEAD(self):
        self.do_GET()

    def log_message(self, format, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--dev", action="store_true", help="stamp the wasm builds, drop any service worker")
    ap.add_argument("--https", action="store_true", help="serve TLS (needs --cert and --key)")
    ap.add_argument("--cert")
    ap.add_argument("--key")
    a = ap.parse_args()
    Handler.dev = a.dev
    httpd = http.server.ThreadingHTTPServer((a.host, a.port), Handler)
    scheme = "http"
    if a.https:
        if not (a.cert and a.key):
            ap.error("--https needs --cert and --key")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(a.cert, a.key)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    print("Serving %s at %s://%s:%d" % (WEB, scheme, a.host or "localhost", a.port))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
