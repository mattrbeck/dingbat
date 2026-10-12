# python3 -I server.py PORT DIR: serves DIR (page.html, the wasm builds,
# links to the workload files under f/: gs.nds, ss.nds, the states, press
# lists and the BIOS dumps, as page.html names them) and /rusage for ndsrun's host
# counters: the first call of a pair snapshots every Playwright WebKit
# process's instructions and cycles and answers "0 0"; the second answers
# the increase of the process that grew most (the WebContent process
# running the page: other WebKit processes on the machine, other agents'
# included, do not add to it).
import http.server, os, subprocess, sys, threading

HERE = os.path.abspath(sys.argv[2])
RUSAGE = os.environ.get('NDSWASM_RUSAGE', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'rusage'))
lock = threading.Lock()
state = {'snap': None}


def counters():
    pids = subprocess.run(['pgrep', '-f', 'ms-playwright/webkit'], capture_output=True,
                          text=True).stdout.split()
    out = {}
    for p in pids:
        r = subprocess.run([RUSAGE, p], capture_output=True, text=True).stdout.split()
        if len(r) == 2:
            out[p] = (int(r[0]), int(r[1]))
    return out


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=HERE, **k)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def do_GET(self):
        if self.path.startswith('/rusage'):
            with lock:
                now = counters()
                if state['snap'] is None:
                    state['snap'] = now
                    body = b'0 0'
                else:
                    best = (0, 0)
                    for p, (i, c) in now.items():
                        i0, c0 = state['snap'].get(p, (0, 0))
                        if i - i0 > best[0]:
                            best = (i - i0, c - c0)
                    state['snap'] = None
                    body = ('%d %d' % best).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
