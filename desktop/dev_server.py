"""Runs the Windows/Linux interface in a browser against the real engine, for development
and tests on any machine without Rust: serves desktop/ui and bridges it to `synccli serve`.

    python3 desktop/dev_server.py [port]      then open http://localhost:<port>

POST /cmd  {"id":..,"cmd":..}  -> written to the engine's stdin
GET  /events                   -> the engine's stdout lines, as server-sent events
POST /dialog {"kind": "open"|"save"|"folder", ...} -> a path typed in the terminal (dev only)
"""
import json, os, queue, subprocess, sys, threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.join(HERE, 'ui')
ENGINE = os.environ.get('SYNCO_ENGINE', os.path.join(HERE, '..', 'engine', '.build', 'release', 'synccli'))
proc = subprocess.Popen([ENGINE, 'serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
listeners, lock = [], threading.Lock()
answers = {}   # canned dialog answers for scripted tests: kind -> path

def pump():
    for line in proc.stdout:
        with lock:
            for q in listeners: q.put(line.strip())
threading.Thread(target=pump, daemon=True).start()

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=UI, **k)
    def log_message(self, *a): pass
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def body(self): return json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
    def do_POST(self):
        if self.path == '/cmd':
            proc.stdin.write(json.dumps(self.body()) + '\n'); proc.stdin.flush()
            self.send_response(204); self.end_headers()
        elif self.path == '/dialog':
            req = self.body()
            path = answers.get(req.get('kind'))
            if path is None:
                path = input(f"[{req.get('kind')}] ruta: ").strip() or None
            out = json.dumps({'path': path}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(out)
        elif self.path == '/answers':
            answers.update(self.body()); self.send_response(204); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def do_GET(self):
        if self.path != '/events': return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream'); self.send_header('Cache-Control', 'no-cache'); self.end_headers()
        q = queue.Queue()
        with lock: listeners.append(q)
        try:
            while True:
                self.wfile.write(f"data: {q.get()}\n\n".encode()); self.wfile.flush()
        except Exception:
            with lock: listeners.remove(q)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
print(f"Synco (interfaz de Windows/Linux) en http://localhost:{port}")
ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
