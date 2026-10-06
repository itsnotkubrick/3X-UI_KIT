"""Проверки портов подключений в kit.sh (inbound_listens, inbounds_down, xray_heal): TCP и UDP отдельно,
перезапуск ядра только если правка закрыла порт. python3 tools/test/kit_ports_test.py"""
import json, os, re, subprocess, tempfile, unittest

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(os.path.join(root, "scripts", "kit.sh"), encoding="utf-8").read()
funcs = "".join(re.search(r"^%s\(\) \{.*?^\}\n" % n, src, re.S | re.M).group(0)
                for n in ("port_net", "inbound_listens", "inbounds_down", "xray_heal"))

INBOUNDS = [
    {"remark": "REALITY", "protocol": "vless", "port": 10443, "enable": True},
    {"remark": "Hysteria2", "protocol": "hysteria", "port": 443, "enable": True},
    {"remark": "Shadowsocks", "protocol": "shadowsocks", "port": 8388, "enable": True},
    {"remark": "VMess-WS", "protocol": "vmess", "port": 10452, "enable": False},
]

# ss и api – заглушки: открытые порты лежат в файле «t:443», «u:443»; перезапуск ядра открывает порты из $AFTER.
STUBS = r'''
set -Eeuo pipefail
say() { echo "SAY: $*"; }; warn() { echo "WARN: $*"; }; sleep() { :; }
ss() { local p=${1:3:1} port=${2##*:}; grep -qx "$p:$port" "$LISTEN" && echo LISTEN || true; }
api() { cat "$LIST"; }
xray_restart_core() { echo RESTART; cp "$AFTER" "$LISTEN"; }
'''


def run(listen, body, after=None):
    d = tempfile.mkdtemp()
    paths = {k: os.path.join(d, k) for k in ("listen", "list", "after")}
    for k, text in (("listen", "\n".join(listen) + "\n"), ("after", "\n".join(after if after is not None else listen) + "\n"),
                    ("list", json.dumps(INBOUNDS))):
        with open(paths[k], "w") as f:
            f.write(text)
    env = dict(os.environ, LISTEN=paths["listen"], LIST=paths["list"], AFTER=paths["after"])
    r = subprocess.run(["bash", "-c", STUBS + funcs + body], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


ALL = ["t:10443", "u:443", "t:8388", "u:8388"]


class Ports(unittest.TestCase):
    def test_all_listen(self):
        code, out = run(ALL + ["t:443"], 'inbounds_down; echo END')
        self.assertEqual(code, 0, out)
        self.assertEqual(out.strip(), "END")

    def test_nginx_tcp_is_not_hysteria_udp(self):
        code, out = run(["t:10443", "t:443", "t:8388", "u:8388"], 'inbounds_down')
        self.assertEqual(out.strip(), "Hysteria2\t443\tudp", out)

    def test_shadowsocks_needs_both(self):
        code, out = run(["t:10443", "u:443", "t:8388"], 'inbounds_down')
        self.assertEqual(out.strip(), "Shadowsocks\t8388\ttcp+udp", out)

    def test_disabled_ignored(self):
        code, out = run(ALL, 'inbounds_down | grep -c VMess || true')
        self.assertEqual(out.strip(), "0")

    def test_bad_port_value(self):
        code, out = run(ALL, 'inbound_listens "443;id" udp && echo YES || echo NO')
        self.assertEqual(out.strip(), "NO")

    def test_heal_restarts_when_patch_closed_port(self):
        code, out = run(["t:10443", "t:8388", "u:8388"], 'xray_heal ""', after=ALL)
        self.assertEqual(code, 0, out)
        self.assertIn("RESTART", out)
        self.assertIn("Hysteria2", out)
        self.assertNotIn("WARN", out)

    def test_heal_quiet_when_nothing_closed(self):
        code, out = run(ALL, 'xray_heal ""')
        self.assertEqual(out.strip(), "")

    def test_heal_ignores_port_down_before_patch(self):
        code, out = run(["t:10443", "t:8388", "u:8388"], 'xray_heal "$(printf "Hysteria2\\t443\\tudp")"')
        self.assertNotIn("RESTART", out)

    def test_heal_warns_if_restart_did_not_help(self):
        code, out = run(["t:10443", "t:8388", "u:8388"], 'xray_heal ""')
        self.assertIn("RESTART", out)
        self.assertIn("WARN: После перезапуска ядра не слушают: Hysteria2:443", out)


if __name__ == "__main__":
    unittest.main()
