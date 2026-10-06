"""Проверка архива копии и сертификатов при --restore (3x-ui.sh): python3 tools/test/restore_archive_test.py"""
import io, json, os, re, sqlite3, subprocess, tarfile, tempfile, unittest

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(os.path.join(root, "scripts", "3x-ui.sh"), encoding="utf-8").read()


def heredoc(after):
    i = src.index(after)
    j = src.index("<<'PY'", i)
    body = src[src.index("\n", j) + 1:]
    return body[:body.index("\nPY\n") + 1]


CHECK = heredoc('python3 - "$file" "$tmp"')
CERT_FILES = heredoc("db_cert_files() {")
PIN = heredoc("pin_cert_in_db() {")


def archive(extra=(), drop=()):
    files = {"etc/x-ui/x-ui.db": b"db", "etc/x-ui/install-result.env": b"X=1\n", "kit-backup.env": b"BACKUP_SSL=ip\n"}
    files.update({k: v for k, v in extra if v is not None})
    d = tempfile.mkdtemp()
    p = os.path.join(d, "b.tar.gz")
    with tarfile.open(p, "w:gz") as t:
        for name, data in list(files.items()) + [(k, v) for k, v in extra if v is None]:
            if name in drop:
                continue
            ti = tarfile.TarInfo(name)
            if data is None:
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    return p


def check(p):
    out = tempfile.mkdtemp()
    return subprocess.run(["python3", "-", p, out], input=CHECK, capture_output=True, text=True)


PEM = b"-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n"


class Archive(unittest.TestCase):
    def test_good(self):
        r = check(archive())
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_good_with_self_cert(self):
        r = check(archive([("root/cert/self", None), ("root/cert/self/fullchain.pem", PEM), ("root/cert/self/privkey.pem", PEM)]))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_empty_self_dir(self):
        r = check(archive([("root/cert/self", None)]))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("root/cert/self/fullchain.pem", r.stderr)

    def test_empty_custom_dir(self):
        self.assertNotEqual(check(archive([("root/cert/custom", None)])).returncode, 0)

    def test_self_without_key(self):
        self.assertNotEqual(check(archive([("root/cert/self/fullchain.pem", PEM)])).returncode, 0)

    def test_self_empty_key(self):
        self.assertNotEqual(check(archive([("root/cert/self/fullchain.pem", PEM), ("root/cert/self/privkey.pem", b"")])).returncode, 0)

    def test_no_db(self):
        self.assertNotEqual(check(archive(drop=("etc/x-ui/x-ui.db",))).returncode, 0)

    def test_dotdot(self):
        self.assertNotEqual(check(archive([("etc/x-ui/../../tmp/x", b"x")])).returncode, 0)


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
