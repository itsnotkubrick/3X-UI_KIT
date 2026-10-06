#!/usr/bin/env bash
# 3X-UI со всеми протоколами одной командой – https://github.com/itsnotkubrick/3X-UI_KIT
#
# Установка:  bash <(curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main/scripts/3x-ui.sh)
#
# Ставит официальную панель 3X-UI (версия закреплена ниже) её собственным
# установщиком, получает сертификат Let's Encrypt на IP, создаёт подключения
# REALITY, XHTTP, VLESS/VMess WS, Trojan gRPC, Shadowsocks 2022, Hysteria2, TUIC,
# AmneziaWG (классика и 3.1) и MTProto (и WireGuard по запросу), включает единую подписку
# с форматом под каждый клиент и настраивает ufw. Домены не нужны.

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail

# На свежем VPS в фоне идут автообновления системы и держат замок dpkg: ждём его, а не падаем.
apt-get() { command apt-get -o DPkg::Lock::Timeout=900 "$@"; }
wait_apt_idle() {
  local i
  pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null || return 0
  printf '%s\n' "==> Система сама ставит обновления – жду, пока закончит (до 15 минут)"
  for i in $(seq 1 180); do
    pgrep -f '/usr/bin/unattended-upgrade$|apt\.systemd\.daily' >/dev/null || return 0
    sleep 5
  done
  return 0
}

XUI_VERSION="v3.9.0"
# SHA256 установщика 3X-UI этой версии: тег могут передвинуть, а хеш – нет (проверено 2026-09-30).
XUI_INSTALL_SHA256="18616fe26c8f6c92db6daa2dcd7cd53c5143ee69ecfd26d8ea6dc9b2c78607a6"
KIT_VERSION="1.2"
# kit и kit-sub берём из того же релиза, что и этот скрипт, а не из меняющейся ветки main.
KIT_RAW="https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/v$KIT_VERSION"
# Ядро Xray для панели. С 26.7.x клиенты на Mihomo и sing-box (Hiddify, FlClash,
# Clash Verge, Mihomo в XKeen) не проходят REALITY – проверено 2026-09-25.
# 26.6.27 – последняя версия, с которой работают все клиенты и которую принимает 3X-UI.
XRAY_CORE="v26.6.27"
# SHA256 архивов этой версии ядра (из официальных файлов .dgst релиза Xray-core). Запасной путь
# через зеркало ставит архив, только если сумма совпала: зеркалу верить не нужно.
# При смене XRAY_CORE обновите суммы: tools/release.sh сверяет их с официальными.
declare -A XRAY_ZIP_SHA256=(
  [64]=b3e5902d06d6282fe53cfa2fc426058b9aeaa429b2c812e20887cd47f26d08bf
  [arm64-v8a]=13a251379bea366c2cf10363ad71e75734193d401f26f518bf0c25e5c8f8c931
)
XRAY_MIRRORS=("https://github.com" "https://ghfast.top/https://github.com")
XUI_REPO="MHSanaei/3x-ui"
RESULT=/root/3x-ui.txt
XUI_ENV=/etc/x-ui/install-result.env
# Сайты для маскировки REALITY: нужны TLS 1.3 и HTTP/2. Берём первый доступный.
# Apple, iCloud, Microsoft и домены .ru сам Xray не советует – их тут нет.
SNI_CANDIDATES=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com)

ALL_PROTOS=(reality reality2 hy2 xhttp ws trojan vmess ss tuic wg awg awg3 mtproto)
# Обычный WireGuard легко распознаётся сетевым оборудованием и работает нестабильно
# (проверено 2026-09-27: рукопожатие доходит до сервера, ответ – нет). По умолчанию не ставим.
DEFAULT_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic awg awg3 mtproto)
declare -A PORTS=([xhttp]=8443 [ws]=2053 [trojan]=2083 [vmess]=2087 [ss]=8388 [tuic]=8444 [wg]=51820 [awg]=51821 [awg3]=51822 [mtproto]=8445)
PROTOS=(); CREATED=(); OPEN=(); NB_ALL=()
# Режим «всё TCP на 443»: nginx разводит по SNI и путям, подключения слушают только localhost.
SINGLE=no
declare -A INNER=([reality]=10443 [xhttp]=10444 [mtproto]=10445 [web]=10446 [selfweb]=10447 [ws]=10451 [vmess]=10452 [trojan]=10453 [sub]=10460)
SNI2=""; SNI3=""
# Свой домен (self-steal): REALITY маскируется под сайт на этом же сервере, а не под чужой.
DOMAIN=""
PANEL_ON=ip     # где открываются панель и подписка: ip или domain (domain – только со своим доменом)
LINK_HOST=""   # адрес в ссылках: свой домен, если он выбран, иначе IP
DOMAIN_CERT_DIR=/root/cert/domain
SELF_IP_CERT=no   # yes – сертификат на IP самоподписанный (Let's Encrypt отказал, пользователь согласился)

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
WARNINGS=(); STEP=0; STEPS=6
say()  { printf '      %s\n' "$*"; }                                   # подробность под шагом
ok()   { printf '      %s\n' "${G}✓${N} $*"; }
step() { STEP=$((STEP + 1)); printf '\n%s\n' "${B}[$STEP/$STEPS]${N} $1"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }                          # сразу (диалоги, ошибки перед остановкой)
later() { WARNINGS+=("$*"); }                                            # в блок «Внимание» в конце
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO. Исправьте причину и запустите скрипт ещё раз."' ERR

rand_str() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"; }
port_busy() { ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .; }

public_ip() {
  local ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-60000 -n 1)
    port_busy "$p" tcp || { echo "$p"; return; }
  done
  die "Не нашёл свободный порт для панели."
}

# REALITY маскируется под чужой сайт: он должен отвечать по TLS 1.3 и HTTP/2.
sni_ok() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

sni_alive() { sni_ok "$1"; }

# --- поиск сайта-прикрытия среди соседей по подсети (общий код kit и установщика) ---

SNI_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# Бесплатные и динамические имена (sslip.io, work.gd и т. п.) часто используют чужие прокси-серверы: под них маскироваться не стоит.
SNI_DYN_RE='(^|\.)(sslip\.io|nip\.io|xip\.io|traefik\.me|work\.gd|duckdns\.org|ddns\.net|hopto\.org|zapto\.org|myftp\.biz|dynu\.net|freeddns\.org|no-ip\.(org|biz|info)|nom\.za|tk|ml|ga|cf|gq)$'
# Известные сайты на чужом IP не подходят: сайт для маскировки должен быть «своим» для подсети сервера.
SNI_BRAND_RE='(^|\.)(google|googleapis|gstatic|youtube|microsoft|windows|apple|icloud|amazon|amazonaws|samsung|yahoo|cloudflare|facebook|instagram|netflix|github|telegram)\.[a-z.]+$'

# Имена с «сомнительными» словами не берём: брать такой сайт для маскировки неприятно и небезопасно для вас.
SNI_BAD_RE='(probiv|porn|xxx|sex|adult|casino|bet|vpn|proxy|torrent|crack|hack|warez|drug|weapon|leak|escort|gambl|poker)'

# У сайта настоящий сертификат: цепочка проходит проверку, имя совпадает.
sni_trusted() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -verify_hostname "$1" -verify_return_error 2>/dev/null | grep -q 'Verification: OK'
}

# На «/» отвечает страница (2xx) или переход на этот же сайт; не за Cloudflare, не переход на чужой сайт.
sni_quality() {
  local out code loc
  out=$(curl -sS -m 10 -o /dev/null -D- "https://$1/" 2>/dev/null | tr -d '\r') || return 1
  code=$(awk 'NR == 1 {print $2}' <<<"$out")
  grep -qiE '^(server: cloudflare|cf-ray:)' <<<"$out" && return 1
  case $code in
    2??) return 0 ;;
    3??) loc=$(awk 'tolower($1) == "location:" {print $2; exit}' <<<"$out"); [[ $loc == /* || $loc =~ ^https?://(www\.)?${1#www.}(/|:|$) ]] ;;
    *) return 1 ;;
  esac
}

host_ip() { # IPv4 сервера
  local h=${HOST:-}
  if [[ $h =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$h"; else getent ahostsv4 "$h" 2>/dev/null | awk 'NR == 1 {print $1}'; fi
}

# Тот же блок /23 (две соседние /24), что и у сервера.
same_net() { # имя
  local me ip a b c x y z
  me=$(host_ip); [[ -n $me ]] || return 1
  IFS=. read -r a b c _ <<<"$me"
  while read -r ip; do
    [[ -n $ip ]] || continue
    IFS=. read -r x y z _ <<<"$ip"
    [[ $x == "$a" && $y == "$b" && $((z >> 1)) == $((c >> 1)) ]] && return 0
  done < <(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  return 1
}

# Имена из сертификатов соседних адресов /24: заходим на 443 без имени и читаем subjectAltName.
nearby_scan() { # основа "a.b.c"
  local me; me=$(host_ip)
  seq 1 254 | xargs -P 8 -I{} bash -c '
      ip=$1; [ "$ip" = "$2" ] && exit 0
      echo | timeout 4 openssl s_client -connect "$ip:443" -tls1_3 -alpn h2 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | tr "," "\n" | sed -n "s/^ *DNS://p"' _ "$1.{}" "$me" 2>/dev/null | sort -u | grep -E "$SNI_RE" | head -40 || true
}

# Подходящие сайты: сначала в /24 сервера, если пусто – во втором /24 того же /23. До 8 имён.
nearby_sites() {
  local me a b c base n names found=0
  set +e; trap - ERR   # выполняется в подпроцессе: сбой одной проверки не должен обрывать поиск
  me=$(host_ip)
  [[ $me =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 0
  IFS=. read -r a b c _ <<<"$me"
  for base in "$a.$b.$c" "$a.$b.$((c ^ 1))"; do
    names=$(nearby_scan "$base")
    for n in $names; do
      [[ $n == "$me" || $n =~ $SNI_DYN_RE || $n =~ $SNI_BRAND_RE || $n =~ $SNI_BAD_RE ]] && continue
      if same_net "$n" && sni_alive "$n" && sni_trusted "$n" && sni_quality "$n"; then echo "$n"; found=$((found + 1)); ((found >= 8)) && return 0; fi
    done
    ((found > 0)) && return 0
  done
  return 0
}

# ---------- свой домен (self-steal) ----------

# Домен должен смотреть на этот сервер: иначе Let's Encrypt не выдаст сертификат,
# а маскировка под чужой адрес ничего не даст.
domain_points_here() { # домен
  local me=$HOST ips
  [[ $me =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || me=$(public_ip)
  ips=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u)
  if [[ -z $ips ]]; then
    warn "У домена $1 нет A-записи. Добавьте её у регистратора: тип A, значение $me."
  elif ! grep -qx "$me" <<<"$ips"; then
    warn "Домен $1 сейчас указывает на $(tr '\n' ' ' <<<"$ips")– а нужен IP этого сервера: $me."
    echo "   Если домен за Cloudflare, выключите проксирование (серое облако вместо оранжевого)." >&2
  else
    return 0
  fi
  return 1
}

ask_tty() { # приглашение; ответ – в REPLY; не 0, если терминал пропал (обрыв SSH, EOF)
  read -r -p "$1" REPLY </dev/tty || { REPLY=""; return 1; }
}

# Где открывать панель и подписку, если выбран свой домен.
panel_on_choice() {
  [[ $PANEL_ON == domain ]] && return 0
  echo
  echo "${B}Где открывать панель и подписку?${N}"
  echo "  ${B}1${N}  По IP        https://$HOST/…   как раньше ${G}[по умолчанию]${N}"
  echo "  ${B}2${N}  По домену    https://$DOMAIN/…  сертификат домена, ссылка не зависит от IP"
  echo "     ${D}Менять можно потом: kit net panel domain | ip${N}"
  ask_tty "Выбор [1]: " || return 0
  REPLY=${REPLY//[[:space:]]/}
  [[ ${REPLY%.} == 2 ]] && PANEL_ON=domain
  return 0
}

# Вопрос пользователю: свой домен, сосед по подсети (по умолчанию) или свой сайт.
choose_masking() {
  echo
  echo "${B}Под какой сайт маскировать сервер?${N}"
  echo "Со стороны он будет выглядеть как обычный сайт."
  echo
  echo "  ${B}1${N}  Свой домен          самый надёжный: нужен домен и свободный порт 80   ${G}[рекомендуем]${N}"
  echo "  ${B}2${N}  Сосед по подсети    подберу сам, домен не нужен   ${G}[рекомендуем]${N}"
  echo "  ${B}3${N}  Свой сайт           вы вводите адрес сами"
  echo "     ${D}Сертификат своего домена виден в публичных журналах сертификатов: связь «домен – сервер» не скрыта.${N}"
  echo
  local d="" prev=""
  ask_tty "Выбор [2]: " || return 0
  REPLY=${REPLY//[[:space:]]/}
  if [[ ${REPLY%.} == 3 ]]; then
    while :; do
      ask_tty "Адрес сайта, например example.com (пусто – подобрать самому): " || return 0
      d=${REPLY,,}; d=${d//[[:space:]]/}
      [[ -n $d ]] || return 0
      if [[ ! $d =~ $re_host ]]; then warn "Нужно только имя, без https://. Пример: example.com"; continue; fi
      if sni_ok "$d"; then SNI=$d; return 0; fi
      warn "$d не отвечает по TLS 1.3 и HTTP/2 – REALITY с ним работать не будет. Выберите другой."
    done
  fi
  [[ ${REPLY%.} == 1 ]] || { echo; return 0; }
  while :; do
    if [[ -n $prev ]]; then ask_tty "Ваш домен [$prev]: " || return 0
    else ask_tty "Ваш домен, например vpn.example.com (пусто – стандартный сайт): " || return 0; fi
    d=${REPLY,,}; d=${d// /}
    [[ -n $d ]] || d=$prev
    [[ -n $d ]] || return 0
    if [[ ! $d =~ $re_host ]]; then warn "Это не похоже на домен (нужно только имя, без https://). Пример: vpn.example.com"; prev=""; continue; fi
    if domain_points_here "$d"; then DOMAIN=$d; panel_on_choice; return 0; fi
    prev=$d
    ask_tty "Enter – проверить ещё раз (DNS обновляется не сразу), s – стандартный сайт, q – выйти: " || return 0
    REPLY=${REPLY//[[:space:]]/}
    case ${REPLY,,} in
      s | ы | с) return 0 ;;
      q | й) die "Остановился по вашей просьбе. Ставить можно снова в любой момент." ;;
    esac
  done
}

# Сертификат для домена через acme.sh, который уже поставил установщик 3X-UI.
# Продлевает его тот же cron, а после продления nginx перечитывает сертификат.
issue_domain_cert() {
  local acme=/root/.acme.sh/acme.sh rc=0 log=/var/log/kit-domain-cert.log
  if [[ -s $DOMAIN_CERT_DIR/fullchain.pem && -s $DOMAIN_CERT_DIR/privkey.pem ]] \
    && openssl x509 -in "$DOMAIN_CERT_DIR/fullchain.pem" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q 'does match' \
    && openssl x509 -in "$DOMAIN_CERT_DIR/fullchain.pem" -noout -issuer 2>/dev/null | grep -q "Let's Encrypt" \
    && openssl x509 -in "$DOMAIN_CERT_DIR/fullchain.pem" -noout -checkend 864000 >/dev/null 2>&1; then
    say "Сертификат для ${B}$DOMAIN${N} уже есть"
    return 0
  fi
  [[ -x $acme ]] || { warn "Не нашёл acme.sh, которым установщик 3X-UI получает сертификаты: не могу выпустить сертификат для $DOMAIN."; return 1; }
  port_busy 80 tcp && { warn "Порт 80/tcp занят: Let's Encrypt не сможет проверить домен $DOMAIN."; return 1; }
  say "Получаю сертификат Let's Encrypt для ${B}$DOMAIN${N}"
  install -m 600 /dev/null "$log"
  # Сбои бывают временными (например, ошибка TLS при скачивании готового сертификата): до трёх попыток.
  local try
  for try in 1 2 3; do
    rc=0
    "$acme" --issue -d "$DOMAIN" --standalone --httpport 80 --server letsencrypt --keylength ec-256 ${rc_force:-} >>"$log" 2>&1 || rc=$?
    [[ $rc == 0 || $rc == 2 ]] && break
    local rc_force="--force"
    sleep 10
  done
  # 2 – сертификат уже свежий, выпускать заново не нужно.
  [[ $rc == 0 || $rc == 2 ]] || { warn "Let's Encrypt не выдал сертификат для $DOMAIN. Обычно дело в одном из трёх: A-запись ещё не обновилась, порт 80 закрыт у хостера или домен за проксированием Cloudflare. Лог: $log"; return 1; }
  # Каталог и ключ – только для root (nginx читает их от root).
  install -d -m 700 "$DOMAIN_CERT_DIR"
  (umask 077; "$acme" --install-cert -d "$DOMAIN" --ecc --fullchain-file "$DOMAIN_CERT_DIR/fullchain.pem" \
    --key-file "$DOMAIN_CERT_DIR/privkey.pem" --reloadcmd "systemctl reload nginx >/dev/null 2>&1 || true" >>"$log" 2>&1) \
    || { warn "Не удалось сохранить сертификат для $DOMAIN. Лог: $log"; return 1; }
  chmod 644 "$DOMAIN_CERT_DIR/fullchain.pem"
  chmod 600 "$DOMAIN_CERT_DIR/privkey.pem"
  return 0
}

# Let's Encrypt не выдал сертификат на IP, а режим со своим доменом без него не работает: предлагаем
# самоподписанный сертификат на IP. Ссылки на подключения продолжат работать (отпечаток уходит в
# ссылки), а подписка в приложениях может не открыться: им такой сертификат не нравится.
ip_cert_self_signed_fallback() {
  local san="IP:$HOST"
  [[ $HOST =~ ^[0-9.]+$ ]] || san="DNS:$HOST"
  warn "Let's Encrypt не выдал сертификат на IP $HOST. Частые причины:"
  {
    echo "   – лимит Let's Encrypt: 5 сертификатов в неделю на один IP;"
    echo "   – входящий порт 80 закрыт (у хостера или в файрволе);"
    echo "   – сбой у самого Let's Encrypt (лог: /var/log/3x-ui-install.log)."
    echo "   Можно продолжить с самоподписанным сертификатом: ссылки на подключения работают, браузер покажет"
    echo "   предупреждение, а подписка в приложениях может не открыться."
  } >&2
  if [[ $yes == no && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
    ask_tty "Продолжить с самоподписанным сертификатом? [Y/n] " || REPLY=""
    REPLY=${REPLY//[[:space:]]/}
    [[ ${REPLY,,} == n* || ${REPLY,,} == н* ]] && return 1
  else
    say "Продолжаю с самоподписанным сертификатом (без вопросов)."
  fi
  install -d -m 700 /root/cert/ip
  (umask 077; openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout /root/cert/ip/privkey.pem \
    -out /root/cert/ip/fullchain.pem -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null)
  chmod 644 /root/cert/ip/fullchain.pem
  chmod 600 /root/cert/ip/privkey.pem
  say "Подключаю самоподписанный сертификат к панели"
  /usr/local/x-ui/x-ui cert -webCert /root/cert/ip/fullchain.pem -webCertKey /root/cert/ip/privkey.pem >/dev/null 2>&1
  systemctl restart x-ui
  API="https://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  wait_panel
  SELF_IP_CERT=yes
  return 0
}

# Куда REALITY отправляет чужих гостей: для своего домена – на nginx этого сервера.
reality_target() { # сайт
  if [[ -n $DOMAIN && $1 == "$DOMAIN" ]]; then echo "127.0.0.1:${INNER[selfweb]}"; else echo "$1:443"; fi
}

# ---------- API панели ----------

api() { # METHOD path [json]
  local url="$API/$2" out
  if [[ $1 == GET ]]; then
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" "$url")
  else
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X "$1" -d "$3" "$url")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель ответила ошибкой на $2: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  jq -c '.obj' <<<"$out"
}

wait_panel() {
  local i
  for i in $(seq 1 60); do
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

# ---------- установка ----------

# Пасхалка – только в конце установки.
kit_banner() {
  echo
  printf '%s' "$G"
  cat <<'ART'
  _ _                   _   _          _          _      _
 (_) |_ ___ _ __   ___ | |_| | ___   _| |__  _ __(_) ___| | __
 | | __/ __| '_ \ / _ \| __| |/ / | | | '_ \| '__| |/ __| |/ /
 | | |_\__ \ | | | (_) | |_|   <| |_| | |_) | |  | | (__|   <
 |_|\__|___/_| |_|\___/ \__|_|\_\\__,_|_.__/|_|  |_|\___|_|\_\
ART
  printf '%s' "$N"
  echo
  echo "${B}3X-UI KIT $KIT_VERSION${N}  ·  it's not Kubrick. it's just a VPN."
  echo "${D}на основе панели 3X-UI (MHSanaei/3x-ui) и ядра Xray · github.com/itsnotkubrick/3X-UI_KIT${N}"
}

main() {
  local a args=()
  for a in "$@"; do
    [[ $a == -h || $a == --help ]] && { usage; exit 0; }
    # --port=8443 понимаем так же, как --port 8443
    if [[ $a == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
  command -v systemctl >/dev/null || die "Нужен systemd."
  # kit-sub работает без root и получает конфиг через LoadCredential: он появился в systemd 247 (Ubuntu 22.04+, Debian 11+).
  local sysv
  sysv=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')
  [[ $sysv =~ ^[0-9]+$ ]] && ((sysv < 247)) && die "Версия systemd ($sysv) слишком старая, нужна 247 и новее: Ubuntu 22.04 и новее, Debian 11 и новее. На этой системе подписка не запустится – поставьте поддерживаемую."
  if [[ -f $RESULT && -x /usr/local/x-ui/x-ui ]]; then
    die "3X-UI уже установлена этим скриптом. Управление: команда x-ui, данные для входа: cat $RESULT"
  fi
  # Панель удалили через меню x-ui, а наши файлы остались – убираем их и ставим заново.
  if [[ -f $RESULT ]]; then
    warn "Панель 3X-UI удалена, но остались файлы прошлой установки – убираю их."
    systemctl disable --now kit-sub kit-update.timer >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/kit-sub.service /etc/systemd/system/kit-update.service /etc/systemd/system/kit-update.timer /usr/local/lib/kit-sub /etc/kit-sub /etc/kit /usr/local/bin/kit \
      /etc/cron.d/kit-nginx-reload /etc/cron.d/kit-xui-menu /etc/cron.d/kit-sub-cert "$RESULT"
    systemctl daemon-reload
    # Наш nginx держит 443 – без этого проверка порта ниже не пустит REALITY.
    if [[ -f /etc/nginx/kit-stream.conf ]]; then
      systemctl stop nginx >/dev/null 2>&1 || true
      rm -f /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf
      sed -i '/kit-stream\.conf/d' /etc/nginx/nginx.conf
    fi
  fi
  if [[ -d /usr/local/x-ui && ! -f $XUI_ENV ]]; then
    die "3X-UI уже установлена другим способом – не трогаю её. Удалите её (x-ui uninstall) или добавьте REALITY в панели вручную."
  fi

  local PORT=443 SNI="" PANEL_SSL=auto HOST="" UFW=yes NAME="admin" yes=no protos=all ucert="" ukey="" multi=no restore=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port | --sni | --panel-ssl | --host | --user | --protocols | --domain | --cert | --key | --restore | --panel-on)
        [[ -n ${2-} ]] || die "У параметра $1 нет значения (см. --help)" ;;
    esac
    case $1 in
      --port) PORT=$2; shift 2 ;;
      --sni) SNI=$2; shift 2 ;;
      --panel-ssl) PANEL_SSL=$2; shift 2 ;;
      --host) HOST=$2; shift 2 ;;
      --user) NAME=$2; shift 2 ;;
      --protocols) protos=$2; shift 2 ;;
      --domain) DOMAIN=$2; shift 2 ;;
      --cert) ucert=$2; shift 2 ;;
      --multi-port) multi=yes; shift ;;
      --key) ukey=$2; shift 2 ;;
      --restore) restore=$2; shift 2 ;;
      --panel-on) PANEL_ON=${2,,}; shift 2 ;;
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  [[ $PORT =~ ^[0-9]{1,5}$ ]] && ((10#$PORT > 0 && 10#$PORT < 65536)) || die "Неверный порт: $PORT"
  PORT=$((10#$PORT))
  if [[ -n $restore ]]; then
    [[ -z $HOST || $HOST =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--host при восстановлении: IP нового сервера"
    restore_main "$restore"
    return
  fi
  # Регистр и точка в конце не важны: vpn.Example.com. – это тот же vpn.example.com.
  local k
  for k in SNI DOMAIN HOST; do
    [[ -z ${!k} ]] || { local v=${!k,,}; v=${v%.}; printf -v "$k" '%s' "$v"; }
  done
  PANEL_SSL=${PANEL_SSL,,}; protos=${protos,,}; protos=${protos// /}
  local re_host='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59})$'
  for k in "$SNI" "$DOMAIN" "$HOST"; do
    [[ $k != *://* && $k != */* ]] || die "Нужно только имя, без https:// и без «/»: например vpn.example.com"
    [[ $k =~ ^[A-Za-z0-9.-]*$ ]] || die "Имя «$k» с не латинскими буквами не подойдёт: запишите его в виде punycode (xn--…), например через idn или в личном кабинете регистратора."
  done
  [[ -z $SNI || $SNI =~ $re_host ]] || die "--sni: нужно имя сайта, например dl.google.com"
  [[ -z $DOMAIN || $DOMAIN =~ $re_host ]] || die "--domain: нужно имя вашего домена, например vpn.example.com"
  [[ -z $DOMAIN || -z $SNI ]] || die "--sni и --domain вместе не нужны: выберите либо чужой сайт (--sni), либо свой домен (--domain)."
  [[ -z $DOMAIN || $multi == no ]] || die "Свой домен работает только в режиме «всё на 443» – уберите --multi-port."
  [[ $PANEL_ON == ip || $PANEL_ON == domain ]] || die "--panel-on: ip или domain"
  [[ $PANEL_ON == ip || -n $DOMAIN || $yes == no ]] || die "--panel-on domain работает только со своим доменом (--domain vpn.example.com)."
  [[ -z $HOST || $HOST =~ $re_host || $HOST =~ ^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$ ]] || die "--host: нужен IP (например 1.2.3.4) или домен"
  [[ $NAME =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."
  [[ $PANEL_SSL =~ ^(auto|ip|none)$ ]] || die "--panel-ssl: auto, ip или none"
  if [[ -n $ucert || -n $ukey ]]; then
    [[ -s $ucert && -s $ukey ]] || die "Нужны оба файла: --cert fullchain.pem --key privkey.pem"
    openssl x509 -in "$ucert" -noout 2>/dev/null || die "$ucert – не сертификат в формате PEM"
    PANEL_SSL=custom
  fi
  case $protos in
    all) PROTOS=("${DEFAULT_PROTOS[@]}") ;;
    minimal) PROTOS=(reality) ;;
    *) IFS=, read -ra PROTOS <<<"$protos"
       local x
       for x in "${PROTOS[@]}"; do [[ " ${ALL_PROTOS[*]} " == *" $x "* ]] || die "Неизвестный протокол: $x. Доступны: ${ALL_PROTOS[*]}"; done ;;
  esac
  if [[ $multi == no && -d /etc/nginx ]] && grep -rqsE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/streams-enabled 2>/dev/null; then
    die "В вашем nginx уже есть блок stream: установщик в режиме «всё на 443» не сможет с ним ужиться. Запустите с --multi-port или уберите свой блок."
  fi
  if port_busy "$PORT" tcp && ! { [[ -f $XUI_ENV ]] && ss -H -ltnp "sport = :$PORT" | grep -q -E 'xray|nginx'; }; then
    die "Порт $PORT/tcp уже занят. REALITY нужен свободный порт – укажите другой: --port 8443"
  fi

  if [[ $PANEL_SSL == auto ]]; then
    if port_busy 80 tcp; then
      PANEL_SSL=none
      later "Порт 80 занят – сертификат для панели не получить. Панель будет доступна только через SSH-туннель."
    else
      PANEL_SSL=ip
    fi
  fi
  [[ $PANEL_SSL == ip ]] && port_busy 80 tcp && die "Для сертификата панели нужен свободный порт 80/tcp."
  # Доверенный сертификат (Let's Encrypt или свой) – панель и подписка доступны снаружи по HTTPS.
  TRUSTED=no
  [[ $PANEL_SSL == ip || $PANEL_SSL == custom ]] && TRUSTED=yes
  if [[ $PANEL_SSL == custom ]]; then
    mkdir -p /root/cert/custom
    install -m 644 "$ucert" /root/cert/custom/fullchain.pem
    install -m 600 "$ukey" /root/cert/custom/privkey.pem
  fi

  kit_banner
  echo
  echo "Поставлю панель 3X-UI и протоколы на этот сервер. Займёт 3–5 минут."
  if ! command -v curl >/dev/null || ! command -v openssl >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive; wait_apt_idle
    apt-get update -qq; apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null
  fi

  local host_given=${HOST:+yes}
  HOST=${HOST:-$(public_ip)}
  [[ -n $HOST ]] || die "Не удалось узнать внешний IP. Укажите его: --host 1.2.3.4"
  local os_name mem_gb
  os_name=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2 / 1048576}' /proc/meminfo 2>/dev/null || echo "?")
  echo
  echo "Сервер: ${B}$HOST${N} · $os_name · ${mem_gb} ГБ памяти"
  # IP определился снаружи, а ссылки получат именно его: у части хостеров это не адрес самого сервера.
  if [[ -z $host_given && $yes == no && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
    ask_tty "Адрес в ссылках: $HOST. Верно? Enter – да, или введите другой IPv4: " || true
    REPLY=${REPLY//[[:space:]]/}
    if [[ -n $REPLY ]]; then
      [[ $REPLY =~ ^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$ ]] || die "Нужен IPv4-адрес, например 203.0.113.10 (или запустите с --host)."
      HOST=$REPLY
    fi
  fi
  if [[ $HOST =~ ^[0-9.]+$ ]] && ! ip -4 -o addr show 2>/dev/null | grep -qw "$HOST"; then
    later "Адрес $HOST не найден на сетевых интерфейсах сервера (бывает за NAT). Если ссылки не работают – запустите с --host и верным IP."
  fi

  # Маскировка: из флагов, по вопросу пользователю или автоматически (сосед по подсети).
  if [[ -n $DOMAIN ]]; then
    [[ $PANEL_SSL == ip ]] || die "Свой домен работает с сертификатом панели Let's Encrypt на IP: освободите порт 80 и не указывайте --cert, --key и --panel-ssl none (сертификат для домена установщик получит сам)."
    domain_points_here "$DOMAIN" || die "Исправьте A-запись домена и запустите скрипт снова (DNS обновляется от нескольких минут до нескольких часов)."
  elif [[ -z $SNI && $yes == no && $PANEL_SSL == ip && $multi == no && ! -f $XUI_ENV && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
    choose_masking
  fi
  if [[ -n $DOMAIN ]]; then
    SNI=$DOMAIN
  elif [[ -z $SNI ]]; then
    echo
    echo "Подбираю сайт для маскировки среди соседей по подсети… (около 250 коротких обращений к порту 443 соседних адресов, около минуты; не нужно – запустите с --sni или --domain)"
    local -a nb=()
    mapfile -t nb < <(nearby_sites | shuf)
    NB_ALL=("${nb[@]}")
    if ((${#nb[@]})); then
      SNI=${nb[0]}; SNI2=${nb[1]:-}; SNI3=${nb[2]:-}
      ok "найден: ${B}$SNI${N} · та же подсеть · TLS 1.3, h2, сертификат верный"
    else
      warn "В подсети подходящего сайта не нашёл."
      echo "   Лучший выход – свой домен: запустите снова с --domain vpn.example.com"
      if [[ $yes == no && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
        ask_tty "   Продолжить с запасным сайтом из списка? [y/N] " || true
        [[ $REPLY =~ ^[yYдД]$ ]] || die "Остановился по вашей просьбе. Ставить можно снова в любой момент."
      else
        later "Сайт для маскировки взят из общего списка (в подсети сервера подходящего не нашлось). Надёжнее свой домен или kit net site."
      fi
      local -a pool=()
      mapfile -t pool < <(printf '%s\n' "${SNI_CANDIDATES[@]}" | shuf)
      for s in "${pool[@]}"; do
        if sni_ok "$s"; then SNI=$s; break; fi
      done
      [[ -n $SNI ]] || die "Ни один сайт из списка не ответил по TLS 1.3 + HTTP/2. Укажите свой: --sni example.com"
      ok "запасной сайт: ${B}$SNI${N}"
    fi
  elif ! sni_ok "$SNI"; then
    die "$SNI не отвечает по TLS 1.3 + HTTP/2 – REALITY с ним работать не будет. Выберите другой сайт."
  fi
  LINK_HOST=${DOMAIN:-$HOST}
  [[ $PANEL_ON == ip || -n $DOMAIN ]] || { PANEL_ON=ip; later "--panel-on domain нужен со своим доменом: панель и подписка открываются по IP."; }
  # Режим «всё на 443»: XHTTP и MTProto различаются по имени сайта, берём и им соседей по подсети.
  if [[ $TRUSTED == yes && $multi == no && ( -z $SNI2 || -z $SNI3 ) ]]; then
    local -a nb2=()
    echo
    if ((${#NB_ALL[@]})); then
      nb2=("${NB_ALL[@]}")
    else
      echo "Подбираю сайты для XHTTP и MTProto… (около 250 коротких обращений к порту 443 соседних адресов вашей подсети)"
      mapfile -t nb2 < <(nearby_sites | shuf)
    fi
    for s in "${nb2[@]}"; do
      [[ $s == "$SNI" || $s == "$SNI2" || $s == "$SNI3" ]] && continue
      if [[ -z $SNI2 ]]; then SNI2=$s; elif [[ -z $SNI3 ]]; then SNI3=$s; fi
    done
  fi
  # Для режима «всё на 443» XHTTP и MTProto нужны свои сайты: nginx различает их по SNI.
  local -a pool2=()
  mapfile -t pool2 < <(printf '%s\n' "${SNI_CANDIDATES[@]}" | shuf)
  for s in "${pool2[@]}"; do
    [[ $s == "$SNI" || $s == "$SNI2" || $s == "$SNI3" ]] && continue
    if [[ -z $SNI2 ]] && sni_ok "$s"; then SNI2=$s; continue; fi
    [[ -z $SNI3 && -n $SNI2 ]] && { SNI3=$s; break; }
  done
  SNI2=${SNI2:-$SNI}; SNI3=${SNI3:-www.cloudflare.com}
  if [[ $TRUSTED == yes && $multi == no && ( $SNI2 =~ $SNI_BRAND_RE || $SNI3 =~ $SNI_BRAND_RE ) ]]; then
    later "XHTTP и MTProto используют известные сайты из общего списка (достаточно соседей по подсети не нашлось). Заменить: kit net site"
  fi

  step "Пакеты"
  export DEBIAN_FRONTEND=noninteractive
  wait_apt_idle
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron unzip >/dev/null
  ok "curl, jq, openssl, qrencode, ufw и другое"

  # --- официальный установщик 3X-UI с закреплённой версией ---
  step "Панель 3X-UI $XUI_VERSION"
  local panel_port panel_path panel_user panel_pass
  panel_port=$(free_port)
  panel_path=$(rand_str 18)
  panel_user=$(rand_str 10)
  panel_pass=$(rand_str 20)
  if [[ -f $XUI_ENV ]]; then
    say "3X-UI уже стоит после прошлого запуска – продолжаю с создания подключений"
  else
    install_xui "$panel_port" "$panel_path" "$panel_user" "$panel_pass"
  fi
  [[ -f $XUI_ENV ]] || die "Установщик не сохранил данные входа. Лог: /var/log/3x-ui-install.log"

  # Данные для входа – из файла, который пишет сам установщик.
  connect_panel
  ok "панель установлена, установщик проверен по SHA256"

  if [[ $PANEL_SSL == custom ]]; then
    say "Подключаю ваш сертификат к панели"
    /usr/local/x-ui/x-ui cert -webCert /root/cert/custom/fullchain.pem -webCertKey /root/cert/custom/privkey.pem >/dev/null 2>&1
    systemctl restart x-ui
    API="https://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    wait_panel
  fi

  # Установщик 3X-UI мог не получить сертификат на IP (порт 80 закрыт у хостера, лимит
  # Let's Encrypt, сбой). Без него панель осталась бы без TLS, а nginx проксирует её по https:
  # получился бы сервер, который говорит «Готово», а панель не открывается.
  if [[ $PANEL_SSL == ip && ! -s /root/cert/ip/fullchain.pem ]]; then
    if [[ -n $DOMAIN ]]; then
      ip_cert_self_signed_fallback || die "Остановил установку по вашему выбору. Запустите скрипт снова без --domain (панель будет доступна через SSH-туннель) или позже, когда сертификат на IP снова можно будет получить."
    else
      later "Let's Encrypt не выдал сертификат на IP $HOST (порт 80 закрыт у хостера, лимит выпусков или сбой). Ставлю без него: панель будет доступна только через SSH-туннель."
      PANEL_SSL=none
      TRUSTED=no
    fi
  fi

  # Без сертификата панель и подписки не должны торчать наружу по HTTP.
  if [[ $PANEL_SSL == none ]]; then
    say "Панель без сертификата – открываю её только для SSH-туннеля (127.0.0.1)"
    local all
    all=$(api POST setting/all '{}')
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1" | .subListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  # --- ядро Xray, совместимое со всеми клиентами ---
  step "Ядро Xray $XRAY_CORE и сертификат"
  set_xray_core

  # --- сертификат для протоколов с TLS ---
  setup_tls_cert
  ok "ядро закреплено, сертификат для протоколов с TLS готов"

  # --- подключения: все выбранные протоколы, один subId на пользователя ---
  step "Подключения"
  EXISTING=$(api GET inbounds/list)
  SUBID=""
  # «Всё на 443» – для новых установок с доверенным сертификатом. Старую многопортовую
  # установку не переделываем: перенос работающих подключений – осознанное решение.
  if [[ $TRUSTED == yes && $multi == no ]]; then
    if jq -e 'any(.[]; .remark == "REALITY" and (.listen // "") != "127.0.0.1")' <<<"$EXISTING" >/dev/null; then
      later "Установка уже работает в режиме с отдельными портами – оставляю его."
    else
      SINGLE=yes
    fi
  fi
  if [[ -n $DOMAIN ]]; then
    [[ $SINGLE == yes ]] || die "Свой домен работает только в режиме «всё на 443», а эта установка уже работает с отдельными портами."
    issue_domain_cert || die "Без сертификата для $DOMAIN продолжать нельзя. Исправьте причину и запустите скрипт снова."
    OPEN+=("80/tcp")
  fi
  # Одна заглушка на сервер: её показывают nginx на 443 и Hysteria2 (masquerade), её же берёт kit net masq.
  install -d -m 755 /var/www/kit
  [[ -s /var/www/kit/index.html ]] || stub_site >/var/www/kit/index.html
  chmod 644 /var/www/kit/index.html
  # Байт в байт как у nginx: $(…) срезал бы последний перевод строки, и длина ответа Hysteria2 отличалась бы.
  STUB_HTML=$(cat /var/www/kit/index.html; printf x); STUB_HTML=${STUB_HTML%x}
  local p
  for p in "${PROTOS[@]}"; do "proto_$p"; done
  # Первый пользователь – сразу на всех протоколах (как «kit user add»).
  ensure_user

  # --- подписка: ссылки, Clash/Mihomo и JSON с автоопределением клиента ---
  setup_subscription
  [[ $SINGLE == yes ]] && setup_nginx
  ok "${#CREATED[@]} подключений, пользователь $NAME"

  step "Защита и обновления"
  install_kit_cli
  if [[ $TRUSTED == yes ]]; then
    /usr/local/bin/kit __subextra >/dev/null 2>&1 || later "Адреса Clash и JSON на странице подписки не подключились: kit update --force"
  fi
  if [[ $PANEL_ON == domain ]]; then
    /usr/local/bin/kit net panel domain >/dev/null 2>&1 || { PANEL_ON=ip; later "Панель и подписку по домену включить не удалось: оставил по IP. Попробуйте позже: kit net panel domain"; }
  fi
  brand_xui_menu
  # Автообновление kit и kit-sub: только подписанные релизы, выключается kit update --manual.
  /usr/local/bin/kit update --auto >/dev/null 2>&1 || later "Автообновление не включилось – включите позже: kit update --auto"
  # Общий лимит трафика: у пользователя несколько записей (AmneziaWG считается отдельно), раз в 5 минут их трафик складывается.
  /usr/local/bin/kit __limit-timer on >/dev/null 2>&1 || later "Проверка общего лимита трафика не включилась – включите позже: kit fix"
  /usr/local/bin/kit net dns on >/dev/null 2>&1 || later "DNS в подписке не настроился – включите позже: kit net dns on"

  # --- файрвол ---
  if [[ $UFW == yes ]]; then
    [[ $TRUSTED == yes && $SINGLE == no ]] && OPEN+=("$XUI_PANEL_PORT/tcp" "$SUB_PORT/tcp")
    [[ $PANEL_SSL == ip ]] && OPEN+=("80/tcp")
    setup_ufw
  fi

  step "Проверка"
  local chk="" i bad=yes
  for i in 1 2 3; do
    sleep 4
    chk=$(/usr/local/bin/kit check --deep 2>&1) && { bad=no; break; }
  done
  if [[ $bad == no ]]; then
    ok "подключения работают: REALITY, XHTTP и Hysteria2 проверены клиентом с самого сервера"
  else
    install -m 600 /dev/null /var/log/kit-install-check.log
    printf '%s\n' "$chk" >/var/log/kit-install-check.log
    later "kit check нашёл: $(sed 's/\x1b\[[0-9;]*m//g' <<<"$chk" | grep -a -m1 '❌' | cut -c1-110). Подробности: kit check --deep"
  fi

  # --- итог ---
  local panel_url links
  local ph=$HOST
  if [[ $PANEL_ON == domain ]]; then ph=$DOMAIN; SUB_URL=${SUB_URL/\/\/$HOST\//\/\/$DOMAIN\/}; fi
  if [[ $SINGLE == yes ]]; then
    panel_url="https://$ph/${XUI_WEB_BASE_PATH#/}"
    panel_url="${panel_url%/}/"
  elif [[ $TRUSTED == yes ]]; then
    panel_url="https://$HOST:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH"
  else
    panel_url="http://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH  (через SSH-туннель: ssh -L $XUI_PANEL_PORT:127.0.0.1:$XUI_PANEL_PORT root@$HOST)"
  fi
  links=$(sub_links "$SUBID")
  # У установок до kit 1.1 AmneziaWG и MTProto лежат в подписках «-awg» и «-tg».
  local extra
  extra=$(sub_links "$SUBID-awg" 1; sub_links "$SUBID-tg" 1)
  [[ -n $extra ]] && links+=$'\n'"$extra"
  AWG_LINKS=$(grep '^vpn://' <<<"$links" || true)
  # MTProto слушает localhost, а клиенты приходят через nginx на 443.
  [[ $SINGLE == yes ]] && links=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=${INNER[mtproto]}/\1\2port=443/" <<<"$links")
  umask 077
  {
    echo "3X-UI KIT (3X-UI $XUI_VERSION) – данные для входа (файл виден только root)"
    echo
    echo "Панель:  $panel_url"
    echo "Логин:   $XUI_USERNAME"
    echo "Пароль:  $XUI_PASSWORD"
    echo
    [[ $TRUSTED == yes ]] && { echo "Подписка ($NAME) – все протоколы одной ссылкой:"; echo "$SUB_URL"; echo; }
    echo "Отдельные подключения ($NAME):"
    echo "$links"
  } >"$RESULT"

  echo
  echo "${G}${B}Готово! Сервер работает.${N}"
  [[ -n $DOMAIN ]] && echo "Маскировка: свой домен ${B}$DOMAIN${N}, сертификат Let's Encrypt продлевается сам."
  [[ $SELF_IP_CERT == yes ]] && later "Сертификат на IP самоподписанный: пользуйтесь ссылками на отдельные подключения, подписка в приложениях может не открыться."
  echo
  echo "${B}ПАНЕЛЬ${N}"
  if [[ $TRUSTED == yes ]]; then
    echo "  $panel_url"
  else
    echo "  Только через SSH-туннель. На вашем компьютере:"
    echo "    ssh -L $XUI_PANEL_PORT:127.0.0.1:$XUI_PANEL_PORT root@$HOST"
    echo "  Затем в браузере:  http://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH"
  fi
  echo "  Логин: ${B}$XUI_USERNAME${N}      Пароль: ${B}$XUI_PASSWORD${N}"
  echo "  ${D}(сохранено в $RESULT, файл виден только root)${N}"
  echo
  if [[ $TRUSTED == yes ]]; then
    echo "${B}ПОДПИСКА${N} – одна ссылка для всех протоколов"
    echo "  ${B}$SUB_URL${N}"
    echo "  Вставьте в Happ, Hiddify, Karing, v2rayN, Clash Verge или FlClash."
    qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
    echo
    KIT_NO_QR=1 /usr/local/bin/kit __links "$NAME" "$SUBID" || true
  else
    /usr/local/bin/kit __links "$NAME" "$SUBID" || true
  fi
  echo
  echo "${D}Порты, выключение и включение протоколов: ${N}${B}kit net${N}"
  if ((${#WARNINGS[@]})); then
    echo
    echo "${B}ВНИМАНИЕ${N}"
    local w n=0
    for w in "${WARNINGS[@]}"; do
      n=$((n + 1)); ((n > 3)) && break
      echo "  ${Y}!${N} $w"
    done
    ((${#WARNINGS[@]} > 3)) && echo "  … и ещё $((${#WARNINGS[@]} - 3)): kit check"
  fi
  echo
  echo "${B}ДАЛЬШЕ${N}"
  echo "  ${B}kit${N}                                  меню управления"
  echo "  ${B}kit user add имя --gb 50 --days 30${N}   добавить пользователя"
  echo "  ${B}kit check --deep${N}                     проверить, что всё работает"
  echo "  ${B}kit backup${N}                           копия сервера (держите в надёжном месте)"
}

# Официальный установщик 3X-UI закреплённой версии, сверенный по SHA256.
install_xui() { # порт путь логин пароль
  local tmp
  tmp=$(mktemp)
  say "Ставлю 3X-UI $XUI_VERSION официальным установщиком (пара минут)"
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/$XUI_REPO/$XUI_VERSION/install.sh"
  [[ $(sha256sum "$tmp" | awk '{print $1}') == "$XUI_INSTALL_SHA256" ]] \
    || die "Установщик 3X-UI $XUI_VERSION не совпал с проверенным (SHA256) – не запускаю. Сообщите нам: github.com/itsnotkubrick/3X-UI_KIT/issues"
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE="${PANEL_SSL/custom/none}" XUI_SERVER_IP="$HOST" \
      XUI_PANEL_PORT="$1" XUI_WEB_BASE_PATH="$2" \
      XUI_USERNAME="$3" XUI_PASSWORD="$4" \
      bash "$tmp" "$XUI_VERSION" </dev/null >/var/log/3x-ui-install.log 2>&1; then
    tail -20 /var/log/3x-ui-install.log >&2
    die "Установщик 3X-UI завершился с ошибкой. Полный лог: /var/log/3x-ui-install.log"
  fi
  rm -f "$tmp"
}

# Панель: API по https или http – сертификат мог появиться после установщика.
connect_panel() {
  # shellcheck disable=SC1090
  . "$XUI_ENV"
  TOKEN=$XUI_API_TOKEN
  local scheme i
  # Панель только что запущена и отвечает не сразу: перебираем обе схемы заново, пока не ответит (раньше после первой неудачной
  # проверки скрипт оставался на http и до конца стучался по http в порт с TLS).
  for i in $(seq 1 60); do
    for scheme in https http; do
      API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
      curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    done
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

# Архив ядра: скачиваем по очереди с GitHub и с зеркала и принимаем только тот, чья SHA256 совпала.
xray_zip_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo 64 ;;
    aarch64 | arm64) echo arm64-v8a ;;
    *) return 1 ;;
  esac
}
xray_fetch_verified() { # каталог; кладёт xray.zip, 0 – сумма совпала
  local d=$1 arch want got base
  arch=$(xray_zip_arch) || return 1
  want=${XRAY_ZIP_SHA256[$arch]}
  for base in "${XRAY_MIRRORS[@]}"; do
    curl -fsSL --connect-timeout 10 --max-time 180 --retry 1 -o "$d/xray.zip" \
      "$base/XTLS/Xray-core/releases/download/$XRAY_CORE/Xray-linux-$arch.zip" 2>/dev/null || continue
    got=$(sha256sum "$d/xray.zip" | awk '{print $1}')
    [[ $got == "$want" ]] && return 0
    warn "Архив ядра Xray с ${base#https://} не прошёл проверку SHA256 – отбрасываю."
  done
  return 1
}
xray_install_fallback() {
  local d bin
  d=$(mktemp -d)
  if ! command -v unzip >/dev/null; then
    wait_apt_idle
    apt-get install -y -qq unzip >/dev/null || { warn "Не удалось поставить unzip – запасной путь загрузки ядра недоступен."; rm -rf "$d"; return 0; }
  fi
  bin=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n 1) || true
  if [[ -n $bin ]] && xray_fetch_verified "$d" && unzip -q -o "$d/xray.zip" xray -d "$d"; then
    install -m 755 "$d/xray" "$bin.new" && mv -f "$bin.new" "$bin"
    systemctl restart x-ui
    wait_panel
  fi
  rm -rf "$d"
}

set_xray_core() {
  local cur_core
  cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
  if [[ $cur_core != "$XRAY_CORE" ]]; then
    say "Ставлю ядро Xray $XRAY_CORE (совместимо с Hiddify, Mihomo и другими клиентами)"
    # 3X-UI 3.9 бывает отвечает ошибкой «GitHub API error», хотя ядро уже заменено: ответ не считаем
    # проверкой, смотрим на версию ядра ниже.
    (api POST "server/installXray/$XRAY_CORE" '{}' >/dev/null) 2>/dev/null || warn "Панель не подтвердила смену ядра – проверяю версию сам."
    for _ in $(seq 1 30); do
      cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
      [[ $cur_core == "$XRAY_CORE" ]] && break
      sleep 2
    done
    if [[ $cur_core != "$XRAY_CORE" ]]; then
      warn "Панель не смогла скачать ядро с GitHub – пробую запасной путь: зеркало с проверкой SHA256."
      xray_install_fallback
      cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
    fi
    [[ $cur_core == "$XRAY_CORE" ]] || later "Не удалось сменить ядро Xray (сейчас $cur_core). Клиенты на Mihomo и sing-box могут не подключиться."
  fi
}

# Порты SSH, на которых сервер слушает сейчас: из настроек sshd, из ss (в Ubuntu 24.04 порт держит
# systemd, но сам sshd тоже в списке) и порт текущего подключения. Нужны, чтобы ufw не запер вас.
ssh_ports() {
  { sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
    ss -H -ltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
    awk '{print $4}' <<<"${SSH_CONNECTION:-}"
  } | grep -E '^[0-9]{1,5}$' | sort -un || true
}

setup_ufw() {
  local ssh_port o
  ssh_port=$(ssh_ports)
  for o in ${ssh_port:-22}; do OPEN+=("$o/tcp"); done
  ok "ufw: открыто ${#OPEN[@]} портов (${OPEN[*]}), панель не торчит наружу"
  for o in "${OPEN[@]}"; do ufw allow "$o" >/dev/null; done
  ufw --force enable >/dev/null || later "ufw не включился (так бывает в контейнерах) – откройте порты у хостера вручную."
}

# ---------- сертификат ----------

setup_tls_cert() {
  PIN=""
  if [[ $PANEL_SSL == custom ]]; then
    CERT=/root/cert/custom/fullchain.pem; KEY=/root/cert/custom/privkey.pem
  elif [[ $PANEL_SSL == ip && -s /root/cert/ip/fullchain.pem ]]; then
    CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
    # Самоподписанный сертификат на IP: отпечаток уходит в ссылки, чтобы клиенты доверяли именно ему.
    if [[ $SELF_IP_CERT == yes ]]; then
      PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
    fi
  else
    # Без Let's Encrypt – свой сертификат, а его отпечаток уходит в ссылки (pcs),
    # чтобы клиенты доверяли именно ему.
    CERT=/root/cert/self/fullchain.pem; KEY=/root/cert/self/privkey.pem
    if [[ ! -s $CERT ]]; then
      mkdir -p /root/cert/self
      local san="DNS:$HOST"
      [[ $HOST =~ ^[0-9.]+$ ]] && san="IP:$HOST"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null
      chmod 600 "$KEY"
    fi
    PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  fi
}

tls_json() { # alpn(JSON-массив)
  jq -nc --arg sni "$HOST" --arg c "$CERT" --arg k "$KEY" --arg pin "$PIN" --argjson alpn "$1" '{
    serverName: $sni, alpn: $alpn, certificates: [{certificateFile: $c, keyFile: $k}],
    settings: ({fingerprint: "chrome"} + (if $pin != "" then {pinnedPeerCertSha256: [$pin]} else {} end))}'
}

# ---------- протоколы ----------

# AmneziaWG – в отдельной подписке: приложения на Xray и sing-box (Happ, v2rayN, Karing,
# Hiddify) его не умеют и видят как обычный WireGuard, который не подключается.
client_base() { # суффикс
  local sid=$SUBID
  [[ $1 == awg* ]] && sid="$SUBID-awg"
  [[ $1 == mtproto ]] && sid="$SUBID-tg"   # ссылка для Telegram, VPN-приложениям не нужна
  jq -nc --arg e "$NAME-$1" --arg s "$sid" '{email: $e, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: $s, comment: "", reset: 0}'
}
uuid() { cat /proc/sys/kernel/random/uuid; }
rnd() { shuf -i "$1-$2" -n 1; }

# add_inbound remark port proto(tcp|udp|both|inner) protocol settings stream
# inner – подключение за nginx: слушает 127.0.0.1, наружу порт не открываем.
add_inbound() {
  local remark=$1 port=$2 net=$3 protocol=$4 settings=$5 stream=$6 body listen=""
  [[ $net == inner ]] && listen=127.0.0.1
  if jq -e --arg r "$remark" 'any(.[]; .remark == $r)' <<<"$EXISTING" >/dev/null; then
    CREATED+=("$remark"); open_port "$port" "$net"; return
  fi
  # Клиентов в подключение не кладём: пользователь добавляется потом сразу во все подключения.
  settings=$(jq -c 'if has("clients") then .clients = [] else . end' <<<"$settings")
  local n
  local nets=$net
  [[ $net == both ]] && nets="tcp udp"
  [[ $net == inner ]] && nets=tcp
  for n in $nets; do
    if port_busy "$port" "$n"; then later "$remark пропущен: порт $port/$n занят"; return; fi
  done
  body=$(jq -nc --arg rm "$remark" --argjson port "$port" --arg p "$protocol" --arg s "$settings" --arg st "$stream" --arg l "$listen" '{
    remark: $rm, enable: true, listen: $l, port: $port, protocol: $p, settings: $s, streamSettings: $st,
    sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
    expiryTime: 0, total: 0}')
  local out
  out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  if [[ $(jq -r '.success' <<<"$out") != true ]] && grep -q 'Duplicate email' <<<"$out"; then
    # Клиент с таким именем остался от удалённого подключения – берём уникальное имя.
    body=$(jq -c --arg sfx "-$(openssl rand -hex 2)" '.settings |= (fromjson | .clients[0].email += $sfx | tojson)' <<<"$body")
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель не создала $remark: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  CREATED+=("$remark"); open_port "$port" "$net"
}

open_port() { # port net
  case $2 in
    inner) ;;
    tcp|udp) OPEN+=("$1/$2") ;;
    both) OPEN+=("$1/tcp" "$1/udp") ;;
  esac
}

# External Proxy 3X-UI: ссылки ведут на HOST:443, хотя подключение слушает localhost.
# SNI – только для TLS через nginx: у REALITY своё имя сайта маскировки, его не трогаем.
ext_proxy() { # forceTls(same|tls) alpn(JSON)
  local sni=""
  [[ $HOST =~ ^[0-9.]+$ ]] || sni=$HOST
  jq -nc --arg f "$1" --arg h "$HOST" --arg lh "${LINK_HOST:-$HOST}" --arg sni "$sni" --argjson alpn "${2:-null}" '[{forceTls: $f, dest: (if $f == "same" then $lh else $h end), port: 443, remark: ""}
    + (if $f == "tls" then {fingerprint: "chrome", alpn: $alpn} + (if $sni != "" then {sni: $sni} else {} end) else {} end)]'
}

proto_reality() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base reality)" '{clients: [$c + {id: $id, flow: "xtls-rprx-vision"}], decryption: "none", fallbacks: []}')
  stream=$(jq -nc --arg sni "$SNI" --arg target "$(reality_target "$SNI")" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {show: false, xver: 0, target: $target, serverNames: [$sni], privateKey: $k.privateKey,
      minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}},
    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy same)" '.externalProxy = $e | .tcpSettings.acceptProxyProtocol = true' <<<"$stream")
    add_inbound "REALITY" "${INNER[reality]}" inner vless "$settings" "$stream"
  else
    add_inbound "REALITY" "$PORT" tcp vless "$settings" "$stream"
  fi
}

# Второй REALITY на высоком свободном порту, напрямую (без nginx). Где-то 443 и привычные порты
# бывает удобнее высокий случайный порт; ключи, shortId и порт у него свои, сайт маскировки тот же.
proto_reality2() {
  local keys stream settings port
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base reality2)" '{clients: [$c + {id: $id, flow: "xtls-rprx-vision"}], decryption: "none", fallbacks: []}')
  stream=$(jq -nc --arg sni "$SNI" --arg target "$(reality_target "$SNI")" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {show: false, xver: 0, target: $target, serverNames: [$sni], privateKey: $k.privateKey,
      minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}},
    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')
  port=$(free_port)
  add_inbound "REALITY-2" "$port" tcp vless "$settings" "$stream"
}

proto_xhttp() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base xhttp)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{
    network: "xhttp", security: "reality", xhttpSettings: {path: $path, mode: "auto"},
    realitySettings: {target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", spiderX: "/"}}}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --arg sni "$SNI2" --argjson e "$(ext_proxy same)" '.realitySettings.target = ($sni + ":443") | .realitySettings.serverNames = [$sni]
      | .externalProxy = $e | .sockopt = {acceptProxyProtocol: true}' <<<"$stream")
    add_inbound "XHTTP" "${INNER[xhttp]}" inner vless "$settings" "$stream"
  else
    add_inbound "XHTTP" "${PORTS[xhttp]}" tcp vless "$settings" "$stream"
  fi
}

proto_ws() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base ws)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["http/1.1"]')" '{network, wsSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "VLESS-WS" "${INNER[ws]}" inner vless "$settings" "$stream"
  else
    add_inbound "VLESS-WS" "${PORTS[ws]}" tcp vless "$settings" "$stream"
  fi
}

proto_trojan() {
  local settings stream
  settings=$(jq -nc --arg pw "$(rand_str 16)" --argjson c "$(client_base trojan)" '{clients: [$c + {password: $pw}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h2"]')" --arg sn "$(rand_str 8 | tr 'A-Z' 'a-z')" '{network: "grpc", security: "tls", grpcSettings: {serviceName: $sn}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["h2"]')" '{network, grpcSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "Trojan-gRPC" "${INNER[trojan]}" inner trojan "$settings" "$stream"
  else
    add_inbound "Trojan-gRPC" "${PORTS[trojan]}" tcp trojan "$settings" "$stream"
  fi
}

proto_vmess() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base vmess)" '{clients: [$c + {id: $id, security: "auto", alterId: 0}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  if [[ $SINGLE == yes ]]; then
    stream=$(jq -c --argjson e "$(ext_proxy tls '["http/1.1"]')" '{network, wsSettings, security: "none", externalProxy: $e}' <<<"$stream")
    add_inbound "VMess-WS" "${INNER[vmess]}" inner vmess "$settings" "$stream"
  else
    add_inbound "VMess-WS" "${PORTS[vmess]}" tcp vmess "$settings" "$stream"
  fi
}

proto_ss() {
  local settings
  settings=$(jq -nc --arg pw "$(openssl rand -base64 16)" --arg upw "$(openssl rand -base64 16)" --argjson c "$(client_base ss)" '{
    method: "2022-blake3-aes-128-gcm", password: $pw, network: "tcp,udp", clients: [$c + {method: "", password: $upw}]}')
  add_inbound "Shadowsocks" "${PORTS[ss]}" both shadowsocks "$settings" '{"network":"tcp","security":"none"}'
}

proto_hy2() {
  local settings stream
  settings=$(jq -nc --arg a "$(rand_str 16)" --argjson c "$(client_base hy2)" '{version: 2, clients: [$c + {auth: $a}]}')
  # На посторонний HTTP/3-запрос сервер отвечает страницей сайта (masquerade), а не молчанием или ошибкой.
  stream=$(jq -nc --argjson t "$(tls_json '["h3"]')" --arg page "${STUB_HTML:-}" '{network: "hysteria", security: "tls", tlsSettings: $t,
    hysteriaSettings: ({version: 2} + (if $page != "" then {masquerade: {type: "string", content: $page, statusCode: 200, headers: {"content-type": "text/html; charset=utf-8"}}} else {} end))}')
  add_inbound "Hysteria2" "$PORT" udp hysteria "$settings" "$stream"
}

proto_tuic() {
  local settings id
  id=$(uuid)
  settings=$(jq -nc --arg id "$id" --arg pw "$(rand_str 16)" --arg c "$CERT" --arg k "$KEY" --argjson cb "$(client_base tuic)" '{
    server: {certificate: $c, private_key: $k, congestion_control: "bbr", alpn: ["h3"], udp_relay_mode: "native",
      zero_rtt_handshake: false, log_level: "warn", sni: ""},
    clients: [$cb + {uuid: $id, id: $id, password: $pw}]}')
  add_inbound "TUIC" "${PORTS[tuic]}" udp tuic "$settings" '{}'
}

wg_pair() { /usr/local/x-ui/bin/xray-linux-* wg; }

proto_wg() {
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg sk "$(awk '/Private/ {print $NF}' <<<"$srv")" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --argjson c "$(client_base wg)" '{mtu: 1420, secretKey: $sk, peers: [], subnetIp: "10.0.0.0", subnetCidr: 24,
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: ["10.0.0.2/32"]}]}')
  add_inbound "WireGuard" "${PORTS[wg]}" udp wireguard "$settings" '{"network":"tcp","security":"none"}'
}

# AmneziaWG: классические параметры понимают Mihomo и роутеры Keenetic,
# полный набор 3.1 – только приложения AmneziaVPN/AmneziaWG. Поэтому два подключения.
awg_obfuscation() { # classic|full
  local jmin s1 s2
  jmin=$(rnd 40 89); s1=$(rnd 15 150); s2=$(rnd 15 150)
  while ((s1 + 56 == s2)); do s2=$(rnd 15 150); done
  local o
  o=$(jq -nc --argjson jc "$(rnd 3 6)" --argjson jmin "$jmin" --argjson jmax "$((jmin + $(rnd 50 250)))" --argjson s1 "$s1" --argjson s2 "$s2" \
    --arg h1 "$(rnd 5 536870911)" --arg h2 "$(rnd 536870912 1073741823)" --arg h3 "$(rnd 1073741824 1610612735)" --arg h4 "$(rnd 1610612736 2147483647)" \
    '{jc: $jc, jmin: $jmin, jmax: $jmax, s1: $s1, s2: $s2, h1: $h1, h2: $h2, h3: $h3, h4: $h4}')
  if [[ $1 == full ]]; then
    # С защитой заголовков (3.1) документация AmneziaWG советует H1–H4 = 1, 2, 3, 4:
    # тип сообщения тогда скрывает сама защита, а свои заголовки отключаются.
    local cp rk rj rt ka ha
    cp=$(rnd 8 24); rk=$(rnd 100 120); rj=$((rk + $(rnd 10 40) + $(rnd 30 60))); rt=$(rnd 3 6); ka=$(rnd 8 12); ha=$(rnd 15 25)
    o=$(jq -c --argjson s3 "$(rnd 12 55)" --argjson s4 "$(rnd 12 27)" --arg i1 "<r $(rnd 32 256)>" --arg hp "$(openssl rand -base64 32)" \
      --arg cp "$cp-$((cp + $(rnd 8 40)))" --arg rk "$rk-$((rk + $(rnd 10 40)))" --arg rj "$rj-$((rj + $(rnd 30 90)))" \
      --arg rt "$rt-$((rt + $(rnd 1 4)))" --arg ka "$ka-$((ka + $(rnd 2 8)))" --arg ha "$ha-$((ha + $(rnd 5 25)))" \
      '. + {h1: "1", h2: "2", h3: "3", h4: "4",
            s3: $s3, s4: $s4, i1: $i1, headerProtectionKey: $hp, contentPaddingAddition: $cp, rekeyAfterTime: $rk,
            rejectAfterTime: $rj, rekeyTimeout: $rt, keepaliveTimeout: $ka, maxHandshakeAttempts: $ha}' <<<"$o")
  fi
  echo "$o"
}

awg_inbound() { # remark port subnet client-ip suffix mode
  local srv cli settings
  srv=$(wg_pair); cli=$(wg_pair)
  settings=$(jq -nc --arg pk "$(awk '/Private/ {print $NF}' <<<"$srv")" --arg pub "$(awk '/Public|Password/ {print $NF}' <<<"$srv" | head -1)" \
    --arg pr "$(awk '/Private/ {print $NF}' <<<"$cli")" --arg pu "$(awk '/Public|Password/ {print $NF}' <<<"$cli" | head -1)" \
    --arg net "$3" --arg ip "$4" --argjson o "$(awg_obfuscation "$6")" --argjson c "$(client_base "$5")" '{
    server: ({privateKey: $pk, publicKey: $pub, subnetIp: $net, subnetCidr: 24, primaryDns: "1.1.1.1", secondaryDns: "8.8.8.8"} + $o),
    clients: [$c + {privateKey: $pr, publicKey: $pu, allowedIPs: [$ip]}]}')
  add_inbound "$1" "$2" udp amneziawg "$settings" '{}'
}

proto_awg() { awg_inbound "AmneziaWG" "${PORTS[awg]}" 10.8.1.0 10.8.1.2/32 awg classic; }
proto_awg3() { awg_inbound "AmneziaWG-3.1" "${PORTS[awg3]}" 10.8.2.0 10.8.2.2/32 awg3 full; }

telegram_reachable() {
  local ip
  for ip in 149.154.167.51 149.154.175.50 91.108.56.130; do
    timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null && return 0
  done
  return 1
}

proto_mtproto() {
  # MTProto бесполезен, если сам сервер не достаёт до Telegram (так бывает у отдельных хостеров).
  if ! telegram_reachable; then
    later "MTProto пропущен: с этого сервера недоступны серверы Telegram – прокси для Telegram здесь работать не будет."
    return
  fi
  local settings
  if [[ $SINGLE == yes ]]; then
    # FakeTLS-домен – свой сайт: nginx узнаёт MTProto по нему и передаёт mtg с реальным IP клиента.
    settings=$(jq -nc --arg d "$SNI3" --argjson c "$(client_base mtproto)" '{fakeTlsDomain: $d, proxyProtocolListener: true, clients: [$c + {secret: ""}]}')
    add_inbound "MTProto" "${INNER[mtproto]}" inner mtproto "$settings" '{}'
  else
    settings=$(jq -nc --argjson c "$(client_base mtproto)" '{fakeTlsDomain: "www.cloudflare.com", clients: [$c + {secret: ""}]}')
    add_inbound "MTProto" "${PORTS[mtproto]}" tcp mtproto "$settings" '{}'
  fi
}

# ---------- пользователи ----------

# Один клиент 3X-UI на все подключения: общие трафик, лимиты и срок, одна подписка.
ensure_user() {
  local list me ids missing legacy
  list=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  ids=$(non_awg_ids)
  me=$(jq -c --arg e "$NAME" 'map(select(.email == $e))[0] // empty' <<<"$list")
  legacy=$(jq -r --arg p "$NAME-" 'map(select((.email | startswith($p)) and (.email | test("-awg[0-9]*$") | not))) | .[0].subId // empty' <<<"$list")
  if [[ -n $me ]]; then
    SUBID=$(jq -r '.subId' <<<"$me")
    missing=$(jq -c --argjson all "$ids" '$all - (.inboundIds // [])' <<<"$me")
    [[ $missing == "[]" ]] || api POST "clients/$NAME/attach" "$(jq -nc --argjson i "$missing" '{inboundIds: $i}')" >/dev/null
    awg_attach "$NAME" "$SUBID"
  elif [[ -n $legacy ]]; then
    # Установка до kit 1.1: у каждого протокола свой клиент – оставляем как есть.
    SUBID=$legacy
  else
    SUBID=$(rand_str 16 | tr 'A-Z' 'a-z')
    api POST clients/add "$(jq -nc --arg e "$NAME" --arg s "$SUBID" --argjson ids "$ids" \
      '{client: {email: $e, subId: $s, totalGB: 0, expiryTime: 0, limitIp: 0, enable: true, flow: "xtls-rprx-vision", comment: "kit"}, inboundIds: $ids}')" >/dev/null
    awg_attach "$NAME" "$SUBID"
  fi
}

# В 3X-UI 3.x у клиента одна запись и в ней одна пара ключей WireGuard и один адрес. Если
# клиент подключён к двум AmneziaWG, в подписку для обоих уходят ключ и адрес одного из них,
# и второй сервер клиента не узнаёт (проверено 2026-09-27). Поэтому к первому AmneziaWG
# подключаем основную запись, а ко второму – запись-«двойник» «имя-awg» с подпиской «<id>-awg»
# (subId в 3X-UI обязан быть уникальным) и теми же лимитами; kit-sub подмешивает её в Clash.
awg_ids() { api GET inbounds/list | jq -r '[.[] | select(.protocol == "amneziawg") | .id] | sort | .[]'; }
non_awg_ids() { api GET inbounds/list | jq -c '[.[] | select(.protocol != "amneziawg") | .id]'; }

awg_attach() { # имя subId [лимит-байт] [срок-мс] [устройств]
  local name=$1 sid=$2 total=${3:-0} exp=${4:-0} lim=${5:-0} n=1 id email have
  have=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  for id in $(awg_ids); do
    local esid=$sid
    if ((n == 1)); then email=$name
    elif ((n == 2)); then email="$name-awg"; esid="$sid-awg"
    else email="$name-awg$n"; esid="$sid-awg$n"; fi
    n=$((n + 1))
    if jq -e --arg e "$email" --argjson i "$id" 'any(.[]; .email == $e and ((.inboundIds // []) | index($i)))' <<<"$have" >/dev/null; then
      continue
    elif jq -e --arg e "$email" 'any(.[]; .email == $e)' <<<"$have" >/dev/null; then
      api POST "clients/$email/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null
    else
      api POST clients/add "$(jq -nc --arg e "$email" --arg s "$esid" --argjson t "$total" --argjson x "$exp" --argjson l "$lim" --argjson i "$id" \
        '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x, limitIp: $l, enable: true, comment: "kit"}, inboundIds: [$i]}')" >/dev/null
    fi
  done
}

KIT_CLI_URL="$KIT_RAW/scripts/kit.sh"

install_kit_cli() {
  install -d -m 700 /etc/kit
  {
    printf 'HOST=%q\n' "$HOST"
    printf 'LINK_HOST=%q\n' "${LINK_HOST:-$HOST}"
    printf 'PANEL_ON=%q\n' "ip"
    printf 'SUB_BASE=%q\n' "${SUB_URL%$SUBID}"
    printf 'SUB_PATH=%q\n' "$SUB_PATH"
    printf 'SUB_INTERNAL=%q\n' "${SUB_INTERNAL:-$SUB_PORT}"
    printf 'SINGLE=%q\n' "$SINGLE"
    printf 'MTPROTO_INNER=%q\n' "${INNER[mtproto]}"
  } >/etc/kit/kit.env
  chmod 600 /etc/kit/kit.env
  install_kit_file
}

install_kit_file() {
  local d src=""
  d=$(dirname "${BASH_SOURCE[0]}")
  [[ -f $d/kit.sh && ${BASH_SOURCE[0]} != /dev/fd/* ]] && src=$d/kit.sh
  if [[ -n $src ]]; then install -m 755 "$src" /usr/local/bin/kit
  else curl -fsSL --retry 3 -o /usr/local/bin/kit "$KIT_CLI_URL" && chmod 755 /usr/local/bin/kit; fi
  bash -n /usr/local/bin/kit || die "Команда kit скачалась повреждённой"
}

KIT_INSTALL_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main/scripts/3x-ui.sh)"

# После «x-ui → Uninstall» меню подсказывает команду официального установщика –
# меняем её на нашу. Только в echo: вызов установщика в «Update» не трогаем.
# Правим один раз при установке, без cron: чужие файлы по расписанию не трогаем.
brand_xui_menu() {
  printf '%s\n' '/echo.*mhsanaei\/3x-ui\/[a-z]*\/install\.sh/ s#bash <(curl -Ls https://raw\.githubusercontent\.com/mhsanaei/3x-ui/[a-z]*/install\.sh)#'"$KIT_INSTALL_CMD"'#' \
    >/etc/kit/xui-menu.sed
  local f
  for f in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
    [[ -f $f ]] && sed -i -f /etc/kit/xui-menu.sed "$f"
  done
  rm -f /etc/cron.d/kit-xui-menu
}

# ---------- всё на 443: nginx ----------

# Сайт-заглушка: на случайный заход по 443 сервер показывает обычный сайт. Страница собирается при
# установке из случайных частей: тема (кафе, фотограф, блог, мастерская…), название, тексты, вёрстка,
# цвета и шрифт. 20 тем × 5 вёрсток – 100 вариантов, а с названиями, адресами и палитрами страницы
# разных серверов не совпадают. Всё внутри скрипта: без внешних шрифтов, скриптов и ссылок.
stub_site() {
  stub_pick() { shift $(($(rnd 1 $#) - 1)); printf '%s' "$1"; }
  local year kind sfx tags items foot name tag font rad bg fg ac mu cd addr copy h k j t mo yy
  local -a ti tx opts idx mon
  year=$(date +%Y)
  # тип (b – название места, p – имя человека)|слова для названия|подзаголовки|пункты «заголовок~текст»|подпись
  # вместо адреса (варианты через ^). В текстах нельзя символы | ^ ~ & < > и двойные кавычки.
  IFS='|' read -r kind sfx tags items foot <<<"$(stub_pick \
"b|Coffee^Café^Coffee House^Coffee Roasters|Small-batch coffee and slow mornings.^Freshly roasted beans, pastries and a quiet corner.^Good coffee, made without hurry.|Our beans~Single-origin lots, roasted in small batches every week.^Breakfast~Granola, toast and pastries from the bakery next door.^Brew bar~Filter, espresso and a seasonal drink of the month.^Take home~Whole beans and ground coffee in 250 g bags.^Hours~Weekdays from 8 to 6, weekends from 9 to 4." \
"b|Bakery^Bakehouse^Bread Co.|Sourdough baked before sunrise.^Bread, buns and cakes from a wood-fired oven.^A neighbourhood bakery since the old days.|Daily bread~Rye, spelt and white sourdough, fresh every morning.^Pastries~Cinnamon buns, croissants and seasonal fruit tarts.^Cakes to order~Birthday and wedding cakes, ordered two days ahead.^Flour~We mill part of our grain on site.^Hours~Open daily from 7, until the bread runs out." \
"p|Photography^Photo^Pictures|Portraits, weddings and quiet landscapes.^Natural light and honest moments.^Stories told in pictures.|Portraits~Relaxed sessions outdoors or in the studio.^Weddings~Full-day coverage with a printed album.^Landscapes~Limited prints from northern coasts and hills.^Prints~Archival paper, signed and numbered.^Booking~Sessions are booked about a month ahead." \
"p|Notes^Journal^Field Notes|Small notes on things I learn.^Writing things down so I do not forget them.^Thoughts on books, tools and long walks.|Keeping a reading log~Two years of short notes on every book I finished.^Plain text everywhere~Why my notes live in simple files and folders.^A slower kitchen~Learning to bake bread on weekends.^Walking the coast~Notes from a week on foot along the shore.^On small habits~What stuck after a year of tiny changes.|Written slowly, updated now and then" \
"b|Books^Bookshop^Book Room|New and second-hand books.^A small shop with a big back room.^Books, maps and a reading chair.|New arrivals~Fresh fiction, travel writing and essays every Friday.^Second-hand~We buy and sell used books in good condition.^Children~A corner full of picture books and stories.^Book club~We meet on the first Thursday of every month.^Orders~Anything in print, usually within a week." \
"b|Bicycles^Bike Works^Cycle Shop|Repairs, parts and friendly advice.^Keeping the town on two wheels.^Bikes fixed while you drink a coffee.|Repairs~Brakes, gears and wheels, usually the same day.^Service~A full check-up before the season starts.^Second-hand bikes~Refurbished city and touring bikes.^Parts~Tyres, chains, lights and locks in stock.^Workshop~Monday to Saturday, no appointment needed." \
"b|Flowers^Florist^Flower Shop|Seasonal flowers, arranged by hand.^Bouquets for every day and every occasion.^Fresh stems from local growers.|Bouquets~Hand-tied and wrapped in paper, ready to go.^Weddings~Flowers for the ceremony, tables and the bride.^Plants~Easy houseplants and pots for small flats.^Subscriptions~A fresh bouquet every week or every month.^Delivery~Same-day delivery across town." \
"b|Yoga^Yoga House^Yoga Studio|Slow classes for busy people.^Move, breathe and rest.^A calm room in the middle of town.|Morning flow~A gentle start to the day, all levels welcome.^Beginners~A four-week course covering the basics.^Stretch and rest~Evening classes to unwind after work.^Private sessions~One-to-one classes by appointment.^Timetable~Classes every day except Sunday." \
"p|Translations^Language Services^Translation|English, German and Spanish translations.^Clear texts in another language.^Careful translation for people and small firms.|Documents~Certificates, letters and contracts.^Websites~Pages and product texts, adapted for readers.^Editing~Proofreading of texts written by non-native speakers.^Deadlines~Short texts are usually ready in two days.^Quote~Send the text and get a price within a day." \
"b|Architects^Architecture^Design Studio|Homes and small buildings.^Quiet buildings that age well.^Design for houses, shops and gardens.|Houses~New homes and careful renovations.^Interiors~Kitchens, built-in furniture and lighting.^Planning~Drawings and paperwork for permits.^Projects~A selection of recent work is available on request.^Visits~Meetings at the studio by appointment." \
"b|Bookkeeping^Accounting^Tax Advisors|Bookkeeping for small businesses.^Numbers in order, every month.^Tax returns without the headache.|Bookkeeping~Monthly records, invoices and bank reconciliation.^Payroll~Salaries and reports for teams of up to fifty.^Tax returns~Yearly returns for companies and sole traders.^Advice~A short call before big decisions.^Office~Open on weekdays, meetings by appointment." \
"b|Woodworks^Furniture^Joinery|Furniture made to last.^Solid wood, simple shapes.^Tables, shelves and cabinets made by hand.|Tables~Oak and ash dining tables made to size.^Shelves~Bookcases and wall shelves for awkward corners.^Repairs~Old chairs and cabinets brought back to life.^Materials~Wood from local sawmills, natural oils only.^Workshop~Visitors welcome on Saturdays." \
"b|Guesthouse^Inn^Rooms|Six rooms and a big breakfast.^A quiet place to stay near the old town.^Simple rooms with a garden view.|Rooms~Double and twin rooms with private bathrooms.^Breakfast~Served from 8 to 10 in the garden room.^Location~Ten minutes on foot from the station.^Long stays~Lower rates for a week or more.^Booking~Write or call, we answer the same day." \
"b|Language School^Learning Center^Language Club|Small groups, real conversations.^Learn a language one evening at a time.^Courses for adults and teenagers.|Group courses~Six to eight students, twice a week.^Private lessons~Flexible times, in person or at home.^Exam preparation~Courses for common language exams.^Placement~A free short test to find your level.^Terms~New groups start every September and February." \
"p|Illustration^Drawings^Art|Illustration for books and packaging.^Ink, paper and a lot of coffee.^Drawings with a story behind them.|Books~Covers and inside pages for children and adults.^Packaging~Labels for tea, coffee and small brands.^Portraits~Drawn portraits from your photos.^Prints~A small shop of signed prints.^Commissions~Open for new work from next month." \
"b|Ceramics^Pottery^Clay Works|Handmade cups, bowls and plates.^Stoneware for everyday use.^A small pottery with an open door.|Tableware~Plates and bowls fired at high temperature.^Classes~Wheel classes for beginners on weekday evenings.^Commissions~Sets for cafés and restaurants.^Glazes~Mixed in the studio from simple recipes.^Studio shop~Open on Fridays and Saturdays." \
"b|Gardens^Landscaping^Garden Design|Gardens planned for real life.^Green spaces that are easy to keep.^Design and care for small gardens.|Design~Plans and planting lists for new gardens.^Planting~Trees, hedges and borders put in by our team.^Care~Seasonal visits for pruning and tidying.^Courtyards~Ideas for small yards and balconies.^Consultation~A first visit with a short written plan." \
"b|Music School^Piano Lessons^Music Room|Lessons for all ages.^Piano, guitar and singing.^Learn to play the music you love.|Piano~Lessons for beginners and returning players.^Guitar~Acoustic and electric, chords to fingerstyle.^Singing~Voice lessons for choirs and solo work.^Concerts~Students play twice a year for family and friends.^Trial lesson~The first half hour is free." \
"b|Docs^Handbook^Documentation|Guides and reference for the project.^Everything you need to get started.^Documentation for users and contributors.|Getting started~Install, set up and run your first project.^Configuration~All options with short examples.^Guides~Step-by-step recipes for common tasks.^Reference~Commands, settings and file formats.^Changelog~What changed in each release.|Documentation for the current release" \
"b|Tailoring^Alterations^Tailors|Alterations and made-to-measure clothes.^Clothes that fit, repaired with care.^A small sewing studio near the market.|Alterations~Hems, sleeves and waistlines adjusted.^Repairs~Zips, buttons and patches done while you wait.^Made to measure~Shirts and dresses cut for you.^Fabrics~Linen, wool and cotton from small mills.^Hours~Tuesday to Saturday, from 10 to 6.")"
  if [[ $kind == p ]]; then
    name="$(stub_pick Anna Clara Daniel Elena Felix Hanna Iris Jonas Lena Lucas Maya Nina Oscar Paula Ruth Simon Tom Vera)"
    name+=" $(stub_pick Avery Bell Carter Dale Ellis Foster Grant Hale Hart Lowe Marsh Moreau Nolan Price Reyes Sato Vance Wells)"
  else
    name=$(stub_pick Alder Amber Ashgrove Birch Bluestone Bramble Brightwater Cedar Clover Copper Driftwood Eastgate Fern Fieldstone \
      Foxglove Granite Greenway Hazel Heron Highland Hillcrest Juniper Kestrel Lakeside Lantern Larch Linden Maple Meadow Mill Moss \
      Northfield Oakridge Orchard Pinecone Quiet\ Hill Red\ Door Riverside Rowan Saffron Saltmarsh Sparrow Stonebridge Sunfield \
      Thistle Tidewater Two\ Rivers Westbrook Willow Wren)
  fi
  IFS='^' read -ra opts <<<"$sfx"; name+=" $(stub_pick "${opts[@]}")"
  IFS='^' read -ra opts <<<"$tags"; tag=$(stub_pick "${opts[@]}")
  # Три пункта из пяти в случайном порядке.
  IFS='^' read -ra opts <<<"$items"
  idx=(0 1 2 3 4)
  for k in 0 1 2; do j=$(rnd "$k" 4); t=${idx[k]}; idx[k]=${idx[j]}; idx[j]=$t; done
  ti=(); tx=()
  for k in 0 1 2; do ti+=("${opts[${idx[k]}]%%~*}"); tx+=("${opts[${idx[k]}]#*~}"); done
  read -r bg fg ac mu cd <<<"$(stub_pick "#f6f7f9 #1f2328 #0969da #57606a #ffffff" "#fdfaf4 #3b2f24 #8a5a2b #7a6a5a #fffdf8" \
    "#111111 #eeeeee #d4a373 #a0a0a0 #1c1c1c" "#f4f1ea #2b2b2b #2f6f4f #6b6b6b #ffffff" "#fbfbfd #1d1d1f #c2410c #6e6e73 #ffffff" \
    "#eef3f8 #102a43 #1f6feb #52606d #ffffff" "#fff8f3 #3d2c2e #b5485d #8c7376 #ffffff" "#f7f7f2 #222222 #6a4c93 #666666 #ffffff" \
    "#0f172a #e2e8f0 #38bdf8 #94a3b8 #1e293b" "#fafaf9 #292524 #4d7c0f #78716c #ffffff")"
  font=$(stub_pick "-apple-system,Segoe UI,Roboto,sans-serif" "Georgia,serif" "Helvetica,Arial,sans-serif" \
    "ui-monospace,Menlo,Consolas,monospace" "Palatino,Book Antiqua,serif" "Verdana,Geneva,sans-serif")
  rad=$(stub_pick 0 4px 6px 10px 16px)
  addr=${foot:-$(rnd 2 180) $(stub_pick Mill\ Lane Station\ Road Church\ Street Bridge\ Street Park\ Avenue Market\ Square \
    Garden\ Row Orchard\ Way River\ Walk Hill\ Road Elm\ Street Harbour\ Road Chapel\ Lane Meadow\ Close)}
  copy="&copy; $year $name"
  h="<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>$name</title><style>body{margin:0;font-family:$font;background:$bg;color:$fg}"
  case $(rnd 1 5) in
    1) h+="body{min-height:100vh;display:grid;place-items:center;text-align:center}main{max-width:560px;padding:32px 20px}h1{font-size:38px;margin:0 0 10px}p{color:$mu;font-size:18px;line-height:1.5}.b{display:inline-block;margin-top:14px;padding:10px 22px;border-radius:$rad;background:$ac;color:$cd}small{display:block;margin-top:44px;color:$mu;font-size:13px}</style></head><body><main><h1>$name</h1><p>$tag</p><p>${tx[0]}</p><span class=\"b\">${ti[1]}</span><small>$addr &middot; $copy</small></main>" ;;
    2) h+="header{background:$ac;color:$cd;padding:44px 20px;text-align:center}h1{margin:0 0 6px;font-size:28px}header p{margin:0;opacity:.85}main{max-width:820px;margin:32px auto;padding:0 20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.c{background:$cd;border:1px solid ${mu}33;border-radius:$rad;padding:18px}.c b{display:block;margin-bottom:6px}.c span{color:$mu;font-size:14px;line-height:1.5}footer{text-align:center;color:$mu;font-size:13px;padding:28px}</style></head><body><header><h1>$name</h1><p>$tag</p></header><main>"
       for k in 0 1 2; do h+="<div class=\"c\"><b>${ti[k]}</b><span>${tx[k]}</span></div>"; done
       h+="</main><footer>$addr &middot; $copy</footer>" ;;
    3) h+="body{display:flex;min-height:100vh;line-height:1.6}nav{width:220px;background:$cd;border-right:1px solid ${mu}33;padding:28px 20px;box-sizing:border-box}nav b{display:block;margin-bottom:18px;color:$ac}nav p{margin:8px 0;color:$mu}main{flex:1;max-width:720px;padding:36px 32px}h1{font-size:26px;margin-top:0}h2{font-size:18px;margin:28px 0 6px}small{display:block;margin-top:40px;color:$mu}@media(max-width:640px){nav{display:none}}</style></head><body><nav><b>$name</b>"
       for k in 0 1 2; do h+="<p>${ti[k]}</p>"; done
       h+="</nav><main><h1>$tag</h1>"
       for k in 0 1 2; do h+="<h2>${ti[k]}</h2><p>${tx[k]}</p>"; done
       h+="<small>$copy</small></main>" ;;
    4) h+="body{line-height:1.6}main{max-width:640px;margin:0 auto;padding:48px 20px}h1{font-size:24px;margin:0}header p{color:$mu;margin:4px 0 32px}article{padding:16px 0;border-top:1px solid ${mu}33}article h2{font-size:17px;margin:0;color:$ac}time{font-size:13px;color:$mu}article p{margin:6px 0 0}footer{margin-top:32px;font-size:13px;color:$mu}</style></head><body><main><header><h1>$name</h1><p>$tag</p></header>"
       mon=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec); mo=$((10#$(date +%m) - 1)); yy=$year
       for k in 0 1 2; do
         h+="<article><time>${mon[mo]} $(rnd 1 28), $yy</time><h2>${ti[k]}</h2><p>${tx[k]}</p></article>"
         mo=$((mo - $(rnd 1 3))); ((mo >= 0)) || { mo=$((mo + 12)); yy=$((yy - 1)); }
       done
       h+="<footer>$addr &middot; $copy</footer></main>" ;;
    *) h+=".t{background:$fg;color:$bg;padding:56px 20px}.t div,main{max-width:760px;margin:0 auto}h1{font-size:34px;margin:0 0 8px}.t p{margin:0;color:$ac}main{padding:28px 20px 48px}.r{display:flex;gap:24px;padding:18px 0;border-bottom:1px solid ${mu}33}.r b{flex:0 0 180px;color:$ac}.r span{color:$mu}footer{padding-top:24px;font-size:13px;color:$mu}@media(max-width:600px){.r{display:block}}</style></head><body><div class=\"t\"><div><h1>$name</h1><p>$tag</p></div></div><main>"
       for k in 0 1 2; do h+="<div class=\"r\"><b>${ti[k]}</b><span>${tx[k]}</span></div>"; done
       h+="<footer>$addr &middot; $copy</footer></main>" ;;
  esac
  printf '%s</body></html>\n' "$h"
}


setup_nginx() {
  say "Настраиваю nginx: всё TCP через порт 443"
  apt-get install -y -qq nginx libnginx-mod-stream >/dev/null
  # Порт 80 нужен Let's Encrypt для продления сертификата – сайт nginx по умолчанию убираем.
  rm -f /etc/nginx/sites-enabled/default

  # Панель – только через nginx.
  local all
  all=$(api POST setting/all '{}')
  if [[ $(jq -r '.webListen' <<<"$all") != 127.0.0.1 ]]; then
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  install -d -m 755 /var/www/kit
  [[ -f /var/www/kit/index.html ]] || { if [[ -n ${STUB_HTML:-} ]]; then printf '%s' "$STUB_HTML"; else stub_site; fi; } >/var/www/kit/index.html

  # Маршруты – из текущих подключений панели: сайты REALITY, пути WebSocket, сервисы gRPC.
  local list reality_sni xhttp_sni mt_sni steal_domain locs="" kind path port
  list=$(api GET inbounds/list)
  # Свой домен: REALITY отдаёт чужим гостям сайт с этого же сервера (nginx на внутреннем порту).
  steal_domain=$(jq -r --arg t "127.0.0.1:${INNER[selfweb]}" '.[] | select(.remark == "REALITY" and .listen == "127.0.0.1")
    | (.streamSettings | if type == "string" then fromjson else . end).realitySettings | select(.target == $t) | .serverNames[0]' <<<"$list")
  reality_sni=$(jq -r '.[] | select(.remark == "REALITY" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  xhttp_sni=$(jq -r '.[] | select(.remark == "XHTTP" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  mt_sni=$(jq -r '.[] | select(.protocol == "mtproto" and .listen == "127.0.0.1") | (.settings | if type == "string" then fromjson else . end).fakeTlsDomain' <<<"$list")
  # Домен и сертификат проверяем до записи конфигов: nginx не должен остаться с маршрутом в никуда.
  if [[ -n $steal_domain ]]; then
    [[ $steal_domain =~ ^[A-Za-z0-9.-]+$ ]] || die "В подключении REALITY странное имя домена – не трогаю nginx."
    [[ -s $DOMAIN_CERT_DIR/fullchain.pem && -s $DOMAIN_CERT_DIR/privkey.pem ]] || die "Нет сертификата для $steal_domain ($DOMAIN_CERT_DIR) – не трогаю nginx."
  fi
  # Всё из базы панели попадает в конфиг nginx, поэтому чужая база (например, из копии)
  # не должна протащить туда лишние директивы: имена и пути проверяем строго.
  local n
  for n in "$reality_sni" "$xhttp_sni" "$mt_sni"; do
    [[ -z $n || $n =~ ^[A-Za-z0-9.-]+$ ]] || die "В подключениях странное имя сайта маскировки – не трогаю nginx."
  done
  while IFS=$'\t' read -r kind path port; do
    [[ -n $path ]] || continue
    [[ $port =~ ^[0-9]{1,5}$ && $path =~ ^/?[A-Za-z0-9._~/-]+$ ]] || die "В подключениях странный путь ($kind) – не трогаю nginx."
    if [[ $kind == ws ]]; then
      locs+="
    location = $path {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_read_timeout 1h;
    }"
    else
      locs+="
    location /$path/ {
        grpc_pass grpc://127.0.0.1:$port;
        grpc_set_header X-Real-IP \$proxy_protocol_addr;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        client_max_body_size 0;
    }"
    fi
  done < <(jq -r '.[] | select(.listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end) as $st
    | if $st.network == "ws" then ["ws", $st.wsSettings.path, .port]
      elif $st.network == "grpc" then ["grpc", $st.grpcSettings.serviceName, .port]
      else empty end | @tsv' <<<"$list")

  # Пути панели (из install-result.env, при --restore – из копии) и подписки попадают в конфиг nginx.
  [[ $XUI_WEB_BASE_PATH =~ ^/?[A-Za-z0-9_-]{1,64}/?$ && $SUB_PATH =~ ^/[A-Za-z0-9_-]{1,64}/$ ]] \
    || die "Странный путь панели или подписки ($XUI_ENV) – не собираю nginx."
  local panel_path=/${XUI_WEB_BASE_PATH#/}
  panel_path=${panel_path%/}/
  {
    echo "# Сгенерировано 3x-ui.sh (3X-UI KIT) – перезаписывается при повторном запуске."
    echo "stream {"
    echo "    map \$ssl_preread_server_name \$kit_upstream {"
    [[ -n $reality_sni ]] && echo "        $reality_sni 127.0.0.1:${INNER[reality]};"
    [[ -n $xhttp_sni && $xhttp_sni != "$reality_sni" ]] && echo "        $xhttp_sni 127.0.0.1:${INNER[xhttp]};"
    [[ -n $mt_sni ]] && echo "        $mt_sni 127.0.0.1:${INNER[mtproto]};"
    echo "        default 127.0.0.1:${INNER[web]};"
    echo "    }"
    echo "    server {"
    echo "        listen 443;"
    echo "        listen [::]:443;"
    echo "        ssl_preread on;"
    echo "        proxy_pass \$kit_upstream;"
    echo "        proxy_protocol on;"
    echo "        proxy_connect_timeout 10s;"
    echo "        proxy_timeout 1h;"
    echo "    }"
    echo "}"
  } >/etc/nginx/kit-stream.conf
  cat >/etc/nginx/conf.d/kit.conf <<NGX
# Сгенерировано 3x-ui.sh (3X-UI KIT) – перезаписывается при повторном запуске.
server {
    listen 127.0.0.1:${INNER[web]} ssl http2 proxy_protocol;
    server_name _;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    # Иначе редирект «добавить слеш» уйдёт на внутренний порт nginx.
    absolute_redirect off;
    access_log off;
$locs
    location $SUB_PATH {
        proxy_pass http://127.0.0.1:${INNER[sub]};
        proxy_set_header Host \$host;
    }
    location $panel_path {
        proxy_pass https://127.0.0.1:$XUI_PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    location / {
        root /var/www/kit;
        index index.html;
    }
}
NGX
  if [[ -n $steal_domain ]]; then
    cat >>/etc/nginx/conf.d/kit.conf <<NGX

# Свой домен (self-steal): сюда REALITY отправляет всех, кто не подключается как клиент.
# Только заглушка, без панели и подписки; порт слушает localhost.
server {
    listen 127.0.0.1:${INNER[selfweb]} ssl http2;
    server_name $steal_domain;
    ssl_certificate $DOMAIN_CERT_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    location / {
        root /var/www/kit;
        index index.html;
    }
}
NGX
  fi
  grep -q 'kit-stream.conf' /etc/nginx/nginx.conf || echo 'include /etc/nginx/kit-stream.conf;' >>/etc/nginx/nginx.conf
  local ngx_log
  ngx_log=$(mktemp)
  if ! nginx -t >"$ngx_log" 2>&1; then
    cat "$ngx_log" >&2; rm -f "$ngx_log"
    # Наш include убираем, чтобы не оставить чужой nginx сломанным.
    sed -i '/kit-stream\.conf/d' /etc/nginx/nginx.conf
    rm -f /etc/nginx/kit-stream.conf
    die "nginx не принял конфиг – лог выше. Если в вашем nginx уже есть блок stream, запустите установку с --multi-port."
  fi
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
  # Let's Encrypt на IP продлевается каждые несколько дней – nginx раз в сутки перечитывает сертификат.
  echo '17 4 * * * root systemctl reload nginx >/dev/null 2>&1' >/etc/cron.d/kit-nginx-reload
  OPEN+=("443/tcp")
  local i
  for i in $(seq 1 10); do port_busy 443 tcp && return 0; sleep 1; done
  die "nginx не открыл порт 443."
}

# ---------- подписка ----------

setup_subscription() {
  local all upd
  all=$(api POST setting/all '{}')
  SUB_PATH=$(jq -r '.subPath // "/sub/"' <<<"$all")
  if [[ $SUB_PATH == /sub/ || -z $SUB_PATH ]]; then SUB_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"; fi
  if [[ $TRUSTED == yes ]]; then
    # Наружу смотрит kit-sub (подписка с учётом приложения), 3X-UI – только на 127.0.0.1.
    SUB_PORT=2096; SUB_INTERNAL=2097
    # Без subURI панель показывает ссылку на внутренний порт 2097, до которого снаружи не достучаться.
    local uri="https://$HOST:$SUB_PORT$SUB_PATH"
    [[ $SINGLE == yes ]] && uri="https://$HOST$SUB_PATH"
    upd=$(jq -c --arg path "$SUB_PATH" --argjson ip "$SUB_INTERNAL" --arg title "3X-UI KIT" --arg uri "$uri" '
      .subEnable = true | .subPath = $path | .subTitle = $title | .subListen = "127.0.0.1" | .subPort = $ip
      | .subURI = $uri
      | .subCertFile = "" | .subKeyFile = ""
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  else
    SUB_PORT=$(jq -r '.subPort // 2096' <<<"$all")
    upd=$(jq -c --arg path "$SUB_PATH" --arg title "3X-UI KIT" '
      .subEnable = true | .subPath = $path | .subTitle = $title
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  fi
  if [[ $upd != "$all" ]]; then
    api POST setting/update "$upd" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi
  [[ $TRUSTED == yes ]] && install_kit_sub
  if [[ $SINGLE == yes ]]; then SUB_URL="https://$HOST$SUB_PATH$SUBID"
  elif [[ $TRUSTED == yes ]]; then SUB_URL="https://$HOST:$SUB_PORT$SUB_PATH$SUBID"; else SUB_URL="http://127.0.0.1:$SUB_PORT$SUB_PATH$SUBID"; fi
  SUB_FETCH="$(if [[ $TRUSTED == yes ]]; then echo https; else echo http; fi)://$HOST:$SUB_PORT$SUB_PATH$SUBID"
}

# Юнит kit-sub: без root (DynamicUser), конфиг и сертификат – через LoadCredential.
# Сертификат Let's Encrypt на IP продлевается раз в несколько дней, поэтому при отдельном
# порте kit-sub перезапускается раз в сутки и берёт свежий.
kit_sub_unit() { # путь-к-сертификату путь-к-ключу (пусто – за nginx)
  cat <<UNIT
[Unit]
Description=kit-sub: подписка с учётом приложения (3X-UI KIT)
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_sub.py
Restart=on-failure
RestartSec=5
DynamicUser=yes
LoadCredential=config.json:/etc/kit-sub/config.json
${1:+LoadCredential=cert.pem:$1}
${2:+LoadCredential=key.pem:$2}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=true
PrivateDevices=true
ProtectProc=invisible
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT
}

KIT_SUB_URL="$KIT_RAW/scripts/kit-sub.py"

# Сам kit_sub.py: рядом со скриптом (запуск из папки scripts/) или из того же релиза.
install_kit_sub_file() {
  install -d -m 755 /usr/local/lib/kit-sub /etc/kit-sub
  local src=${KIT_SUB_SRC:-}
  if [[ -z $src ]]; then
    local d; d=$(dirname "${BASH_SOURCE[0]}")
    [[ -f $d/kit-sub.py && ${BASH_SOURCE[0]} != /dev/fd/* ]] && src=$d/kit-sub.py
  fi
  if [[ -n $src ]]; then install -m 644 "$src" /usr/local/lib/kit-sub/kit_sub.py
  else curl -fsSL --retry 3 -o /usr/local/lib/kit-sub/kit_sub.py "$KIT_SUB_URL"; fi
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" /usr/local/lib/kit-sub/kit_sub.py || die "kit-sub скачался повреждённым"
}

install_kit_sub() {
  say "Ставлю подписку с учётом приложения (kit-sub)"
  apt-get install -y -qq python3 python3-yaml >/dev/null
  install_kit_sub_file
  if [[ $SINGLE == yes ]]; then
    # За nginx: слушаем только localhost, TLS снимает nginx на 443.
    jq -n --arg path "$SUB_PATH" --argjson port "${INNER[sub]}" --arg up "http://127.0.0.1:$SUB_INTERNAL" --arg host "$HOST" --arg lh "${LINK_HOST:-$HOST}" \
      '{listen: "127.0.0.1", port: $port, path: $path, upstream: $up, host: $host} + (if $lh != $host then {link_host: $lh} else {} end)' >/etc/kit-sub/config.json
  else
    jq -n --arg path "$SUB_PATH" --argjson port "$SUB_PORT" --arg up "http://127.0.0.1:$SUB_INTERNAL" \
      --arg cert "$CERT" --arg key "$KEY" --arg host "$HOST" --arg lh "${LINK_HOST:-$HOST}" \
      '{listen: "0.0.0.0", port: $port, path: $path, upstream: $up, cert: $cert, key: $key, host: $host} + (if $lh != $host then {link_host: $lh} else {} end)' >/etc/kit-sub/config.json
  fi
  chmod 600 /etc/kit-sub/config.json
  if [[ $SINGLE == yes ]]; then
    kit_sub_unit >/etc/systemd/system/kit-sub.service
  else
    kit_sub_unit "$CERT" "$KEY" >/etc/systemd/system/kit-sub.service
    echo '19 4 * * * root systemctl restart kit-sub >/dev/null 2>&1' >/etc/cron.d/kit-sub-cert
  fi
  systemctl daemon-reload
  systemctl enable kit-sub >/dev/null 2>&1
  systemctl restart kit-sub
  local i
  local kp=$SUB_PORT
  [[ $SINGLE == yes ]] && kp=${INNER[sub]}
  for i in $(seq 1 20); do port_busy "$kp" tcp && return 0; sleep 1; done
  journalctl -u kit-sub -n 20 --no-pager >&2 || true
  die "kit-sub не запустился – лог выше."
}

# Ссылки пользователя – из его же подписки (её собирает сама 3X-UI).
# Ссылки пользователя – прямо из подписки 3X-UI внутри сервера (мимо kit-sub, который
# прячет от VPN-приложений vpn:// и tg://). sub_links subId [попыток]
sub_links() {
  local id=$1 tries=${2:-20} raw="" i port=${SUB_INTERNAL:-$SUB_PORT} scheme=http
  [[ -z ${SUB_INTERNAL:-} && $TRUSTED == yes ]] && scheme=https
  for i in $(seq 1 "$tries"); do
    # Настоящий адрес в Host – 3X-UI подставит его в ссылки.
    raw=$(curl -fsSk -m 10 -A "v2rayN/7.0" -H "Host: ${LINK_HOST:-$HOST}:$SUB_PORT" "$scheme://127.0.0.1:$port$SUB_PATH$id" 2>/dev/null) && [[ -n $raw ]] && break
    raw=""; sleep 2
  done
  if grep -q '://' <<<"$raw"; then echo "$raw"; else base64 -d <<<"$raw" 2>/dev/null || true; fi
}

# Файл настроек из копии можно читать, только если в нём нет ничего, кроме
# ИМЯ=значение без подстановок и команд, и все имена – из списка для этого файла.
# Иначе чужой архив подменил бы переменные установщика или kit (RESULT, PATH, KIT_VERSION…).
# Значение каждого имени – тоже по его формату: kit потом подставляет их в sed, nginx и ссылки.
# Кавычки – только пустые (''): так printf %q пишет пустое значение, остальное у нас без кавычек.
safe_env() { # файл имя...
  local f=$1 n re; shift
  [[ -r $f ]] || die "В копии нет файла ${f##*/}."
  grep -qvE "^([A-Z][A-Z0-9_]*=([A-Za-z0-9._:/@%+,=_-]*|''))?$" "$f" \
    && die "Это не резервная копия 3X-UI KIT или она повреждена (файл ${f##*/}). Ничего не менял."
  while IFS= read -r n; do
    [[ " $* " == *" $n "* ]] || die "Это не резервная копия 3X-UI KIT или она повреждена (лишнее имя $n в ${f##*/}). Ничего не менял."
    case $n in
      BACKUP_KIT_VERSION) re='^[0-9]{1,3}(\.[0-9]{1,3}){1,3}$' ;;
      BACKUP_HOST | HOST) re='^[A-Za-z0-9.:-]{1,253}$' ;;
      LINK_HOST) re='^[A-Za-z0-9.:-]{0,253}$' ;;
      BACKUP_SSL) re='^(ip|custom|none)$' ;;
      BACKUP_DATE) re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ;;
      XUI_USERNAME | XUI_PASSWORD) re='^[A-Za-z0-9._:/@%+,=-]{1,128}$' ;;
      XUI_PANEL_PORT | SUB_INTERNAL) re='^[0-9]{1,5}$' ;;
      XUI_WEB_BASE_PATH) re='^/?[A-Za-z0-9_-]{1,64}/?$' ;;
      XUI_ACCESS_URL) re='^(https?://[A-Za-z0-9._:-]{1,253}/[A-Za-z0-9_/-]{0,130})?$' ;;
      XUI_API_TOKEN) re='^[A-Za-z0-9._+/=-]{0,200}$' ;;
      XUI_DB_TYPE) re='^(sqlite|postgres)?$' ;;
      PANEL_ON) re='^(ip|domain)?$' ;;
      SUB_BASE) re='^https?://[A-Za-z0-9.:-]{1,253}(/[A-Za-z0-9_-]{1,64}){0,4}/?$' ;;
      SUB_PATH) re='^/[A-Za-z0-9_-]{1,64}/$' ;;
      SINGLE) re='^(yes|no)?$' ;;
      MTPROTO_INNER) re='^[0-9]{0,5}$' ;;
      *) die "Это не резервная копия 3X-UI KIT или она повреждена (имя $n в ${f##*/}). Ничего не менял." ;;
    esac
    [[ $(env_get "$f" "$n") =~ $re ]] \
      || die "Это не резервная копия 3X-UI KIT или она повреждена (значение $n в ${f##*/}). Ничего не менял."
  done < <(grep -oE '^[A-Z][A-Z0-9_]*' "$f")
  return 0
}

# Одно значение из файла, проверенного safe_env: читаем в подоболочке, основной shell не трогаем.
env_get() { # файл имя
  ( . "$1"; printf '%s' "${!2:-}" )
}

# Меняет старый IP на новый в базе панели и файлах kit (только целиком, 1.2.3.4 не заденет 11.2.3.45).
replace_host() { # старый новый файлы...
  python3 - "$@" <<'PY'
import re, sqlite3, sys
old, new, files = sys.argv[1], sys.argv[2], sys.argv[3:]
rx = re.compile(r"(?<![0-9.])" + re.escape(old) + r"(?![0-9])")
sub = lambda v: rx.sub(new, v) if isinstance(v, str) else v
db = sqlite3.connect("/etc/x-ui/x-ui.db")
db.create_function("kit_sub", 1, sub)
# hosts – адреса для ссылок подписки (панель 3.9+): если их не заменить, часть ссылок после переезда ведёт на старый IP.
for table, cols in (("inbounds", ("settings", "stream_settings")), ("settings", ("value",)),
                    ("hosts", ("address", "sni", "host_header", "remark", "server_description"))):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)).fetchone():
        continue
    have = {r[1] for r in db.execute("PRAGMA table_info(%s)" % table)}
    for c in cols:
        if c in have:
            db.execute("UPDATE %s SET %s = kit_sub(%s)" % (table, c, c))
db.commit(); db.close()
for f in files:
    s = open(f).read()
    open(f, "w").write(rx.sub(new, s))
PY
}

# Файлы сертификатов, на которые ссылаются подключения в базе: без них Xray не стартует.
db_cert_files() {
  python3 - <<'PY'
import json, sqlite3
db = sqlite3.connect("file:/etc/x-ui/x-ui.db?mode=ro", uri=True)
out = set()
for s, st in db.execute("SELECT settings, stream_settings FROM inbounds"):
    for raw, key in ((st, "stream"), (s, "settings")):
        try:
            j = json.loads(raw)
            if key == "stream":
                out.update(c.get("certificateFile") for c in j["tlsSettings"]["certificates"])
            else:
                out.add(j["server"]["certificate"])  # TUIC
        except Exception:
            pass
for f in sorted(x for x in out if isinstance(x, str) and x and "\n" not in x):
    print(f)
PY
}

pin_cert_in_db() { # сертификат отпечаток: закрепить отпечаток в подключениях с этим сертификатом (уходит в ссылки)
  python3 - "$1" "$2" <<'PY'
import json, sqlite3, sys
cert, pin = sys.argv[1], sys.argv[2]
db = sqlite3.connect("/etc/x-ui/x-ui.db")
for iid, raw in db.execute("SELECT id, stream_settings FROM inbounds").fetchall():
    try:
        st = json.loads(raw)
        t = st["tlsSettings"]
        if not any(c.get("certificateFile") == cert for c in t["certificates"]):
            continue
    except Exception:
        continue
    t["settings"] = dict(t.get("settings") or {}, pinnedPeerCertSha256=[pin])
    db.execute("UPDATE inbounds SET stream_settings = ? WHERE id = ?", (json.dumps(st, indent=2, ensure_ascii=False), iid))
db.commit(); db.close()
PY
}

# Let's Encrypt на новый IP мог не выдаться (лимит выпусков, закрытый порт 80), а подключения из копии ссылаются
# на его файлы. Тогда на тот же путь кладём самоподписанный сертификат и закрепляем его отпечаток в подключениях,
# как при обычной установке без Let's Encrypt. Путь из базы – только наш (/root/cert/ip или /root/cert/self).
restore_self_cert() { # путь-к-fullchain.pem
  local cert=$1 dir san="IP:$HOST" pin
  if [[ ! $cert =~ ^/root/cert/(ip|self)/fullchain\.pem$ ]]; then
    printf '%s\n' "${R}!${N}  Подключения ссылаются на сертификат $cert, а его нет: Xray не запустится. Положите файл на место и перезапустите: systemctl restart x-ui" >&2
    later "Нет сертификата $cert, на который ссылаются подключения: Xray не запустится, пока файл не вернётся на место."
    return 0
  fi
  dir=${cert%/*}
  [[ $HOST =~ ^[0-9.]+$ ]] || san="DNS:$HOST"
  if [[ $dir == /root/cert/ip ]]; then
    printf '%s\n' "${R}!${N}  Let's Encrypt не выдал сертификат на IP $HOST (лимит: 5 сертификатов в неделю на один IP, закрытый порт 80 или сбой; лог: /var/log/3x-ui-install.log)." >&2
    echo "   Ставлю самоподписанный: ссылки на подключения работают (отпечаток в них), браузер покажет предупреждение, а подписка в приложениях может не открыться." >&2
    later "Сертификат на IP самоподписанный (Let's Encrypt не выдал): пользуйтесь ссылками на отдельные подключения (kit user link имя), подписка в приложениях может не открыться."
    SELF_IP_CERT=yes
  fi
  install -d -m 700 "$dir"
  (umask 077; openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$dir/privkey.pem" \
    -out "$cert" -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null)
  chmod 644 "$cert"
  chmod 600 "$dir/privkey.pem"
  pin=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  # Панель берёт тот же путь из настроек копии. «x-ui cert» не зовём: он включает TLS и у встроенной подписки,
  # а kit-sub ходит к ней по http.
  pin_cert_in_db "$cert" "$pin"
}

xray_alive() { # ждём ядро Xray (дочерний процесс x-ui) до 20 секунд
  local i pid
  for i in $(seq 1 10); do
    pid=$(systemctl show -p MainPID --value x-ui 2>/dev/null || true)
    [[ $pid =~ ^[1-9][0-9]*$ ]] && pgrep -P "$pid" '^xray-linux-' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

restore_main() { # файл
  local file=$1 tmp old_ip=""
  [[ -f $file ]] || die "Нет файла $file. Сначала скопируйте копию на этот сервер: scp kit-backup-….tar.gz root@IP:"
  [[ -d /usr/local/x-ui ]] && die "Восстанавливать можно только на чистый сервер, а здесь уже стоит 3X-UI."
  port_busy 443 tcp && die "Порт 443/tcp занят. Восстанавливать нужно на чистый VPS."

  say "Ставлю пакеты: curl, jq, openssl, qrencode, ufw, python3"
  export DEBIAN_FRONTEND=noninteractive
  wait_apt_idle
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron python3 python3-yaml >/dev/null

  # Сначала проверяем архив целиком: только наши пути, только файлы и папки, без ссылок
  # и «../». Чужой архив не должен ничего записать мимо.
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  python3 - "$file" "$tmp" <<'PY' || die "Это не резервная копия 3X-UI KIT или она повреждена. Ничего не менял."
import os, sys, tarfile
allowed = ("etc/x-ui/x-ui.db", "etc/x-ui/install-result.env", "etc/kit/kit.env", "etc/kit-sub/config.json", "etc/kit-sub/rules.yaml",
           "etc/nginx/kit-stream.conf", "etc/nginx/conf.d/kit.conf", "var/www/kit", "root/cert/self",
           "root/cert/custom", "root/3x-ui.txt", "kit-backup.env")
parents = {"etc", "etc/x-ui", "etc/kit", "etc/kit-sub", "etc/nginx", "etc/nginx/conf.d", "var", "var/www", "root", "root/cert"}
with tarfile.open(sys.argv[1], "r:gz") as t:
    ms = []
    for m in t.getmembers():
        n = os.path.normpath(m.name)
        if n == ".":
            continue
        if n.startswith("/") or ".." in n.split("/"):
            sys.exit("путь " + m.name)
        if not (m.isfile() or m.isdir()):
            sys.exit("не файл " + m.name)
        if not (n in parents and m.isdir()) and not any(n == a or n.startswith(a + "/") for a in allowed):
            sys.exit("лишний " + m.name)
        m.name = n
        m.uid = m.gid = 0
        m.uname = m.gname = "root"
        m.mode = 0o700 if m.isdir() else 0o600
        ms.append(m)
    names = {m.name for m in ms}
    for need in ("etc/x-ui/x-ui.db", "etc/x-ui/install-result.env", "kit-backup.env"):
        if need not in names:
            sys.exit("нет " + need)
    # Каталог сертификата есть – в нём оба файла, иначе установка споткнётся на полпути.
    files = {m.name for m in ms if m.isfile() and m.size > 0}
    for c in ("root/cert/self", "root/cert/custom"):
        if any(n == c or n.startswith(c + "/") for n in names):
            for f in ("fullchain.pem", "privkey.pem"):
                if c + "/" + f not in files:
                    sys.exit("нет " + c + "/" + f)
    if hasattr(tarfile, "data_filter"):
        t.extractall(sys.argv[2], members=ms, filter="data")
    else:
        t.extractall(sys.argv[2], members=ms)
PY
  local f
  safe_env "$tmp/kit-backup.env" BACKUP_KIT_VERSION BACKUP_HOST BACKUP_SSL BACKUP_DATE
  safe_env "$tmp/etc/x-ui/install-result.env" XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_WEB_BASE_PATH XUI_ACCESS_URL XUI_API_TOKEN XUI_DB_TYPE
  [[ $(env_get "$tmp/etc/x-ui/install-result.env" XUI_PANEL_PORT) =~ ^[0-9]{1,5}$ ]] \
    || die "Это не резервная копия 3X-UI KIT или она повреждена (порт панели). Ничего не менял."
  if [[ -f $tmp/etc/kit/kit.env ]]; then
    safe_env "$tmp/etc/kit/kit.env" HOST LINK_HOST PANEL_ON SUB_BASE SUB_PATH SUB_INTERNAL SINGLE MTPROTO_INNER
  fi
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); assert c.execute('PRAGMA integrity_check').fetchone()[0]=='ok'; c.execute('SELECT count(*) FROM inbounds')" \
    "$tmp/etc/x-ui/x-ui.db" 2>/dev/null || die "База панели в копии повреждена. Ничего не менял."

  local BACKUP_HOST BACKUP_SSL BACKUP_DATE BACKUP_KIT_VERSION
  BACKUP_HOST=$(env_get "$tmp/kit-backup.env" BACKUP_HOST)
  BACKUP_SSL=$(env_get "$tmp/kit-backup.env" BACKUP_SSL)
  BACKUP_DATE=$(env_get "$tmp/kit-backup.env" BACKUP_DATE)
  BACKUP_KIT_VERSION=$(env_get "$tmp/kit-backup.env" BACKUP_KIT_VERSION)
  [[ $BACKUP_HOST =~ ^[A-Za-z0-9.:-]+$ ]] || die "Это не резервная копия 3X-UI KIT или она повреждена (адрес сервера). Ничего не менял."
  [[ $BACKUP_SSL =~ ^(ip|custom|none)$ ]] || die "В копии нет данных о сертификате."
  [[ $BACKUP_SSL != custom || -f $tmp/root/cert/custom/fullchain.pem ]] \
    || die "Это не резервная копия 3X-UI KIT или она повреждена (нет своего сертификата). Ничего не менял."
  PANEL_SSL=$BACKUP_SSL
  # Домен переезжает вместе с сервером (поменяйте A-запись), IP – нет.
  if [[ $BACKUP_HOST =~ ^[0-9.]+$ ]]; then
    HOST=${HOST:-$(public_ip)}
    [[ -n $HOST ]] || die "Не удалось узнать внешний IP. Укажите его: --host 1.2.3.4"
    [[ $HOST != "$BACKUP_HOST" ]] && old_ip=$BACKUP_HOST
  else
    HOST=$BACKUP_HOST
  fi
  # Свой домен (self-steal): берём из подключения REALITY в базе. Сертификат в копию не кладём,
  # на новом сервере он выпускается заново, а для этого домен уже должен вести на новый IP.
  DOMAIN=$(python3 - "$tmp/etc/x-ui/x-ui.db" 2>/dev/null <<'PY' || true
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for (s,) in db.execute("SELECT stream_settings FROM inbounds WHERE remark = 'REALITY'"):
    try:
        r = json.loads(s)["realitySettings"]
    except Exception:
        continue
    if r.get("target") == "127.0.0.1:10447" and r.get("serverNames"):
        print(r["serverNames"][0])
        break
PY
)
  [[ $PANEL_SSL == ip || -n $DOMAIN ]] && port_busy 80 tcp && die "Для сертификата нужен свободный порт 80/tcp."
  if [[ -n $DOMAIN ]]; then
    [[ $DOMAIN =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "В копии странное имя домена – не восстанавливаю."
    domain_points_here "$DOMAIN" || die "Сервер в копии маскируется под домен $DOMAIN. Сначала направьте его A-запись на этот сервер, потом запустите восстановление снова. Ничего не менял."
  fi
  # Конфиги nginx и kit-sub из архива не берём, а собираем заново: из копии – только
  # проверенные значения (путь подписки, порты, режим).
  SINGLE=no; SUB_PATH=""; SUB_INTERNAL=""; SUB_PORT=""
  if [[ -f $tmp/etc/kit/kit.env ]]; then
    SINGLE=$(env_get "$tmp/etc/kit/kit.env" SINGLE); SINGLE=${SINGLE:-no}
    SUB_PATH=$(env_get "$tmp/etc/kit/kit.env" SUB_PATH)
    LINK_HOST=$(env_get "$tmp/etc/kit/kit.env" LINK_HOST)
    SUB_INTERNAL=$(env_get "$tmp/etc/kit/kit.env" SUB_INTERNAL)
    # kit потом подключает этот файл от root: адрес в нём должен быть тем же, что в копии.
    [[ $SINGLE =~ ^(yes|no)$ && $SUB_PATH =~ ^/[A-Za-z0-9_-]+/$ && $SUB_INTERNAL =~ ^[0-9]{1,5}$ \
       && $(env_get "$tmp/etc/kit/kit.env" HOST) == "$BACKUP_HOST" ]] \
      || die "В копии странные настройки kit (kit.env) – не восстанавливаю."
  fi
  if [[ -f $tmp/etc/kit-sub/config.json ]]; then
    SUB_PORT=$(jq -r '.port' "$tmp/etc/kit-sub/config.json" 2>/dev/null || true)
    [[ $SUB_PORT =~ ^[0-9]{1,5}$ && -n $SUB_PATH ]] || die "В копии странные настройки подписки – не восстанавливаю."
  fi
  say "Копия от ${BACKUP_DATE:-?} (kit ${BACKUP_KIT_VERSION:-?}), сервер ${B}$HOST${N}"

  # 3X-UI той же закреплённой версии, потом подменяем её базу на базу из копии:
  # подключения, ключи REALITY, пользователи и их подписки остаются прежними.
  install_xui "$(free_port)" "$(rand_str 18)" "$(rand_str 10)" "$(rand_str 20)"
  systemctl stop x-ui
  # Служебные файлы WAL от базы, созданной установщиком, к базе из копии не подходят: с ними она «битая».
  rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm
  install -m 600 "$tmp/etc/x-ui/x-ui.db" /etc/x-ui/x-ui.db
  install -m 600 "$tmp/etc/x-ui/install-result.env" "$XUI_ENV"
  local c
  for c in self custom; do
    [[ -d $tmp/root/cert/$c ]] || continue
    install -d -m 700 "/root/cert/$c"
    install -m 644 "$tmp/root/cert/$c/fullchain.pem" "/root/cert/$c/fullchain.pem"
    install -m 600 "$tmp/root/cert/$c/privkey.pem" "/root/cert/$c/privkey.pem"
  done
  install -d -m 700 /etc/kit
  install -d -m 755 /etc/kit-sub  # kit-sub (без root) читает rules.yaml
  [[ -f $tmp/etc/kit-sub/rules.yaml ]] && install -m 644 "$tmp/etc/kit-sub/rules.yaml" /etc/kit-sub/rules.yaml
  [[ -f $tmp/etc/kit/kit.env ]] && install -m 600 "$tmp/etc/kit/kit.env" /etc/kit/kit.env
  [[ -f $tmp/root/3x-ui.txt ]] && install -m 600 "$tmp/root/3x-ui.txt" "$RESULT"
  if [[ -n $old_ip ]]; then
    say "Меняю адрес сервера в подключениях: $old_ip → $HOST"
    local files=()
    for f in "$XUI_ENV" /etc/kit/kit.env "$RESULT"; do if [[ -f $f ]]; then files+=("$f"); fi; done
    replace_host "$old_ip" "$HOST" "${files[@]}"
    # Адрес в ссылках, взятый из копии, тоже был старым IP (со своим доменом он остаётся доменом).
    [[ ${LINK_HOST:-} == "$old_ip" ]] && LINK_HOST=$HOST
  fi
  local cf
  while IFS= read -r cf; do
    [[ -s $cf ]] || restore_self_cert "$cf"
  done < <(db_cert_files)
  systemctl start x-ui
  connect_panel
  set_xray_core

  # Сертификат: Let's Encrypt на новый IP выпустил установщик, свой и самоподписанный – из копии.
  setup_tls_cert
  TRUSTED=no
  [[ $PANEL_SSL == ip || $PANEL_SSL == custom ]] && TRUSTED=yes
  if [[ -n $SUB_PORT ]]; then
    install_kit_sub
    [[ $SINGLE == yes ]] || OPEN+=("$SUB_PORT/tcp")
  fi
  # Заглушка – из копии (её показывают nginx и Hysteria2). Всё на 443: nginx строит маршруты по подключениям из базы.
  install -d -m 755 /var/www/kit
  [[ -f $tmp/var/www/kit/index.html ]] && install -m 644 "$tmp/var/www/kit/index.html" /var/www/kit/index.html
  if [[ $SINGLE == yes ]]; then
    [[ -n $DOMAIN ]] && { issue_domain_cert || die "Не удалось получить сертификат для $DOMAIN: порт 80 должен быть свободен, а A-запись домена указывать на этот сервер. Лог: /var/log/kit-domain-cert.log"; }
    setup_nginx
  fi

  if [[ -f /etc/kit/kit.env ]]; then
    install_kit_file
    # Панель по домену: nginx собран заново, значит блок домена нужно вернуть (домен должен указывать на этот сервер).
    if grep -q '^PANEL_ON=domain' /etc/kit/kit.env; then
      sed -i 's/^PANEL_ON=.*/PANEL_ON=ip/' /etc/kit/kit.env
      /usr/local/bin/kit net panel domain >/dev/null 2>&1 || { /usr/local/bin/kit __xver 0 >/dev/null 2>&1 || true; warn "Панель по домену не включилась (домен должен указывать на этот сервер): kit net panel domain"; }
    fi
    brand_xui_menu
    /usr/local/bin/kit update --auto >/dev/null 2>&1 || later "Автообновление не включилось – включите позже: kit update --auto"
    /usr/local/bin/kit __limit-timer on >/dev/null 2>&1 || later "Проверка общего лимита трафика не включилась – включите позже: kit fix"
  fi

  # Порты – по подключениям из копии: что слушает не только localhost, то и открываем.
  if [[ $UFW == yes ]]; then
    local p
    while read -r p; do OPEN+=("$p"); done < <(api GET inbounds/list | jq -r '.[] | select(.listen != "127.0.0.1")
      | if (.protocol | test("^(hysteria|hysteria2|tuic|wireguard|amneziawg)$")) then "\(.port)/udp"
        elif .protocol == "shadowsocks" then "\(.port)/tcp", "\(.port)/udp" else "\(.port)/tcp" end')
    [[ $TRUSTED == yes && $SINGLE == no ]] && OPEN+=("$XUI_PANEL_PORT/tcp")
    [[ $PANEL_SSL == ip || -n $DOMAIN ]] && OPEN+=("80/tcp")
    setup_ufw
  fi

  local n_in n_cl
  n_in=$(api GET inbounds/list | jq length)
  n_cl=$(api GET inbounds/list | jq '[.[] | (.settings | if type == "string" then fromjson else . end).clients // [] | .[].email] | unique | length')
  local core_ok=yes
  xray_alive || core_ok=no
  kit_banner
  echo
  if [[ $core_ok == yes ]]; then
    echo "${G}${B}Готово! Сервер восстановлен из копии: $n_in подключений, $n_cl клиентских записей.${N}"
  else
    echo "${R}${B}Сервер восстановлен из копии ($n_in подключений, $n_cl клиентских записей), но ядро Xray не запустилось: подключения не работают.${N}"
    echo "Причина – в журнале: ${B}tail -n 30 /var/log/x-ui/3xui.log${N}, проверка: ${B}kit check${N}"
  fi
  echo "Логин и пароль панели прежние, адрес панели и подписки: ${B}cat $RESULT${N}"
  echo
  if [[ -n $old_ip ]]; then
    warn "IP сервера сменился: $old_ip → $HOST."
    echo "Старые подписки указывают на старый IP, поэтому клиентам нужно один раз добавить"
    echo "подписку заново: ${B}kit user list${N}, затем ${B}kit user link имя${N}."
    echo "${D}Чтобы в следующий раз переезд прошёл без хлопот для клиентов, ставьте сервер на домен (--cert, --key, --host).${N}"
  else
    echo "Клиентам ничего менять не нужно: ключи, ссылки и подписки те же."
  fi
  [[ $PANEL_SSL == custom ]] && echo "Направьте A-запись домена ${B}$HOST${N} на IP этого сервера, если ещё не сделали."
  if ((${#WARNINGS[@]})); then
    echo
    echo "${B}ВНИМАНИЕ${N}"
    local w
    for w in "${WARNINGS[@]}"; do echo "  ${Y}!${N} $w"; done
  fi
  [[ $core_ok == yes ]] || exit 1
  return 0
}

usage() {
  cat <<EOF
3X-UI со всеми протоколами одной командой

  --protocols all     all (по умолчанию – всё, кроме WireGuard), minimal (только REALITY)
                      или список через запятую: reality,reality2,hy2,xhttp,ws,trojan,vmess,ss,tuic,wg,awg,awg3,mtproto
                      (обычный WireGuard работает нестабильно – включайте его, только если сервер и
                      пользователи за границей)
  --port 443          порт REALITY (TCP) и Hysteria2 (UDP), по умолчанию 443
  --sni сайт          чужой сайт для маскировки (по умолчанию подбирается сам)
  --domain домен      свой домен для маскировки (надёжнее): его A-запись должна вести на этот
                      сервер, порт 80 свободен; сертификат Let's Encrypt установщик получит сам.
                      Без флагов установщик спросит, какую маскировку выбрать
  --panel-ssl ip|none сертификат панели: ip – Let's Encrypt на IP (нужен порт 80),
                      none – панель только через SSH-туннель (по умолчанию выбирается сам)
  --cert файл --key файл  свой сертификат (например, для домена) вместо Let's Encrypt на IP;
                      тогда --host – это домен из сертификата
  --user admin        имя первого клиента
  --host 1.2.3.4      адрес в ссылке, если IP определился неверно
  --restore файл      поднять сервер из резервной копии kit backup (на чистом VPS)
  --panel-on ip|domain панель и подписка по IP (по умолчанию) или по своему домену (нужен --domain)
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

main "$@"
