#!/usr/bin/env python3
"""按 routes.json 起一个或多个假引擎。

用法：
  serve_fixtures.py <fixtures_dir> <base_port>     # 目录下每个子目录一个端口
  serve_fixtures.py <single_dir>   <port>          # 目录自己含 routes.json ⇒ 只起一个

目录名以 _ 开头的会被忽略。启动后打印 `ready <port...>` 并常驻服务。
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

target = sys.argv[1]
base_port = int(sys.argv[2])

routes_by_port = {}
if os.path.exists(os.path.join(target, "routes.json")):
    with open(os.path.join(target, "routes.json")) as f:
        routes_by_port[base_port] = json.load(f)
else:
    port = base_port
    for name in sorted(os.listdir(target)):
        d = os.path.join(target, name)
        rp = os.path.join(d, "routes.json")
        if name.startswith("_") or not os.path.exists(rp):
            continue
        with open(rp) as f:
            routes_by_port[port] = json.load(f)
        port += 1


class H(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        routes = getattr(self.server, "routes", {})
        path = self.path.split("?")[0]
        if path not in routes:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(routes[path], ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


for p, routes in routes_by_port.items():
    srv = ThreadingHTTPServer(("127.0.0.1", p), H)
    srv.routes = routes
    threading.Thread(target=srv.serve_forever, daemon=True).start()

print("ready " + " ".join(str(p) for p in sorted(routes_by_port)), flush=True)
threading.Event().wait()