"""Проверки сайта-заглушки (stub_site в 3x-ui.sh): python3 tools/test/stub_test.py"""
import html.parser, os, re, subprocess, unittest

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
src = open(os.path.join(root, "scripts", "3x-ui.sh"), encoding="utf-8").read()
func = re.search(r"^stub_site\(\) \{.*?^\}\n", src, re.S | re.M).group(0)
N = 300
# rnd на сервере – через shuf, здесь – через /dev/urandom (на Mac нет shuf; $RANDOM в подоболочках повторяется).
script = ('set -Eeuo pipefail\nrnd() { echo $(( $1 + $(od -An -N2 -tu2 /dev/urandom) % ($2 - $1 + 1) )); }\n' + func
          + 'for i in $(seq %d); do stub_site; echo "@@END@@"; done\n' % N)
raw = subprocess.run(["bash", "-c", script], capture_output=True, check=True).stdout
PAGES = [p.strip() for p in raw.decode("utf-8").split("@@END@@") if p.strip()]  # strict: только UTF-8

forbidden = []
fp = os.path.join(root, ".git", "hooks", "forbidden.txt")
if os.path.exists(fp):
    forbidden = [w.strip().lower() for w in open(fp, encoding="utf-8") if w.strip() and not w.startswith("#")]
PUBLIC = re.compile(r"vpn|proxy|xray|x-ui|cumulo|hysteria|reality|v2ray|clash|\bkit\b|tunnel|censor|block|bypass|server", re.I)
EXTERNAL = re.compile(r"https?:|//|\bsrc=|\bhref=|<script|<link|<iframe|<img|@import|url\(|\bon[a-z]+=", re.I)
VOID = {"meta", "br", "hr", "input", "img"}


class Balance(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(); self.stack = []; self.bad = []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            self.bad.append(tag)


class Stub(unittest.TestCase):
    def test_count(self):
        self.assertEqual(len(PAGES), N)

    def test_valid_html(self):
        for p in PAGES:
            self.assertTrue(p.startswith('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">'), p[:80])
            self.assertTrue(p.endswith("</body></html>"), p[-40:])
            b = Balance(); b.feed(p); b.close()
            self.assertEqual((b.stack, b.bad), ([], []), p)
            self.assertEqual(p.count("<title>"), 1)

    def test_no_external_and_no_leftovers(self):
        for p in PAGES:
            self.assertIsNone(EXTERNAL.search(p), p)
            text = re.sub(r"<style>.*?</style>", "", p)
            self.assertIsNone(re.search(r"[$|^~`\\]", text), p)
            self.assertNotIn("\n", p)

    def test_words(self):
        for p in PAGES:
            low = p.lower()
            self.assertIsNone(PUBLIC.search(re.sub(r"<style>.*?</style>", "", p)), p)  # в стилях есть display:block
            for w in forbidden:
                self.assertNotIn(w, low)

    def test_variety(self):
        titles = {re.search(r"<title>(.*?)</title>", p).group(1) for p in PAGES}
        self.assertGreater(len(titles), N * 0.8)
        layouts = {k for p in PAGES for k, m in (("hero", "place-items:center;text-align"), ("cards", "header{background"),
                                                    ("nav", "nav{width"), ("notes", "article{"), ("band", ".t{background")) if m in p}
        self.assertEqual(len(layouts), 5)
        themes = {re.search(r"<title>.*? (\S+)</title>", p).group(1) for p in PAGES}
        self.assertGreaterEqual(len(themes), 25)  # последние слова названий: Coffee, Bakery, Photography…
        # Ни одно окончание названия не встречается заметно чаще других (было: «Studio» у каждого пятого).
        ends = [re.search(r"<title>.*? (\S+)</title>", p).group(1) for p in PAGES]
        top = max(set(ends), key=ends.count)
        self.assertLess(ends.count(top), N * 0.08, (top, ends.count(top)))


if __name__ == "__main__":
    unittest.main()
