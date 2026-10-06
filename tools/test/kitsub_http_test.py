"""Ответы kit-sub как у nginx (режим --multi-port): python3 tools/test/kitsub_http_test.py"""
import json, os, shutil, socket, ssl, subprocess, sys, tempfile, threading, time, unittest, importlib.util

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
tmp = tempfile.mkdtemp()
cfgp = os.path.join(tmp, "config.json")
json.dump({"listen": "127.0.0.1", "port": 1, "path": "/sub/", "upstream": "http://127.0.0.1:1/"}, open(cfgp, "w"))
os.environ["KIT_SUB_CONFIG"] = cfgp
os.environ["KIT_SUB_RULES"] = os.path.join(tmp, "rules.yaml")
spec = importlib.util.spec_from_file_location("kit_sub", os.path.join(root, "scripts", "kit-sub.py"))
ks = importlib.util.module_from_spec(spec); spec.loader.exec_module(ks)
srv = ks.Server(("127.0.0.1", 0), ks.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()


def raw(data):
    s = socket.create_connection(srv.server_address[:2]); s.settimeout(3); s.sendall(data); out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except socket.timeout:
        out += b"<open>"
    s.close()
    return out.decode(errors="replace")


class Http(unittest.TestCase):
    def test_status_and_server(self):
        r = raw(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        self.assertTrue(r.startswith("HTTP/1.1 404 Not Found\r\n"), r[:40])
        self.assertIn("\r\nServer: nginx\r\n", r)
        self.assertIn("\r\nContent-Length: ", r)

    def test_keep_alive(self):
        r = raw(b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        self.assertEqual(r.count("HTTP/1.1 404 Not Found"), 2)
        self.assertNotIn("<open>", r)

    def test_post_closes(self):
        r = raw(b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
        self.assertTrue(r.startswith("HTTP/1.1 404"))
        self.assertIn("Connection: close", r)
        self.assertNotIn("<open>", r)

    def test_garbage_request_line(self):
        for req in (b"GARBAGE\r\n\r\n", b"GET\r\n\r\n", b"GET / HTTP/1.1 x\r\n\r\n", b"POST /\r\n\r\n"):
            r = raw(req)
            self.assertTrue(r.startswith("HTTP/1.1 400 Bad Request\r\n"), (req, r[:60]))
            self.assertIn("\r\nServer: nginx\r\n", r)
            self.assertIn("Connection: close", r)
            self.assertIn("<center><h1>400 Bad Request</h1></center>", r)
            self.assertNotIn("<open>", r)

    def test_bad_version(self):
        r = raw(b"GET / HTTP/9.9\r\n\r\n")
        self.assertTrue(r.startswith("HTTP/1.1 505"), r[:40])

    def test_connection_header(self):
        r = raw(b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        first, second = r.split("HTTP/1.1 404", 2)[1:]
        self.assertIn("\r\nConnection: keep-alive\r\n", first)
        self.assertIn("\r\nConnection: close\r\n", second)
        self.assertEqual(r.count("Connection:"), 2)

    def test_http10_closes(self):
        r = raw(b"GET / HTTP/1.0\r\n\r\n")
        self.assertTrue(r.startswith("HTTP/1.1 404"))
        self.assertIn("\r\nConnection: close\r\n", r)
        self.assertNotIn("<open>", r)


@unittest.skipUnless(shutil.which("openssl"), "нужен openssl")
class Tls(unittest.TestCase):
    """Свой TLS (--multi-port): ALPN http/1.1, как у nginx без http2."""
    def test_alpn(self):
        d = tempfile.mkdtemp()
        cert, key = os.path.join(d, "c.pem"), os.path.join(d, "k.pem")
        subprocess.run(["openssl", "req", "-x509", "-nodes", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-keyout", key, "-out", cert, "-subj", "/CN=1.2.3.4", "-days", "1"], check=True, capture_output=True)
        s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
        cfg = os.path.join(d, "config.json")
        with open(cfg, "w") as f:
            json.dump({"listen": "127.0.0.1", "port": port, "path": "/sub/", "upstream": "http://127.0.0.1:1/", "cert": cert, "key": key}, f)
        env = dict(os.environ, KIT_SUB_CONFIG=cfg, KIT_SUB_RULES=os.path.join(d, "rules.yaml"))
        env.pop("CREDENTIALS_DIRECTORY", None)
        p = subprocess.Popen([sys.executable, os.path.join(root, "scripts", "kit-sub.py")], env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            for alpn, want in ((["h2", "http/1.1"], "http/1.1"), (["h2"], None)):
                ctx.set_alpn_protocols(alpn)
                for _ in range(50):
                    try:
                        c = socket.create_connection(("127.0.0.1", port), timeout=3)
                        break
                    except OSError:
                        time.sleep(0.1)
                with ctx.wrap_socket(c) as t:
                    self.assertEqual(t.selected_alpn_protocol(), want)
                    t.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                    self.assertTrue(t.recv(64).startswith(b"HTTP/1.1 404"))
        finally:
            p.terminate(); p.wait()


if __name__ == "__main__":
    unittest.main()
