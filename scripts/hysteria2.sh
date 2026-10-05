#!/usr/bin/env bash
# Hysteria2 одной командой – https://github.com/itsnotkubrick/3X-UI_KIT
#
# Установка:   bash <(curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main/scripts/hysteria2.sh)
# Управление:  hy2 help
#
# Ставит официальный бинарник Hysteria2 (версия закреплена ниже, контрольная
# сумма проверяется), настраивает сертификат, сайт-заглушку, ufw и выдаёт
# ссылку hy2:// с QR-кодом.

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail

# На свежем VPS в фоне идут автообновления системы и держат замок dpkg: ждём его, а не падаем.
apt-get() { command apt-get -o DPkg::Lock::Timeout=900 "$@"; }

HY_VERSION="2.13.0"
HY_REPO="HyNetworks/hysteria"
# SHA256 бинарников этой версии, записанные в сам скрипт: проверка не зависит от файла
# hashes.txt, который лежит там же, где бинарник (2026-10-05, сверено со скачанными бинарниками и hashes.txt релиза app/v2.13.0).
declare -A HY_SHA256=(
  [amd64]=907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691
  [arm64]=a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7
)
KIT_VERSION="1.2"
KIT_REPO_RAW="https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT"
# Скрипт берём из тега релиза, а не из меняющейся ветки main.
SELF_URL="$KIT_REPO_RAW/v$KIT_VERSION/scripts/hysteria2.sh"

BIN=/usr/local/bin/hysteria
CLI=/usr/local/bin/hy2
CONF_DIR=/etc/hysteria
CONF=$CONF_DIR/config.yaml
STATE=$CONF_DIR/install.env      # настройки установки
USERS=$CONF_DIR/users            # строки «имя пароль»
MASQ_DIR=/var/www/masq
DATA_DIR=/var/lib/hysteria
UNIT=/etc/systemd/system/hysteria-server.service
SYSCTL=/etc/sysctl.d/99-hysteria.conf

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

trap 'die "Ошибка в строке $LINENO. Если это установка – исправьте причину и запустите скрипт ещё раз."' ERR

need_root() { [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."; }

# Прежнее имя файла настроек – переносим, чтобы старые установки не сломались.
if [[ -f $CONF_DIR/pinkman.env && ! -f $STATE && -w $CONF_DIR ]]; then
  mv "$CONF_DIR/pinkman.env" "$STATE"
fi

# ---------- проверки ----------

check_os() {
  [[ -r /etc/os-release ]] || die "Не удалось определить систему."
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
    *) warn "Проверено на Ubuntu 22.04/24.04 и Debian 12/13, у вас ${PRETTY_NAME:-неизвестно}. Продолжаю." ;;
  esac
  command -v systemctl >/dev/null || die "Нужен systemd."
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Архитектура $(uname -m) не поддерживается." ;;
  esac
}

port_busy() { # port proto(tcp|udp)
  ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .
}

public_ip() {
  local ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

rand() { openssl rand -hex "${1:-16}"; }

# ---------- установка ----------

install_packages() {
  say "Ставлю пакеты: curl, openssl, qrencode, ufw"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl openssl qrencode ca-certificates iproute2 ufw >/dev/null
}

install_binary() {
  local arch tmp url expected actual
  arch=$(detect_arch)
  url="https://github.com/$HY_REPO/releases/download/app/v$HY_VERSION"
  tmp=$(mktemp -d)
  say "Скачиваю Hysteria $HY_VERSION ($arch) с GitHub"
  curl -fsSL --retry 3 -o "$tmp/hysteria" "$url/hysteria-linux-$arch"
  expected=${HY_SHA256[$arch]:-}
  actual=$(sha256sum "$tmp/hysteria" | awk '{print $1}')
  [[ -n $expected && $expected == "$actual" ]] || { rm -rf "$tmp"; die "Контрольная сумма не совпала – файл повреждён или подменён."; }
  install -m 755 "$tmp/hysteria" "$BIN"
  rm -rf "$tmp"
  say "Контрольная сумма совпала: ${D}${actual:0:16}…${N}"
}

install_cli() {
  # Скрипт копирует сам себя, чтобы работала команда hy2.
  local src="${BASH_SOURCE[0]}"
  if [[ -f $src && $src != /dev/fd/* && $src != /proc/* ]]; then
    install -m 755 "$src" "$CLI"
  else
    curl -fsSL --retry 3 -o "$CLI" "$SELF_URL" && chmod 755 "$CLI"
  fi
}

write_masq() {
  mkdir -p "$MASQ_DIR"
  [[ -f $MASQ_DIR/index.html ]] && return
  cat >"$MASQ_DIR/index.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Please wait</title><style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.dots{display:flex;gap:15px;margin-bottom:30px}.d{width:20px;height:20px;background:#fff;border-radius:50%;animation:b 1.4s infinite ease-in-out both}.d:nth-child(1){animation-delay:-.32s}.d:nth-child(2){animation-delay:-.16s}@keyframes b{0%,80%,100%{transform:scale(0);opacity:.2}40%{transform:scale(1);opacity:1}}.t{color:#555;font-size:14px;letter-spacing:2px;font-weight:600}</style></head><body><div class="dots"><div class="d"></div><div class="d"></div><div class="d"></div></div><div class="t">RETRYING CONNECTION</div></body></html>
HTML
}

make_self_signed() {
  local sni=$1
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$CONF_DIR/server.key" -out "$CONF_DIR/server.crt" \
    -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" -days 3650 2>/dev/null
  chown hysteria:hysteria "$CONF_DIR/server.key" "$CONF_DIR/server.crt"
  chmod 600 "$CONF_DIR/server.key"
}

cert_pin() {
  openssl x509 -in "$CONF_DIR/server.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

render_config() {
  local u p
  . "$STATE"
  {
    echo "# Сгенерировано hy2 – правьте через команду hy2, ручные изменения перезапишутся."
    echo "listen: :$PORT"
    echo
    if [[ -n ${DOMAIN:-} ]]; then
      echo "acme:"
      echo "  type: http"
      echo "  domains:"
      echo "    - $DOMAIN"
      echo "  email: $EMAIL"
      echo "  dir: $DATA_DIR/acme"
    else
      echo "tls:"
      echo "  cert: $CONF_DIR/server.crt"
      echo "  key: $CONF_DIR/server.key"
    fi
    echo
    echo "auth:"
    echo "  type: userpass"
    echo "  userpass:"
    while read -r u p; do
      [[ -n $u ]] && echo "    \"$u\": \"$p\""
    done <"$USERS"
    echo
    echo "masquerade:"
    echo "  type: file"
    echo "  file:"
    echo "    dir: $MASQ_DIR"
    if [[ -n ${DOMAIN:-} ]]; then
      echo "  listenHTTP: :80"
      echo "  listenHTTPS: :$PORT"
      echo "  forceHTTPS: true"
    fi
  } >"$CONF.new"
  chown root:hysteria "$CONF.new"
  chmod 640 "$CONF.new"
  mv "$CONF.new" "$CONF"
}

write_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=Hysteria2 Server (3X-UI_KIT)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$BIN server --config $CONF
WorkingDirectory=$DATA_DIR
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

tune_sysctl() {
  # Буферы UDP побольше – рекомендация разработчиков Hysteria для скорости.
  printf 'net.core.rmem_max=16777216\nnet.core.wmem_max=16777216\n' >"$SYSCTL"
  sysctl -q -p "$SYSCTL" 2>/dev/null || warn "Не удалось применить sysctl (так бывает в контейнерах) – на работу не влияет."
}

# Порты SSH, на которых сервер слушает сейчас (sshd, ss и порт текущего подключения):
# ufw не должен запереть вас, в том числе на Ubuntu 24.04, где порт держит systemd.
ssh_ports() {
  { sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
    ss -H -ltnp 2>/dev/null | awk '/"sshd"/ {n = split($4, a, ":"); print a[n]}'
    awk '{print $4}' <<<"${SSH_CONNECTION:-}"
  } | grep -E '^[0-9]{1,5}$' | sort -un || true
}

setup_ufw() {
  . "$STATE"
  [[ ${UFW:-yes} == yes ]] || return 0
  local ssh_port p
  ssh_port=$(ssh_ports)
  ssh_port=${ssh_port:-22}
  say "Настраиваю ufw: SSH $(tr '\n' ' ' <<<"$ssh_port")/tcp, Hysteria $PORT/udp${DOMAIN:+, сайт 80/tcp и $PORT/tcp}"
  for p in $ssh_port; do ufw allow "$p/tcp" >/dev/null; done
  ufw allow "$PORT/udp" >/dev/null
  if [[ -n ${DOMAIN:-} ]]; then
    ufw allow 80/tcp >/dev/null
    ufw allow "$PORT/tcp" >/dev/null
  fi
  ufw --force enable >/dev/null || warn "ufw не включился (так бывает в контейнерах) – откройте порты у хостера вручную."
}

# Ждём строку «server up and running» в логе с момента запуска: с доменом
# Hysteria сначала получает сертификат, это занимает до минуты.
start_and_wait() {
  local since i log
  since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl restart hysteria-server
  for i in $(seq 1 90); do
    log=$(journalctl -u hysteria-server --since "$since" --no-pager -o cat 2>/dev/null || true)
    grep -q 'server up and running' <<<"$log" && return 0
    if grep -q 'FATAL' <<<"$log"; then
      systemctl stop hysteria-server || true
      echo >&2
      grep 'FATAL' <<<"$log" | tail -1 | cut -c1-400 >&2
      echo >&2
      if grep -qi 'acme\|certificate' <<<"$log"; then
        die "Не удалось получить сертификат. Проверьте, что A-запись домена указывает на этот сервер, а порт 80/tcp открыт у хостера. Потом: hy2 restart"
      fi
      die "Hysteria не запустилась – причина выше. После исправления: hy2 restart"
    fi
    sleep 1
  done
  die "Hysteria не ответила за 90 секунд. Лог: journalctl -u hysteria-server -n 50"
}

cmd_install() {
  need_root
  check_os
  [[ -f $STATE ]] && die "Hysteria уже установлена этим скриптом. Команды управления: hy2 help"

  local DOMAIN="" EMAIL="" PORT=443 USERNAME="admin" HOST="" UFW=yes SNI="" yes=no a args=()
  # --port=8443 понимаем так же, как --port 8443
  for a in "$@"; do
    if [[ $a == --*=* ]]; then args+=("${a%%=*}" "${a#*=}"); else args+=("$a"); fi
  done
  set -- ${args[@]+"${args[@]}"}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain | --email | --port | --user | --host | --sni)
        [[ -n ${2-} ]] || die "У параметра $1 нет значения (см. hy2 help)" ;;
    esac
    case $1 in
      --domain) DOMAIN=$2; shift 2 ;;
      --email) EMAIL=$2; shift 2 ;;
      --port) PORT=$2; shift 2 ;;
      --user) USERNAME=$2; shift 2 ;;
      --host) HOST=$2; shift 2 ;;
      --sni) SNI=$2; shift 2 ;;
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      *) die "Неизвестный параметр: $1 (см. hy2 help)" ;;
    esac
  done

  if [[ $yes == no && -t 0 && -z $DOMAIN ]]; then
    echo
    echo "${B}Установка Hysteria2${N}"
    echo "С доменом сертификат выпустит Let's Encrypt, а по адресу домена откроется сайт-заглушка."
    echo "Без домена будет самоподписанный сертификат – это тоже работает."
    read -rp "Домен (Enter – без домена): " DOMAIN
    if [[ -n $DOMAIN ]]; then read -rp "Почта для Let's Encrypt: " EMAIL; fi
  fi
  # Значения попадают в install.env и конфиг Hysteria – пропускаем только допустимые символы.
  # Регистр и точка в конце не важны: Vpn.Example.com. – это vpn.example.com
  local k
  for k in DOMAIN SNI HOST; do
    [[ -z ${!k} ]] || { local v=${!k//[[:space:]]/}; v=${v,,}; v=${v%.}; printf -v "$k" '%s' "$v"; }
    [[ ${!k} != *://* && ${!k} != */* ]] || die "Нужно только имя, без https:// и без «/»: например vpn.example.com"
    [[ ${!k} =~ ^[A-Za-z0-9.-]*$ ]] || die "Имя «${!k}» с не латинскими буквами не подойдёт: запишите его в виде punycode (xn--…)."
  done
  EMAIL=${EMAIL//[[:space:]]/}
  local re_host='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59})$'
  if [[ -n $DOMAIN ]]; then
    [[ $DOMAIN =~ $re_host ]] || die "Похоже, это не домен: $DOMAIN"
    [[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]] || die "Для Let's Encrypt нужна почта: --email you@example.com"
  fi
  [[ -z $SNI || $SNI =~ $re_host ]] || die "--sni: нужно имя сайта, например www.bing.com"
  [[ -z $HOST || $HOST =~ $re_host || $HOST =~ ^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$ ]] || die "--host: нужен IP (например 1.2.3.4) или домен"
  [[ $PORT =~ ^[0-9]{1,5}$ ]] && ((10#$PORT > 0 && 10#$PORT < 65536)) || die "Неверный порт: $PORT"
  PORT=$((10#$PORT))
  [[ $USERNAME =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя пользователя: латиница, цифры, _ . - (до 32 символов)."

  port_busy "$PORT" udp && die "UDP-порт $PORT уже занят. Выберите другой: --port 8443"
  if [[ -n $DOMAIN ]]; then
    port_busy 80 tcp && die "TCP-порт 80 занят – он нужен Let's Encrypt для проверки домена."
    port_busy "$PORT" tcp && die "TCP-порт $PORT занят – на нём будет сайт-заглушка."
  fi

  install_packages
  HOST=${HOST:-${DOMAIN:-$(public_ip)}}
  [[ -n $HOST ]] || die "Не удалось узнать внешний IP. Укажите его: --host 1.2.3.4"
  if [[ -n $DOMAIN ]]; then
    local resolved my_ip
    resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}') || true
    [[ -n $resolved ]] || die "Домен $DOMAIN не найден в DNS. Создайте A-запись на IP сервера и подождите пару минут."
    my_ip=$(public_ip)
    [[ $resolved == "$my_ip" ]] || warn "Домен $DOMAIN указывает на $resolved, а IP сервера $my_ip. Если сертификат не выпустится – проверьте A-запись."
  fi
  SNI=${SNI:-${DOMAIN:-www.bing.com}}

  id hysteria &>/dev/null || useradd --system --no-create-home --home-dir "$DATA_DIR" --shell /usr/sbin/nologin hysteria
  install -d -o hysteria -g hysteria -m 750 "$DATA_DIR"
  install -d -o root -g hysteria -m 750 "$CONF_DIR"

  install_binary
  write_masq
  [[ -z $DOMAIN ]] && make_self_signed "$SNI"

  # printf %q: файл потом читается через source, значения не должны превратиться в команды.
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'PORT=%q\n' "$PORT"
    printf 'HOST=%q\n' "$HOST"
    printf 'SNI=%q\n' "$SNI"
    printf 'UFW=%q\n' "$UFW"
  } >"$STATE"
  chmod 600 "$STATE"
  printf '%s %s\n' "$USERNAME" "$(rand 16)" >"$USERS"
  chmod 600 "$USERS"

  render_config
  write_unit
  tune_sysctl
  install_cli
  setup_ufw

  say "Запускаю Hysteria${DOMAIN:+ и получаю сертификат для $DOMAIN}"
  systemctl daemon-reload
  systemctl enable hysteria-server >/dev/null 2>&1
  start_and_wait

  echo
  echo "${G}${B}Готово! Hysteria2 работает.${N}"
  show_link "$USERNAME"
  echo
  echo "Добавить пользователя: ${B}hy2 add имя${N}   · все команды: ${B}hy2 help${N}"
}

# ---------- управление ----------

require_installed() { need_root; [[ -f $STATE ]] || die "Hysteria не установлена этим скриптом."; }

user_link() {
  . "$STATE"
  local u=$1 p q
  p=$(awk -v u="$u" '$1==u {print $2}' "$USERS")
  [[ -n $p ]] || die "Нет пользователя $u"
  q="sni=$SNI"
  if [[ -z ${DOMAIN:-} ]]; then q="$q&insecure=1&pinSHA256=$(cert_pin)"; fi
  echo "hy2://$u:$p@$HOST:$PORT/?$q#$u@$HOST"
}

show_link() {
  local link
  link=$(user_link "$1")
  echo
  echo "Ссылка для ${B}$1${N} – вставьте в Hiddify, v2rayN, Streisand или NekoBox:"
  echo
  echo "$link"
  echo
  if command -v qrencode >/dev/null; then qrencode -t ANSIUTF8 -m 1 "$link"; fi
}

reload_service() {
  render_config
  start_and_wait
}

cmd_restart() {
  require_installed
  systemctl reset-failed hysteria-server 2>/dev/null || true
  reload_service
  say "Hysteria перезапущена."
}

cmd_add() {
  require_installed
  local u=${1:-}
  [[ $u =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Использование: hy2 add имя (латиница, цифры, _ . -)"
  awk -v u="$u" '$1==u {f=1} END {exit !f}' "$USERS" && die "Пользователь $u уже есть. Ссылка: hy2 link $u"
  printf '%s %s\n' "$u" "$(rand 16)" >>"$USERS"
  reload_service
  say "Пользователь $u добавлен."
  show_link "$u"
}

cmd_del() {
  require_installed
  local u=${1:-}
  [[ -n $u ]] || die "Использование: hy2 del имя"
  awk -v u="$u" '$1==u {f=1} END {exit !f}' "$USERS" || die "Нет пользователя $u"
  [[ $(grep -c . "$USERS") -gt 1 ]] || die "Это последний пользователь – сначала добавьте другого."
  awk -v u="$u" '$1!=u' "$USERS" >"$USERS.new" && mv "$USERS.new" "$USERS" && chmod 600 "$USERS"
  reload_service
  say "Пользователь $u удалён, его ссылка больше не работает."
}

cmd_list() {
  require_installed
  echo "Пользователи:"
  awk '{print "  • " $1}' "$USERS"
}

cmd_link() {
  require_installed
  local u=${1:-$(awk 'NR==1{print $1}' "$USERS")}
  show_link "$u"
}

cmd_status() {
  require_installed
  . "$STATE"
  echo "Версия:  $("$BIN" version 2>/dev/null | awk '/^Version:/ {print $2}')"
  echo "Адрес:   $HOST:$PORT/udp"
  if [[ -n ${DOMAIN:-} ]]; then echo "Сертификат: Let's Encrypt для $DOMAIN"; else echo "Сертификат: самоподписанный ($SNI)"; fi
  echo "Пользователей: $(grep -c . "$USERS")"
  systemctl --no-pager --lines=5 status hysteria-server || true
}

# Открытый ключ, которым автор подписывает релизы (тот же, что в kit). Обновление ставится,
# только если SHA256SUMS релиза подписан этим ключом и скрипт совпал с подписанным хешем.
KIT_SIGNERS=(
  # SHA256:VDuGgJ8dOeCNXB4nBZf3+kRlWthw3+vh8rfMxzMSRIM (itsnotkubrick, 2026-09-30)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrTGCDhhnm8XO1ekpPJuSWRVCJiFiupEspfQxcbEBmz 3X-UI KIT releases"
)
KIT_SIG_NS="3x-ui-kit-release"
KIT_SIG_ID="releases@3x-ui-kit"

cmd_update() {
  require_installed
  local tmp latest raw sum k
  latest=$(curl -fsS -m 8 "$KIT_REPO_RAW/main/VERSION" | tr -d '[:space:]') || true
  [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Не удалось узнать последнюю версию: GitHub недоступен с сервера."
  [[ $latest != "$KIT_VERSION" && $(printf '%s\n%s\n' "$latest" "$KIT_VERSION" | sort -V | tail -1) == "$KIT_VERSION" ]] \
    && die "На GitHub версия $latest старше вашей $KIT_VERSION – ничего не делаю."
  ((${#KIT_SIGNERS[@]})) || die "В этой сборке нет ключа подписи – проверить обновление нечем."
  command -v ssh-keygen >/dev/null || apt-get install -y -qq openssh-client >/dev/null
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  raw="$KIT_REPO_RAW/v$latest"
  say "Скачиваю и проверяю подпись версии $latest"
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$raw/SHA256SUMS" && curl -fsSL --retry 3 -o "$tmp/SHA256SUMS.sig" "$raw/SHA256SUMS.sig" \
    || die "Не удалось скачать подпись релиза – ничего не менял."
  for k in "${KIT_SIGNERS[@]}"; do printf '%s namespaces="%s" %s\n' "$KIT_SIG_ID" "$KIT_SIG_NS" "$k" >>"$tmp/allowed_signers"; done
  ssh-keygen -Y verify -f "$tmp/allowed_signers" -I "$KIT_SIG_ID" -n "$KIT_SIG_NS" -s "$tmp/SHA256SUMS.sig" <"$tmp/SHA256SUMS" >/dev/null 2>&1 \
    || die "Подпись релиза $latest не сошлась с ключом автора – это не наш релиз. Ничего не менял."
  grep -qx "# 3X-UI KIT $latest" "$tmp/SHA256SUMS" || die "Подписанный релиз не той версии – ничего не менял."
  sum=$(awk '$2 == "scripts/hysteria2.sh" {print $1}' "$tmp/SHA256SUMS")
  curl -fsSL --retry 3 -o "$tmp/hysteria2.sh" "$raw/scripts/hysteria2.sh" || die "Не удалось скачать скрипт – ничего не менял."
  [[ $sum =~ ^[0-9a-f]{64}$ && $(sha256sum "$tmp/hysteria2.sh" | awk '{print $1}') == "$sum" ]] \
    || die "Скрипт не совпал с подписанным SHA256 – ничего не менял."
  bash -n "$tmp/hysteria2.sh" || die "Скачанный скрипт повреждён – ничего не менял."
  bash "$tmp/hysteria2.sh" __update_binary
  install -m 755 "$tmp/hysteria2.sh" "$CLI"
}

cmd_update_binary() {
  require_installed
  local cur
  cur=$("$BIN" version 2>/dev/null | awk '/^Version:/ {print $2}')
  if [[ $cur == "v$HY_VERSION" ]]; then say "Уже стоит последняя проверенная версия $HY_VERSION."; return; fi
  install_binary
  reload_service
  say "Hysteria обновлена: $cur → v$HY_VERSION"
}

cmd_uninstall() {
  require_installed
  local ans=""
  if [[ ${1:-} != -y && -t 0 ]]; then
    read -rp "Удалить Hysteria и всех пользователей? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  . "$STATE"
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true
  rm -f "$UNIT" "$BIN" "$SYSCTL"
  systemctl daemon-reload
  if [[ ${UFW:-yes} == yes ]] && command -v ufw >/dev/null; then
    ufw delete allow "$PORT/udp" >/dev/null 2>&1 || true
    if [[ -n ${DOMAIN:-} ]]; then
      ufw delete allow 80/tcp >/dev/null 2>&1 || true
      ufw delete allow "$PORT/tcp" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$CONF_DIR" "$DATA_DIR" "$MASQ_DIR"
  userdel hysteria 2>/dev/null || true
  rm -f "$CLI"
  say "Hysteria удалена."
}

cmd_help() {
  cat <<EOF
${B}hy2${N} – управление Hysteria2

  hy2 add имя       добавить пользователя и показать его ссылку
  hy2 del имя       удалить пользователя
  hy2 list          список пользователей
  hy2 link [имя]    ссылка и QR-код
  hy2 status        версия, адрес, состояние сервиса
  hy2 restart       перезапустить (например, после исправления DNS)
  hy2 update        обновить скрипт и Hysteria до проверенной версии
  hy2 uninstall     удалить всё

Параметры установки (для запуска без вопросов):
  --domain example.com --email you@example.com   сертификат Let's Encrypt
  --port 443          UDP-порт (по умолчанию 443)
  --user admin        имя первого пользователя
  --sni www.bing.com  SNI для самоподписанного сертификата
  --host 1.2.3.4      адрес в ссылке, если IP определился неверно
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

main() {
  local cmd=${1:-}
  case $cmd in
    add|del|list|link|status|restart|update|uninstall|help) shift; "cmd_$cmd" "$@" ;;
    __update_binary) cmd_update_binary ;;
    install) shift; cmd_install "$@" ;;
    -h|--help) cmd_help ;;
    ""|-*)
      if [[ -f $STATE && $# -eq 0 ]]; then cmd_help; else cmd_install "$@"; fi ;;
    *) die "Неизвестная команда: $cmd (см. hy2 help)" ;;
  esac
}

main "$@"
