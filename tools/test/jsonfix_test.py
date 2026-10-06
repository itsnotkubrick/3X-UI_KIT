"""Проверки fix_vless_encryption в kit-sub: python3 tools/test/jsonfix_test.py"""
import json, os, tempfile, unittest, importlib.util

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
tmp = tempfile.mkdtemp()
cfgp = os.path.join(tmp, "config.json")
json.dump({"listen": "127.0.0.1", "port": 1, "path": "/sub/", "upstream": "http://127.0.0.1:1/"}, open(cfgp, "w"))
os.environ["KIT_SUB_CONFIG"] = cfgp
os.environ["KIT_SUB_RULES"] = os.path.join(tmp, "rules.yaml")
spec = importlib.util.spec_from_file_location("kit_sub", os.path.join(root, "scripts", "kit-sub.py"))
ks = importlib.util.module_from_spec(spec); spec.loader.exec_module(ks)


def vnext(**u):
    return {"protocol": "vless", "settings": {"vnext": [{"address": "1.2.3.4", "port": 443, "users": [dict(id="x", **u)]}]}}


def flat(**u):
    return {"protocol": "vless", "settings": dict(address="1.2.3.4", port=443, id="x", **u)}


def run(obj):
    return json.loads(ks.fix_vless_encryption(json.dumps(obj).encode()))


def enc_vnext(o):
    return o["outbounds"][0]["settings"]["vnext"][0]["users"][0].get("encryption")


class Fix(unittest.TestCase):
    def test_vnext(self):
        self.assertEqual(enc_vnext(run({"outbounds": [vnext()]})), "none")
        self.assertEqual(enc_vnext(run({"outbounds": [vnext(encryption="")]})), "none")
        self.assertEqual(enc_vnext(run({"outbounds": [vnext(encryption="none")]})), "none")
        self.assertEqual(enc_vnext(run({"outbounds": [vnext(encryption="mlkem768x25519plus.native.0rtt.abc")]})),
                         "mlkem768x25519plus.native.0rtt.abc")

    def test_flat(self):
        for u, want in (({}, "none"), ({"encryption": ""}, "none"), ({"encryption": "none"}, "none"), ({"encryption": "mlkem.x"}, "mlkem.x")):
            self.assertEqual(run({"outbounds": [flat(**u)]})["outbounds"][0]["settings"]["encryption"], want)

    def test_array_and_many(self):
        r = run([{"outbounds": [vnext(), flat(), vnext(encryption="mlkem.x")]}, {"outbounds": [vnext()]}])
        self.assertEqual(enc_vnext(r[0]), "none")
        self.assertEqual(r[0]["outbounds"][1]["settings"]["encryption"], "none")
        self.assertEqual(r[0]["outbounds"][2]["settings"]["vnext"][0]["users"][0]["encryption"], "mlkem.x")
        self.assertEqual(enc_vnext(r[1]), "none")

    def test_not_vless_untouched(self):
        src = {"outbounds": [{"protocol": "trojan", "settings": {"servers": [{"address": "a", "password": "p"}]}},
                             {"protocol": "freedom", "settings": {}}, {"protocol": "blackhole"},
                             {"protocol": "shadowsocks", "settings": {"id": "x"}}]}
        raw = json.dumps(src).encode()
        self.assertEqual(ks.fix_vless_encryption(raw), raw)

    def test_bytes_as_is(self):
        for raw in (b"", b"not json", b"{broken", b"\xff\xfe\x00", b"123", b"null", b'"s"', b"[1,2]", b'{"outbounds": 5}',
                    b'{"outbounds": [null, 1, {"protocol": "vless", "settings": 3}]}'):
            self.assertEqual(ks.fix_vless_encryption(raw), raw)

    def test_big(self):
        raw = json.dumps({"outbounds": [vnext()], "pad": "a" * (ks.JSON_FIX_MAX + 1)}).encode()
        self.assertEqual(ks.fix_vless_encryption(raw), raw)

    def test_unchanged_is_identical_and_idempotent(self):
        raw = json.dumps({"outbounds": [vnext(encryption="none")]}, indent=2).encode()
        self.assertEqual(ks.fix_vless_encryption(raw), raw)
        once = ks.fix_vless_encryption(json.dumps({"outbounds": [vnext()]}).encode())
        self.assertEqual(ks.fix_vless_encryption(once), once)

    def test_utf8(self):
        out = ks.fix_vless_encryption(json.dumps({"remarks": "Привет", "outbounds": [vnext()]}, ensure_ascii=False).encode())
        self.assertIn("Привет".encode(), out)


if __name__ == "__main__":
    unittest.main()
