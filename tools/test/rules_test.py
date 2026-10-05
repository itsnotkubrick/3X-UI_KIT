"""Проверки раздельной маршрутизации kit-sub: python3 tools/test/rules_test.py"""
import json, os, sys, tempfile, unittest, importlib.util

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
tmp = tempfile.mkdtemp()
cfgp = os.path.join(tmp, "config.json")
json.dump({"listen": "127.0.0.1", "port": 1, "path": "/sub/", "upstream": "http://127.0.0.1:1/"}, open(cfgp, "w"))
os.environ["KIT_SUB_CONFIG"] = cfgp
os.environ["KIT_SUB_RULES"] = os.path.join(tmp, "rules.yaml")
spec = importlib.util.spec_from_file_location("kit_sub", os.path.join(root, "scripts", "kit-sub.py"))
ks = importlib.util.module_from_spec(spec); spec.loader.exec_module(ks)
import yaml

BASE = yaml.safe_dump({"proxies": [{"name": "a", "type": "vless"}, {"name": "b", "type": "vless"}],
                       "proxy-groups": [{"name": "Авто", "type": "url-test", "proxies": ["a", "b"]}],
                       "rules": ["MATCH,Авто"], "dns": {"enable": False}}).encode()


def write(text):
    with open(ks.RULES_FILE, "w") as f:
        f.write(text)


class Rules(unittest.TestCase):
    def tearDown(self):
        if os.path.exists(ks.RULES_FILE):
            os.remove(ks.RULES_FILE)

    def apply(self, text):
        write(text)
        loaded = ks.load_rules(report=lambda m: None)
        self.assertIsNotNone(loaded)
        return yaml.safe_load(ks.apply_rules(BASE, loaded))

    def test_no_file(self):
        self.assertIsNone(ks.load_rules())

    def test_basic(self):
        c = self.apply("via_vpn:\n  - GEOSITE,youtube\n  - DOMAIN-SUFFIX, example.org \n  - IP-CIDR,1.2.3.0/24\n")
        r = c["rules"]
        self.assertEqual(r[-1], "MATCH,DIRECT")
        self.assertIn("GEOSITE,youtube,Авто", r)
        self.assertIn("DOMAIN-SUFFIX,example.org,Авто", r)
        self.assertIn("IP-CIDR,1.2.3.0/24,Авто,no-resolve", r)  # адресные правила не разрешают имена
        self.assertLess(r.index("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"), r.index("GEOSITE,youtube,Авто"))
        self.assertEqual(c["mode"], "rule")

    def test_dns_no_leak(self):
        c = self.apply("via_vpn:\n  - GEOSITE,youtube\n  - DOMAIN-SUFFIX,example.org\n  - DOMAIN,api.example.com\n")
        d = c["dns"]
        self.assertEqual(d["enhanced-mode"], "fake-ip")
        self.assertEqual(d["nameserver"], ["system"])
        self.assertNotIn("fallback", d)
        self.assertEqual(d["nameserver-policy"]["geosite:youtube"], ks.DOH_DEFAULT)
        self.assertIn("+.example.org", d["nameserver-policy"])
        self.assertIn("api.example.com", d["nameserver-policy"])
        # DoH-серверы идут через VPN, а не напрямую
        self.assertIn("IP-CIDR,1.1.1.1/32,Авто,no-resolve", c["rules"])
        self.assertFalse(c["sniffer"]["override-destination"])

    def test_direct_dns(self):
        c = self.apply("direct_dns:\n  - https://dns.example.net/dns-query\n  - http://evil/x\n  - 'https://a b/'\nvia_vpn:\n  - GEOSITE,openai\n")
        self.assertEqual(c["dns"]["nameserver"], ["https://dns.example.net/dns-query"])

    def test_bad_rules_dropped(self):
        write("via_vpn:\n  - MATCH,DIRECT\n  - PROCESS-NAME,x\n  - SCRIPT,abc\n  - 'DOMAIN,a.com,DIRECT'\n  - 'DOMAIN,a b'\n  - GEOSITE,youtube\n  - 'DOMAIN-SUFFIX,x.org\\nMATCH,Авто'\n")
        loaded = ks.load_rules(report=lambda m: None)
        self.assertEqual(loaded[0], [("GEOSITE", "youtube")])

    def test_broken_files_leave_subscription_alone(self):
        for text in ("", "via_vpn: 5", "via_vpn: []", "- a\n- b", ":\n  - [", "via_vpn:\n  - MATCH,DIRECT"):
            write(text)
            self.assertIsNone(ks.load_rules(report=lambda m: None), text)
        with open(ks.RULES_FILE, "wb") as f:
            f.write(b"via_vpn:\n" + b"  - DOMAIN,a.com\n" * 6000)
        self.assertIsNone(ks.load_rules(report=lambda m: None))  # слишком большой

    def test_limits_and_duplicates(self):
        write("via_vpn:\n" + "".join(f"  - DOMAIN,h{i}.example.org\n" for i in range(400)) + "  - DOMAIN,h1.example.org\n")
        rules, _ = ks.load_rules(report=lambda m: None)
        self.assertEqual(len(rules), ks.RULES_MAX_COUNT)
        self.assertEqual(len(set(rules)), len(rules))

    def test_no_proxies_untouched(self):
        write("via_vpn:\n  - GEOSITE,youtube\n")
        loaded = ks.load_rules(report=lambda m: None)
        self.assertEqual(ks.apply_rules(b"proxies: []\n", loaded), b"proxies: []\n")

    def test_forgiving_input(self):
        # Что если: строчные типы, BOM и CRLF из Windows-редактора, лишние пробелы
        with open(ks.RULES_FILE, "wb") as f:
            f.write("\ufeffvia_vpn:\r\n  - geosite , youtube\r\n  - domain-suffix,Example.ORG\r\n".encode("utf-8"))
        rules, _ = ks.load_rules(report=lambda m: None)
        self.assertEqual(rules, [("GEOSITE", "youtube"), ("DOMAIN-SUFFIX", "Example.ORG")])

    def test_bad_cidr_and_short_keyword(self):
        write("via_vpn:\n  - IP-CIDR,999.1.1.1/8\n  - IP-CIDR,1.2.3.4/99\n  - IP-CIDR6,1.2.3.0/24\n  - IP-CIDR,2001:db8::/32\n"
              "  - IP-CIDR,203.0.113.0/24\n  - IP-CIDR6,2001:db8::/32\n  - DOMAIN-KEYWORD,a\n  - DOMAIN-KEYWORD,video\n")
        rules, _ = ks.load_rules(report=lambda m: None)
        self.assertEqual(rules, [("IP-CIDR", "203.0.113.0/24"), ("IP-CIDR6", "2001:db8::/32"), ("DOMAIN-KEYWORD", "video")])

    def test_template_from_kit_sh_is_valid(self):
        # Что если: шаблон kit net split on сам окажется с ошибкой
        import re
        t = open(os.path.join(root, "scripts", "kit.sh"), encoding="utf-8").read()
        body = t[t.index("split_template() {"):]
        body = body[body.index("<<'YAML'\n") + 9: body.index("\nYAML\n")]
        write(body)
        rules, _ = ks.load_rules(report=lambda m: self.fail(m))
        self.assertGreater(len(rules), 40)
        self.assertIn(("GEOIP", "telegram"), rules)
        self.assertNotIn(("DOMAIN-SUFFIX", "example.org"), rules)  # пример закомментирован


if __name__ == "__main__":
    unittest.main(verbosity=1)
