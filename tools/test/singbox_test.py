"""Конфиг sing-box для Karing и Hiddify в kit-sub: python3 tools/test/singbox_test.py
Если рядом есть sing-box (переменная SING_BOX=путь к бинарнику), выданный конфиг проверяется ещё и `sing-box check`."""
import base64, json, os, subprocess, tempfile, threading, unittest, urllib.request, importlib.util

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
tmp = tempfile.mkdtemp()
cfgp = os.path.join(tmp, "config.json")
json.dump({"listen": "127.0.0.1", "port": 1, "path": "/sub/", "upstream": "http://127.0.0.1:1/"}, open(cfgp, "w"))
os.environ["KIT_SUB_CONFIG"] = cfgp
os.environ["KIT_SUB_RULES"] = os.path.join(tmp, "rules.yaml")
spec = importlib.util.spec_from_file_location("kit_sub", os.path.join(root, "scripts", "kit-sub.py"))
ks = importlib.util.module_from_spec(spec); spec.loader.exec_module(ks)
import yaml

PBK = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
U = "0b9f6a8e-1111-4222-8333-444455556666"
VMESS = "vmess://" + base64.b64encode(json.dumps({"v": "2", "ps": "VMess WS-admin", "add": "203.0.113.10", "port": "443", "id": U,
                                                  "aid": "0", "scy": "auto", "net": "ws", "path": "/vm", "host": "", "tls": "tls",
                                                  "sni": "203.0.113.10", "fp": "chrome"}).encode()).decode()
LINKS = "\n".join([
    f"vless://{U}@203.0.113.10:443?type=tcp&security=reality&pbk=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA&fp=chrome&sni=www.example.com&sid=ab12&flow=xtls-rprx-vision#VLESS%20REALITY-admin",
    f"vless://{U}@203.0.113.10:443?type=xhttp&security=reality&pbk=AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA&sni=www.example.com&path=%2Fx#XHTTP-admin",
    f"vless://{U}@203.0.113.10:443?type=ws&security=tls&path=%2Fws&sni=203.0.113.10&fp=firefox&alpn=http%2F1.1#VLESS%20WS-admin",
    f"trojan://pass%40word@203.0.113.10:443?type=grpc&serviceName=tg&security=tls&sni=203.0.113.10#Trojan%20gRPC-admin",
    VMESS,
    "ss://" + base64.urlsafe_b64encode(b"2022-blake3-aes-256-gcm:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=").decode().rstrip("=") + "@203.0.113.10:8388#SS-admin",
    "hysteria2://hypass@203.0.113.10:443?sni=203.0.113.10&alpn=h3#Hysteria2-admin",
    f"tuic://{U}:tpass@203.0.113.10:8444?sni=203.0.113.10&congestion_control=bbr&alpn=h3#TUIC-admin",
    "vpn://AAAA#AmneziaWG", "tg://proxy?server=203.0.113.10&port=443&secret=ee00",
    "wireguard://PRIV@203.0.113.10:51820?publickey=PUB&address=10.0.0.2%2F32#WG",
    f"vless://{U}@203.0.113.10:443?type=ws&security=tls&pcs=ABCD#Pinned",  # закреплённый отпечаток – sing-box не умеет, пропускаем
    f"vless://{U}@203.0.113.10:443?type=ws&security=tls&allowInsecure=1#Insecure",  # без проверки сертификата – пропускаем
])
RULES = ("via_vpn:\n  - GEOSITE,youtube\n  - GEOSITE,category-ai-!cn\n  - DOMAIN-SUFFIX,Example.ORG\n  - DOMAIN,api.example.com\n"
         "  - DOMAIN-KEYWORD,video\n  - GEOIP,telegram\n  - IP-CIDR,203.0.113.0/24\n  - IP-CIDR6,2001:db8::/32\n")


def write(text):
    with open(ks.RULES_FILE, "w", encoding="utf-8") as f:
        f.write(text)


def loaded(text=RULES):
    write(text)
    return ks.load_rules(report=lambda m: None)


def build(links=LINKS, rules=RULES):
    out = ks.singbox_config(links.encode(), loaded(rules))
    return None if out is None else json.loads(out)


def sing_box_check(cfg):
    sb = os.environ.get("SING_BOX")
    if not sb:
        return
    p = os.path.join(tmp, "sb.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False)
    r = subprocess.run([sb, "check", "-c", p], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


class Convert(unittest.TestCase):
    def tearDown(self):
        if os.path.exists(ks.RULES_FILE):
            os.remove(ks.RULES_FILE)

    def test_outbounds(self):
        c = build()
        o = {x["tag"]: x for x in c["outbounds"]}
        self.assertEqual(o["VLESS REALITY-admin"]["tls"]["reality"], {"enabled": True, "public_key": PBK, "short_id": "ab12"})
        self.assertEqual(o["VLESS REALITY-admin"]["flow"], "xtls-rprx-vision")
        self.assertEqual(o["VLESS WS-admin"]["transport"], {"type": "ws", "path": "/ws"})
        self.assertEqual(o["VLESS WS-admin"]["tls"]["utls"]["fingerprint"], "firefox")
        self.assertEqual(o["Trojan gRPC-admin"]["password"], "pass@word")
        self.assertEqual(o["Trojan gRPC-admin"]["transport"], {"type": "grpc", "service_name": "tg"})
        self.assertEqual(o["VMess WS-admin"]["transport"]["path"], "/vm")
        self.assertEqual(o["SS-admin"]["password"], "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")
        self.assertEqual(o["Hysteria2-admin"]["tls"]["alpn"], ["h3"])
        self.assertEqual(o["TUIC-admin"]["password"], "tpass")
        for skipped in ("XHTTP-admin", "AmneziaWG", "WG", "Pinned", "Insecure"):
            self.assertNotIn(skipped, o)
        self.assertNotIn("endpoints", c)
        for x in c["outbounds"]:  # ослабленной проверки сертификата нет нигде
            self.assertNotIn("insecure", x.get("tls", {}))
        sing_box_check(c)

    def test_route_and_dns(self):
        c = build()
        r, d = c["route"], c["dns"]
        self.assertEqual(r["final"], "direct")
        self.assertEqual(r["rules"][:2], [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"}])
        self.assertIn({"ip_is_private": True, "outbound": "direct"}, r["rules"])
        self.assertIn({"ip_cidr": ["1.1.1.1/32", "8.8.8.8/32"], "outbound": "Прокси"}, r["rules"])  # DoH – через VPN
        self.assertIn({"domain": ["api.example.com"], "domain_suffix": ["example.org"], "domain_keyword": ["video"],
                       "outbound": "Прокси"}, r["rules"])
        self.assertIn({"rule_set": ["geosite-youtube", "geosite-category-ai-!cn"], "outbound": "Прокси"}, r["rules"])
        self.assertIn({"ip_cidr": ["203.0.113.0/24", "2001:db8::/32"], "outbound": "Прокси"}, r["rules"])
        self.assertIn({"rule_set": ["geoip-telegram"], "outbound": "Прокси"}, r["rules"])
        # Ни одного правила без условия (в sing-box оно совпало бы со всем)
        for rule in r["rules"][2:] + d["rules"]:
            self.assertTrue(any(k not in ("outbound", "server", "action") for k in rule), rule)
        # DNS: список – только по DoH через VPN, остальное – системный DNS
        srv = {s["tag"]: s for s in d["servers"]}
        self.assertEqual(srv["dns-proxy"], {"type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "detour": "Прокси"})
        self.assertEqual(d["final"], "dns-local")
        self.assertEqual(srv["dns-local"]["type"], "local")
        self.assertTrue(all(x["server"] == "dns-proxy" for x in d["rules"]))
        self.assertEqual(len(d["rules"]), 2)  # имена и категории GEOSITE; адресные правила DNS не касаются
        sing_box_check(c)

    def test_rule_sets_fixed_url_via_proxy(self):
        c = build()
        for rs in c["route"]["rule_set"]:
            kind, name = rs["tag"].split("-", 1)
            self.assertEqual(rs["url"], f"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/{kind}/{name}.srs")
            self.assertEqual(rs["download_detour"], "Прокси")
        self.assertEqual(len({rs["tag"] for rs in c["route"]["rule_set"]}), len(c["route"]["rule_set"]))

    def test_bad_category_names_never_reach_url(self):
        # Что если: в категории «../» или адрес – путь загрузки не должен уйти из папки meta-rules-dat
        c = build(rules="via_vpn:\n  - GEOSITE,../../../evil/repo/main/x\n  - GEOSITE,a:b\n  - GEOSITE,..x\n  - GEOSITE,YouTube\n  - GEOSITE,youtube\n")
        self.assertEqual([rs["tag"] for rs in c["route"]["rule_set"]], ["geosite-youtube"])
        for name in ("../x", "a/b", "a:b", "..", "x..y", "a%2f", "", "-x", "a" * 81):
            self.assertFalse(ks.srs_ok(name), name)
        for name in ("youtube", "category-ai-!cn", "google@cn", "category-ads-all"):
            self.assertTrue(ks.srs_ok(name), name)

    def test_only_unusable_rules(self):
        self.assertIsNone(build(rules="via_vpn:\n  - GEOSITE,a:b\n"))  # нечего применять – подписка прежняя

    def test_direct_dns(self):
        c = build(rules="direct_dns:\n  - https://dns.example.net:8443/q\nvia_vpn:\n  - GEOSITE,youtube\n")
        srv = {s["tag"]: s for s in c["dns"]["servers"]}
        self.assertEqual(srv["dns-direct"], {"type": "https", "tag": "dns-direct", "server": "dns.example.net", "path": "/q",
                                             "server_port": 8443, "domain_resolver": "dns-bootstrap"})
        self.assertEqual(c["dns"]["final"], "dns-direct")
        c = build(rules="direct_dns:\n  - https://9.9.9.9/dns-query\nvia_vpn:\n  - DOMAIN,a.example.com\n")
        self.assertNotIn("domain_resolver", {s["tag"]: s for s in c["dns"]["servers"]}["dns-direct"])
        sing_box_check(c)

    def test_names_quotes_unicode_duplicates(self):
        links = "\n".join([f'vless://{U}@203.0.113.10:443?security=reality&pbk={PBK}#{n}' for n in
                           ("%22%7D%2C%7B%22x", "Привет", "Привет", "Прокси", "direct", "%0Aa%0Db", "")])
        c = build(links=links, rules='via_vpn:\n  - \'DOMAIN,a.example.com"\'\n  - DOMAIN-SUFFIX,пример.рф\n  - DOMAIN,b.example.com\n')
        tags = [o["tag"] for o in c["outbounds"]]
        self.assertEqual(len(tags), len(set(tags)))
        self.assertIn('"},{"x', tags)
        self.assertIn("Привет 2", tags)
        self.assertIn("Прокси 2", tags)
        self.assertIn("direct 2", tags)
        self.assertIn("ab", tags)
        self.assertIn("vless", tags)
        self.assertEqual(c["route"]["rules"][4], {"domain": ["b.example.com"], "outbound": "Прокси"})  # кавычка и юникод отброшены правилом
        sing_box_check(c)

    def test_single_proxy_no_auto(self):
        c = build(links=LINKS.splitlines()[0])
        self.assertEqual([o["tag"] for o in c["outbounds"]], ["Прокси", "VLESS REALITY-admin", "direct"])
        sing_box_check(c)

    def test_nothing_usable(self):
        for body in (b"", b"!!!not base64!!!", b"vpn://AAAA\ntg://proxy?server=x", b"\xff\xfe", b"<html>panel</html>",
                     b"a" * (ks.JSON_FIX_MAX + 1)):
            self.assertIsNone(ks.singbox_config(body, loaded()), body[:20])

    def test_base64_body(self):
        c = json.loads(ks.singbox_config(base64.b64encode(LINKS.encode()), loaded()))
        self.assertIn("VLESS REALITY-admin", [o["tag"] for o in c["outbounds"]])

    def test_broken_links_skipped(self):
        for bad in (f"vless://@203.0.113.10:443?security=reality&pbk=" + PBK + "#x", f"vless://{U}@203.0.113.10:99999?security=none#x",
                    f"vless://{U}@203.0.113.10:443?security=reality#nopbk", f"vless://{U}@bad_host!:443#x",
                    f"vless://{U}@203.0.113.10:443?encryption=mlkem768#x", "vmess://notjson", "vmess://" + base64.b64encode(b"[1]").decode(),
                    "ss://bm9wZQ@203.0.113.10:8388#x", "hysteria2://p@203.0.113.10:443-500#x", "tuic://u@203.0.113.10:1#x",
                    f"vless://{U}@203.0.113.10:443?security=xtls#x"):
            self.assertIsNone(ks.singbox_config(bad.encode(), loaded()), bad)


class Agents(unittest.TestCase):
    def test_singbox_ua(self):
        for ua in ("Karing/1.2.25.2802 platform/ios;mihomo/1.19.28;clash-verge;FLClash;mihomo.party/", "karing", "Hiddify/2.0",
                   "HiddifyNext/4.1.0 (android) like ClashMeta v2ray sing-box", "HiddifyNext/2.0", "clash.meta karing"):
            self.assertTrue(ks.SINGBOX_UA.search(ua[:512]), ua)
        for ua in ("", "sing-box/1.12", "SFI/1.12", "FlClash/0.8", "clash-verge/v2", "Happ/1.0", "v2rayN/7.0", "Mozilla/5.0",
                   "a" * 600 + "karing"):  # очень длинный: смотрим только начало
            self.assertFalse(ks.SINGBOX_UA.search(ua[:512]), ua[:40])


CLASH = yaml.safe_dump({"proxies": [{"name": "a", "type": "vless", "server": "203.0.113.10", "port": 443}],
                        "proxy-groups": [{"name": "g", "type": "select", "proxies": ["a"]}], "rules": ["MATCH,g"]}).encode()


class Http(unittest.TestCase):
    """Через настоящий обработчик, upstream подменён заглушкой: какой формат и с каким User-Agent уходит к панели."""
    def setUp(self):
        self.calls = []
        self.orig = ks.upstream

        def fake(sub_id, ua, host, accept, prefix=None):
            self.calls.append((sub_id, ua, prefix))
            if ua == ks.LINKS_UA:
                return 200, {"content-type": "text/plain; charset=utf-8", "subscription-userinfo": "upload=1; expire=0",
                             "profile-title": "3X-UI KIT", "content-disposition": "attachment"}, LINKS.encode()
            if ks.CLASH_UA.search(ua):
                return 200, {"content-type": "application/yaml"}, CLASH
            return 200, {"content-type": "text/plain; charset=utf-8"}, b"vless://a@b:1#x\n"
        ks.upstream = fake
        self.srv = ks.Server(("127.0.0.1", 0), ks.Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); ks.upstream = self.orig
        if os.path.exists(ks.RULES_FILE):
            os.remove(ks.RULES_FILE)

    def get(self, ua, path=None):
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.srv.server_address[1], path or ks.PATH + "abc123"),
                                     headers={"User-Agent": ua})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()

    def test_karing_gets_singbox_with_rules(self):
        write(RULES)
        ua = 'Karing/1.2 clash"}{"x'
        code, h, body = self.get(ua)
        self.assertEqual(code, 200)
        self.assertTrue(h["content-type"].startswith("application/json"))
        self.assertNotIn("content-disposition", h)
        self.assertEqual(h["subscription-userinfo"], "upload=1")
        self.assertEqual(h["profile-title"], "3X-UI KIT")
        c = json.loads(body)
        self.assertEqual(c["route"]["final"], "direct")
        self.assertNotIn(b"Karing", body)  # User-Agent в ответ не попадает
        self.assertEqual(self.calls, [("abc123", ks.LINKS_UA, ks.PATH)])  # панели – нейтральный User-Agent
        sing_box_check(c)

    def test_hiddify_gets_singbox(self):
        write(RULES)
        _, h, body = self.get("HiddifyNext/4.1.0 (android) like ClashMeta v2ray sing-box")
        self.assertIn("outbounds", json.loads(body))

    def test_split_off_unchanged(self):
        # Что если: kit net split off – Karing снова получает прежнюю подписку (Clash без AmneziaWG, без правил)
        _, h, body = self.get("Karing/1.2 clash")
        self.assertIn("yaml", h["content-type"])
        self.assertEqual(yaml.safe_load(body)["rules"], ["MATCH,g"])
        self.assertEqual([c[1] for c in self.calls], ["Karing/1.2 clash"])

    def test_broken_rules_unchanged(self):
        write("via_vpn: [")
        _, h, _ = self.get("Karing/1.2 clash")
        self.assertIn("yaml", h["content-type"])

    def test_upstream_fails_fallback(self):
        write(RULES)
        fake = ks.upstream
        ks.upstream = lambda sub_id, ua, *a: (500, {}, b"") if ua == ks.LINKS_UA else fake(sub_id, ua, *a)
        _, h, _ = self.get("Karing/1.2 clash")
        self.assertIn("yaml", h["content-type"])

    def test_other_apps_untouched(self):
        # Регрессия: Mihomo, Happ, v2rayN, браузер – один запрос к панели с их User-Agent, без sing-box
        write(RULES)
        for ua in ("FlClash/0.8", "clash-verge/v2", "Happ/1.0", "v2rayN/7.0", "Mozilla/5.0", "sing-box/1.12", ""):
            self.calls.clear()
            _, h, body = self.get(ua)
            self.assertEqual(self.calls[0][1], ua, ua)  # Mihomo-приложения ещё подмешивают «-awg» – как раньше
            self.assertNotIn(ks.LINKS_UA, [c[1] for c in self.calls], ua)
            self.assertNotIn("application/json", h["content-type"], ua)

    def test_mihomo_still_gets_rules(self):
        write(RULES)
        _, _, body = self.get("FlClash/0.8")
        self.assertEqual(yaml.safe_load(body)["rules"][-1], "MATCH,DIRECT")

    def test_awg_and_extra_paths_untouched(self):
        write(RULES)
        for path in (ks.PATH + "abc123-awg", ks.PATH + "abc123-tg"):
            self.calls.clear()
            self.get("Karing/1.2 clash", path)
            self.assertEqual([c[1] for c in self.calls], ["Karing/1.2 clash"], path)


if __name__ == "__main__":
    unittest.main(verbosity=1)
