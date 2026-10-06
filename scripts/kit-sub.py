#!/usr/bin/env python3
"""Подписка с учётом приложения – посредник перед подпиской 3X-UI.

https://github.com/itsnotkubrick/3X-UI_KIT

Слушает публичный адрес подписки (HTTPS) и ходит в подписку 3X-UI на 127.0.0.1:
  * Clash / Mihomo (Clash Verge, FlClash, Mihomo Party…) – конфиг 3X-UI плюс AmneziaWG
    из подписки «<id>-awg»: Mihomo умеет AmneziaWG, а остальные приложения нет;
  * Karing и Hiddify при включённой раздельной маршрутизации (rules.yaml) – конфиг sing-box с правилами;
  * остальные приложения и браузер – ответ 3X-UI как есть (ссылки или страница);
  * заголовок Subscription-Userinfo: expire=0 («бессрочно») убирается – иначе
    приложения показывают срок «01.01.1970».

Настройки – /etc/kit-sub/config.json. Сертификат перечитывается сам после продления.
"""

import base64
import binascii
import http.client
import http.server
import ipaddress
import json
import os
import re
import socket
import sys
import ssl
import threading
import time
import urllib.error
import urllib.parse
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
# Karing и Hiddify (ядро sing-box) при включённой раздельной маршрутизации получают конфиг sing-box с правилами.
# Karing в User-Agent перечисляет и clash, и mihomo – поэтому эта проверка идёт раньше проверки на Clash.
SINGBOX_UA = re.compile(r"karing|hiddify", re.I)
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


JSON_FIX_MAX = 2 * 1024 * 1024


def fix_vless_encryption(body):
    """JSON-подписка панели: у vless-пользователя без encryption (нет поля или пусто) ставим "none" – Xray иначе
    не принимает конфиг. Две формы: vnext[].users[] и плоская (settings.id/encryption). Непустое значение
    (например, mlkem) не трогаем. Не разобралось, слишком большое или менять нечего – тело как пришло."""
    if len(body) > JSON_FIX_MAX:
        return body
    try:
        data = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeError, RecursionError):
        log("JSON-подписка: тело не разобралось, отдаю как есть")
        return body
    changed = False

    def fix(user):
        nonlocal changed
        if isinstance(user, dict) and (user.get("encryption") is None or user.get("encryption") == ""):
            user["encryption"] = "none"
            changed = True

    for cfg in (data if isinstance(data, list) else [data]):
        outs = cfg.get("outbounds") if isinstance(cfg, dict) else None
        for o in outs if isinstance(outs, list) else []:
            st = o.get("settings") if isinstance(o, dict) and o.get("protocol") == "vless" else None
            if not isinstance(st, dict):
                continue
            for v in st.get("vnext") if isinstance(st.get("vnext"), list) else []:
                for u in v.get("users") if isinstance(v, dict) and isinstance(v.get("users"), list) else []:
                    fix(u)
            if "id" in st:
                fix(st)
    return json.dumps(data, ensure_ascii=False).encode() if changed else body


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
        data = yaml.safe_load(raw.decode("utf-8-sig")) or {}
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
        kind, _, value = r.partition(",")
        r = kind.upper() + "," + value  # «domain-suffix,…» тоже понимаем
        m = RULE_RE.match(r)
        if not m:
            say(f"правила: пропускаю непонятное правило {str(item)[:80]!r}")
            continue
        kind, value = m.group(1), m.group(2)
        if kind in ("IP-CIDR", "IP-CIDR6"):
            try:
                net = ipaddress.ip_network(value, strict=False)
            except ValueError:
                net = None
            if net is None or net.version != (6 if kind == "IP-CIDR6" else 4):
                say(f"правила: неверная подсеть {value!r} – пропускаю")
                continue
        if kind == "DOMAIN-KEYWORD" and len(value) < 4:
            say(f"правила: слово {value!r} слишком короткое (под него попадёт почти всё) – пропускаю")
            continue
        if (kind, value) not in seen and len(rules) < RULES_MAX_COUNT:
            seen.add((kind, value))
            rules.append((kind, value))
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


# --- Конфиг sing-box для Karing и Hiddify (формат sing-box 1.12 и новее) ---
# Источник – обычный список ссылок той же подписки (запрашивается у 3X-UI с нейтральным User-Agent), правила – из load_rules().
# Всё собирается словарями и выдаётся через json.dumps: значения из ссылок и rules.yaml в JSON не склеиваются строками.
# Не попадают: XHTTP, WireGuard, AmneziaWG, MTProto (sing-box их не умеет или им нужен отдельный формат), а также
# подключения с закреплённым отпечатком или без проверки сертификата (sing-box не умеет закреплять – не ослабляем проверку).
LINKS_UA = "kit-sub"
SB_PROXY, SB_AUTO, SB_DIRECT = "Прокси", "Авто", "direct"
SRS_URL = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/{}/{}.srs"
SRS_NAME = re.compile(r"^[a-z0-9][a-z0-9_.!@-]{0,79}$")  # без «/», «:», «%» и «..»: адрес загрузки не уходит из папки
SB_HOST = re.compile(r"^[A-Za-z0-9.:-]{1,253}$")
SB_FP = ("chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized")
SS_METHODS = ("aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "chacha20-ietf-poly1305", "xchacha20-poly1305",
              "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305")


def srs_ok(name):
    return bool(SRS_NAME.match(name)) and ".." not in name


def _b64(s):
    s = re.sub(r"\s+", "", s).replace("-", "+").replace("_", "/")
    return base64.b64decode(s + "=" * (-len(s) % 4), validate=True).decode("utf-8")


def _host_port(u):
    host, port = u.hostname or "", u.port or 443  # u.port сам бросает ValueError на мусор
    if not SB_HOST.match(host) or not 1 <= port <= 65535:
        raise ValueError("адрес")
    return {"server": host, "server_port": port}


def _first(q, *keys):
    return next((q[k][0] for k in keys if q.get(k) and q[k][0]), "")


def _truthy(v):
    return v in ("1", "true", "True")


def _sb_tls(q, server, default="none"):
    sec = (_first(q, "security") or default).lower()
    if sec == "none":
        return None
    if sec not in ("tls", "reality") or _first(q, "pcs", "pinSHA256") or _truthy(_first(q, "allowInsecure", "insecure")):
        raise ValueError("tls")
    t = {"enabled": True, "server_name": _first(q, "sni", "peer") or _first(q, "host") or server}
    alpn = [a.strip() for a in _first(q, "alpn").split(",") if a.strip()]
    if alpn:
        t["alpn"] = alpn
    fp = _first(q, "fp") or ("chrome" if sec == "reality" else "")
    if fp:  # отпечаток, которого sing-box не знает, сломал бы весь конфиг
        t["utls"] = {"enabled": True, "fingerprint": fp if fp in SB_FP else "chrome"}
    if sec == "reality":
        if not _first(q, "pbk"):
            raise ValueError("pbk")
        t["reality"] = {"enabled": True, "public_key": _first(q, "pbk")}
        if _first(q, "sid"):
            t["reality"]["short_id"] = _first(q, "sid")
    return t


def _sb_transport(q):
    net = (_first(q, "type") or "tcp").lower()
    path, host = _first(q, "path") or "/", _first(q, "host")
    if net in ("tcp", "raw"):
        if _first(q, "headerType") == "http":
            return {"type": "http", "path": path, **({"host": [host]} if host else {})}
        return None
    if net == "ws":
        return {"type": "ws", "path": path, **({"headers": {"Host": host}} if host else {})}
    if net == "httpupgrade":
        return {"type": "httpupgrade", "path": path, **({"host": host} if host else {})}
    if net == "grpc":
        sn = _first(q, "serviceName", "path")
        return {"type": "grpc", **({"service_name": sn} if sn else {})}
    raise ValueError("транспорт " + net)  # xhttp и прочее sing-box не умеет


def _sb_vmess(link):
    j = json.loads(_b64(link[len("vmess://"):].split("#")[0]))
    if not isinstance(j, dict) or not j.get("id") or not j.get("add"):
        raise ValueError("vmess")
    net = str(j.get("net") or "tcp")
    q = {"type": [net], "security": [str(j.get("tls") or "none")]}
    for k, src in (("host", "host"), ("sni", "sni"), ("alpn", "alpn"), ("fp", "fp"), ("pbk", "pbk"), ("sid", "sid")):
        if j.get(src):
            q[k] = [str(j[src])]
    if j.get("path"):
        q["serviceName" if net == "grpc" else "path"] = [str(j["path"])]
    if j.get("type") and j["type"] != "none" and net != "grpc":
        q["headerType"] = [str(j["type"])]
    u = urllib.parse.urlsplit("vmess://x@" + ("[%s]" % j["add"] if ":" in str(j["add"]) else str(j["add"])) + ":" + str(j.get("port")))
    o = {"type": "vmess", **_host_port(u), "uuid": str(j["id"]), "security": str(j.get("scy") or "auto"),
         "alter_id": int(j.get("aid") or 0)}
    return str(j.get("ps") or ""), o, q


def sb_outbound(link):
    """Одна ссылка → (имя, outbound sing-box). Неподдерживаемое – ValueError."""
    scheme = link.split("://", 1)[0].lower()
    if scheme == "vmess":
        name, o, q = _sb_vmess(link)
    else:
        u = urllib.parse.urlsplit(link)
        q = urllib.parse.parse_qs(u.query)
        name = urllib.parse.unquote(u.fragment)
        user = urllib.parse.unquote(u.username or "")
        if scheme == "vless":
            if not user or _first(q, "encryption") not in ("", "none"):
                raise ValueError("vless")
            o = {"type": "vless", **_host_port(u), "uuid": user}
            if _first(q, "flow"):
                o["flow"] = _first(q, "flow")
        elif scheme == "trojan":
            if not user:
                raise ValueError("trojan")
            o = {"type": "trojan", **_host_port(u), "password": user}
            q.setdefault("security", ["tls"])
        elif scheme == "ss":
            if _first(q, "plugin"):
                raise ValueError("ss plugin")
            info = user if ":" in user else _b64(user)
            method, _, pw = info.partition(":")
            if method.lower() not in SS_METHODS or not pw:
                raise ValueError("ss")
            return name, {"type": "shadowsocks", **_host_port(u), "method": method.lower(), "password": pw}
        elif scheme in ("hy2", "hysteria2", "tuic"):
            if re.search(r":\d+[-,]", u.netloc) or _first(q, "pinSHA256") or _truthy(_first(q, "insecure", "allow_insecure")):
                raise ValueError(scheme)
            pw = urllib.parse.unquote(u.password or "")
            t = {"enabled": True, "server_name": _first(q, "sni") or u.hostname or ""}
            alpn = [a.strip() for a in _first(q, "alpn").split(",") if a.strip()]
            if scheme == "tuic":
                if not user or not pw:
                    raise ValueError("tuic")
                t["alpn"] = alpn or ["h3"]
                return name, {"type": "tuic", **_host_port(u), "uuid": user, "password": pw, "tls": t,
                              "congestion_control": _first(q, "congestion_control") or "bbr",
                              "udp_relay_mode": _first(q, "udp_relay_mode") or "native"}
            auth = user + (":" + pw if pw else "")
            if not auth:
                raise ValueError("hy2")
            if alpn:
                t["alpn"] = alpn
            o = {"type": "hysteria2", **_host_port(u), "password": auth, "tls": t}
            obfs = _first(q, "obfs")
            if obfs:
                if obfs != "salamander":
                    raise ValueError("obfs")
                o["obfs"] = {"type": "salamander", "password": _first(q, "obfs-password")}
            return name, o
        else:
            raise ValueError(scheme)  # vpn:// (AmneziaWG), tg://, wireguard:// и прочее
    tls = _sb_tls(q, o["server"])
    if tls:
        o["tls"] = tls
    tr = _sb_transport(q)
    if tr:
        o["transport"] = tr
    return name, o


def singbox_config(links_body, loaded):
    """Список ссылок 3X-UI + правила → конфиг sing-box (bytes) или None, если не из чего собрать (тогда подписка прежняя).
    Через VPN – только список, остальное напрямую (final: direct). DNS без утечек: имена из списка разрешаются по DoH
    через VPN (detour), остальные – системным DNS или direct_dns; DoH-серверы 1.1.1.1 и 8.8.8.8 и сами идут через VPN.
    Категории GEOSITE/GEOIP – готовые наборы .srs с фиксированного адреса, скачиваются тоже через VPN (download_detour)."""
    if len(links_body) > JSON_FIX_MAX:
        return None
    text = links_body.decode("utf-8", "replace").strip()
    if "://" not in text:
        try:
            text = _b64(text)
        except (ValueError, UnicodeError):
            return None
    outs, tags = [], {SB_PROXY, SB_AUTO, SB_DIRECT}
    for line in text.splitlines():
        line = line.strip()
        if not line or "://" not in line:
            continue
        try:
            name, o = sb_outbound(line)
        except (ValueError, KeyError, TypeError, UnicodeError, binascii.Error, RecursionError):
            continue
        base = re.sub(r"[\x00-\x1f\x7f]", "", name).strip()[:64] or o["type"]
        tag, n = base, 2
        while tag in tags:
            tag, n = f"{base} {n}", n + 1
        tags.add(tag)
        outs.append({"tag": tag, **o})
    if not outs:
        return None
    names = [o["tag"] for o in outs]
    rules, direct_dns = loaded

    def pick(kind):  # без повторов, домены – строчными
        out = []
        for k, v in rules:
            v = v.lower() if k != "IP-CIDR" and k != "IP-CIDR6" else v
            if k == kind and v not in out:
                out.append(v)
        return out

    sets = [(kind, v) for kind in ("geosite", "geoip") for v in pick(kind.upper()) if srs_ok(v)]
    dom = {"domain": pick("DOMAIN"), "domain_suffix": pick("DOMAIN-SUFFIX"), "domain_keyword": pick("DOMAIN-KEYWORD")}
    # Каждое правило – с непустым условием: пустое правило в sing-box совпадает со всем.
    by_name = [r for r in ({k: v for k, v in dom.items() if v},
                           {"rule_set": [f"geosite-{v}" for k, v in sets if k == "geosite"]}) if any(r.values())]
    by_ip = [r for r in ({"ip_cidr": pick("IP-CIDR") + pick("IP-CIDR6")},
                         {"rule_set": [f"geoip-{v}" for k, v in sets if k == "geoip"]}) if any(r.values())]
    if not by_name and not by_ip:
        return None
    dns_servers = [{"type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "detour": SB_PROXY},
                   {"type": "local", "tag": "dns-local"},
                   # Имена самих серверов (если сервер задан доменом) – по DoH напрямую, как в подписке Mihomo.
                   {"type": "https", "tag": "dns-bootstrap", "server": "1.1.1.1"}]
    final_dns = "dns-local"
    if direct_dns:
        d = urllib.parse.urlsplit(direct_dns[0])
        srv = {"type": "https", "tag": "dns-direct", "server": d.hostname, "path": d.path or "/dns-query"}
        if d.port:
            srv["server_port"] = d.port
        try:
            ipaddress.ip_address(d.hostname)
        except ValueError:
            srv["domain_resolver"] = "dns-bootstrap"
        dns_servers.append(srv)
        final_dns = "dns-direct"
    dns_rules = [dict(r, server="dns-proxy") for r in by_name]
    route_rules = [{"action": "sniff"}, {"protocol": "dns", "action": "hijack-dns"},
                   {"ip_is_private": True, "outbound": SB_DIRECT},
                   {"ip_cidr": ["1.1.1.1/32", "8.8.8.8/32"], "outbound": SB_PROXY}] + [dict(r, outbound=SB_PROXY) for r in by_name + by_ip]
    auto = [SB_AUTO] if len(outs) > 1 else []
    cfg = {
        "log": {"level": "warn"},
        "dns": {"servers": dns_servers, "rules": dns_rules, "final": final_dns, "strategy": "ipv4_only"},
        "outbounds": [{"type": "selector", "tag": SB_PROXY, "outbounds": auto + names, "default": (auto + names)[0]}]
        + ([{"type": "urltest", "tag": SB_AUTO, "outbounds": names, "url": "https://www.gstatic.com/generate_204",
             "interval": "5m", "tolerance": 100}] if auto else [])
        + outs + [{"type": "direct", "tag": SB_DIRECT}],
        "route": {"rules": route_rules,
                  "rule_set": [{"type": "remote", "tag": f"{k}-{v}", "format": "binary", "url": SRS_URL.format(k, v),
                                "download_detour": SB_PROXY} for k, v in sets],
                  "final": SB_DIRECT, "auto_detect_interface": True, "default_domain_resolver": "dns-bootstrap"},
    }
    if not cfg["route"]["rule_set"]:
        del cfg["route"]["rule_set"]
    return json.dumps(cfg, ensure_ascii=False, indent=1).encode()


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
        if prefix == PATH and SUB_ID.match(sub_id) and not sub_id.endswith(("-awg", "-tg")) and SINGBOX_UA.search(ua[:512]):
            # Karing и Hiddify: при включённой раздельной маршрутизации – конфиг sing-box с правилами. User-Agent приложения
            # нужен только для выбора формата: панели уходит нейтральный, в ответ он не попадает. Не вышло – подписка прежняя.
            loaded = load_rules()
            if loaded:
                scode, sheaders, sbody = upstream(sub_id, LINKS_UA, host, "*/*", prefix)
                try:
                    out = singbox_config(sbody, loaded) if scode == 200 else None
                except (ValueError, TypeError, KeyError, UnicodeError) as e:
                    log(f"конфиг sing-box не собран: {e}")
                    out = None
                if out:
                    log(f"{ua[:80]!r} → sing-box+rules")
                    sheaders = {k: v for k, v in sheaders.items() if k not in ("content-type", "content-disposition")}
                    sheaders["content-type"] = "application/json; charset=utf-8"
                    return self.reply(200, sheaders, out)
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
            elif code == 200 and ("json" in headers.get("content-type", "") or (
                    "text/plain" in headers.get("content-type", "") and body.lstrip()[:1] in (b"[", b"{"))):
                # Панель 3.9 отдаёт JSON-подписку с Content-Type text/plain – определяем по телу.
                body = fix_vless_encryption(body)
            elif code == 200 and "text/plain" in headers.get("content-type", ""):
                body = strip_links(body)
            if code == 200 and clash and CONF.get("auto", True):
                body = add_auto(body)
            if code == 200 and clash and CONF.get("dns", True):
                body = add_dns(body)
            if code == 200 and awg:
                # Правила – только приложениям на ядре Mihomo (проверено: geosite, sniffer, nameserver-policy). Karing, Hiddify
                # и другие на sing-box тоже могут просить формат Clash, но свою маршрутизацию они ведут сами: им подписка прежняя.
                loaded = load_rules()
                if loaded:
                    body = apply_rules(body, loaded)
        except (yaml.YAMLError, UnicodeError) as e:
            log(f"не удалось обработать подписку: {e}")
        self.reply(code, headers, body)

    def reply(self, code, headers, body):
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


def routing_payload(kind, loaded):
    """Профиль маршрутизации для самой панели 3X-UI (она раздаёт его приложениям на Xray): kind = happ | json.
    happ – заголовок Routing для Happ: через VPN только список, GlobalProxy=false.
    json – правила для JSON-подписки Xray (серверы DoH 1.1.1.1 и 8.8.8.8 – тоже через VPN); конструктор панели всегда ставит в конец «всё через прокси», поэтому остальное
    отправляем напрямую раньше (порядок block-proxy-direct, прямые regexp:.* и 0.0.0.0/0)."""
    rules, direct_dns = loaded
    sites, ips = [], []
    for k, v in rules:
        if k == "GEOSITE":
            sites.append("geosite:" + v)
        elif k == "DOMAIN-SUFFIX":
            sites.append("domain:" + v)
        elif k == "DOMAIN":
            sites.append("full:" + v)
        elif k == "DOMAIN-KEYWORD":
            sites.append(v)
        elif k == "GEOIP":
            ips.append("geoip:" + v)
        else:
            ips.append(v)
    if kind == "happ":
        data = {"Name": "3X-UI KIT", "GlobalProxy": "false", "DomainStrategy": "IPIfNonMatch", "ProxySites": sites,
                "ProxyIp": ips, "DirectIp": ["geoip:private"]}
    else:
        # localhost – системный DNS клиента для прямых сайтов (как в подписке Mihomo); список direct_dns его заменяет.
        data = {"Name": "3X-UI KIT", "DomainStrategy": "IPIfNonMatch", "RouteOrder": "block-proxy-direct",
                "ProxySites": sites, "ProxyIp": ["1.1.1.1", "8.8.8.8"] + ips, "DirectSites": ["regexp:.*"],
                "DirectIp": ["geoip:private", "0.0.0.0/0", "::/0"], "DomesticDNSDomain": direct_dns[0] if direct_dns else "localhost"}
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # Happ ждёт в заголовке ссылку happ://routing/onadd/<base64>; панели для JSON-подписки нужен обычный JSON.
    return "happ://routing/onadd/" + base64.b64encode(text.encode()).decode() if kind == "happ" else text


GEO_URL = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/{}.dat"


def unknown_geo(kind, names):
    """Сверяет категории GEOSITE/GEOIP с базой, которую скачают приложения: неизвестное имя ломает запуск конфига у клиента.
    Нет доступа к GitHub – не проверяем."""
    if not names:
        return []
    try:
        with urllib.request.urlopen(GEO_URL.format(kind), timeout=30) as r:
            data = r.read(48 * 1024 * 1024)
    except (urllib.error.URLError, OSError) as e:
        print(f"Категории {kind.upper()} не проверил: база недоступна ({e}). Названия сверьте по github.com/MetaCubeX/meta-rules-dat.")
        return []
    return [n for n in names if b"\x0a" + bytes([len(n)]) + n.upper().encode() not in data]


def unknown_srs(kind, names):
    """То же для Karing и Hiddify: у каждой категории должен быть готовый набор .srs (иначе sing-box не запустит конфиг).
    Имя с недопустимыми символами в их конфиг не попадает – о нём тоже сообщаем. Нет доступа к GitHub – не проверяем."""
    bad = []
    for n in names:
        if not srs_ok(n.lower()):
            bad.append(n)
            continue
        try:
            req = urllib.request.Request(SRS_URL.format(kind, n.lower()), method="HEAD")
            urllib.request.urlopen(req, timeout=15).close()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                bad.append(n)
        except (urllib.error.URLError, OSError) as e:
            print(f"Наборы {kind.upper()} для Karing и Hiddify не проверил: GitHub недоступен ({e}).")
            break
    return bad


def main():
    if "--routing-payload" in sys.argv:
        # kit net split: профиль для панели (для Happ и Xray); пусто и код 1, если правил нет.
        loaded = load_rules(report=lambda m: print(m, file=sys.stderr))
        if not loaded:
            raise SystemExit(1)
        print(routing_payload(sys.argv[sys.argv.index("--routing-payload") + 1], loaded))
        raise SystemExit(0)
    if "--check-rules" in sys.argv:
        # kit net split check: тот же разбор, что и при выдаче подписки, но с отчётом на экран.
        loaded = load_rules(report=print)
        if loaded:
            print(f"Правил через VPN: {len(loaded[0])}; DNS для остального: {', '.join(loaded[1]) or 'системный'}")
            bad = [f"{k} {n}" for k in ("geosite", "geoip") for n in unknown_geo(k, [v for kk, v in loaded[0] if kk == k.upper()])]
            if not bad:  # по базе всё есть – сверяем ещё наборы sing-box (Karing и Hiddify)
                bad = [f"{k} {n}" for k in ("geosite", "geoip") for n in unknown_srs(k, [v for kk, v in loaded[0] if kk == k.upper()])]
            if bad:
                print("Нет такой категории: " + ", ".join(bad) + ". Приложение не сможет запустить конфиг – исправьте или удалите эти строки.")
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
