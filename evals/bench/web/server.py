#!/usr/bin/env python3
"""Local web fixtures for the eval. One server per lane (port).

Static pages come from ./static. Everything an agent submits is appended to
<state_dir>/port-<port>.jsonl so checkers can read it:
  POST /api/submit/<form>   form fields (urlencoded or JSON)
  POST /api/upload          multipart file upload (records name, size, sha256)
  GET/POST /api/state/<key> small JSON state (kanban board)
  GET /download/<name>.csv  a CSV download (logged)
  GET /data/<name>.html     pages generated from task data (data/<name>.html in state_dir)
"""
import cgi
import hashlib
import json
import os
import sys
import time
import urllib.parse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")


def make_handler(port, state_dir):
    log_path = os.path.join(state_dir, f"port-{port}.jsonl")
    kv_dir = os.path.join(state_dir, f"kv-{port}")
    data_dir = os.path.join(state_dir, f"data-{port}")
    os.makedirs(kv_dir, exist_ok=True)
    os.makedirs(data_dir, exist_ok=True)

    def log(rec):
        rec["t"] = time.time()
        with open(log_path, "a") as f:
            f.write(json.dumps(rec) + "\n")

    class H(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=STATIC, **kw)

        def log_message(self, fmt, *args):
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def _json(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _html(self, code, html):
            body = html.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            if path.startswith("/api/state/"):
                key = os.path.basename(path)
                p = os.path.join(kv_dir, key + ".json")
                return self._json(200, json.load(open(p)) if os.path.exists(p) else None)
            if path.startswith("/data/"):
                p = os.path.join(data_dir, os.path.basename(path))
                if os.path.exists(p):
                    return self._html(200, open(p).read())
                return self._html(404, "<h1>Not found</h1>")
            if path.startswith("/download/"):
                name = os.path.basename(path)
                p = os.path.join(data_dir, name)
                if not os.path.exists(p):
                    return self._html(404, "<h1>Not found</h1>")
                body = open(p, "rb").read()
                log({"kind": "download", "name": name})
                self.send_response(200)
                self.send_header("Content-Type", "text/csv")
                self.send_header("Content-Disposition", f'attachment; filename="{name}"')
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            return super().do_GET()

        def do_POST(self):
            path = urllib.parse.urlparse(self.path).path
            length = int(self.headers.get("Content-Length") or 0)
            ctype = self.headers.get("Content-Type", "")
            if path == "/api/upload":
                form = cgi.FieldStorage(fp=self.rfile, headers=self.headers,
                                        environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": ctype})
                files = []
                fields = {}
                for k in form.keys():
                    items = form[k] if isinstance(form[k], list) else [form[k]]
                    for it in items:
                        if it.filename:
                            data = it.file.read()
                            files.append({"field": k, "filename": it.filename, "size": len(data),
                                          "sha256": hashlib.sha256(data).hexdigest()})
                        else:
                            fields[k] = it.value
                log({"kind": "upload", "files": files, "fields": fields})
                return self._html(200, "<h1>Upload received</h1><p id='result'>Thanks, we received %d file(s).</p>" % len(files))
            raw = self.rfile.read(length) if length else b""
            if path.startswith("/api/state/"):
                key = os.path.basename(path)
                try:
                    obj = json.loads(raw or b"null")
                except Exception:
                    return self._json(400, {"error": "bad json"})
                json.dump(obj, open(os.path.join(kv_dir, key + ".json"), "w"))
                log({"kind": "state", "key": key, "value": obj})
                return self._json(200, {"ok": True})
            if path.startswith("/api/submit/"):
                form = os.path.basename(path)
                if "json" in ctype:
                    data = json.loads(raw or b"{}")
                else:
                    q = urllib.parse.parse_qs(raw.decode(), keep_blank_values=True)
                    data = {k: (v if len(v) > 1 else v[0]) for k, v in q.items()}
                log({"kind": "submit", "form": form, "data": data})
                if "json" in ctype:
                    return self._json(200, {"ok": True})
                return self._html(200, "<html><head><title>Submitted</title></head><body><h1>Thank you!</h1>"
                                       "<p id='result'>Your submission was received.</p></body></html>")
            return self._json(404, {"error": "not found"})

    return H


def main():
    state_dir = sys.argv[1]
    ports = [int(p) for p in sys.argv[2:]] or [8765]
    os.makedirs(state_dir, exist_ok=True)
    import threading
    servers = []
    for port in ports:
        srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(port, state_dir))
        servers.append(srv)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    print("serving", ports, flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
