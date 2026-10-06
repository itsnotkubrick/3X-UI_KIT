#!/usr/bin/env bash
# Проверка, подходит ли новая версия ядра Xray клиентам на Mihomo и sing-box (REALITY по TCP).
# Запускать от root на ТЕСТОВОМ сервере с установленным KIT: скрипт на время подменяет ядро панели
# проверенной по SHA256 версией, прогоняет клиентов и в любом случае возвращает прежнее ядро.
#
#   bash core-compat.sh v26.9.30            проверить версию ядра
#   bash core-compat.sh                     проверить то, что сейчас стоит (контроль)
#   MIHOMO=v1.19.32 SINGBOX=1.14.2 bash core-compat.sh v26.9.30     взять конкретные клиенты
#   MIHOMO_SHA256=… SINGBOX_SHA256=…        свои суммы архивов клиентов, если GitHub не прислал digest
set -Eeuo pipefail

CAND=${1:-}
BIN=/usr/local/x-ui/bin/xray-linux-amd64
W=$(mktemp -d); BAK=$W/xray.orig
[[ $EUID -eq 0 && -x $BIN ]] || { echo "Нужен root на сервере с панелью 3X-UI." >&2; exit 1; }
command -v kit >/dev/null || { echo "Нужен установленный kit." >&2; exit 1; }
arch=$(uname -m); case $arch in x86_64) xa=64; ma=amd64 ;; aarch64) xa=arm64-v8a; ma=arm64 ;; *) echo "Только amd64 и arm64." >&2; exit 1 ;; esac

restore() { if [[ -f $BAK ]]; then systemctl stop x-ui; install -m 755 "$BAK" "$BIN"; systemctl start x-ui; sleep 8; fi; pkill -f "$W/" 2>/dev/null || true; rm -rf "$W"; }
trap restore EXIT

gh() { curl -fsSL "$1"; }
latest_tag() { gh "https://api.github.com/repos/$1/releases?per_page=30" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if not r['prerelease'] and not r['draft']:
        print(r['tag_name']); break"; }

# --- ядро-кандидат ---
if [[ -n $CAND ]]; then
  cp -a "$BIN" "$BAK"
  gh "https://github.com/XTLS/Xray-core/releases/download/$CAND/Xray-linux-$xa.zip" >"$W/x.zip"
  gh "https://github.com/XTLS/Xray-core/releases/download/$CAND/Xray-linux-$xa.zip.dgst" >"$W/x.dgst"
  want=$(awk 'tolower($0) ~ /sha2-256/ {print $NF; exit}' "$W/x.dgst"); got=$(sha256sum "$W/x.zip" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || { echo "Сумма ядра $CAND не совпала – остановился." >&2; exit 1; }
  unzip -q -o "$W/x.zip" xray -d "$W"; systemctl stop x-ui; install -m 755 "$W/xray" "$BIN"; systemctl start x-ui; sleep 8
fi
echo "Ядро на сервере: $("$BIN" -version | head -1)"

# --- клиенты (суммы – из метаданных релиза) ---
fetch() { # репозиторий метка-файла-шаблон выходной-файл
  gh "https://api.github.com/repos/$1/releases/tags/$2" | python3 -c "
import json, re, sys
r = json.load(sys.stdin)
for a in r['assets']:
    if re.fullmatch(sys.argv[1], a['name']):
        print(a['browser_download_url'], (a.get('digest') or '').replace('sha256:', '')); break" "$3"; }
MV=${MIHOMO:-$(latest_tag MetaCubeX/mihomo)}; SV=${SINGBOX:-$(latest_tag SagerNet/sing-box | sed 's/^v//')}
read -r murl msum < <(fetch MetaCubeX/mihomo "$MV" "mihomo-linux-$ma-compatible-$MV.gz") || true
read -r surl ssum < <(fetch SagerNet/sing-box "v$SV" "sing-box-$SV-linux-$ma.tar.gz") || true
# Без суммы ничего не запускаем: либо digest из GitHub, либо закреплённая вручную.
msum=${MIHOMO_SHA256:-${msum:-}}; ssum=${SINGBOX_SHA256:-${ssum:-}}
[[ -n ${murl:-} && $msum =~ ^[0-9a-f]{64}$ ]] || { echo "Нет архива или SHA256 для mihomo $MV (GitHub не прислал digest) – не ставлю. Задайте MIHOMO_SHA256=… со страницы релиза." >&2; exit 1; }
[[ -n ${surl:-} && $ssum =~ ^[0-9a-f]{64}$ ]] || { echo "Нет архива или SHA256 для sing-box $SV (GitHub не прислал digest) – не ставлю. Задайте SINGBOX_SHA256=… со страницы релиза." >&2; exit 1; }
gh "$murl" >"$W/m.gz"; [[ $(sha256sum "$W/m.gz" | awk '{print $1}') == "$msum" ]] || { echo "Сумма mihomo не совпала." >&2; exit 1; }
gunzip -c "$W/m.gz" >"$W/mihomo"; chmod +x "$W/mihomo"
gh "$surl" >"$W/s.tgz"; [[ $(sha256sum "$W/s.tgz" | awk '{print $1}') == "$ssum" ]] || { echo "Сумма sing-box не совпала." >&2; exit 1; }
mkdir -p "$W/sb"; tar xzf "$W/s.tgz" -C "$W/sb" --strip-components=1

link=$(KIT_NO_QR=1 kit user link "${USER_NAME:-admin}" --all 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -a -E '^  vless://.*security=reality.*type=tcp' | head -1 | tr -d ' ')
[[ -n $link ]] || { echo "Не нашёл ссылку REALITY (tcp) у пользователя ${USER_NAME:-admin}." >&2; exit 1; }
export LINK=$link W

python3 - <<'PY'
import json, os
from urllib.parse import urlparse, parse_qs
u = urlparse(os.environ["LINK"]); q = {k: v[0] for k, v in parse_qs(u.query).items()}
W = os.environ["W"]
json.dump({"mixed-port": 17890, "log-level": "warning", "rules": ["MATCH,P"], "proxies": [{
    "name": "P", "type": "vless", "server": u.hostname, "port": u.port, "uuid": u.username, "network": "tcp", "tls": True,
    "udp": True, "flow": q.get("flow", ""), "servername": q["sni"], "client-fingerprint": q.get("fp", "chrome"),
    "reality-opts": {"public-key": q["pbk"], "short-id": q["sid"], "support-x25519mlkem768": q.get("support-x25519mlkem768") == "true"}}]}, open(W + "/m.yaml", "w"))
json.dump({"log": {"level": "warn"}, "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 17891}], "outbounds": [{
    "type": "vless", "server": u.hostname, "server_port": u.port, "uuid": u.username, "flow": q.get("flow", ""),
    "tls": {"enabled": True, "server_name": q["sni"], "utls": {"enabled": True, "fingerprint": q.get("fp", "chrome")},
            "reality": {"enabled": True, "public_key": q["pbk"], "short_id": q["sid"]}}}]}, open(W + "/s.json", "w"))
PY

probe() { # порт
  curl -sS -m 12 -x "http://127.0.0.1:$1" -o /dev/null -w '%{http_code}' "https://www.cloudflare.com/cdn-cgi/trace?x=$RANDOM" 2>/dev/null || true
}
setsid nohup "$W/mihomo" -d "$W" -f "$W/m.yaml" >"$W/m.log" 2>&1 </dev/null & sleep 5
mc=$(probe 17890); pkill -f "$W/mihomo" || true
setsid nohup "$W/sb/sing-box" run -c "$W/s.json" >"$W/s.log" 2>&1 </dev/null & sleep 4
sc=$(probe 17891); pkill -f "$W/sb/sing-box" || true

ok() { [[ $1 == 200 ]] && echo "работает" || echo "НЕ РАБОТАЕТ (http=${1:-000})"; }
echo
echo "Ядро Xray: ${CAND:-как стоит}"
echo "  Mihomo $MV:    $(ok "$mc")"
echo "  sing-box $SV:  $(ok "$sc")"
echo "Xray-клиенты (Happ, v2rayN) здесь не проверяются: они на том же ядре."
[[ $mc == 200 && $sc == 200 ]]
