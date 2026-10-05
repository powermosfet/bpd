"""REST contract stub used only by the NixOS integration check."""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"mode": "ok", "posts": []}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            payload = json.dumps(state).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/mode":
            with lock:
                state["mode"] = payload["mode"]
            self.send_response(204)
            self.end_headers()
            return
        if self.path != "/api/product":
            self.send_error(404)
            return
        with lock:
            state["posts"].append(payload)
            mode = state["mode"]
        if mode in ("timeout", "slow"):
            time.sleep(12 if mode == "timeout" else 2)
        if mode == "disconnect":
            self.connection.shutdown(2)
            self.connection.close()
            return
        self.send_response(500 if mode == "error" else 201)
        self.end_headers()


ThreadingHTTPServer(("127.0.0.1", 8003), Handler).serve_forever()
