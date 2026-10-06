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

# Проверка файлов настроек – те же строки, что в --restore, после распаковки архива.
FUNCS = "".join(re.search(r"^%s\(\) \{.*?^\}\n" % n, src, re.S | re.M).group(0) for n in ("safe_env", "env_get"))
ENV_CHECK = src[src.index('  safe_env "$tmp/kit-backup.env"'):src.index('  python3 -c "import sqlite3')]
ENVS = {
    "kit-backup.env": b"BACKUP_KIT_VERSION=1.2\nBACKUP_HOST=1.2.3.4\nBACKUP_SSL=ip\nBACKUP_DATE=2026-10-06\n",
    "etc/x-ui/install-result.env": b"XUI_USERNAME=abcDEF1234\nXUI_PASSWORD=Pass1234567890abcdef\nXUI_PANEL_PORT=31234\n"
                                   b"XUI_WEB_BASE_PATH=AbCdEf123456789012\nXUI_ACCESS_URL=https://1.2.3.4:31234/AbCdEf123456789012\n"
                                   b"XUI_API_TOKEN=tok_ABCdef0123456789\nXUI_DB_TYPE=sqlite\n",
    "etc/kit/kit.env": b"HOST=1.2.3.4\nLINK_HOST=1.2.3.4\nPANEL_ON=ip\nSUB_BASE=https://1.2.3.4/AbC123/\nSUB_PATH=/AbC123/\n"
                       b"SUB_INTERNAL=10446\nSINGLE=yes\nMTPROTO_INNER=10445\n",
}
# kit.env 1.1.x: без LINK_HOST и PANEL_ON, подписка на своём порту.
KIT_11 = b"HOST=1.2.3.4\nSUB_BASE=https://1.2.3.4:2096/AbC123/\nSUB_PATH=/AbC123/\nSUB_INTERNAL=2096\nSINGLE=no\nMTPROTO_INNER=''\n"


def restore_env(over=None):
    files = dict(ENVS)
    files.update(over or {})
    p = archive([(k, v) for k, v in files.items()])
    out = tempfile.mkdtemp()
    r = subprocess.run(["python3", "-", p, out], input=CHECK, capture_output=True, text=True)
    if r.returncode:
        return r
    script = 'set -Eeuo pipefail\ndie() { echo "DIE: $*"; exit 1; }\n' + FUNCS + 'tmp=$1\n' + ENV_CHECK + 'echo ENV-OK\n'
    return subprocess.run(["bash", "-c", script, "t", out], capture_output=True, text=True)


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


class RestoreEnv(unittest.TestCase):
    def test_good_12(self):
        r = restore_env()
        self.assertIn("ENV-OK", r.stdout, r.stdout + r.stderr)

    def test_good_11(self):
        r = restore_env({"etc/kit/kit.env": KIT_11,
                         "kit-backup.env": b"BACKUP_KIT_VERSION=1.1.2\nBACKUP_HOST=1.2.3.4\nBACKUP_SSL=ip\nBACKUP_DATE=2026-09-01\n"})
        self.assertIn("ENV-OK", r.stdout, r.stdout + r.stderr)

    def bad(self, over):
        r = restore_env(over)
        self.assertNotIn("ENV-OK", r.stdout)
        self.assertIn("Это не резервная копия 3X-UI KIT", r.stdout + r.stderr)

    def test_mtproto_inner_sed(self):
        for v in (b"MTPROTO_INNER='[0-9]*.*/touch \\/tmp\\/pwn-test/e;#'", b"MTPROTO_INNER='1/x/;1e touch /tmp/pwn-test #'", b"MTPROTO_INNER=1/x/e"):
            self.bad({"etc/kit/kit.env": ENVS["etc/kit/kit.env"].replace(b"MTPROTO_INNER=10445", v)})

    def test_panel_path_nginx(self):
        for v in (b"XUI_WEB_BASE_PATH='x/ { return 200; } location /zz'", b"XUI_WEB_BASE_PATH=x/../y", b"XUI_WEB_BASE_PATH=$(id)"):
            self.bad({"etc/x-ui/install-result.env": ENVS["etc/x-ui/install-result.env"].replace(b"XUI_WEB_BASE_PATH=AbCdEf123456789012", v)})

    def test_values_every_file(self):
        for name in ENVS:
            for line in ENVS[name].splitlines():
                n = line.split(b"=")[0]
                for v in (b"'a;b'", b"$(touch /tmp/pwn-test)", b"a b", b"x" * 300):
                    self.bad({name: ENVS[name].replace(line, n + b"=" + v)})


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
