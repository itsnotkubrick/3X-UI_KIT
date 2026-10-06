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


def run(name, text, extra=""):
    d = tempfile.mkdtemp()
    p = os.path.join(d, name)
    open(p, "w").write(text)
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
        self.assertNotIn("OK", out)

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


if __name__ == "__main__":
    unittest.main()
