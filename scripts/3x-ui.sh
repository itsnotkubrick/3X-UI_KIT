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
# Каждый протокол проверен настоящими клиентами – см. tests/matrix.

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

XUI_VERSION="v3.8.5"
# SHA256 установщика 3X-UI этой версии: тег могут передвинуть, а хеш – нет (проверено 2026-09-30).
XUI_INSTALL_SHA256="4e3fe7fe00ef8e904ce6a0e9c36fd8a0c7179fe5e786f23e31801aee84c6347d"
KIT_VERSION="1.1.1"
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

ALL_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic wg awg awg3 mtproto)
# Обычный WireGuard легко распознаётся сетевым оборудованием и работает нестабильно
# (проверено 2026-09-27: рукопожатие доходит до сервера, ответ – нет). По умолчанию не ставим.
DEFAULT_PROTOS=(reality hy2 xhttp ws trojan vmess ss tuic awg awg3 mtproto)
declare -A PORTS=([xhttp]=8443 [ws]=2053 [trojan]=2083 [vmess]=2087 [ss]=8388 [tuic]=8444 [wg]=51820 [awg]=51821 [awg3]=51822 [mtproto]=8445)
PROTOS=(); CREATED=(); OPEN=()
# Режим «всё TCP на 443»: nginx разводит по SNI и путям, подключения слушают только localhost.
SINGLE=no
declare -A INNER=([reality]=10443 [xhttp]=10444 [mtproto]=10445 [web]=10446 [selfweb]=10447 [ws]=10451 [vmess]=10452 [trojan]=10453 [sub]=10460)
SNI2=""; SNI3=""
# Свой домен (self-steal): REALITY маскируется под сайт на этом же сервере, а не под чужой.
DOMAIN=""
DOMAIN_CERT_DIR=/root/cert/domain
SELF_IP_CERT=no   # yes – сертификат на IP самоподписанный (Let's Encrypt отказал, пользователь согласился)

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
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

# Вопрос пользователю: чужой сайт по умолчанию или свой домен. Без ответа – стандартный.
choose_masking() {
  echo
  echo "${B}Под какой сайт маскировать сервер?${N}"
  echo "Чтобы сервер не выделялся, он притворяется обычным сайтом. Имя этого сайта (SNI) видно"
  echo "всем по пути, поэтому от выбора зависит, насколько трудно вас заметить."
  echo
  echo "  ${B}1)${N} Стандартный сайт ${D}(рекомендуем, если не уверены)${N}"
  echo "     Сервер притворяется популярным сайтом (по умолчанию ${SNI_CANDIDATES[0]}). Ничего готовить"
  echo "     не нужно, работает сразу. Минус: IP вашего сервера не принадлежит этому сайту,"
  echo "     и при желании цензор может это заметить."
  echo
  echo "  ${B}2)${N} Свой домен ${D}(надёжнее)${N}"
  echo "     Сервер притворяется вашим собственным сайтом: на нём настоящая страница и сертификат"
  echo "     Let's Encrypt. Нужно заранее: свой домен, его A-запись на IP этого сервера и свободный"
  echo "     порт 80. Сертификат установщик получит сам."
  echo "     ${D}Честно: сертификат домена попадает в публичные журналы сертификатов, поэтому связь${N}"
  echo "     ${D}«домен – сервер» не скрыта. «Надёжнее» не значит «невидимо».${N}"
  echo
  local d="" prev=""
  ask_tty "Ваш выбор [1]: " || return 0
  [[ $REPLY == 2 ]] || { echo; return 0; }
  while :; do
    if [[ -n $prev ]]; then ask_tty "Ваш домен [$prev]: " || return 0
    else ask_tty "Ваш домен, например vpn.example.com (пусто – стандартный сайт): " || return 0; fi
    d=${REPLY,,}; d=${d// /}
    [[ -n $d ]] || d=$prev
    [[ -n $d ]] || return 0
    if [[ ! $d =~ $re_host ]]; then warn "Это не похоже на домен. Пример: vpn.example.com"; prev=""; continue; fi
    if domain_points_here "$d"; then DOMAIN=$d; return 0; fi
    prev=$d
    ask_tty "Enter – проверить ещё раз (DNS обновляется не сразу), s – стандартный сайт, q – выйти: " || return 0
    case ${REPLY,,} in
      s) return 0 ;;
      q) die "Остановился по вашей просьбе. Ставить можно снова в любой момент." ;;
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
  "$acme" --issue -d "$DOMAIN" --standalone --httpport 80 --server letsencrypt --keylength ec-256 >"$log" 2>&1 || rc=$?
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
    [[ ${REPLY,,} == n* ]] && return 1
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
  echo "${B}3X-UI KIT${N} на основе панели 3X-UI (MHSanaei/3x-ui), ядра Xray и mihomo"
  echo
  echo "  https://github.com/itsnotkubrick/3X-UI_KIT"
  echo "  ${D}it's not Kubrick. it's just a VPN.${N}"
  echo
  echo "Ниже – данные для входа в панель и подключения."
}

main() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
  command -v systemctl >/dev/null || die "Нужен systemd."
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

  local PORT=443 SNI="" PANEL_SSL=auto HOST="" UFW=yes NAME="admin" yes=no protos=all ucert="" ukey="" multi=no
  while [[ $# -gt 0 ]]; do
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
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  [[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) || die "Неверный порт: $PORT"
  local re_host='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ -z $SNI || $SNI =~ $re_host ]] || die "--sni: нужно имя сайта, например dl.google.com"
  [[ -z $DOMAIN || $DOMAIN =~ $re_host ]] || die "--domain: нужно имя вашего домена, например vpn.example.com"
  [[ -z $DOMAIN || -z $SNI ]] || die "--sni и --domain вместе не нужны: выберите либо чужой сайт (--sni), либо свой домен (--domain)."
  [[ -z $DOMAIN || $multi == no ]] || die "Свой домен работает только в режиме «всё на 443» – уберите --multi-port."
  [[ -z $HOST || $HOST =~ $re_host || $HOST =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "--host: нужен IP или домен"
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
  if port_busy "$PORT" tcp && ! { [[ -f $XUI_ENV ]] && ss -H -ltnp "sport = :$PORT" | grep -q -E 'xray|nginx'; }; then
    die "Порт $PORT/tcp уже занят. REALITY нужен свободный порт – укажите другой: --port 8443"
  fi

  if [[ $PANEL_SSL == auto ]]; then
    if port_busy 80 tcp; then
      PANEL_SSL=none
      warn "Порт 80 занят – сертификат для панели не получить. Панель будет доступна только через SSH-туннель."
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

  say "Ставлю пакеты: curl, jq, openssl, qrencode, ufw"
  export DEBIAN_FRONTEND=noninteractive
  wait_apt_idle
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron unzip >/dev/null

  HOST=${HOST:-$(public_ip)}
  [[ -n $HOST ]] || die "Не удалось узнать внешний IP. Укажите его: --host 1.2.3.4"

  # Маскировка: из флагов, по вопросу пользователю или стандартная.
  if [[ -n $DOMAIN ]]; then
    [[ $PANEL_SSL == ip ]] || die "Свой домен работает с сертификатом панели Let's Encrypt на IP: освободите порт 80 и не указывайте --cert, --key и --panel-ssl none (сертификат для домена установщик получит сам)."
    domain_points_here "$DOMAIN" || die "Исправьте A-запись домена и запустите скрипт снова (DNS обновляется от нескольких минут до нескольких часов)."
  elif [[ -z $SNI && $yes == no && $PANEL_SSL == ip && $multi == no && ! -f $XUI_ENV && -t 1 ]] && { : </dev/tty; } 2>/dev/null; then
    choose_masking
  fi
  if [[ -n $DOMAIN ]]; then
    SNI=$DOMAIN
  elif [[ -z $SNI ]]; then
    say "Выбираю сайт для маскировки REALITY"
    for s in "${SNI_CANDIDATES[@]}"; do
      if sni_ok "$s"; then SNI=$s; break; fi
    done
    [[ -n $SNI ]] || die "Ни один сайт из списка не ответил по TLS 1.3 + HTTP/2. Укажите свой: --sni example.com"
  elif ! sni_ok "$SNI"; then
    die "$SNI не отвечает по TLS 1.3 + HTTP/2 – REALITY с ним работать не будет. Выберите другой сайт."
  fi
  say "Маскировка: ${B}$SNI${N}${DOMAIN:+ (свой домен)}"
  # Для режима «всё на 443» XHTTP и MTProto нужны свои сайты: nginx различает их по SNI.
  for s in "${SNI_CANDIDATES[@]}"; do
    [[ $s == "$SNI" ]] && continue
    if [[ -z $SNI2 ]] && sni_ok "$s"; then SNI2=$s; continue; fi
    [[ -z $SNI3 && -n $SNI2 ]] && { SNI3=$s; break; }
  done
  SNI2=${SNI2:-$SNI}; SNI3=${SNI3:-www.cloudflare.com}

  # --- официальный установщик 3X-UI с закреплённой версией ---
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
      warn "Let's Encrypt не выдал сертификат на IP $HOST (порт 80 закрыт у хостера, лимит выпусков или сбой). Ставлю без него: панель будет доступна только через SSH-туннель."
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
  set_xray_core

  # --- сертификат для протоколов с TLS ---
  setup_tls_cert

  # --- подключения: все выбранные протоколы, один subId на пользователя ---
  EXISTING=$(api GET inbounds/list)
  SUBID=""
  # «Всё на 443» – для новых установок с доверенным сертификатом. Старую многопортовую
  # установку не переделываем: перенос работающих подключений – осознанное решение.
  if [[ $TRUSTED == yes && $multi == no ]]; then
    if jq -e 'any(.[]; .remark == "REALITY" and (.listen // "") != "127.0.0.1")' <<<"$EXISTING" >/dev/null; then
      warn "Установка уже работает в режиме с отдельными портами – оставляю его."
    else
      SINGLE=yes
    fi
  fi
  if [[ -n $DOMAIN ]]; then
    [[ $SINGLE == yes ]] || die "Свой домен работает только в режиме «всё на 443», а эта установка уже работает с отдельными портами."
    issue_domain_cert || die "Без сертификата для $DOMAIN продолжать нельзя. Исправьте причину и запустите скрипт снова."
    OPEN+=("80/tcp")
  fi
  local p
  for p in "${PROTOS[@]}"; do "proto_$p"; done
  # Первый пользователь – сразу на всех протоколах (как «kit user add»).
  ensure_user

  # --- подписка: ссылки, Clash/Mihomo и JSON с автоопределением клиента ---
  setup_subscription
  [[ $SINGLE == yes ]] && setup_nginx
  install_kit_cli
  brand_xui_menu
  # Автообновление kit и kit-sub: только подписанные релизы, выключается kit update --manual.
  /usr/local/bin/kit update --auto >/dev/null 2>&1 || warn "Автообновление не включилось – включите позже: kit update --auto"

  # --- файрвол ---
  if [[ $UFW == yes ]]; then
    [[ $TRUSTED == yes && $SINGLE == no ]] && OPEN+=("$XUI_PANEL_PORT/tcp" "$SUB_PORT/tcp")
    [[ $PANEL_SSL == ip ]] && OPEN+=("80/tcp")
    setup_ufw
  fi

  # --- итог ---
  local panel_url links
  if [[ $SINGLE == yes ]]; then
    panel_url="https://$HOST/${XUI_WEB_BASE_PATH#/}"
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

  kit_banner
  echo
  echo "${G}${B}Готово! 3X-UI работает: ${#CREATED[@]} протоколов.${N}"
  echo "${D}${CREATED[*]}${N}"
  [[ -n $DOMAIN ]] && echo "Маскировка: свой домен ${B}$DOMAIN${N}, сертификат Let's Encrypt продлевается сам."
  [[ $SELF_IP_CERT == yes ]] && echo "${Y}Сертификат на IP самоподписанный:${N} используйте ссылки на отдельные подключения из /root/3x-ui.txt, подписка в приложениях может не открыться."
  echo
  echo "Панель:  ${B}$panel_url${N}"
  echo "Логин:   ${B}$XUI_USERNAME${N}"
  echo "Пароль:  ${B}$XUI_PASSWORD${N}"
  echo
  if [[ $TRUSTED == yes ]]; then
    echo "Подписка для ${B}$NAME${N} – все протоколы одной ссылкой. Вставьте её в Hiddify, v2rayN, Happ,"
    echo "Clash Verge или FlClash: приложение само получит подходящий формат."
    echo
    echo "$SUB_URL"
    echo
    qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
    if [[ -n $AWG_LINKS ]]; then
      echo
      echo "AmneziaWG приходит по подписке в Clash Verge и FlClash; для AmneziaVPN – ссылки vpn:// в $RESULT."
    fi
  else
    echo "Без сертификата подписка недоступна снаружи – вот ссылки по одной:"
    echo
    echo "$links"
  fi
  echo
  if [[ -n $PIN && " ${CREATED[*]} " == *" TUIC "* ]]; then
    warn "TUIC со своим сертификатом: в клиенте включите «Разрешить небезопасный» (allow insecure) – отпечаток TUIC-ссылки не передают."
  fi
  echo "Всё это сохранено в ${B}$RESULT${N}."
  echo
  echo "Дополнительные пользователи – одной командой, сразу во все протоколы, со своей подпиской:"
  echo "  ${B}kit user add sasha --gb 50 --days 30${N}"
  echo "  ${B}kit user list${N}     – кто сколько израсходовал и до какого числа"
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
  local scheme
  for scheme in https http; do
    API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
  done
  wait_panel
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
    api POST "server/installXray/$XRAY_CORE" '{}' >/dev/null
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
    [[ $cur_core == "$XRAY_CORE" ]] || warn "Не удалось сменить ядро Xray (сейчас $cur_core). Клиенты на Mihomo и sing-box могут не подключиться."
  fi
}

setup_ufw() {
  local ssh_port o
  ssh_port=$(ss -H -ltnp 2>/dev/null | awk '/sshd/ {sub(/.*:/,"",$4); print $4; exit}')
  OPEN+=("${ssh_port:-22}/tcp")
  say "Настраиваю ufw: ${OPEN[*]}"
  for o in "${OPEN[@]}"; do ufw allow "$o" >/dev/null; done
  ufw --force enable >/dev/null || warn "ufw не включился (так бывает в контейнерах) – откройте порты у хостера вручную."
}

# ---------- сертификат ----------

setup_tls_cert() {
  PIN=""
  if [[ $PANEL_SSL == custom ]]; then
    CERT=/root/cert/custom/fullchain.pem; KEY=/root/cert/custom/privkey.pem
  elif [[ $PANEL_SSL == ip && -s /root/cert/ip/fullchain.pem ]]; then
    CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
    # Самоподписанный сертификат на IP: отпечаток уходит в ссылки, чтобы клиенты доверяли именно ему.
    [[ $SELF_IP_CERT == yes ]] && PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
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
  return 0
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
    if port_busy "$port" "$n"; then warn "$remark пропущен: порт $port/$n занят"; return; fi
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
  jq -nc --arg f "$1" --arg h "$HOST" --arg sni "$sni" --argjson alpn "${2:-null}" '[{forceTls: $f, dest: $h, port: 443, remark: ""}
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
  stream=$(jq -nc --argjson t "$(tls_json '["h3"]')" '{network: "hysteria", hysteriaSettings: {version: 2}, security: "tls", tlsSettings: $t}')
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
  # MTProto бесполезен, если сам сервер не достаёт до Telegram (некоторые хостеры его блокируют).
  if ! telegram_reachable; then
    warn "MTProto пропущен: с этого сервера недоступны серверы Telegram – прокси для Telegram здесь работать не будет."
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
      '{client: {email: $e, subId: $s, totalGB: 0, expiryTime: 0, limitIp: 0, enable: true, comment: "kit"}, inboundIds: $ids}')" >/dev/null
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

# Сайт-заглушка: на случайный заход по 443 сервер показывает обычный сайт. Шаблон выбирается
# случайно из набора, чтобы тысячи серверов 3X-UI KIT не выглядели одинаково. Всё внутри
# скрипта, со сторонних сайтов ничего не скачивается.
stub_site() {
  local n year
  n=$(rnd 1 6); year=$(date +%Y)
  case $n in
    1) cat <<'HTML'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title><style>body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f7f9;color:#1f2328}main{text-align:center;padding:24px}h1{font-weight:600;font-size:28px}p{color:#57606a}</style></head><body><main><h1>Site is under construction</h1><p>Please check back soon.</p></main></body></html>
HTML
    ;;
    2) cat <<'HTML'
<!DOCTYPE html><html><head><title>Welcome to nginx!</title><style>html{color-scheme:light dark}body{width:35em;margin:0 auto;font-family:Tahoma,Verdana,Arial,sans-serif}</style></head><body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p><p>For online documentation and support please refer to <a href="http://nginx.org/">nginx.org</a>.<br/>Commercial support is available at <a href="http://nginx.com/">nginx.com</a>.</p><p><em>Thank you for using nginx.</em></p></body></html>
HTML
    ;;
    3) cat <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Lena Hart Photography</title><style>body{margin:0;font-family:Georgia,serif;background:#111;color:#eee}header{padding:48px 24px 16px;text-align:center}h1{font-weight:400;letter-spacing:.2em;text-transform:uppercase;font-size:22px}p{color:#aaa}.g{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:8px;padding:24px}.g div{aspect-ratio:4/3;background:linear-gradient(135deg,#2b2b2b,#444)}footer{text-align:center;color:#666;padding:24px;font-size:13px}</style></head><body><header><h1>Lena Hart</h1><p>Landscape &amp; travel photography</p></header><section class="g"><div></div><div></div><div></div><div></div><div></div><div></div></section><footer>&copy; $year Lena Hart. New portfolio coming soon.</footer></body></html>
HTML
    ;;
    4) cat <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Notes</title><style>body{max-width:640px;margin:0 auto;padding:40px 20px;font:16px/1.6 ui-monospace,Menlo,Consolas,monospace;color:#222;background:#fdfdf8}h1{font-size:20px}a{color:#0645ad}li{margin:6px 0}small{color:#888}</style></head><body><h1>~/notes</h1><p>Small notes about Linux, networks and home servers.</p><ul><li><a href="#">Setting up a home NAS with ZFS</a> <small>$year-03-14</small></li><li><a href="#">Notes on systemd timers</a> <small>$year-02-02</small></li><li><a href="#">Why I moved my blog to a static site</a> <small>$year-01-09</small></li></ul><p><small>Comments are closed.</small></p></body></html>
HTML
    ;;
    5) cat <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Green Bean Coffee</title><style>body{margin:0;font-family:Helvetica,Arial,sans-serif;background:#f4efe6;color:#3b2f24;text-align:center}main{padding:72px 20px}h1{font-size:40px;margin:0 0 8px}p{font-size:18px}.b{display:inline-block;margin-top:16px;padding:10px 22px;border:2px solid #3b2f24;border-radius:24px}small{display:block;margin-top:48px;color:#8a7a68}</style></head><body><main><h1>Green Bean Coffee</h1><p>Specialty coffee &middot; fresh pastries &middot; open daily 8&ndash;18</p><span class="b">Online orders coming soon</span><small>&copy; $year Green Bean Coffee</small></main></body></html>
HTML
    ;;
    6) cat <<HTML
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Status</title><style>body{margin:0;font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#fff;color:#24292f}main{max-width:560px;margin:64px auto;padding:0 20px}h1{font-size:22px}.r{display:flex;justify-content:space-between;padding:12px 0;border-bottom:1px solid #eaeef2}.ok{color:#1a7f37}small{color:#8c959f}</style></head><body><main><h1>System status</h1><div class="r"><span>Website</span><span class="ok">Operational</span></div><div class="r"><span>API</span><span class="ok">Operational</span></div><div class="r"><span>Storage</span><span class="ok">Operational</span></div><p><small>Updated automatically &middot; $year</small></p></main></body></html>
HTML
    ;;
  esac
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
  [[ -f /var/www/kit/index.html ]] || stub_site >/var/www/kit/index.html

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
  nginx -t >/tmp/nginx-test.log 2>&1 || { cat /tmp/nginx-test.log >&2; die "nginx не принял конфиг – лог выше."; }
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
    jq -n --arg path "$SUB_PATH" --argjson port "${INNER[sub]}" --arg up "http://127.0.0.1:$SUB_INTERNAL" --arg host "$HOST" \
      '{listen: "127.0.0.1", port: $port, path: $path, upstream: $up, host: $host}' >/etc/kit-sub/config.json
  else
    jq -n --arg path "$SUB_PATH" --argjson port "$SUB_PORT" --arg up "http://127.0.0.1:$SUB_INTERNAL" \
      --arg cert "$CERT" --arg key "$KEY" --arg host "$HOST" \
      '{listen: "0.0.0.0", port: $port, path: $path, upstream: $up, cert: $cert, key: $key, host: $host}' >/etc/kit-sub/config.json
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
    raw=$(curl -fsSk -m 10 -A "v2rayN/7.0" -H "Host: $HOST:$SUB_PORT" "$scheme://127.0.0.1:$port$SUB_PATH$id" 2>/dev/null) && [[ -n $raw ]] && break
    raw=""; sleep 2
  done
  if grep -q '://' <<<"$raw"; then echo "$raw"; else base64 -d <<<"$raw" 2>/dev/null || true; fi
}

usage() {
  cat <<EOF
3X-UI со всеми протоколами одной командой

  --protocols all     all (по умолчанию – всё, кроме WireGuard), minimal (только REALITY)
                      или список через запятую: reality,hy2,xhttp,ws,trojan,vmess,ss,tuic,wg,awg,awg3,mtproto
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
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

main "$@"
