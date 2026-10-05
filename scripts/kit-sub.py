#!/usr/bin/env python3
"""Подписка с учётом приложения – посредник перед подпиской 3X-UI.

https://github.com/itsnotkubrick/3X-UI_KIT

Слушает публичный адрес подписки (HTTPS) и ходит в подписку 3X-UI на 127.0.0.1:
  * Clash / Mihomo (Clash Verge, FlClash, Mihomo Party…) – конфиг 3X-UI плюс AmneziaWG
    из подписки «<id>-awg»: Mihomo умеет AmneziaWG, а остальные приложения нет;
  * остальные приложения и браузер – ответ 3X-UI как есть (ссылки или страница);
  * заголовок Subscription-Userinfo: expire=0 («бессрочно») убирается – иначе
    приложения показывают срок «01.01.1970».

Настройки – /etc/kit-sub/config.json. Сертификат перечитывается сам после продления.
"""

import base64
import http.client
import http.server
import json
import os
import re
import socket
import sys
import ssl
import threading
import time
import urllib.error
import urllib.request

import yaml

# Под systemd kit-sub работает без root (DynamicUser): конфиг и сертификат ему передаёт
# systemd через LoadCredential в $CREDENTIALS_DIRECTORY.
CREDS = os.environ.get("CREDENTIALS_DIRECTORY", "")
CONFIG = os.environ.get("KIT_SUB_CONFIG") or (
    os.path.join(CREDS, "config.json") if CREDS and os.path.exists(os.path.join(CREDS, "config.json")) else "/etc/kit-sub/config.json")
CLASH_UA = re.compile(r"clash|mihomo|flclash|stash|nyanpasu|meta", re.I)
# AmneziaWG добавляем только приложениям на ядре Mihomo. Karing, Hiddify и другие на sing-box
# тоже могут просить формат Clash (Karing так и делает), но AmneziaWG не умеют.
NO_AWG_UA = re.compile(r"karing|hiddify|nekobox|sing-?box|husi|stash|shadowrocket|v2box|streisand|happ|loon|surge|quantumult", re.I)
SUB_ID = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
# Страница подписки для браузера (React от 3X-UI) подгружает скрипты и стили из «<путь>/assets/…»: пропускаем только такие файлы.
ASSET = re.compile(r"^assets/[A-Za-z0-9_.-]{1,128}\.(js|css|woff2?|svg|png|ico|map)$")
# Заголовки Happ, которые 3X-UI отдаёт в подписке (маршрутизация, баннеры, настройки клиента).
HAPP_HEADERS = ("routing", "routing-enable", "announce", "providerid", "new-url", "fallback-url",
                "hide-settings", "no-limit-enabled", "ping-type", "color-profile", "tun-mode", "tun-type",
                "exclude-routes", "exclude-apns-enable", "per-app-proxy-mode", "per-app-proxy-list",
                "notification-subs-expire", "sub-expire", "sub-expire-button-link", "sub-info-text",
                "sub-info-color", "sub-info-button-text", "sub-info-button-link",
                "subscription-autoconnect", "subscription-autoconnect-type", "subscription-always-hwid-enable")
PASS_HEADERS = ("content-type", "content-disposition", "profile-title", "profile-update-interval",
                "profile-web-page-url", "subscription-userinfo", "support-url", "cache-control") + HAPP_HEADERS

with open(CONFIG, encoding="utf-8") as f:
    CONF = json.load(f)
PATH = "/" + CONF["path"].strip("/") + "/"
# Раздельная маршрутизация (необязательно): /etc/kit-sub/rules.yaml – через VPN только перечисленное, остальное напрямую.
# Файл читается при каждом запросе подписки, перезапуск не нужен. Нет файла или он битый – подписка как обычно (всё через VPN).
RULES_FILE = os.environ.get("KIT_SUB_RULES") or "/etc/kit-sub/rules.yaml"
RULES_MAX_BYTES, RULES_MAX_COUNT = 65536, 300
RULE_RE = re.compile(r"^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|GEOSITE|IP-CIDR|IP-CIDR6|GEOIP),([A-Za-z0-9._:/!@+-]{1,120})$")
DOH_RE = re.compile(r"^https://[A-Za-z0-9.-]{1,100}(:\d{1,5})?/[A-Za-z0-9._/-]{0,60}$")
DOH_DEFAULT = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
PRIVATE_NETS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16"]
# Дополнительные пути, которые панель показывает на странице подписки (Clash и JSON): обрабатываются так же, как основной.
EXTRA = ["/" + x.strip("/") + "/" for x in CONF.get("extra_paths", []) if isinstance(x, str) and re.fullmatch(r"/?[A-Za-z0-9_-]+/?", x)]


def log(msg):
    print(msg, flush=True)


def upstream(sub_id, ua, host, accept, prefix=None):
    """GET к подписке 3X-UI. Возвращает (код, заголовки, тело) или (None, {}, b"")."""
    req = urllib.request.Request(CONF["upstream"].rstrip("/") + (prefix or PATH) + sub_id, headers={
        "User-Agent": ua, "Host": host, "Accept": accept or "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, http.client.HTTPException, OSError, socket.timeout) as e:
        log(f"upstream недоступен: {e}")
        return None, {}, b""


def fix_userinfo(value):
    # «expire=0» значит «бессрочно», но приложения рисуют 01.01.1970 – убираем.
    parts = [p.strip() for p in value.split(";") if p.strip() and p.strip() != "expire=0"]
    return "; ".join(parts)


def strip_links(body):
    """Список ссылок (base64 или текст) без vpn:// и tg:// – их не умеет ни одно VPN-приложение
    со ссылками: vpn:// – конфиг для AmneziaVPN, tg:// – прокси для Telegram."""
    text = body.decode("utf-8", "replace").strip()
    encoded = "://" not in text
    if encoded:
        try:
            text = base64.b64decode(text + "=" * (-len(text) % 4)).decode("utf-8", "replace")
        except ValueError:
            return body
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith(("vpn://", "tg://"))]
    out = "\n".join(lines)
    return base64.b64encode(out.encode()).decode().encode() if encoded else out.encode()


def strip_awg(clash_yaml):
    """Clash-конфиг без AmneziaWG – для приложений, которые его не умеют."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    awg = {p.get("name") for p in cfg.get("proxies") or [] if isinstance(p, dict) and "amnezia-wg-option" in p}
    if not awg:
        return clash_yaml
    cfg["proxies"] = [p for p in cfg["proxies"] if p.get("name") not in awg]
    for g in cfg.get("proxy-groups") or []:
        if isinstance(g.get("proxies"), list):
            g["proxies"] = [x for x in g["proxies"] if x not in awg]
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def merge_awg(main_yaml, awg_yaml):
    """Добавляет прокси AmneziaWG в Clash-конфиг и во все группы, где перечислены прокси."""
    main = yaml.safe_load(main_yaml)
    awg = yaml.safe_load(awg_yaml)
    if not isinstance(main, dict) or not isinstance(awg, dict):
        return main_yaml
    extra = [p for p in (awg.get("proxies") or []) if isinstance(p, dict) and p.get("name")]
    if not extra:
        return main_yaml
    names = {p.get("name") for p in main.get("proxies") or []}
    for p in extra:
        # 3X-UI дописывает к имени запись-«двойника» («AmneziaWG-3.1-sasha-awg») – убираем хвост.
        p["name"] = re.sub(r"-[^-\s]+-awg\d*$", "", p["name"]) or p["name"]
        base, n = p["name"], 2
        while p["name"] in names:
            p["name"] = f"{base} {n}"
            n += 1
        names.add(p["name"])
    main.setdefault("proxies", []).extend(extra)
    added = [p["name"] for p in extra]
    for g in main.get("proxy-groups") or []:
        lst = g.get("proxies")
        if isinstance(lst, list) and any(x in names for x in lst):
            pos = lst.index("DIRECT") if "DIRECT" in lst else len(lst)
            g["proxies"] = lst[:pos] + added + lst[pos:]
    return yaml.safe_dump(main, allow_unicode=True, sort_keys=False).encode()


AUTO_GROUP = "Авто"


def add_auto(clash_yaml):
    """Группа «Авто» (url-test): клиент сам выбирает самый быстрый из рабочих протоколов и переключается,
    когда один из них перестаёт отвечать. Ставится первой в выбор, поэтому берётся по умолчанию;
    вручную по-прежнему можно выбрать любой протокол."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    allp = [p for p in cfg.get("proxies") or [] if isinstance(p, dict) and p.get("name")]
    names = [p["name"] for p in allp]
    # WireGuard и AmneziaWG разрешают имена сайтов на самом клиенте (по обычному UDP внутри туннеля), поэтому в автовыбор
    # не входят: по умолчанию клиент идёт протоколами, где имя уходит на сервер. Вручную их выбрать по-прежнему можно.
    auto_names = [p["name"] for p in allp if p.get("type") != "wireguard" and "amnezia-wg-option" not in p]
    groups = cfg.get("proxy-groups")
    if len(auto_names) < 2 or not isinstance(groups, list) or any(g.get("name") == AUTO_GROUP for g in groups if isinstance(g, dict)):
        return clash_yaml
    groups.insert(0, {"name": AUTO_GROUP, "type": "url-test", "url": "http://www.gstatic.com/generate_204",
                      "interval": 300, "tolerance": 100, "lazy": True, "proxies": auto_names})
    for g in groups[1:]:
        lst = g.get("proxies") if isinstance(g, dict) else None
        if isinstance(g, dict) and g.get("type") == "select" and isinstance(lst, list) and any(x in names for x in lst):
            g["proxies"] = [AUTO_GROUP] + lst
            break
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


# DNS в Clash-подписке: 3X-UI профиль без раздела dns не присылает, и как клиент будет разрешать имена, зависит от
# самого приложения (системный DNS, возможны утечки). Добавляем безопасный вариант, если своего dns в профиле нет:
# fake-ip, запросы идут как обычный трафик по правилам (то есть через прокси) и по DoH, без запасного локального DNS.
# Адреса серверов имён – числовые, чтобы не нужен был ещё один запрос для их поиска.
DNS_BLOCK = {
    "enable": True,
    "ipv6": False,
    "enhanced-mode": "fake-ip",
    "fake-ip-range": "198.18.0.1/16",
    "fake-ip-filter": ["*.lan", "+.local"],
    "respect-rules": True,
    "default-nameserver": ["1.1.1.1", "8.8.8.8"],
    "nameserver": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"],
    # Имена самих серверов (если сервер задан доменом) разрешаются напрямую, но по DoH.
    "proxy-server-nameserver": ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"],
}


def add_dns(clash_yaml):
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict) or "dns" in cfg:
        return clash_yaml
    cfg["dns"] = dict(DNS_BLOCK)
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def load_rules(report=None):
    """Читает RULES_FILE: список via_vpn («ТИП,ЗНАЧЕНИЕ») и необязательный direct_dns (адреса DoH для остального).
    Возвращает (правила, direct_dns) или None, если файла нет или он непригоден: тогда подписка остаётся прежней."""
    say = report or log
    try:
        with open(RULES_FILE, "rb") as f:
            raw = f.read(RULES_MAX_BYTES + 1)
    except FileNotFoundError:
        return None
    except OSError as e:
        say(f"правила: не удалось прочитать {RULES_FILE}: {e}")
        return None
    if len(raw) > RULES_MAX_BYTES:
        say(f"правила: файл больше {RULES_MAX_BYTES // 1024} КБ – не применяю")
        return None
    try:
        data = yaml.safe_load(raw.decode("utf-8")) or {}
    except (yaml.YAMLError, UnicodeError) as e:
        say(f"правила: файл не разобран ({e}) – не применяю")
        return None
    items = data.get("via_vpn") if isinstance(data, dict) else None
    if not isinstance(items, list) or not items:
        say("правила: нет списка via_vpn – не применяю")
        return None
    rules, seen = [], set()
    for item in items[:RULES_MAX_COUNT + 50]:
        r = re.sub(r"\s*,\s*", ",", str(item).strip())
        m = RULE_RE.match(r)
        if not m:
            say(f"правила: пропускаю непонятное правило {str(item)[:80]!r}")
        elif r not in seen and len(rules) < RULES_MAX_COUNT:
            seen.add(r)
            rules.append((m.group(1), m.group(2)))
    if not rules:
        say("правила: ни одного пригодного – не применяю")
        return None
    direct = data.get("direct_dns")
    direct = [d for d in direct if isinstance(d, str) and DOH_RE.match(d)][:4] if isinstance(direct, list) else []
    return rules, direct


def apply_rules(clash_yaml, loaded):
    """Раздельная маршрутизация. Перечисленное идёт через VPN (первая группа прокси), остальное – напрямую.
    DNS при этом не течёт: имена из списка в fake-ip режиме у клиента не разрешаются вовсе (сайт называется серверу),
    запросы про них (на случай IP-подключений) – по DoH через VPN, а для остальных – системный DNS или direct_dns."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    groups = [g.get("name") for g in cfg.get("proxy-groups") or [] if isinstance(g, dict) and g.get("name")]
    proxies = [p.get("name") for p in cfg.get("proxies") or [] if isinstance(p, dict) and p.get("name")]
    target = groups[0] if groups else proxies[0] if proxies else None
    if target is None:
        return clash_yaml
    rules, direct_dns = loaded
    out = [f"IP-CIDR,{n},DIRECT,no-resolve" for n in PRIVATE_NETS]
    # DoH-серверы – через VPN, чтобы запросы про сайты из списка не выходили мимо него.
    out += [f"IP-CIDR,{h}/32,{target},no-resolve" for h in ("1.1.1.1", "8.8.8.8")]
    policy = {}
    for kind, value in rules:
        # Правилам по адресам не даём разрешать имена (иначе это обычный DNS-запрос мимо VPN).
        out.append(f"{kind},{value},{target}" + (",no-resolve" if kind in ("IP-CIDR", "IP-CIDR6", "GEOIP") else ""))
        if kind == "GEOSITE":
            policy["geosite:" + value] = DOH_DEFAULT
        elif kind == "DOMAIN-SUFFIX":
            policy["+." + value] = DOH_DEFAULT
        elif kind == "DOMAIN":
            policy[value] = DOH_DEFAULT
    out.append("MATCH,DIRECT")
    cfg["mode"] = "rule"
    cfg["rules"] = out
    dns = dict(DNS_BLOCK)
    dns["nameserver"] = direct_dns or ["system"]
    if policy:
        dns["nameserver-policy"] = policy
    cfg["dns"] = dns
    # Для подключений по IP (без имени) домен берётся из TLS/HTTP/QUIC – иначе правила по доменам их не увидят.
    cfg["sniffer"] = {"enable": True, "override-destination": False,
                      "sniff": {"TLS": {"ports": [443, 8443]}, "HTTP": {"ports": [80, "8080-8880"]}, "QUIC": {"ports": [443]}}}
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    timeout = 20  # зависшие соединения не держим

    def setup(self):
        # TLS-рукопожатие – в потоке запроса, а не в общем цикле приёма соединений.
        # Без сертификата (за nginx, на 127.0.0.1) работаем по обычному HTTP.
        self.request.settimeout(self.timeout)
        if self.server.ssl_ctx is not None:
            self.request = self.server.ssl_ctx.wrap_socket(self.request, server_side=True)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, ConnectionError, socket.timeout, OSError):
            pass

    def log_message(self, fmt, *args):  # без IP клиентов в логах
        pass

    def send_plain(self, code, text=""):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        # Свои ответы вместо страницы ошибок Python, в том же виде, что у обычного nginx.
        self.close_connection = True
        self.send_html_error(code)

    def send_html_error(self, code):
        phrase = self.responses.get(code, ("Error",))[0]
        body = (f"<html>\r\n<head><title>{code} {phrase}</title></head>\r\n<body>\r\n<center><h1>{code} {phrase}</h1></center>\r\n"
                "<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_other(self):
        self.send_html_error(404)

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_other

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        prefix = next((x for x in (PATH, *EXTRA) if path.startswith(x)), None)
        if prefix is None:
            return self.send_html_error(404)
        sub_id = path[len(prefix):]
        if not SUB_ID.match(sub_id) and not (prefix == PATH and ASSET.match(sub_id)):
            return self.send_html_error(404)
        ua = self.headers.get("User-Agent", "")
        host = CONF.get("link_host") or self.headers.get("Host", CONF.get("host", ""))
        accept = self.headers.get("Accept", "")
        code, headers, body = upstream(sub_id, ua, host, accept, prefix)
        if code is None:
            return self.send_html_error(502)

        clash = (bool(CLASH_UA.search(ua)) or prefix != PATH) and "yaml" in headers.get("content-type", "")
        awg = clash and not NO_AWG_UA.search(ua)
        # В журнал – только приложение и что ему отдали, без IP.
        log(f"{ua[:80]!r} → {'clash+awg' if awg else 'clash' if clash else headers.get('content-type', '?').split(';')[0]}")
        try:
            if code == 200 and clash and not awg:
                body = strip_awg(body)
            elif code == 200 and awg and not sub_id.endswith(("-awg", "-tg")):
                # Установки до kit 1.1 держали AmneziaWG в подписке «<id>-awg» – подмешиваем её.
                acode, _, abody = upstream(sub_id + "-awg", ua, host, accept, prefix)
                if acode == 200 and abody:
                    body = merge_awg(body, abody)
            elif code == 200 and "text/plain" in headers.get("content-type", ""):
                body = strip_links(body)
            if code == 200 and clash and CONF.get("auto", True):
                body = add_auto(body)
            if code == 200 and clash and CONF.get("dns", True):
                body = add_dns(body)
            if code == 200 and clash:
                loaded = load_rules()
                if loaded:
                    body = apply_rules(body, loaded)
        except (yaml.YAMLError, UnicodeError) as e:
            log(f"не удалось обработать подписку: {e}")

        self.send_response(code)
        for k in PASS_HEADERS:
            if k in headers:
                v = fix_userinfo(headers[k]) if k == "subscription-userinfo" else headers[k]
                if v and "\r" not in v and "\n" not in v:
                    self.send_header(k.title(), v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    ssl_ctx = None

    def handle_error(self, request, client_address):  # обрывы TLS от сканеров – не ошибка
        pass
    address_family = socket.AF_INET6 if ":" in CONF.get("listen", "") else socket.AF_INET


GEOSITE_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"


def unknown_geosites(names):
    """Сверяет категории GEOSITE с базой, которую скачают приложения: неизвестное имя ломает запуск конфига у клиента.
    Нет доступа к GitHub – не проверяем (None-результат пустой)."""
    if not names:
        return []
    try:
        with urllib.request.urlopen(GEOSITE_URL, timeout=30) as r:
            data = r.read(32 * 1024 * 1024)
    except (urllib.error.URLError, OSError):
        print("Категории GEOSITE не проверил: база недоступна. Названия сверьте по github.com/MetaCubeX/meta-rules-dat (geo/geosite).")
        return []
    bad = []
    for n in names:
        b = n.upper().encode()
        if b"\x0a" + bytes([len(b)]) + b not in data:
            bad.append(n)
    return bad


def main():
    if "--check-rules" in sys.argv:
        # kit net split check: тот же разбор, что и при выдаче подписки, но с отчётом на экран.
        loaded = load_rules(report=print)
        if loaded:
            print(f"Правил через VPN: {len(loaded[0])}; DNS для остального: {', '.join(loaded[1]) or 'системный'}")
            unknown = unknown_geosites([v for k, v in loaded[0] if k == "GEOSITE"])
            if unknown:
                print("Нет такой категории GEOSITE: " + ", ".join(unknown) + ". Приложение не сможет запустить конфиг – исправьте или удалите эти строки.")
                raise SystemExit(2)
        raise SystemExit(0 if loaded else 1)
    cert, key = CONF.get("cert"), CONF.get("key")
    if cert and CREDS and os.path.exists(os.path.join(CREDS, "cert.pem")):
        cert, key = os.path.join(CREDS, "cert.pem"), os.path.join(CREDS, "key.pem")
    if not cert:
        srv = Server((CONF.get("listen", "127.0.0.1"), int(CONF["port"])), Handler)
        log(f"kit-sub слушает http://{CONF.get('listen', '127.0.0.1')}:{CONF['port']}{PATH} (TLS снимает nginx)")
        srv.serve_forever()
        return
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    stamp = [os.path.getmtime(cert)]

    def reload_cert():
        # Let's Encrypt на IP живёт 6 дней – после продления берём новый сертификат без перезапуска.
        while True:
            time.sleep(600)
            try:
                m = os.path.getmtime(cert)
                if m != stamp[0]:
                    ctx.load_cert_chain(cert, key)
                    stamp[0] = m
                    log("сертификат обновлён")
            except (OSError, ssl.SSLError) as e:
                log(f"не удалось перечитать сертификат: {e}")

    threading.Thread(target=reload_cert, daemon=True).start()
    srv = Server((CONF.get("listen", "0.0.0.0"), int(CONF["port"])), Handler)
    srv.ssl_ctx = ctx
    log(f"kit-sub слушает {CONF.get('listen', '0.0.0.0')}:{CONF['port']}{PATH}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
