"""Сертификаты при --restore (3x-ui.sh): python3 tools/test/restore_archive_test.py"""
import json, os, sqlite3, subprocess, tempfile, unittest

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(os.path.join(root, "scripts", "3x-ui.sh"), encoding="utf-8").read()


def heredoc(after):
    i = src.index(after)
    j = src.index("<<'PY'", i)
    body = src[src.index("\n", j) + 1:]
    return body[:body.index("\nPY\n") + 1]


CERT_FILES = heredoc("db_cert_files() {")
PIN = heredoc("pin_cert_in_db() {")


def make_db():
    d = tempfile.mkdtemp()
    p = os.path.join(d, "x-ui.db")
    db = sqlite3.connect(p)
    db.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT, settings TEXT, stream_settings TEXT)")
    hy = {"network": "hysteria", "security": "tls", "tlsSettings": {"certificates": [
        {"certificateFile": "/root/cert/ip/fullchain.pem", "keyFile": "/root/cert/ip/privkey.pem"}], "settings": {"fingerprint": "chrome"}},
        "hysteriaSettings": {"masquerade": {"content": "<p>Кофейня</p>"}}}
    tuic = {"server": {"certificate": "/root/cert/ip/fullchain.pem"}}
    other = {"tlsSettings": {"certificates": [{"certificateFile": "/root/cert/custom/fullchain.pem"}]}}
    db.executemany("INSERT INTO inbounds (remark, settings, stream_settings) VALUES (?, ?, ?)", [
        ("Hysteria2", "{}", json.dumps(hy)), ("TUIC", json.dumps(tuic), ""), ("Other", "{}", json.dumps(other)),
        ("Broken", "not json", "[1]")])
    db.commit(); db.close()
    return p


def run_db(code, p, *args):
    code = code.replace("/etc/x-ui/x-ui.db", p)
    return subprocess.run(["python3", "-", *args], input=code, capture_output=True, text=True)


class Certs(unittest.TestCase):
    def test_cert_files(self):
        r = run_db(CERT_FILES, make_db())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), ["/root/cert/custom/fullchain.pem", "/root/cert/ip/fullchain.pem"])

    def test_pin_only_matching_inbound(self):
        p = make_db()
        r = run_db(PIN, p, "/root/cert/ip/fullchain.pem", "ab" * 32)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = dict(sqlite3.connect(p).execute("SELECT remark, stream_settings FROM inbounds"))
        hy = json.loads(rows["Hysteria2"])
        self.assertEqual(hy["tlsSettings"]["settings"], {"fingerprint": "chrome", "pinnedPeerCertSha256": ["ab" * 32]})
        self.assertEqual(hy["hysteriaSettings"]["masquerade"]["content"], "<p>Кофейня</p>")
        self.assertNotIn("pinnedPeerCertSha256", rows["Other"])
        self.assertEqual(rows["Broken"], "[1]")

    def test_restore_writes_only_own_paths(self):
        # Путь сертификата приходит из базы копии: генерировать можно только в /root/cert/ip и /root/cert/self.
        self.assertIn(r"^/root/cert/(ip|self)/fullchain\.pem$", src)


if __name__ == "__main__":
    unittest.main()
