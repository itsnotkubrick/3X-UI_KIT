"""Ответы kit-sub как у nginx (режим --multi-port): python3 tools/test/kitsub_http_test.py"""
import json, os, socket, tempfile, threading, unittest, importlib.util

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


if __name__ == "__main__":
    unittest.main()
