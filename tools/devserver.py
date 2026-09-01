#!/usr/bin/env python3
"""検証用の PostgREST 互換ミニサーバ。ローカルPGに psql 経由で問い合わせる。
プロジェクトのファイルは書き換えず、config.js と index.html の CSP だけ
配信時に差し替える。"""
import http.server, json, re, subprocess, urllib.parse, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PSQL = ["psql", "-h", "127.0.0.1", "-p", "55432", "-U", "postgres", "-d", "camp", "-tA", "-q"]
PORT = 8777

def q(sql):
    p = subprocess.run(PSQL + ["-c", sql], capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()

def rows_json(sql_body):
    code, out, err = q("select coalesce(json_agg(t),'[]'::json) from (%s) t;" % sql_body)
    if code != 0:
        return None, err
    return out or "[]", None

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=ROOT, **k)

    def log_message(self, *a): pass

    def _send(self, status, body, ctype="application/json"):
        b = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "Date, Content-Range")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/rest/v1/"):
            t = path[len("/rest/v1/"):]
            table = {"rooms": "select id,name,sort_order from rooms order by sort_order",
                     "slots": "select start_at,session_date from slots order by start_at",
                     "reservations": "select id,room_id,start_at,group_name from reservations"}.get(t)
            if not table:
                return self._send(404, json.dumps({"message": "no table"}))
            out, err = rows_json(table)
            if err: return self._send(500, json.dumps({"message": "NETWORK"}))
            return self._send(200, out)

        # 配信時のみ差し替える（プロジェクトのファイルは無変更）
        if path in ("/", "/index.html"):
            html = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
            # connect-src の中身は本番の Supabase ホストなので、宛先を問わず
            # 'self' に潰す（プレースホルダ固定で置換すると実URLを書いた後に効かなくなる）。
            html = re.sub(r"connect-src https://[^;\"]+", "connect-src 'self'", html, count=1)
            return self._send(200, html, "text/html; charset=utf-8")
        if path == "/config.js":
            return self._send(200,
                "window.CONFIG={SUPABASE_URL:'http://127.0.0.1:%d',SUPABASE_ANON_KEY:'test',"
                "CAMP_NAME:'サークル合宿 2026'};" % PORT, "application/javascript; charset=utf-8")
        return super().do_GET()

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        args = json.loads(self.rfile.read(n) or "{}")
        def lit(v):
            if v is None: return "null"
            return "'" + str(v).replace("'", "''") + "'"
        if path.endswith("/rpc/create_reservation"):
            sql = "select create_reservation(%s::smallint,%s::timestamptz,%s,%s)" % (
                lit(args.get("p_room_id")), lit(args.get("p_start_at")),
                lit(args.get("p_group_name")), lit(args.get("p_pin")))
        elif path.endswith("/rpc/cancel_reservation"):
            sql = "select cancel_reservation(%s::uuid,%s)" % (lit(args.get("p_id")), lit(args.get("p_pin")))
        else:
            return self._send(404, json.dumps({"message": "no rpc"}))
        code, out, err = q(sql)
        if code != 0 or err:
            msg = err.split("\n")[0].replace("ERROR:  ", "").strip() or "NETWORK"
            return self._send(400, json.dumps({"code": "P0001", "message": msg,
                                               "details": None, "hint": None}))
        return self._send(200, json.dumps(out))

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
