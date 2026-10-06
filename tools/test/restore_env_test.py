"""Проверки разбора файлов настроек из резервной копии (safe_env, env_get в 3x-ui.sh):
python3 tools/test/restore_env_test.py"""
import os, re, subprocess, tempfile, unittest

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(os.path.join(root, "scripts", "3x-ui.sh"), encoding="utf-8").read()
funcs = "".join(re.search(r"^%s\(\) \{.*?^\}\n" % n, src, re.S | re.M).group(0) for n in ("safe_env", "env_get"))

BACKUP = ("BACKUP_KIT_VERSION", "BACKUP_HOST", "BACKUP_SSL", "BACKUP_DATE")
XUI = ("XUI_USERNAME", "XUI_PASSWORD", "XUI_PANEL_PORT", "XUI_WEB_BASE_PATH", "XUI_ACCESS_URL", "XUI_API_TOKEN", "XUI_DB_TYPE")
KIT = ("HOST", "LINK_HOST", "PANEL_ON", "SUB_BASE", "SUB_PATH", "SUB_INTERNAL", "SINGLE", "MTPROTO_INNER")

# Как пишут kit backup, установщик 3X-UI и install_kit_cli (printf %q).
GOOD = {
    "kit-backup.env": "BACKUP_KIT_VERSION=1.2\nBACKUP_HOST=1.2.3.4\nBACKUP_SSL=ip\nBACKUP_DATE=2026-10-06\n",
    "install-result.env": "XUI_USERNAME=abcDEF1234\nXUI_PASSWORD=Pass1234567890abcdef\nXUI_PANEL_PORT=31234\n"
                          "XUI_WEB_BASE_PATH=AbCdEf123456789012\nXUI_ACCESS_URL=https://1.2.3.4:31234/AbCdEf123456789012\n"
                          "XUI_API_TOKEN=tok_ABCdef0123456789\nXUI_DB_TYPE=sqlite\n",
    "kit.env": "HOST=1.2.3.4\nLINK_HOST=1.2.3.4\nPANEL_ON=ip\nSUB_BASE=https://1.2.3.4/AbC123/\nSUB_PATH=/AbC123/\n"
               "SUB_INTERNAL=2096\nSINGLE=yes\nMTPROTO_INNER=''\n",
}
NAMES = {"kit-backup.env": BACKUP, "install-result.env": XUI, "kit.env": KIT}
# Другие настоящие варианты: kit.env 1.1.x (без LINK_HOST и PANEL_ON, свой порт подписки), «всё на 443» с доменом,
# install-result.env с путём панели в слешах (панель стояла до установщика) и пустыми значениями.
GOOD_MORE = [
    ("kit.env", "HOST=1.2.3.4\nSUB_BASE=https://1.2.3.4:2096/AbC123/\nSUB_PATH=/AbC123/\nSUB_INTERNAL=2096\nSINGLE=no\nMTPROTO_INNER=''\n"),
    ("kit.env", "HOST=1.2.3.4\nSUB_BASE=http://127.0.0.1:2096/AbC123/\nSUB_PATH=/AbC123/\nSUB_INTERNAL=2096\nSINGLE=no\nMTPROTO_INNER=''\n"),
    ("kit.env", "HOST=1.2.3.4\nSUB_BASE=https://1.2.3.4/Ab-C_123/\nSUB_PATH=/Ab-C_123/\nSUB_INTERNAL=10446\nSINGLE=yes\nMTPROTO_INNER=10445\n"),
    ("kit.env", "HOST=vpn.example.com\nLINK_HOST=vpn.example.com\nPANEL_ON=domain\nSUB_BASE=https://vpn.example.com/AbC123/\n"
                "SUB_PATH=/AbC123/\nSUB_INTERNAL=10446\nSINGLE=yes\nMTPROTO_INNER=10445\n"),
    ("install-result.env", "XUI_USERNAME=admin\nXUI_PASSWORD=Pass_1234-abc.def\nXUI_PANEL_PORT=2053\nXUI_WEB_BASE_PATH=/AbCdEf123456789012/\n"
                           "XUI_ACCESS_URL=http://SERVER_IP_UNKNOWN:2053//AbCdEf123456789012/\nXUI_API_TOKEN=''\nXUI_DB_TYPE=sqlite\n"),
    ("kit-backup.env", "BACKUP_KIT_VERSION=1.1.2\nBACKUP_HOST=vpn.example.com\nBACKUP_SSL=custom\nBACKUP_DATE=2026-09-01\n"),
]
# Плохие значения: проверяются для каждого имени в каждом файле.
BAD_VALUES = ("$(touch /tmp/pwn-test)", "`id`", "1;id", "1; id", "'1;id'", "'a b'", "a b", "'", "\"x\"", "$HOME", "x\\y",
              "1\nid", "'1\n/e;#'", "a" * 300, "9" * 300, "x{", "a|b", "a&b", "a>b", "a*b")


def run(name, text, extra=""):
    d = tempfile.mkdtemp()
    p = os.path.join(d, name)
    with open(p, "w") as fh:
        fh.write(text)
    script = ('set -Eeuo pipefail\ndie() { echo "DIE: $*"; exit 1; }\n' + funcs
              + 'RESULT=/root/3x-ui.txt\nsafe_env "$1" ' + " ".join(NAMES[name]) + '\necho OK\n' + extra)
    r = subprocess.run(["bash", "-c", script, "t", p], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


class SafeEnv(unittest.TestCase):
    def test_good_copy(self):
        for name, text in GOOD.items():
            code, out = run(name, text)
            self.assertEqual(code, 0, out)
            self.assertIn("OK", out)

    def test_good_variants(self):
        for name, text in GOOD_MORE:
            code, out = run(name, text)
            self.assertEqual(code, 0, name + ": " + out)
            self.assertIn("OK", out)

    def test_bad_value_every_field(self):
        for name, text in GOOD.items():
            for n in NAMES[name]:
                for bad in BAD_VALUES:
                    lines = [l for l in text.splitlines() if not l.startswith(n + "=")] + [n + "=" + bad]
                    self.rejected(name, "\n".join(lines) + "\n")

    def test_wrong_format(self):
        # Безопасные символы, но не тот формат.
        for name, n, bad in (("kit.env", "MTPROTO_INNER", "1/x/e"), ("kit.env", "MTPROTO_INNER", "abc"), ("kit.env", "SINGLE", "maybe"),
                             ("kit.env", "PANEL_ON", "x"), ("kit.env", "SUB_PATH", "/../"), ("kit.env", "SUB_PATH", "/a"),
                             ("kit.env", "SUB_BASE", "file:///etc/"), ("kit.env", "SUB_INTERNAL", "20x6"), ("kit.env", "HOST", ""),
                             ("kit.env", "LINK_HOST", "a/b"), ("kit-backup.env", "BACKUP_SSL", "le"), ("kit-backup.env", "BACKUP_DATE", "today"),
                             ("kit-backup.env", "BACKUP_KIT_VERSION", "1.2/x"), ("install-result.env", "XUI_WEB_BASE_PATH", "a/b"),
                             ("install-result.env", "XUI_WEB_BASE_PATH", ""), ("install-result.env", "XUI_WEB_BASE_PATH", "a.b"),
                             ("install-result.env", "XUI_DB_TYPE", "mysql"), ("install-result.env", "XUI_PANEL_PORT", "123456"),
                             ("install-result.env", "XUI_USERNAME", ""), ("install-result.env", "XUI_ACCESS_URL", "ftp://1.2.3.4/x")):
            lines = [l for l in GOOD[name].splitlines() if not l.startswith(n + "=")] + [n + "=" + bad]
            self.rejected(name, "\n".join(lines) + "\n")

    def test_audit_payloads(self):
        # Из повторного аудита 1.2: выражение sed с флагом e и чужие директивы nginx.
        for bad in ("MTPROTO_INNER='[0-9]*.*/touch \\/tmp\\/pwn-test/e;#'", "MTPROTO_INNER='1/x/;1e touch /tmp/pwn-test #'"):
            self.rejected("kit.env", GOOD["kit.env"].replace("MTPROTO_INNER=''\n", bad + "\n"))
        self.rejected("install-result.env", GOOD["install-result.env"].replace(
            "XUI_WEB_BASE_PATH=AbCdEf123456789012", "XUI_WEB_BASE_PATH='x/ { return 200; } location /zz'"))

    def test_values(self):
        code, out = run("kit-backup.env", GOOD["kit-backup.env"],
                        'echo "[$(env_get "$1" BACKUP_HOST)|$(env_get "$1" BACKUP_SSL)|$(env_get "$1" NOPE)]"\n')
        self.assertIn("[1.2.3.4|ip|]", out)
        code, out = run("kit.env", GOOD["kit.env"], 'echo "[$(env_get "$1" SUB_PATH)|$(env_get "$1" MTPROTO_INNER)]"\n')
        self.assertIn("[/AbC123/|]", out)

    def test_env_get_does_not_touch_shell(self):
        code, out = run("kit-backup.env", GOOD["kit-backup.env"], 'env_get "$1" BACKUP_HOST >/dev/null; echo "[${BACKUP_HOST:-none}]"\n')
        self.assertIn("[none]", out)

    def rejected(self, name, text):
        code, out = run(name, text, 'echo "RESULT=$RESULT"\n')
        self.assertNotEqual(code, 0, out)
        self.assertIn("Это не резервная копия 3X-UI KIT", out)
        self.assertNotIn("\nOK\n", "\n" + out)

    def test_result_in_backup_env(self):
        self.rejected("kit-backup.env", GOOD["kit-backup.env"] + "RESULT=/etc/cron.d/x\n")

    def test_kit_version_in_kit_env(self):
        self.rejected("kit.env", GOOD["kit.env"] + "KIT_VERSION=9.9\n")

    def test_foreign_names(self):
        for bad in ("PATH=/tmp", "IFS=x", "XUI_ENV=/etc/cron.d/x", "HOST=5.6.7.8", "KIT_RAW=https://example.org/"):
            self.rejected("kit-backup.env", GOOD["kit-backup.env"] + bad + "\n")
        for bad in ("PATH=/tmp", "RESULT=/etc/cron.d/x", "XUI_ENV=/tmp/x", "KIT_VERSION=9.9"):
            self.rejected("install-result.env", GOOD["install-result.env"] + bad + "\n")
        for bad in ("RESULT=/etc/cron.d/x", "XUI_PIN=v0", "BACKUP_HOST=1.2.3.4"):
            self.rejected("kit.env", GOOD["kit.env"] + bad + "\n")

    def test_substitutions(self):
        for bad in ("BACKUP_DATE=$(id)", "BACKUP_DATE=`id`", 'BACKUP_DATE="$HOME"', "export BACKUP_DATE=1", "BACKUP_DATE=1; id", " BACKUP_DATE=1"):
            self.rejected("kit-backup.env", GOOD["kit-backup.env"] + bad + "\n")


kit_src = open(os.path.join(root, "scripts", "kit.sh"), encoding="utf-8").read()
PANEL_PATH = re.search(r"^panel_web_path\(\) \{.*?^\}\n", kit_src, re.S | re.M).group(0)


class NginxPaths(unittest.TestCase):
    """Путь панели и подписки перед сборкой nginx (kit.sh panel_web_path, 3x-ui.sh setup_nginx)."""

    def path(self, base, sub="/AbC123/"):
        r = subprocess.run(["bash", "-c", PANEL_PATH + 'XUI_WEB_BASE_PATH=$1 SUB_PATH=$2\npanel_web_path || echo NO', "t", base, sub],
                           capture_output=True, text=True)
        return r.stdout.strip()

    def test_good(self):
        self.assertEqual(self.path("AbCdEf123456789012"), "/AbCdEf123456789012/")
        self.assertEqual(self.path("/AbC_d-1/"), "/AbC_d-1/")

    def test_bad(self):
        for bad in ("x/ { return 200; } location /zz", "", "/", "a/b", "a;b", "a\nb", "$(id)", "a" * 65):
            self.assertEqual(self.path(bad), "NO", bad)
        for bad in ("/a b/", "/a/ { }", "", "/../"):
            self.assertEqual(self.path("AbC", bad), "NO", bad)

    def test_setup_nginx_checks(self):
        self.assertIn('[[ $XUI_WEB_BASE_PATH =~ ^/?[A-Za-z0-9_-]{1,64}/?$ && $SUB_PATH =~ ^/[A-Za-z0-9_-]{1,64}/$ ]]', src)


if __name__ == "__main__":
    unittest.main()
