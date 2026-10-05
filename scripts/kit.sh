#!/usr/bin/env bash
# kit – управление сервером 3X-UI KIT: пользователи, обновление, резервная копия.
# https://github.com/itsnotkubrick/3X-UI_KIT
#
#   kit user add имя [--gb 50] [--days 30] [--devices 3]
#   kit user list | link имя | limit имя [--gb N] [--days N] | off имя | on имя | del имя
#   kit update [--auto | --manual] | kit backup | kit check | kit fix | kit version

# Запуск через sh (dash) ломается на непонятной ошибке синтаксиса – подскажем сразу.
[ -n "${BASH_VERSION:-}" ] || { echo "Запустите через bash, а не через sh." >&2; exit 1; }

set -Eeuo pipefail
export LC_ALL=C.UTF-8  # ширина колонок по символам, а не байтам

KIT_VERSION="1.2"
KIT_RAW="https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main"
# Файлы новой версии берём из её тега, а не из меняющейся ветки main.
kit_ref_raw() { echo "https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/v$1"; }

XUI_ENV=/etc/x-ui/install-result.env
KIT_ENV=/etc/kit/kit.env
KIT_LATEST=/etc/kit/latest-version

# Проверенные версии: kit panel update ставит именно их, kit check предупреждает о других.
# Суммы архива панели и x-ui.sh сверяет tools/release.sh с официальными (перед каждым выпуском).
XUI_PIN="v3.9.0"
XRAY_PIN="v26.6.27"
declare -A XUI_TARBALL_SHA256=(
  [amd64]=d7cbe0bf6358ee0d2117c24fd2efb483502e411d38e2ea59bd0bf5e7a3e39390
  [arm64]=9a2e43c976a2e71618a30d8f38b52476b25ed363c6989599e2f625cc52f51a81
)
XUI_SH_SHA256=d28959cb5da86c8ddaf2199e5c32dd1ea5dc0a87fcc53f900dd39b133070898a

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
[[ -f $XUI_ENV && -f $KIT_ENV ]] || die "Не найдена установка – сначала поставьте сервер скриптом 3x-ui.sh."
# shellcheck disable=SC1090
. "$XUI_ENV"; . "$KIT_ENV"

API=""
for scheme in https http; do
  API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
  curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
done

api() { # METHOD path [json]
  local out
  if [[ $1 == GET ]]; then
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" "$API/$2")
  else
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $XUI_API_TOKEN" -H 'Content-Type: application/json' -X "$1" -d "${3:-{\}}" "$API/$2")
  fi
  [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] || die "Панель ответила ошибкой: $(jq -r '.msg // .' <<<"$out" 2>/dev/null | head -c 300)"
  jq -c '.obj' <<<"$out"
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

clients() { api GET clients/list | jq -c 'if type == "array" then . else .clients end'; }
client() { clients | jq -c --arg e "$1" 'map(select(.email == $e))[0] // empty'; }
# Все записи пользователя: основная и «двойники» для AmneziaWG («имя-awgN»).
emails_of() { clients | jq -r --arg e "$1" '.[] | select(.email == $e or ((.email | startswith($e + "-awg")) and (.email[($e | length) + 4:] | test("^[0-9]*$")))) | .email'; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."; }
rand_id() { openssl rand -base64 48 | tr -dc 'a-z0-9' | head -c 16; }

# Числа из командной строки: «08» не должно читаться как восьмеричное, а 30 цифр – переполнять счёт.
gb_bytes() { [[ ${1-} =~ ^[0-9]{1,6}$ ]] || die "--gb: целое число гигабайт (до 999999), например --gb 50"; echo $((10#$1 * 1073741824)); }
days_ms() { [[ ${1-} =~ ^[0-9]{1,5}$ ]] || die "--days: целое число дней (до 99999), например --days 30"; ((10#$1 == 0)) && { echo 0; return; }; echo $((($(date +%s) + 10#$1 * 86400) * 1000)); }
# Флаги вида --gb=50 превращаем в «--gb 50»; у флага без значения – понятная ошибка.
eq_args() { # печатает аргументы по одному
  local a
  for a in "$@"; do if [[ $a == --*=* ]]; then printf '%s\n%s\n' "${a%%=*}" "${a#*=}"; else printf '%s\n' "$a"; fi; done
}
need_val() { [[ -n ${2-} ]] || die "У параметра $1 нет значения."; }

human() { # байты → «1.2 ГБ»
  awk -v b="$1" 'BEGIN { split("Б КБ МБ ГБ ТБ", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

sub_url() { echo "${SUB_BASE}$1"; }

# Отдельные ссылки на протоколы – прямо из подписки 3X-UI внутри сервера (мимо kit-sub, который
# прячет от VPN-приложений vpn:// и tg://). collect_links subId фильтр – печатает подходящие строки.
collect_links() {
  local sid=$1 filter=$2 raw out="" suffix scheme
  for suffix in "" -awg; do
    raw=""
    # Внутренняя подписка отвечает по http (всё на 443) или по https (свой порт с сертификатом).
    for scheme in http https; do
      raw=$(curl -fsSk -m 10 -A "v2rayN/7" -H "Host: ${LINK_HOST:-$HOST}" "$scheme://127.0.0.1:$SUB_INTERNAL$SUB_PATH$sid$suffix" 2>/dev/null) && [[ -n $raw ]] && break
      raw=""
    done
    grep -q '://' <<<"$raw" || raw=$(base64 -d <<<"$raw" 2>/dev/null || true)
    out+=$(grep -E "$filter" <<<"$raw" || true)$'\n'
  done
  [[ ${SINGLE:-no} == yes ]] && out=$(sed "s/^\(tg:\/\/proxy?\)\(.*\)port=${MTPROTO_INNER:-10445}/\1\2port=443/" <<<"$out")
  grep . <<<"$out" || true
}

direct_links() { # subId фильтр
  local out
  out=$(collect_links "$1" "$2")
  echo
  if [[ -n $out ]]; then echo "$out"; else echo "Отдельных ссылок нет."; fi
}

# Панель «через SSH-туннель»: подписка слушает только 127.0.0.1, с телефона по ней не зайти.
local_only_sub() { [[ ${SUB_BASE:-} == http://127.0.0.1* || ${SUB_BASE:-} == http://localhost* ]]; }

show_link() { # имя subId
  local url
  url=$(sub_url "$2")
  echo
  if local_only_sub; then
    echo "В режиме «панель через SSH-туннель» подписка открывается только на самом сервере,"
    echo "поэтому подключайтесь ссылками на протоколы ниже."
    echo
    links_block "$1" "$2"
    return 0
  fi
  echo "Подписка ${B}$1${N} – все протоколы одной ссылкой. Вставьте в Happ, Hiddify, Karing,"
  echo "v2rayN, Clash Verge или FlClash:"
  echo
  echo "$url"
  echo
  command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$url"
  echo "${D}Отдельные ссылки на каждый протокол: kit user link $1 --all${N}"
}

cmd_add() {
  local name=${1:-} gb=0 days=0 devices=0
  valid_name "$name"; shift
  mapfile -t _args < <(eq_args "$@"); set -- ${_args[@]+"${_args[@]}"}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) need_val "$@"; gb=$2; shift 2 ;;
      --days) need_val "$@"; days=$2; shift 2 ;;
      --devices) need_val "$@"; devices=$2; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [[ $devices =~ ^[0-9]{1,4}$ ]] || die "--devices: целое число"
  devices=$((10#$devices))
  [[ -z $(client "$name") ]] || die "Пользователь $name уже есть. Ссылка: kit user link $name"
  local ids sid body
  ids=$(non_awg_ids)
  [[ $ids != "[]" ]] || die "На сервере нет подключений."
  gb_bytes "$gb" >/dev/null; days_ms "$days" >/dev/null
  gb=$((10#$gb)); days=$((10#$days))
  sid=$(rand_id)
  body=$(jq -nc --arg e "$name" --arg s "$sid" --argjson t "$(gb_bytes "$gb")" --argjson x "$(days_ms "$days")" \
    --argjson ip "$devices" --argjson ids "$ids" '{client: {email: $e, subId: $s, totalGB: $t, expiryTime: $x,
    limitIp: $ip, enable: true, flow: "xtls-rprx-vision", comment: "kit"}, inboundIds: $ids}')
  api POST clients/add "$body" >/dev/null
  awg_attach "$name" "$sid" "$(gb_bytes "$gb")" "$(days_ms "$days")" "$devices"
  say "Пользователь $name добавлен во все протоколы ($(api GET inbounds/list | jq length))$( ((gb)) && echo ", лимит $gb ГБ")$( ((days)) && echo ", на $days дн")."
  show_link "$name" "$sid"
}

cmd_link() {
  local name=${1:-} flag=${2:-} c sid out
  valid_name "$name"
  c=$(client "$name"); [[ -n $c ]] || die "Нет пользователя $name"
  sid=$(jq -r '.subId' <<<"$c")
  case $flag in
    --amnezia)
      out=$(collect_links "$sid" '^vpn://')
      [[ -n $out ]] || die "Ссылок AmneziaVPN нет: AmneziaWG на этом сервере не установлен."
      echo
      echo "AmneziaVPN: в приложении «Добавить подключение», вставьте ссылку целиком."
      echo "Первая – классический AmneziaWG, вторая (если есть) – версия 3.1."
      echo
      echo "$out" ;;
    --telegram)
      out=$(collect_links "$sid" '^tg://')
      [[ -n $out ]] || die "Ссылки для Telegram нет: MTProto на этом сервере не установлен."
      echo
      echo "Telegram: откройте ссылку на телефоне или наведите камеру на QR-код, Telegram предложит добавить прокси."
      echo
      echo "$out"
      echo
      command -v qrencode >/dev/null && qrencode -t ANSIUTF8 -m 1 "$(head -1 <<<"$out")"
      return 0 ;;
    "" | --all)
      show_link "$name" "$sid"
      # В режиме «только на сервере» показ уже содержит все ссылки.
      if [[ $flag == --all ]] && ! local_only_sub; then echo; links_block "$name" "$sid"; fi ;;
    *) die "kit user link имя [--all | --amnezia | --telegram]" ;;
  esac
}

cmd_list() {
  local now
  now=$(($(date +%s) * 1000))
  clients | jq -r --argjson now "$now" '
    map(select(.subId != null)) | group_by(.subId | sub("-awg[0-9]*$"; "")) | map(sort_by(.email | length) as $g | $g[0] + {used: ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add),
      seen: ([$g[] | .traffic.lastOnline // 0] | max)}) | sort_by(.email)[]
    | [.email, .used, (.totalGB // 0), (.expiryTime // 0), .enable, .seen] | @tsv' |
  {
    printf "${B}%-18s %-22s %-14s %-10s %s${N}\n" "Пользователь" "Трафик" "До" "Статус" "Был в сети"
    while IFS=$'\t' read -r email used total exp en last; do
      local tr till st seen
      tr="$(human "$used")"; ((total > 0)) && tr="$tr / $(human "$total")"
      if ((exp > 0)); then till=$(date -d "@$((exp / 1000))" +%d.%m.%Y); else till="бессрочно"; fi
      if [[ $en != true ]]; then st="${R}выключен${N}"
      elif ((exp > 0 && exp < $(date +%s) * 1000)); then st="${Y}истёк${N}"
      elif ((total > 0 && used >= total)); then st="${Y}лимит${N}"
      else st="${G}активен${N}"; fi
      if ((last > 0)); then seen=$(date -d "@$((last / 1000))" '+%d.%m %H:%M'); else seen="–"; fi
      printf "%-18s %-22s %-14s %-19s %s\n" "$email" "$tr" "$till" "$st" "$seen"
    done
  }
}

# Меняет все записи пользователя (основную и «двойников» AmneziaWG), каждую – от её собственных данных.
update_user() { # имя jq-фильтр [аргументы jq...]
  local name=$1 filter=$2 e rec body
  shift 2
  for e in $(emails_of "$name"); do
    rec=$(client "$e")
    body=$(jq -c "$@" "{email, subId, totalGB, expiryTime, limitIp, enable, comment} | $filter" <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
  done
}

cmd_limit() {
  local name=${1:-} f="." gb="" days="" dev=""
  valid_name "$name"; shift
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  mapfile -t _args < <(eq_args "$@"); set -- ${_args[@]+"${_args[@]}"}
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gb) need_val "$@"; gb=$(gb_bytes "$2"); f+=" | .totalGB = \$gb"; shift 2 ;;
      --days) need_val "$@"; days=$(days_ms "$2"); f+=" | .expiryTime = \$days"; shift 2 ;;
      --devices) need_val "$@"; [[ $2 =~ ^[0-9]{1,4}$ ]] || die "--devices: целое число"; dev=$((10#$2)); f+=" | .limitIp = \$dev"; shift 2 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  update_user "$name" "$f" --argjson gb "${gb:-0}" --argjson days "${days:-0}" --argjson dev "${dev:-0}"
  cmd_enforce --quiet
  say "Лимиты $name обновлены (0 – без ограничений)."
}

# Общий лимит трафика. У пользователя несколько записей в панели (основная и «двойник» AmneziaWG),
# и панель считает трафик каждой записи отдельно. Раз в 5 минут складываем трафик всех записей и,
# если сумма дошла до лимита основной записи, отключаем их все. Когда счётчики сброшены, лимит
# поднят или трафик ушёл ниже лимита, включаем обратно только те записи, которые отключили сами
# (в комментарии записи «kit:limit»), чтобы не перебить ваше ручное «kit user off».
cmd_enforce() {
  local dry=no quiet=no a list plan line e act used lim rec body
  for a in "$@"; do
    case $a in
      --dry-run) dry=yes ;;
      --quiet) quiet=yes ;;
      *) die "kit user enforce [--dry-run]" ;;
    esac
  done
  list=$(clients)
  plan=$(jq -c --argjson now "$(($(date +%s) * 1000))" '
    map(select((.subId // "") != ""))
    | group_by(.subId | sub("-awg[0-9]*$"; ""))
    | .[]
    | (sort_by(.email | length)) as $g
    | ($g[0].totalGB // 0) as $lim
    | ([$g[] | (.traffic.up // 0) + (.traffic.down // 0)] | add) as $used
    | $g[]
    | if $lim > 0 and $used >= $lim and .enable == true then {email, act: "off", used: $used, lim: $lim}
      elif ($lim == 0 or $used < $lim) and .enable == false and .comment == "kit:limit"
           and ((.expiryTime // 0) == 0 or .expiryTime > $now) then {email, act: "on", used: $used, lim: $lim}
      else empty end' <<<"$list")
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    e=$(jq -r '.email' <<<"$line"); act=$(jq -r '.act' <<<"$line")
    used=$(jq -r '.used' <<<"$line"); lim=$(jq -r '.lim' <<<"$line")
    if [[ $dry == yes ]]; then
      echo "$e: $([[ $act == off ]] && echo отключить || echo включить) (трафик $(human "$used") из $(human "$lim"))"
      continue
    fi
    rec=$(jq -c --arg e "$e" 'map(select(.email == $e))[0]' <<<"$list")
    if [[ $act == off ]]; then
      body=$(jq -c '{email, subId, totalGB, expiryTime, limitIp, enable, comment} | .enable = false | .comment = "kit:limit"' <<<"$rec")
    else
      body=$(jq -c '{email, subId, totalGB, expiryTime, limitIp, enable, comment} | .enable = true | .comment = "kit"' <<<"$rec")
    fi
    api POST "clients/update/$e" "$body" >/dev/null
    if [[ $quiet == no || $act == off ]]; then
      if [[ $act == off ]]; then echo "$e: отключён, общий лимит исчерпан ($(human "$used") из $(human "$lim"))"
      elif ((lim == 0)); then echo "$e: включён обратно, лимит снят"
      else echo "$e: включён обратно, трафик ниже лимита ($(human "$used") из $(human "$lim"))"; fi
    fi
  done <<<"$plan"
  return 0
}

# Проверка общего лимита раз в 5 минут (systemd-таймер).
limit_timer_on() {
  cat >/etc/systemd/system/kit-limit.service <<'UNIT'
[Unit]
Description=3X-UI KIT: общий лимит трафика пользователей (сумма по всем записям)
After=x-ui.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kit user enforce --quiet
TimeoutStartSec=120
UNIT
  cat >/etc/systemd/system/kit-limit.timer <<'UNIT'
[Unit]
Description=3X-UI KIT: проверка общего лимита трафика раз в 5 минут

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now kit-limit.timer >/dev/null 2>&1
}
limit_timer_enabled() { systemctl is-enabled -q kit-limit.timer 2>/dev/null; }

# xtls-rprx-vision для REALITY. Панель сама ставит flow только там, где он допустим (REALITY по TCP), на XHTTP, WS и др. его нет.
# Клиент без Vision не подключится к серверу, где у пользователя Vision включён, поэтому у существующих пользователей
# включаем только по команде: ссылки в подписке обновятся сами, а вручную сохранённые ссылки на REALITY придётся заменить.
cmd_vision() { # имя|--all [off]
  local target=${1:-} flow="xtls-rprx-vision" e rec body n=0
  [[ -n $target ]] || die "kit user vision имя|--all [off]"
  [[ ${2:-} == off ]] && flow=""
  if [[ $target == --all ]]; then
    mapfile -t _emails < <(clients | jq -r '.[] | select(.email | test("-awg[0-9]*$") | not) | .email')
  else
    valid_name "$target"; [[ -n $(client "$target") ]] || die "Нет пользователя $target"
    _emails=("$target")
  fi
  for e in "${_emails[@]}"; do
    rec=$(client "$e")
    body=$(jq -c --arg f "$flow" '{email, subId, totalGB, expiryTime, limitIp, enable, comment} + {flow: $f}' <<<"$rec")
    api POST "clients/update/$e" "$body" >/dev/null
    n=$((n + 1))
  done
  if [[ -n $flow ]]; then say "Vision включён у $n польз.: ссылка REALITY в подписке теперь с flow=xtls-rprx-vision (приложения подхватят при обновлении подписки)."
  else say "Vision выключен у $n польз."; fi
}

cmd_toggle() { # имя true|false
  valid_name "$1"
  [[ -n $(client "$1") ]] || die "Нет пользователя $1"
  update_user "$1" ".enable = \$v" --argjson v "$2"
  if [[ $2 == true ]]; then say "Пользователь $1 включён."; else say "Пользователь $1 выключен – подписка и подключения не работают."; fi
}

cmd_del() {
  local name=${1:-} ans=""
  valid_name "$name"
  [[ -n $(client "$name") ]] || die "Нет пользователя $name"
  if [[ ${2:-} != -y && -t 0 ]]; then
    read -rp "Удалить $name со всех протоколов? [y/N] " ans
    [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return; }
  fi
  local e
  for e in $(emails_of "$name"); do api POST "clients/del/$e" >/dev/null; done
  say "Пользователь $name удалён, его подписка больше не работает."
}

# ---------- версия и обновление ----------

# Открытый ключ, которым автор подписывает релизы (ssh-keygen -Y sign). Закрытая часть
# есть только у автора, поэтому подменить обновление, взломав один GitHub, не выйдет.
# Новый ключ приходит только в релизе, подписанном старым.
KIT_SIGNERS=(
  # SHA256:VDuGgJ8dOeCNXB4nBZf3+kRlWthw3+vh8rfMxzMSRIM (itsnotkubrick, 2026-09-30)
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGrTGCDhhnm8XO1ekpPJuSWRVCJiFiupEspfQxcbEBmz 3X-UI KIT releases"
)
KIT_SIG_NS="3x-ui-kit-release"
KIT_SIG_ID="releases@3x-ui-kit"
KIT_MANUAL=/etc/kit/manual-update
KIT_UPDATE_LOG=/var/log/kit-update.log

xray_version() {
  local b
  for b in /usr/local/x-ui/bin/xray-linux-*; do [[ -x $b ]] && "$b" version 2>/dev/null | awk 'NR==1 {print "v" $2}'; return; done
}
remote_version() { curl -fsS -m "${1:-5}" "$KIT_RAW/VERSION" 2>/dev/null | tr -d '[:space:]'; }
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1) == "$1" ]]; }  # $1 новее $2?
auto_enabled() { systemctl is-enabled -q kit-update.timer 2>/dev/null; }

# Раз в сутки узнаём последнюю версию (не дольше 3 секунд) и подсказываем обновиться.
update_hint() {
  local latest=""
  if [[ ! -f $KIT_LATEST ]] || (($(date +%s) - $(stat -c %Y "$KIT_LATEST") > 86400)); then
    latest=$(remote_version 3) || true
    [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] && echo "$latest" >"$KIT_LATEST" || touch "$KIT_LATEST"
  fi
  latest=$(cat "$KIT_LATEST" 2>/dev/null || true)
  if [[ -n $latest ]] && newer "$latest" "$KIT_VERSION"; then
    echo
    if auto_enabled; then
      echo "${Y}↑ Вышла версия $latest${N} (у вас $KIT_VERSION). Встанет сама этой ночью или сейчас: ${B}kit update${N}"
    else
      echo "${Y}↑ Доступна версия $latest${N} (у вас $KIT_VERSION). Обновить: ${B}kit update${N}"
    fi
  fi
}

cmd_version() {
  echo "3X-UI KIT $KIT_VERSION"
  echo "${D}панель 3X-UI $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || echo '?'), ядро Xray $(xray_version)${N}"
  if auto_enabled; then echo "${D}автообновление: включено (только подписанные релизы), журнал $KIT_UPDATE_LOG${N}"
  else echo "${D}автообновление: выключено, включить: kit update --auto${N}"; fi
  update_hint
}

# Что нового в версии $1 – из CHANGELOG.md, без разметки.
changelog_of() {
  curl -fsS -m 5 "$KIT_RAW/CHANGELOG.md" 2>/dev/null | awk -v v="## v$1" '
    index($0, v) == 1 { on = 1; t = substr($0, length(v) + 1); sub(/^[: ]+/, "", t); if (t != "") print t; next } on && /^## / { exit } on' | sed -E 's/ ?Спасибо .*$//; s/\[([^]]*)\]\([^)]*\)/\1/g; s/\*\*//g; s/`//g' | grep -v '^[[:space:]]*$' | head -40 || true
}

# Скачивает релиз $1 в каталог $2 и проверяет: подпись SHA256SUMS нашим ключом, версию
# внутри подписанного файла и SHA256 каждого файла. Любое несовпадение – отказ.
fetch_release() { # версия каталог
  local v=$1 d=$2 raw f sum k
  ((${#KIT_SIGNERS[@]})) || { warn "В этой сборке kit нет ключа подписи – проверить обновление нечем."; return 1; }
  command -v ssh-keygen >/dev/null || { warn "Нет ssh-keygen (пакет openssh-client) – подпись не проверить."; return 1; }
  raw=$(kit_ref_raw "$v")
  curl -fsSL --retry 3 -o "$d/SHA256SUMS" "$raw/SHA256SUMS" && curl -fsSL --retry 3 -o "$d/SHA256SUMS.sig" "$raw/SHA256SUMS.sig" \
    || { warn "Не удалось скачать подпись релиза $v."; return 1; }
  : >"$d/allowed_signers"
  for k in "${KIT_SIGNERS[@]}"; do printf '%s namespaces="%s" %s\n' "$KIT_SIG_ID" "$KIT_SIG_NS" "$k" >>"$d/allowed_signers"; done
  if ! ssh-keygen -Y verify -f "$d/allowed_signers" -I "$KIT_SIG_ID" -n "$KIT_SIG_NS" -s "$d/SHA256SUMS.sig" <"$d/SHA256SUMS" >/dev/null 2>&1; then
    warn "Подпись релиза $v не сошлась с ключом автора – это не наш релиз. Ничего не ставлю."
    return 1
  fi
  # Версия записана внутри подписанного файла: старый подписанный релиз под видом нового не пройдёт.
  grep -qx "# 3X-UI KIT $v" "$d/SHA256SUMS" || { warn "Подписанный релиз не той версии – ничего не ставлю."; return 1; }
  for f in scripts/kit.sh scripts/kit-sub.py; do
    sum=$(awk -v f="$f" '$2 == f {print $1}' "$d/SHA256SUMS")
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { warn "В подписанном списке нет $f."; return 1; }
    curl -fsSL --retry 3 -o "$d/${f##*/}" "$raw/$f" || { warn "Не удалось скачать $f."; return 1; }
    [[ $(sha256sum "$d/${f##*/}" | awk '{print $1}') == "$sum" ]] || { warn "$f не совпал с подписанным SHA256 – ничего не ставлю."; return 1; }
  done
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

# Подписка отвечает? Берём настоящего пользователя и спрашиваем kit-sub изнутри сервера.
sub_ok() {
  local cfg=/etc/kit-sub/config.json port path scheme=http sid i
  port=$(jq -r '.port' "$cfg"); path=$(jq -r '.path' "$cfg")
  [[ -n $(jq -r '.cert // empty' "$cfg") ]] && scheme=https
  sid=$(clients 2>/dev/null | jq -r '[.[] | .subId // empty | select(. != "")][0] // empty' 2>/dev/null || true)
  for i in $(seq 1 10); do
    if [[ -n $sid ]]; then
      curl -fsSk -m 5 -o /dev/null -A "Happ/1.0" "$scheme://127.0.0.1:$port$path$sid" 2>/dev/null && return 0
    else
      # Пользователей нет – достаточно, что служба жива и слушает порт.
      systemctl is-active -q kit-sub && ss -Hltn "sport = :$port" | grep -q . && return 0
    fi
    sleep 1
  done
  return 1
}

# Сервер ещё не получил исправления 1.1 (например, kit обновили вручную из 1.0)?
needs_migration() {
  [[ -f /etc/cron.d/kit-xui-menu ]] && return 0
  [[ -f /etc/systemd/system/kit-sub.service ]] && ! grep -q '^DynamicUser=yes' /etc/systemd/system/kit-sub.service && return 0
  [[ ! -f $KIT_MANUAL ]] && ! auto_enabled && return 0
  limit_timer_enabled || return 0
  return 1
}

# Автообновление: раз в сутки ночью со случайной задержкой, чтобы тысячи серверов не шли
# на GitHub в одну минуту. Ставит только подписанные релизы и только kit и kit-sub.
auto_on() {
  cat >/etc/systemd/system/kit-update.service <<UNIT
[Unit]
Description=3X-UI KIT: автообновление kit и kit-sub (только подписанные релизы)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kit update --unattended
StandardOutput=append:$KIT_UPDATE_LOG
StandardError=append:$KIT_UPDATE_LOG
UNIT
  cat >/etc/systemd/system/kit-update.timer <<'UNIT'
[Unit]
Description=3X-UI KIT: проверка обновлений раз в сутки

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  rm -f "$KIT_MANUAL"
  systemctl daemon-reload
  systemctl enable --now kit-update.timer >/dev/null 2>&1
}

auto_off() {
  systemctl disable --now kit-update.timer >/dev/null 2>&1 || true
  install -d -m 700 /etc/kit
  touch "$KIT_MANUAL"
}

cmd_update() {
  local force="" unattended=no latest tmp panel=no
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=yes ;;
      --panel) panel=yes ;;
      --auto) auto_on; say "Автообновление включено: раз в сутки ночью, только подписанные релизы. Журнал: $KIT_UPDATE_LOG"; return ;;
      --manual) auto_off; say "Автообновление выключено. Обновляться вручную: kit update, включить снова: kit update --auto"; return ;;
      --unattended) unattended=yes ;;
      *) die "Неизвестный параметр: $1 (kit update [--panel | --force | --auto | --manual])" ;;
    esac
    shift
  done
  [[ $panel == no ]] || { panel_update ${force:+--force}; return; }
  # Ночной запуск и ручной не должны встретиться.
  exec 9>/run/kit-update.lock
  flock -n 9 || die "Обновление уже идёт."
  [[ $unattended == yes ]] && echo "--- $(date '+%F %T') kit $KIT_VERSION: проверяю обновления"

  latest=$(remote_version) || true
  [[ $latest =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Не удалось узнать последнюю версию: GitHub недоступен с сервера. Попробуйте позже."
  echo "$latest" >"$KIT_LATEST"
  # Откатить на старую версию нельзя даже с подписью: только вперёд или та же.
  newer "$KIT_VERSION" "$latest" && die "На GitHub версия $latest старше вашей $KIT_VERSION – ничего не делаю."
  if ! newer "$latest" "$KIT_VERSION" && [[ $force != yes ]] && ! needs_migration; then
    say "У вас последняя версия: $KIT_VERSION."
    [[ $unattended == yes ]] || echo "${D}Переустановить файлы kit той же версии: kit update --force${N}"
    return
  fi
  if [[ $latest == "$KIT_VERSION" ]]; then say "Применяю исправления версии $latest"; else say "3X-UI KIT $KIT_VERSION → $latest"; fi
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  fetch_release "$latest" "$tmp" || die "Сервер не тронут."
  bash -n "$tmp/kit.sh" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$tmp/kit-sub.py" \
    || die "Файлы релиза не прошли проверку синтаксиса – сервер не тронут."

  # Подписка kit-sub: ставим новую, проверяем, что отвечает, иначе возвращаем старую.
  if [[ -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    cp /usr/local/lib/kit-sub/kit_sub.py "$tmp/kit_sub.old"
    cp /etc/systemd/system/kit-sub.service "$tmp/kit-sub.service.old"
    install -m 644 "$tmp/kit-sub.py" /usr/local/lib/kit-sub/kit_sub.py
    # С 1.1 kit-sub работает без root: переписываем юнит под DynamicUser и LoadCredential.
    local c k
    c=$(jq -r '.cert // empty' /etc/kit-sub/config.json); k=$(jq -r '.key // empty' /etc/kit-sub/config.json)
    local sysv
    sysv=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')
    if [[ $sysv =~ ^[0-9]+$ ]] && ((sysv < 247)); then
      # LoadCredential появился в systemd 247: на более старой юнит без root не запустится, оставляем прежний.
      warn "systemd $sysv старше 247: юнит kit-sub не меняю (подписка работает как раньше). Лучше перейти на Ubuntu 22.04+ или Debian 11+."
    else
      kit_sub_unit "$c" "$k" >/etc/systemd/system/kit-sub.service
      [[ -n $c ]] && echo '19 4 * * * root systemctl restart kit-sub >/dev/null 2>&1' >/etc/cron.d/kit-sub-cert
    fi
    systemctl daemon-reload
    if systemctl restart kit-sub && sleep 2 && sub_ok; then
      say "Подписка kit-sub обновлена и отвечает"
    else
      install -m 644 "$tmp/kit_sub.old" /usr/local/lib/kit-sub/kit_sub.py
      install -m 644 "$tmp/kit-sub.service.old" /etc/systemd/system/kit-sub.service
      grep -q '^LoadCredential=cert.pem' "$tmp/kit-sub.service.old" || rm -f /etc/cron.d/kit-sub-cert
      systemctl daemon-reload
      systemctl restart kit-sub || true
      die "Новая подписка не ответила – вернул прежнюю, kit остался версии $KIT_VERSION. Лог: journalctl -u kit-sub -n 30"
    fi
  fi

  # Исправления для установок 1.0.
  local all uri
  all=$(api POST setting/all)
  uri=${SUB_BASE:-}
  if [[ $uri == https://* && $(jq -r '.subURI // ""' <<<"$all") != "$uri" ]]; then
    api POST setting/update "$(jq -c --arg u "$uri" '.subURI = $u' <<<"$all")" >/dev/null
    say "Ссылка подписки в панели: $uri…"
  fi
  # 1.0 ставил cron, который каждый день правил файлы x-ui, – убираем.
  rm -f /etc/cron.d/kit-xui-menu
  # Автообновление включено по умолчанию, пока его не выключили командой kit update --manual.
  [[ -f $KIT_MANUAL ]] || auto_enabled || { auto_on; say "Включил автообновление: kit update --manual, чтобы выключить"; }

  # Общий лимит трафика: проверка раз в 5 минут (с 1.2).
  limit_timer_enabled || { limit_timer_on; say "Включил проверку общего лимита трафика (раз в 5 минут)"; }

  # Через rename: bash дочитывает текущий kit по ходу работы, его файл трогать нельзя.
  install -m 755 "$tmp/kit.sh" /usr/local/bin/kit.new && mv -f /usr/local/bin/kit.new /usr/local/bin/kit
  echo
  echo "${G}✓ Готово: 3X-UI KIT $latest.${N} Пользователи, ссылки и подписки не менялись."
  [[ $unattended == yes ]] && return
  local news
  news=$(changelog_of "$latest")
  if [[ -n $news ]]; then echo; echo "${B}Что нового в $latest${N}"; echo "$news"; fi
}

# ---------- проверка и починка ----------

# kit check только читает и показывает, что с сервером. kit fix чинит безопасное: перезапускает
# упавшие службы, возвращает права на файлы, включает автообновление, перечитывает сертификат.
CHECK_BAD=0; CHECK_WARN=0; CHECK_FIX=(); CHECK_QUIET=no
c_ok()   { [[ $CHECK_QUIET == yes ]] || printf '%s\n' "${G}✅${N} $*"; }
c_info() { [[ $CHECK_QUIET == yes ]] || printf '%s\n' "${D}ℹ  $*${N}"; }
c_warn() { printf '%s\n' "${Y}⚠${N}  $*"; CHECK_WARN=$((CHECK_WARN + 1)); }
c_bad()  { printf '%s\n' "${R}❌${N} ${*:2}"; CHECK_BAD=$((CHECK_BAD + 1)); [[ -z $1 ]] || CHECK_FIX+=("$1"); } # код-починки сообщение

# Сайт маскировки отвечает по TLS 1.3 и HTTP/2 (как требует REALITY)? Проверка с самого сервера.
sni_alive() { echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null | grep -q 'ALPN protocol: h2'; }

check_services() {
  local pid u
  if systemctl is-active -q x-ui; then c_ok "служба x-ui работает"; else c_bad svc:x-ui "служба x-ui не работает (journalctl -u x-ui -n 50)"; fi
  if [[ ${SINGLE:-no} == yes ]]; then
    if systemctl is-active -q nginx; then c_ok "nginx работает"; else c_bad svc:nginx "nginx не работает (journalctl -u nginx -n 50)"; fi
  fi
  if [[ -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    if systemctl is-active -q kit-sub; then
      c_ok "служба kit-sub работает"
      pid=$(systemctl show -p MainPID --value kit-sub 2>/dev/null || true)
      u=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ' || true)
      if [[ -n $u && $u != root ]]; then c_ok "kit-sub работает не от root (пользователь $u)"; else c_bad "" "kit-sub работает от root – это небезопасно, обновите kit: kit update --force"; fi
    else
      c_bad svc:kit-sub "служба kit-sub не работает (journalctl -u kit-sub -n 50)"
    fi
  fi
  if auto_enabled; then c_ok "автообновление включено"
  elif [[ -f $KIT_MANUAL ]]; then c_info "автообновление выключено вами (включить: kit update --auto)"
  else c_bad timer "автообновление не включено"; fi
  local novis
  novis=$(api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.remark == "REALITY") | (.settings | if type == "string" then fromjson else . end).clients[]? | select((.flow // "") == "")] | length' 2>/dev/null || echo 0)
  if [[ ${novis:-0} =~ ^[0-9]+$ ]] && ((novis > 0)); then c_info "у $novis польз. в REALITY не включён xtls-rprx-vision (включить: kit user vision имя|--all)"; fi
  if limit_timer_enabled; then c_ok "проверка общего лимита трафика включена"
  else c_bad limit "проверка общего лимита трафика не включена (лимит у AmneziaWG считался бы отдельно)"; fi
}

check_versions() {
  local xv pv; xv=$(xray_version || true); pv=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)
  c_info "kit $KIT_VERSION, панель 3X-UI ${pv:-?}, ядро Xray ${xv:-?}"
  if [[ -n $xv ]] && newer "$xv" "$XRAY_PIN"; then
    c_warn "ядро Xray $xv новее проверенного (${XRAY_PIN#v}): клиенты на Mihomo и sing-box могут не подключаться к REALITY (kit fix вернёт проверенное)"
    CHECK_FIX+=(core)
  fi
  if [[ -n $pv ]] && newer "v${pv#v}" "$XUI_PIN"; then
    c_warn "панель 3X-UI $pv новее проверенной (${XUI_PIN#v}): часть команд kit может работать иначе"
  elif [[ -n $pv && v${pv#v} != "$XUI_PIN" ]]; then
    c_info "панель 3X-UI $pv, проверена ${XUI_PIN#v}: обновить можно командой kit panel update"
  fi
  if [[ -s $KIT_LATEST ]] && newer "$(cat "$KIT_LATEST")" "$KIT_VERSION"; then
    c_info "вышла версия $(cat "$KIT_LATEST"): kit update"
  fi
}

check_cert() {
  local cert end left
  cert=$(awk '$1 == "ssl_certificate" {sub(/;$/, "", $2); print $2; exit}' /etc/nginx/conf.d/kit.conf 2>/dev/null || true)
  [[ -n $cert ]] || cert=$(jq -r '.cert // empty' /etc/kit-sub/config.json 2>/dev/null || true)
  [[ -n $cert ]] || { c_info "сертификат не настроен (режим без TLS)"; return 0; }
  [[ -f $cert ]] || { c_bad cert "файл сертификата $cert из настроек не найден"; return 0; }
  if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
    c_bad cert "сертификат $cert просрочен"
  else
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    left=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
    if openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1; then c_ok "сертификат действителен ещё ~$left дн."
    else c_warn "сертификат истекает меньше чем через сутки: проверьте продление (acme.sh --cron)"; fi
  fi
}

check_exposure() {
  local bind f m bad=0
  # Панель наружу не торчит: за nginx или в режиме «только SSH-туннель».
  if [[ ${SINGLE:-no} == yes || ! -f /usr/local/lib/kit-sub/kit_sub.py ]]; then
    bind=$(ss -ltnH "sport = :$XUI_PANEL_PORT" 2>/dev/null | awk '{print $4}' || true)
    if [[ -z $bind ]]; then c_bad "" "панель не слушает порт $XUI_PANEL_PORT"
    elif grep -qv '^127\.0\.0\.1:' <<<"$bind"; then c_bad "" "панель слушает наружу ($(tr '\n' ' ' <<<"$bind")): в настройках 3X-UI укажите адрес 127.0.0.1"
    else c_ok "панель слушает только localhost"; fi
  fi
  if [[ ${SINGLE:-no} == yes ]]; then
    if ss -ltnH 'sport = :443' 2>/dev/null | grep -q .; then c_ok "порт 443 слушается"; else c_bad svc:nginx "порт 443 никто не слушает"; fi
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
      if ufw status | grep -Eq '^443/tcp +ALLOW'; then c_ok "ufw пропускает 443/tcp"; else c_bad "" "ufw не пропускает 443/tcp: ufw allow 443/tcp"; fi
    fi
  fi
  for f in /etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json /root/3x-ui.txt /root/cert/*/privkey.pem; do
    [[ -f $f ]] || continue
    m=$(stat -c %a "$f")
    [[ $m == 600 ]] || { c_bad perms "права на $f: $m (нужно 600)"; bad=1; }
  done
  ((bad)) || c_ok "файлы с паролями и ключами доступны только root"
}

# Ответ подписки похож на подписку: для Clash есть proxies, для остальных – ссылки (текстом или в base64).
sub_body_ok() { # файл приложение
  case $2 in
    clash*) grep -q '^proxies:' "$1" ;;
    *) grep -q '://' "$1" || base64 -d "$1" 2>/dev/null | grep -q '://' ;;
  esac
}

check_subscription() {
  local cfg=/etc/kit-sub/config.json port path scheme=http sid ua code size body up sub_cert
  [[ -f $cfg ]] || { c_info "подписка не установлена (режим без сертификата: используйте отдельные ссылки из /root/3x-ui.txt)"; return 0; }
  port=$(jq -r '.port' "$cfg"); path=$(jq -r '.path' "$cfg")
  # Частая поломка: команда «x-ui cert» или меню панели включает TLS у встроенной подписки 3X-UI,
  # а kit-sub ходит к ней по http – подписка перестаёт отвечать.
  up=$(jq -r '.upstream // empty' "$cfg")
  sub_cert=$(api POST setting/all '{}' 2>/dev/null | jq -r '.subCertFile // empty' 2>/dev/null || true)
  if [[ $up == http://* && -n $sub_cert ]]; then
    c_bad subtls "у встроенной подписки 3X-UI включён TLS (сертификат $sub_cert), а kit-sub ходит к ней по http – подписка не отвечает"
  fi
  body=$(mktemp)
  [[ -n $(jq -r '.cert // empty' "$cfg") ]] && scheme=https
  sid=$(clients 2>/dev/null | jq -r '[.[] | .subId // empty | select(. != "")][0] // empty' 2>/dev/null || true)
  [[ -n $sid ]] || { c_info "пользователей нет, подписку проверить нечем"; return 0; }
  for ua in "Happ/1.0" "HiddifyNext/2.0" "v2rayN/7.0" "clash-verge/v2"; do
    : >"$body"
    code=$(curl -sgk -m 10 -A "$ua" -o "$body" -w '%{http_code}' "$scheme://127.0.0.1:$port$path$sid" 2>/dev/null || true)
    size=$(wc -c <"$body" | tr -d ' ')
    if [[ $code == 200 && ${size:-0} -gt 0 ]] && sub_body_ok "$body" "$ua"; then c_ok "подписка отвечает для $ua ($size байт)"
    elif [[ $code == 200 ]]; then c_bad svc:kit-sub "подписка для $ua: ответ 200, но в нём нет ссылок на подключения"
    else c_bad svc:kit-sub "подписка для $ua: HTTP ${code:-нет ответа}"; fi
  done
  rm -f "$body"
  if [[ ${SINGLE:-no} == yes ]]; then
    body=$(mktemp)
    code=$(curl -sk -m 10 -A "Happ/1.0" -o "$body" -w '%{http_code}' "https://127.0.0.1$path$sid" 2>/dev/null || true)
    if [[ $code == 200 ]] && sub_body_ok "$body" "Happ/1.0"; then c_ok "подписка отвечает и через nginx (443)"; else c_bad svc:nginx "подписка через nginx: HTTP ${code:-нет ответа} или ответ без ссылок (ищите причину выше)"; fi
    rm -f "$body"
  fi
}

check_masking() {
  local list line sni target host ips
  list=$(api GET inbounds/list 2>/dev/null) || { c_bad "" "не удалось получить подключения из панели (панель не отвечает?)"; return 0; }
  while IFS=$'\t' read -r name sni target; do
    [[ -n $sni ]] || continue
    if [[ $target == 127.0.0.1:* ]]; then
      ips=$(getent ahostsv4 "$sni" 2>/dev/null | awk '{print $1}' | sort -u || true); host=${HOST:-}
      if [[ -n $ips ]] && grep -qx "$host" <<<"$ips"; then c_ok "$name: свой домен $sni указывает на этот сервер"
      else c_bad "" "$name: свой домен $sni не указывает на этот сервер (A-запись: ${ips:-нет}, нужен $host)"; fi
    elif sni_alive "$sni"; then
      c_ok "$name: сайт маскировки $sni отвечает по TLS 1.3 и HTTP/2"
    else
      c_bad "" "$name: сайт маскировки $sni не отвечает по TLS 1.3 и HTTP/2 – смените его в панели 3X-UI"
    fi
  done < <(jq -r '.[] | select(.protocol == "vless") | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | select($s.security == "reality") | [.remark, ($s.realitySettings.serverNames[0] // ""), ($s.realitySettings.target // "")] | @tsv' <<<"$list" 2>/dev/null || true)
  c_info "Проверка идёт с самого сервера: доступность из вашей сети она не покажет."
}

check_system() {
  local used
  if command -v timedatectl >/dev/null; then
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then c_ok "время синхронизировано"
    else c_warn "время не синхронизировано: при сильном сдвиге TLS и REALITY не работают (kit fix включит синхронизацию)"; CHECK_FIX+=(ntp); fi
  fi
  used=$(df -P / | awk 'NR==2 {gsub("%", "", $5); print $5}')
  if ((${used:-0} >= 95)); then c_warn "диск заполнен на ${used}%"; else c_ok "место на диске: занято ${used:-?}%"; fi
}

# Маскировка: известный сайт на чужом IP и запасные порты, которые на посторонний запрос отвечают пустой страницей.
check_stealth() {
  local id kind remark sni names list
  while IFS=$'\t' read -r id kind remark sni; do
    [[ $kind == reality && -n $sni && $sni =~ $SNI_BRAND_RE ]] || continue
    same_net "$sni" || c_warn "$remark: $sni – известный сайт на чужом IP не годится для маскировки. Лучше сосед по подсети: kit net site"
  done < <(sni_targets 2>/dev/null || true)
  list=$(api GET inbounds/list 2>/dev/null) || return 0
  if jq -e 'any(.[]; .protocol == "hysteria" and .enable == true)' <<<"$list" >/dev/null && [[ -z $(hy_masq_state) ]]; then
    c_warn "Hysteria2 на посторонний HTTP/3-запрос отвечает не как сайт. Включить: kit net masq on"
  fi
  if [[ -z $(jq -r '.subJsonDns // ""' <<<"$(api POST setting/all '{}' 2>/dev/null)" 2>/dev/null) ]]; then
    c_warn "DNS в подписке Xray JSON обычный (UDP 8.8.8.8). Включить DoH через прокси: kit net dns on"
  fi
  names=$(jq -r '[.[] | select(.enable == true and .listen != "127.0.0.1" and (.remark == "VLESS-WS" or .remark == "Trojan-gRPC" or .remark == "VMess-WS")) | .remark] | join(", ")' <<<"$list")
  [[ -z $names ]] || c_warn "$names открыты на своих портах и на посторонний запрос отвечают пустой страницей. Не нужны? kit net off имя (режим «всё на 443» прячет их за сайтом)"
}

run_checks() {
  CHECK_BAD=0; CHECK_WARN=0; CHECK_FIX=()
  check_services; check_versions; check_cert; check_exposure; check_subscription; check_masking; check_stealth; check_system
}

# kit check --deep: подключения проверяются так, как это делает клиент, – с самого сервера.
# Порты: каждое включённое подключение должно слушать. Сами подключения: настоящий клиент Xray ходит
# через REALITY (TCP и XHTTP) на публичный адрес сервера и открывает страницу через него.
deep_ports() {
  local list name port
  list=$(api GET inbounds/list 2>/dev/null) || { c_bad "" "не удалось получить подключения из панели"; return 0; }
  while IFS=$'\t' read -r name port; do
    if ss -Hlntu "sport = :$port" 2>/dev/null | grep -q .; then c_ok "$name: порт $port слушает"
    else c_bad "" "$name: порт $port не слушает (подключение включено, но сервис не открыл порт)"; fi
  done < <(jq -r '.[] | select(.enable == true) | [.remark, .port] | @tsv' <<<"$list")
}

# Отпечаток сертификата Hysteria2 из самого подключения: в ссылке его может не быть (сертификат Let's Encrypt или свой).
deep_hy_pin() {
  local f
  f=$(api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.protocol == "hysteria")][0] | (.streamSettings | if type == "string" then fromjson else . end).tlsSettings.certificates[0].certificateFile // empty' 2>/dev/null || true)
  [[ -r $f ]] && openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
  return 0
}

deep_client_config() { # ссылка порт-socks [отпечаток] → конфиг клиента Xray (печатает JSON); не 0 – проверять нечем
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote
u = urlparse(sys.argv[1]); q = {k: v[0] for k, v in parse_qs(u.query).items()}
if u.scheme == "hysteria2":
    tls = {"serverName": q.get("sni", ""), "alpn": ["h3"], "fingerprint": q.get("fp", "chrome")}
    pin = q.get("pinSHA256") or (sys.argv[3] if len(sys.argv) > 3 else "")
    if not pin:
        sys.exit(1)
    tls["pinnedPeerCertSha256"] = pin
    print(json.dumps({"log": {"loglevel": "none"},
        "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [{"protocol": "hysteria", "settings": {"version": 2, "address": u.hostname, "port": u.port},
            "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls,
                               "hysteriaSettings": {"version": 2, "auth": u.username}}}]}))
    sys.exit(0)
if u.scheme != "vless" or q.get("security") != "reality":
    sys.exit(1)
net = q.get("type", "tcp")
st = {"network": net, "security": "reality", "realitySettings": {
    "serverName": q.get("sni", ""), "fingerprint": q.get("fp", "chrome"), "publicKey": q.get("pbk", ""),
    "shortId": q.get("sid", ""), "spiderX": unquote(q.get("spx", "/"))}}
if net == "xhttp":
    st["xhttpSettings"] = {"path": unquote(q.get("path", "/")), "mode": q.get("mode", "auto")}
user = {"id": u.username, "encryption": "none"}
if q.get("flow"):
    user["flow"] = q["flow"]
print(json.dumps({"log": {"loglevel": "none"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
    "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [user]}]}, "streamSettings": st}]}))
PY
}

deep_clients() {
  local xray sid link name cfg port=18080 pid ok tmp hypin
  hypin=$(deep_hy_pin)
  xray=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
  [[ -x $xray ]] || { c_warn "не нашёл Xray панели – подключения не проверил"; return 0; }
  command -v python3 >/dev/null || { c_warn "нет python3 – подключения не проверил"; return 0; }
  sid=$(clients 2>/dev/null | jq -r '[.[] | select(.enable == true and .subId != "") | .subId][0] // empty')
  [[ -n $sid ]] || { c_info "нет включённых пользователей – проверять подключения нечем (kit user add имя)"; return 0; }
  tmp=$(mktemp -d)
  while IFS= read -r link; do
    name=${link#*@}; name=${name%%\?*}; name=${name##*:}
    if [[ $link == hysteria2://* ]]; then name="Hysteria2 (порт $name/udp)"; elif [[ $link == *type=xhttp* ]]; then name="XHTTP (порт $name)"; else name="REALITY (порт $name)"; fi
    port=$((port + 1)); cfg=$tmp/$port.json
    deep_client_config "$link" "$port" "$hypin" >"$cfg" 2>/dev/null || continue
    "$xray" run -c "$cfg" >/dev/null 2>&1 & pid=$!
    sleep 2; ok=no
    # Ядро панели после смены настроек перезапускается несколько секунд: даём до трёх попыток.
    for _ in 1 2 3; do
      curl -fsS -m 15 --socks5-hostname "127.0.0.1:$port" -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && { ok=yes; break; }
      sleep 3
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    if [[ $ok == yes ]]; then c_ok "$name: клиент подключился к серверу и открыл страницу"
    else c_bad "" "$name: клиент не смог подключиться и открыть страницу (проверьте kit sni, журнал: journalctl -u x-ui -n 30)"; fi
  done < <(collect_links "$sid" '^(vless://.*security=reality|hysteria2://)')
  rm -rf "$tmp"
  c_info "Проверка идёт с самого сервера: доступность из вашей сети она не покажет. Остальные протоколы проверены только по открытому порту."
}

cmd_check() {
  local deep=no
  [[ ${1:-} != --fix ]] || { shift; cmd_fix "$@"; return; }
  [[ ${1:-} != --deep ]] || deep=yes
  [[ -z ${1:-} || $deep == yes ]] || die "Команда: kit check [--deep | --fix]"
  echo "${B}kit check${N} – проверка сервера (ничего не меняет)"
  echo
  run_checks
  if [[ $deep == yes ]]; then echo; echo "${B}Подключения${N}"; deep_ports; deep_clients; fi
  echo
  if ((CHECK_BAD == 0)); then
    echo "${G}${B}Всё в порядке.${N}$( ((CHECK_WARN)) && echo " Предупреждений: $CHECK_WARN." || true)"
  else
    echo "${R}${B}Проблем: $CHECK_BAD.${N} Безопасные исправления: ${B}kit fix${N} (сначала можно посмотреть: kit fix --dry-run)."
    return 1
  fi
}

fix_action() { # код
  case $1 in
    svc:x-ui) say "Перезапускаю x-ui"; systemctl restart x-ui; sleep 3 ;;
    svc:nginx)
      if nginx -t >/dev/null 2>&1; then say "Перезапускаю nginx"; systemctl restart nginx
      else warn "Конфиг nginx не проходит проверку (nginx -t) – не трогаю, чтобы не сломать сервер."; fi ;;
    svc:kit-sub) say "Перезапускаю kit-sub"; systemctl restart kit-sub; sleep 2 ;;
    subtls)
      say "Убираю сертификат у встроенной подписки 3X-UI (TLS снимает nginx, kit-sub ходит по http)"
      local all upd
      all=$(api POST setting/all '{}')
      upd=$(jq -c '.subCertFile = "" | .subKeyFile = ""' <<<"$all")
      api POST setting/update "$upd" >/dev/null
      systemctl restart x-ui; sleep 4 ;;
    timer) say "Включаю автообновление"; auto_on ;;
    limit) say "Включаю проверку общего лимита трафика"; limit_timer_on ;;
    core) say "Возвращаю проверенное ядро Xray ${XRAY_PIN#v}"; pin_core || true ;;
    perms)
      say "Возвращаю права 600 на файлы с паролями и ключами"
      local f
      for f in /etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json /root/3x-ui.txt /root/cert/*/privkey.pem; do
        if [[ -f $f ]]; then chmod 600 "$f"; fi
      done ;;
    cert)
      if nginx -t >/dev/null 2>&1; then say "Перечитываю сертификат в nginx"; systemctl reload nginx
      else warn "Конфиг nginx не проходит проверку – сертификат не перечитываю."; fi
      warn "Если сертификат всё ещё просрочен, запустите продление: ~/.acme.sh/acme.sh --cron" ;;
    ntp) fix_ntp ;;
  esac
}

# На минимальном Debian 13 нет клиента NTP, и «timedatectl set-ntp» отвечает «NTP not supported».
# Ставим systemd-timesyncd, но только если нет другого.
fix_ntp() {
  say "Включаю синхронизацию времени"
  timedatectl set-ntp true 2>/dev/null && return 0
  if other_ntp_installed; then
    warn "Время синхронизирует другой NTP-клиент (chrony или ntp) – проверьте, что его служба запущена."
    return 0
  fi
  say "Ставлю systemd-timesyncd"
  # timedatectl после установки ещё не видит новую службу, поэтому включаем её напрямую.
  if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq systemd-timesyncd >/dev/null 2>&1 \
      && systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
    return 0
  fi
  warn "Не удалось включить синхронизацию времени. Поставьте клиент вручную: apt install systemd-timesyncd"
}

other_ntp_installed() {
  local p
  for p in chrony ntp ntpsec openntpd; do
    [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == "install ok installed" ]] && return 0
  done
  return 1
}

# Что чинить сейчас: если найдена причина (TLS у подписки), перезапуски kit-sub и nginx – лишь
# следствия: сначала лечим причину, потом проверяем заново.
fix_plan() {
  local c
  while IFS= read -r c; do
    if [[ $c == svc:kit-sub || $c == svc:nginx ]] && printf '%s\n' "${CHECK_FIX[@]}" | grep -qx subtls; then continue; fi
    echo "$c"
  done < <(printf '%s\n' "${CHECK_FIX[@]}" | sort -u)
}

cmd_fix() {
  local dry=no c pass plan
  case ${1:-} in --dry-run) dry=yes ;; "") ;; *) die "kit fix [--dry-run]" ;; esac
  echo "${B}kit fix${N} – безопасные исправления (службы, права, автообновление, сертификат, время)"
  echo
  CHECK_QUIET=yes; run_checks; CHECK_QUIET=no
  if ((${#CHECK_FIX[@]} == 0)); then
    if ((CHECK_BAD == 0)); then echo "${G}Чинить нечего: всё в порядке.${N}"; return 0; fi
    echo; echo "${Y}Автоматически эти проблемы не исправить, они описаны выше. Подробности: kit check${N}"; return 1
  fi
  if [[ $dry == yes ]]; then
    while IFS= read -r c; do echo "  будет сделано: $c"; done < <(fix_plan)
    return 0
  fi
  for pass in 1 2; do
    plan=$(fix_plan)
    [[ -n $plan ]] || break
    while IFS= read -r c; do fix_action "$c"; done <<<"$plan"
    CHECK_QUIET=yes; run_checks; CHECK_QUIET=no
    ((${#CHECK_FIX[@]})) || break
  done
  echo; echo "${B}Повторная проверка${N}"; echo
  run_checks
  echo
  if ((CHECK_BAD == 0)); then echo "${G}${B}Готово: всё в порядке.${N}"; else echo "${R}Осталось проблем: $CHECK_BAD.${N} Часть из них нужно решать вручную (см. выше)."; return 1; fi
}

# ---------- резервная копия ----------

# Что входит в копию: база панели (пользователи,
# ключи, подключения), настройки kit и kit-sub, nginx, сайт-заглушка, свои сертификаты.
# Сертификаты Let's Encrypt (на IP и на свой домен) не берём: на новом сервере он выпускается заново.
BACKUP_PATHS=(/etc/x-ui/install-result.env /etc/kit/kit.env /etc/kit-sub/config.json
  /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf /var/www/kit /root/cert/self /root/cert/custom /root/3x-ui.txt)

# Вернуть проверенное ядро Xray (панель 3.9 иногда отвечает ошибкой GitHub API, хотя ядро заменено, поэтому смотрим на версию).
pin_core() {
  local cur="" i
  (api POST "server/installXray/$XRAY_PIN" '{}' >/dev/null) 2>/dev/null || true
  for i in $(seq 1 30); do
    cur=$(xray_version || true)
    [[ $cur == "$XRAY_PIN" ]] && return 0
    sleep 2
  done
  warn "Не удалось вернуть ядро Xray $XRAY_PIN (сейчас ${cur:-?})."
  return 1
}

panel_healthy() { # ждём ответа панели до 60 секунд
  local i
  for i in $(seq 1 30); do
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

# Обновление панели до проверенной версии. Делает только безопасную часть официального обновления:
# проверенный архив, замена файлов панели, миграция базы. Не трогает ядро Xray, сертификаты и настройки
# (официальный update.sh при отсутствии сертификата сам выпускает его и включает TLS, меняет ядро и ставит fail2ban).
panel_update() {
  local force=no a arch cur target=${XUI_PIN#v} tmp ts bak got want os_id keep_core
  for a in "$@"; do
    case $a in
      --force) force=yes ;;
      *) die "kit panel update [--force]" ;;
    esac
  done
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "Обновление панели умеет только amd64 и arm64." ;; esac
  cur=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)
  [[ -n $cur ]] || die "Не удалось узнать версию панели."
  cur=${cur#v}
  if [[ $cur == "$target" && $force == no ]]; then
    say "Панель уже $target: это проверенная версия."
    return 0
  fi
  if newer "v$cur" "$XUI_PIN" && [[ $force == no ]]; then
    die "У вас панель $cur новее проверенной $target. Откат не поддерживается; если что-то не работает, пришлите вывод kit check."
  fi
  say "Обновляю панель 3X-UI $cur → $target (настройки, пользователи и ядро Xray сохраняются)"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу
  trap "rm -rf -- '$tmp'" EXIT

  # 1. Архив и скрипт меню – только с совпавшей зашитой суммой.
  curl -fL --retry 3 -m 600 -o "$tmp/x-ui.tar.gz" "https://github.com/MHSanaei/3x-ui/releases/download/$XUI_PIN/x-ui-linux-$arch.tar.gz" 2>/dev/null \
    || die "Не удалось скачать панель с GitHub. Сервер не тронут."
  got=$(sha256sum "$tmp/x-ui.tar.gz" | awk '{print $1}'); want=${XUI_TARBALL_SHA256[$arch]}
  [[ $got == "$want" ]] || die "Архив панели не совпал с проверенным (SHA256) – не ставлю. Сервер не тронут."
  curl -fsSL --retry 3 -m 60 -o "$tmp/x-ui.sh" "https://raw.githubusercontent.com/MHSanaei/3x-ui/$XUI_PIN/x-ui.sh" \
    || die "Не удалось скачать x-ui.sh. Сервер не тронут."
  [[ $(sha256sum "$tmp/x-ui.sh" | awk '{print $1}') == "$XUI_SH_SHA256" ]] || die "Скрипт меню x-ui не совпал с проверенным (SHA256) – не ставлю. Сервер не тронут."
  tar tzf "$tmp/x-ui.tar.gz" | grep -qE '^/|(^|/)\.\.(/|$)' && die "В архиве панели странные пути – не ставлю."
  tar xzf "$tmp/x-ui.tar.gz" -C "$tmp"
  [[ -s $tmp/x-ui/x-ui ]] || die "В архиве панели нет x-ui. Сервер не тронут."

  # 2. Копия на случай отката (база снимается средствами SQLite).
  ts=$(date +%Y%m%d-%H%M); bak=/root/x-ui-before-update-$ts
  install -d -m 700 "$bak/etc-x-ui"
  cp -a /usr/local/x-ui "$bak/usr-local-x-ui"
  cp -a /etc/x-ui/. "$bak/etc-x-ui/"
  cp -a /etc/systemd/system/x-ui.service "$bak/x-ui.service" 2>/dev/null || true
  cp -a /usr/bin/x-ui "$bak/x-ui.sh" 2>/dev/null || true
  python3 - /etc/x-ui/x-ui.db "$bak/x-ui.db" <<'PY' || die "Не удалось сохранить копию базы. Сервер не тронут."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2]); src.backup(dst); dst.close(); src.close()
PY
  say "Копия прежней панели: $bak"

  # 3. Замена файлов. Ядро Xray (проверенное) оставляем: берём его из прежней установки.
  keep_core=$tmp/xray.keep
  cp -a "/usr/local/x-ui/bin/xray-linux-$arch" "$keep_core"
  systemctl stop x-ui
  pkill -f 'mtg-linux-[^ ]* run ' >/dev/null 2>&1 || true
  install -m 755 "$tmp/x-ui/x-ui" /usr/local/x-ui/x-ui.new && mv -f /usr/local/x-ui/x-ui.new /usr/local/x-ui/x-ui
  for f in "$tmp"/x-ui/bin/*; do
    case ${f##*/} in xray-linux-*) continue ;; esac
    cp -af "$f" /usr/local/x-ui/bin/
  done
  install -m 755 "$keep_core" "/usr/local/x-ui/bin/xray-linux-$arch"
  chmod +x "/usr/local/x-ui/bin/mtg-linux-$arch" 2>/dev/null || true
  rm -rf /usr/local/x-ui/bin/tuic-server /usr/local/x-ui/bin/tuic   # TUIC теперь встроен в панель
  install -m 755 "$tmp/x-ui.sh" /usr/local/x-ui/x-ui.sh
  install -m 755 "$tmp/x-ui.sh" /usr/bin/x-ui.new && mv -f /usr/bin/x-ui.new /usr/bin/x-ui
  os_id=$(. /etc/os-release && echo "${ID:-}")
  case $os_id in
    ubuntu | debian) [[ -f $tmp/x-ui/x-ui.service.debian ]] && install -m 644 "$tmp/x-ui/x-ui.service.debian" /etc/systemd/system/x-ui.service ;;
    *) warn "Файл службы не менял (система $os_id): оставил прежний." ;;
  esac
  chown -R root:root /usr/local/x-ui
  [[ -f /usr/local/x-ui/bin/config.json ]] && chmod 640 /usr/local/x-ui/bin/config.json
  systemctl daemon-reload
  /usr/local/x-ui/x-ui migrate >/dev/null 2>&1 || true
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl start x-ui

  # 4. Проверка и откат при провале.
  if panel_healthy && [[ $(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1) == "$target" ]]; then
    systemctl is-active -q x-ui || true
    say "Панель обновлена до $target, ядро Xray ${XRAY_PIN#v} осталось."
    echo "Копию прежней панели можно удалить, когда убедитесь, что всё работает: rm -rf $bak"
    echo "Проверить сервер: ${B}kit check${N}"
    return 0
  fi
  warn "Панель после обновления не отвечает – возвращаю прежнюю."
  systemctl stop x-ui || true
  rm -rf /usr/local/x-ui && cp -a "$bak/usr-local-x-ui" /usr/local/x-ui
  cp -a "$bak/etc-x-ui/." /etc/x-ui/
  [[ -f $bak/x-ui.service ]] && cp -a "$bak/x-ui.service" /etc/systemd/system/x-ui.service
  [[ -f $bak/x-ui.sh ]] && install -m 755 "$bak/x-ui.sh" /usr/bin/x-ui
  systemctl daemon-reload; systemctl start x-ui || true
  die "Обновление не удалось, прежняя панель восстановлена ($cur). Копия: $bak. Лог: journalctl -u x-ui -n 50"
}

cmd_backup() {
  local out tmp p ssl=none c
  out=/root/kit-backup-$(date +%Y%m%d-%H%M).tar.gz
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # путь подставляем сразу: при выходе локальной переменной уже нет
  trap "rm -rf -- '$tmp'" EXIT
  install -d -m 700 "$tmp/etc/x-ui"
  # Снимок базы средствами SQLite: панель продолжает работать, копия целая.
  python3 - /etc/x-ui/x-ui.db "$tmp/etc/x-ui/x-ui.db" <<'PY' || die "Не удалось скопировать базу панели."
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
  for p in "${BACKUP_PATHS[@]}"; do if [[ -e $p ]]; then cp -a --parents "$p" "$tmp"; fi; done
  # Какой сертификат был у панели и подписки – новый сервер должен получить такой же.
  c=$(jq -r '.cert // empty' /etc/kit-sub/config.json 2>/dev/null || true)
  [[ -z $c && -f /etc/nginx/conf.d/kit.conf ]] && c=$(awk '$1 == "ssl_certificate" {sub(/;$/, "", $2); print $2; exit}' /etc/nginx/conf.d/kit.conf)
  case $c in
    /root/cert/ip/*) ssl=ip ;;
    /root/cert/custom/*) ssl=custom ;;
  esac
  {
    printf 'BACKUP_KIT_VERSION=%q\n' "$KIT_VERSION"
    printf 'BACKUP_HOST=%q\n' "$HOST"
    printf 'BACKUP_SSL=%q\n' "$ssl"
    printf 'BACKUP_DATE=%q\n' "$(date +%F)"
  } >"$tmp/kit-backup.env"
  (umask 077; tar -czf "$out" -C "$tmp" .)
  chmod 600 "$out"
  say "Резервная копия: ${B}$out${N} ($(du -h "$out" | cut -f1))"
  echo
  echo "В ней ключи и пароли от сервера, храните её как пароль. Скачать к себе (на компьютере):"
  echo "  ${B}scp root@$HOST:$out .${N}"
  echo
}

# ---------- сайт маскировки: kit sni ----------

SNI_POOL=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com www.microsoft.com www.cloudflare.com)

# --- поиск сайта-прикрытия среди соседей по подсети (общий код kit и установщика) ---

SNI_RE='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

# Бесплатные и динамические имена (sslip.io, work.gd и т. п.) часто используют чужие прокси-серверы: под них маскироваться не стоит.
SNI_DYN_RE='(^|\.)(sslip\.io|nip\.io|xip\.io|traefik\.me|work\.gd|duckdns\.org|ddns\.net|hopto\.org|zapto\.org|myftp\.biz|dynu\.net|freeddns\.org|no-ip\.(org|biz|info)|nom\.za|tk|ml|ga|cf|gq)$'
# Известные сайты на чужом IP не подходят: сайт-прикрытие должен быть «своим» для подсети сервера.
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
  seq 1 254 | xargs -P 24 -I{} bash -c '
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

# Подключения, у которых есть сайт маскировки: id, вид (reality, mtproto, self – свой домен), название, сайт.
sni_targets() {
  api GET inbounds/list | jq -r '.[] | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | (.settings | if type == "string" then fromjson else . end) as $c
    | if .protocol == "vless" and $s.security == "reality" then
        [.id, (if (($s.realitySettings.target // "") | startswith("127.0.0.1:")) then "self" else "reality" end), .remark, ($s.realitySettings.serverNames[0] // "")]
      elif .protocol == "mtproto" then [.id, "mtproto", .remark, ($c.fakeTlsDomain // "")]
      else empty end | @tsv'
}

sni_body() { # id вид новый-сайт → тело для inbounds/update
  api GET inbounds/list | jq -c --argjson id "$1" --arg k "$2" --arg n "$3" '.[] | select(.id == $id)
    | (.streamSettings | if type == "string" then fromjson else . end) as $s
    | (.settings | if type == "string" then fromjson else . end) as $c
    | (if $k == "reality" then ($s | .realitySettings.serverNames = [$n] | .realitySettings.target = ($n + ":443")) else $s end) as $s2
    | (if $k == "mtproto" then ($c | .fakeTlsDomain = $n) else $c end) as $c2
    | {id, remark, enable, listen, port, protocol, expiryTime, total, settings: ($c2 | tojson), streamSettings: ($s2 | tojson),
       sniffing: (.sniffing | if type == "string" then . else tojson end)}'
}

sni_show() {
  local id kind remark sni mark
  say "Сайты маскировки (сервер: ${HOST:-?})"
  while IFS=$'\t' read -r id kind remark sni; do
    [[ -n $sni ]] || continue
    if [[ $kind == self ]]; then mark="свой домен"
    elif same_net "$sni"; then mark="из подсети сервера"
    else mark="чужая подсеть"; fi
    printf '  %-10s %-28s %s\n' "$remark" "$sni" "$mark"
  done < <(sni_targets)
  echo
  echo "Сменить: ${B}kit sni rotate${N} (сам подберёт), ${B}kit sni rotate --nearby${N} (искать в подсети сервера), ${B}kit sni rotate сайт.com${N}"
}

sni_rotate() { # [--nearby] [--dry-run] [сайт]
  local nearby=no dry=no site="" a
  while (($#)); do
    case $1 in
      --nearby) nearby=yes ;;
      --dry-run) dry=yes ;;
      -*) die "Неизвестный параметр $1. Команда: kit sni rotate [--nearby] [--dry-run] [сайт]" ;;
      *) site=${1,,}; [[ $site =~ $SNI_RE ]] || die "Нужно имя сайта, например dl.google.com (без https://)." ;;
    esac
    shift
  done
  local -a ids=() kinds=() remarks=() olds=() news=() pool=() used=()
  local id kind remark sni
  while IFS=$'\t' read -r id kind remark sni; do
    [[ $kind == self || -z $sni ]] && continue
    ids+=("$id"); kinds+=("$kind"); remarks+=("$remark"); olds+=("$sni"); used+=("$sni")
  done < <(sni_targets)
  ((${#ids[@]})) || die "Нет подключений, у которых можно сменить сайт маскировки (при своём домене маскировка уже под ваш сайт)."

  [[ -z $site ]] || { pool+=("$site"); }
  if [[ $nearby == yes ]]; then
    say "Ищу сайты в подсети сервера (около 250 коротких подключений к порту 443 соседних адресов)"
    while read -r a; do [[ -n $a ]] && pool+=("$a"); done < <(nearby_sites)
    if ((${#pool[@]} == 0)); then
      warn "В подсети подходящего сайта не нашёл. Известный сайт на чужом IP подходит хуже остальных."
      echo "  Лучший выход – свой домен (установка с --domain) или свой сайт: kit net site сайт.com"
      if [[ -t 0 ]]; then
        ask_tty "  Взять запасной сайт из списка? [y/N] "
        [[ $REPLY =~ ^[yYдД]$ ]] || { echo "Отменено."; return 0; }
      fi
    fi
  fi
  pool+=("${SNI_POOL[@]}")

  local c i taken
  for i in "${!ids[@]}"; do
    for c in "${pool[@]}"; do
      taken=no
      for a in "${used[@]}" "${news[@]}"; do [[ $a == "$c" ]] && taken=yes; done
      [[ $taken == yes ]] && continue
      if sni_alive "$c"; then news+=("$c"); break; fi
      [[ $c == "$site" ]] && die "$c не отвечает по TLS 1.3 + HTTP/2 – REALITY с ним работать не будет."
    done
    [[ -n ${news[$i]:-} ]] || die "Не нашёл свободный сайт для ${remarks[$i]}: все из списка заняты или не отвечают по TLS 1.3 + HTTP/2. Укажите свой: kit sni rotate сайт.com"
  done

  echo "${B}Было → станет:${N}"
  for i in "${!ids[@]}"; do
    printf '  %-10s %-28s → %s%s\n' "${remarks[$i]}" "${olds[$i]}" "${news[$i]}" "$(same_net "${news[$i]}" && echo '  (из подсети сервера)')"
  done
  for i in "${!ids[@]}"; do
    if [[ ${news[$i]} =~ $SNI_BRAND_RE ]] && ! same_net "${news[$i]}"; then
      warn "Для ${remarks[$i]} в подсети не хватило сайтов – взят известный сайт из общего списка, он подходит хуже соседа. Лучше свой сайт: kit net site сайт.com"
      break
    fi
  done
  [[ $dry == no ]] || { echo "${D}(--dry-run: ничего не менял)${N}"; return 0; }
  if [[ -t 0 ]]; then
    ask_tty "Применить? [Y/n] "
    [[ ! $REPLY =~ ^[nNнН]$ ]] || { echo "Отменено."; return 0; }
  fi

  local bak
  bak=/root/x-ui-before-sni-$(date +%Y%m%d-%H%M%S).db
  install -m 600 /dev/null "$bak"; cat /etc/x-ui/x-ui.db >"$bak"
  say "Копия базы панели: $bak"

  local -a done_i=()
  sni_revert() {
    local j
    warn "Возвращаю прежние сайты."
    for j in "${done_i[@]}"; do
      (api POST "inbounds/update/${ids[$j]}" "$(sni_body "${ids[$j]}" "${kinds[$j]}" "${olds[$j]}")" >/dev/null) 2>/dev/null || warn "Не удалось вернуть ${remarks[$j]}: восстановите из $bak"
    done
  }
  local body
  for i in "${!ids[@]}"; do
    body=$(sni_body "${ids[$i]}" "${kinds[$i]}" "${news[$i]}")
    [[ -n $body ]] || { sni_revert; die "Не нашёл подключение ${remarks[$i]} в панели."; }
    if ! (api POST "inbounds/update/${ids[$i]}" "$body" >/dev/null); then sni_revert; die "Панель не приняла новый сайт для ${remarks[$i]}. Ничего не изменилось."; fi
    done_i+=("$i")
  done

  # Режим «всё на 443»: nginx различает подключения по имени сайта, обновляем его таблицу.
  local conf=/etc/nginx/kit-stream.conf
  if [[ ${SINGLE:-no} == yes && -f $conf ]]; then
    local cbak tmp
    cbak=$(mktemp); cp -p "$conf" "$cbak"; tmp=$(mktemp)
    cp "$conf" "$tmp"
    for i in "${!ids[@]}"; do
      awk -v o="${olds[$i]}" -v n="${news[$i]}" '$1 == o && $2 ~ /^127\.0\.0\.1:[0-9]+;$/ {printf "        %s %s\n", n, $2; next} {print}' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done
    cat "$tmp" >"$conf"; rm -f "$tmp"
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx; then
      cat "$cbak" >"$conf"; rm -f "$cbak"
      sni_revert; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
      die "nginx не принял новые имена. Всё возвращено как было."
    fi
    rm -f "$cbak"
  fi

  sleep 2
  systemctl is-active -q x-ui || warn "Панель не отвечает – проверьте: systemctl status x-ui"
  say "Готово. Сайт маскировки сменён."
  [[ $nearby == no ]] || echo "Это чужие сайты из вашей подсети: откройте их в браузере и убедитесь, что на них нет ничего неприятного. Не подошли – kit sni rotate ещё раз."
  echo "Подписка у клиентов обновится сама при следующем обновлении подписки в приложении."
  echo "Ссылки REALITY, XHTTP и MTProto, сохранённые вручную, нужно заменить на новые: ${B}kit user link имя --all${N}"
}

# ---------- порты подключений: kit port ----------

port_net() { # protocol → tcp|udp|both
  case $1 in
    hysteria | hysteria2 | tuic | wireguard | amneziawg) echo udp ;;
    shadowsocks) echo both ;;
    *) echo tcp ;;
  esac
}

port_show() {
  local list
  list=$(api GET inbounds/list)
  say "Порты подключений"
  jq -r '.[] | [.remark, .port, .protocol, .listen] | @tsv' <<<"$list" | while IFS=$'\t' read -r name port proto listen; do
    if [[ $listen == 127.0.0.1 ]]; then printf '  %-14s %-6s %s\n' "$name" "$port" "внутренний (за nginx на 443)"
    else printf '  %-14s %-6s %s\n' "$name" "$port" "$(port_net "$proto")"; fi
  done
  echo
  echo "Сменить: ${B}kit port set имя порт${N}, например: kit port set REALITY 8443"
}

port_set() { # имя порт
  local name=${1:-} new=${2:-} list row id old proto listen net body
  [[ -n $name && $new =~ ^[0-9]{1,5}$ ]] || die "kit port set имя порт, например: kit port set REALITY 8443"
  new=$((10#$new)); ((new >= 1 && new <= 65535)) || die "Порт: число от 1 до 65535."
  list=$(api GET inbounds/list)
  row=$(jq -c --arg n "${name,,}" '[.[] | select((.remark | ascii_downcase) == $n)][0] // empty' <<<"$list")
  [[ -n $row ]] || die "Нет подключения «$name». Список: kit port"
  id=$(jq -r '.id' <<<"$row"); old=$(jq -r '.port' <<<"$row"); proto=$(jq -r '.protocol' <<<"$row"); listen=$(jq -r '.listen' <<<"$row")
  [[ $listen != 127.0.0.1 ]] || die "$name работает за nginx на внутреннем порту, снаружи это 443: менять нечего (режим «всё на 443»)."
  [[ $new != "$old" ]] || die "$name уже на порту $new."
  case $new in 22 | 80) die "Порт $new занят под SSH или проверку сертификата – выберите другой." ;; esac
  [[ $new != "${XUI_PANEL_PORT:-}" ]] || die "Порт $new – это панель."
  net=$(port_net "$proto")
  # TCP и UDP на одном номере не конфликтуют (REALITY по tcp и Hysteria2 по udp делят 443).
  local on op opr oid
  while IFS=$'\t' read -r oid op opr; do
    [[ $oid != "$id" && $op == "$new" ]] || continue
    on=$(port_net "$opr")
    [[ $on == both || $net == both || $on == "$net" ]] && die "Порт $new/$on уже занят другим подключением."
  done < <(jq -r '.[] | [.id, .port, .protocol] | @tsv' <<<"$list")
  case $net in
    tcp) ss -Hltn "sport = :$new" | grep -q . && die "Порт $new/tcp занят другой программой." ;;
    udp) ss -Hlun "sport = :$new" | grep -q . && die "Порт $new/udp занят другой программой." ;;
    both) { ss -Hltn "sport = :$new"; ss -Hlun "sport = :$new"; } | grep -q . && die "Порт $new занят другой программой." ;;
  esac
  body=$(jq -c --argjson p "$new" '{id, remark, enable, listen, port: $p, protocol, expiryTime, total, settings: (.settings | if type == "string" then . else tojson end),
    streamSettings: (.streamSettings | if type == "string" then . else tojson end), sniffing: (.sniffing | if type == "string" then . else tojson end)}' <<<"$row")
  local ufw_on=no
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ufw_on=yes
  [[ $ufw_on == no ]] || port_ufw allow "$new" "$net"
  if ! (api POST "inbounds/update/$id" "$body" >/dev/null); then
    [[ $ufw_on == no ]] || port_ufw delete "$new" "$net"
    die "Панель не приняла новый порт. Ничего не изменилось."
  fi
  [[ $ufw_on == no ]] || port_ufw delete "$old" "$net"
  sleep 2
  if ss -Hlntu "sport = :$new" 2>/dev/null | grep -q .; then say "$name теперь на порту ${B}$new${N} (был $old)."
  else warn "$name переведён на порт $new, но он пока не слушает: проверьте kit check --deep."; fi
  echo "Подписка обновит ссылки сама. Сохранённые вручную ссылки на $name нужно заменить: ${B}kit user link имя --all${N}"
  echo "Если у хостера есть свой межсетевой экран (в личном кабинете), откройте в нём порт $new ($net) и закройте $old."
}

port_ufw() { # allow|delete порт tcp|udp|both
  local act=$1 p=$2 n=$3
  if [[ $n == both ]]; then
    if [[ $act == allow ]]; then ufw allow "$p/tcp" >/dev/null; ufw allow "$p/udp" >/dev/null
    else ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; ufw delete allow "$p/udp" >/dev/null 2>&1 || true; fi
  elif [[ $act == allow ]]; then ufw allow "$p/$n" >/dev/null
  else ufw delete allow "$p/$n" >/dev/null 2>&1 || true; fi
}

# ---------- второй REALITY на высоком порту: kit reality add ----------

reality_add() { # [порт]
  local want=${1:-} list base id port="" keys sid settings stream body c n=0 tries bid
  [[ -z $want || $want =~ ^[0-9]{1,5}$ ]] || die "kit reality add [порт], например: kit reality add 24443"
  list=$(api GET inbounds/list)
  jq -e 'any(.[]; .remark == "REALITY-2")' <<<"$list" >/dev/null && die "REALITY-2 уже есть. Порт: kit port, смена: kit port set REALITY-2 порт"
  base=$(jq -c '[.[] | select(.remark == "REALITY")][0] // empty' <<<"$list")
  [[ -n $base ]] || die "На сервере нет подключения REALITY, на которое можно опереться."
  if [[ -n $want ]]; then
    port=$((10#$want)); ((port >= 1024 && port <= 65535)) || die "Порт: число от 1024 до 65535."
  else
    for tries in $(seq 1 50); do
      port=$(shuf -i 20000-60000 -n 1)
      jq -e --argjson p "$port" 'any(.[]; .port == $p)' <<<"$list" >/dev/null && { port=""; continue; }
      ss -Hlntu "sport = :$port" | grep -q . || break
      port=""
    done
    [[ -n $port ]] || die "Не нашёл свободный порт."
  fi
  jq -e --argjson p "$port" 'any(.[]; .port == $p)' <<<"$list" >/dev/null && die "Порт $port уже занят другим подключением."
  ss -Hlntu "sport = :$port" | grep -q . && die "Порт $port занят другой программой."
  [[ $port != "${XUI_PANEL_PORT:-}" ]] || die "Порт $port – это панель."

  keys=$(api GET server/getNewX25519Cert)
  sid=$(openssl rand -hex 8)
  settings=$(jq -nc '{clients: [], decryption: "none", fallbacks: []}')
  # Сайт маскировки (или свой домен) – как у основного REALITY, ключи и shortId – свои.
  stream=$(jq -c --argjson k "$keys" --arg sid "$sid" '(.streamSettings | if type == "string" then fromjson else . end)
    | .externalProxy = [] | .tcpSettings.acceptProxyProtocol = false | .realitySettings.xver = 0
    | .realitySettings.privateKey = $k.privateKey | .realitySettings.shortIds = [$sid]
    | .realitySettings.settings.publicKey = $k.publicKey | del(.sockopt)' <<<"$base")
  body=$(jq -nc --argjson port "$port" --arg s "$settings" --arg st "$stream" '{remark: "REALITY-2", enable: true, listen: "", port: $port, protocol: "vless",
    settings: $s, streamSettings: $st, sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}", expiryTime: 0, total: 0}')
  api POST inbounds/add "$body" >/dev/null
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then ufw allow "$port/tcp" >/dev/null; fi
  id=$(api GET inbounds/list | jq -r '[.[] | select(.remark == "REALITY-2")][0].id')
  [[ $id =~ ^[0-9]+$ ]] || die "Панель не создала REALITY-2."
  # Тем же пользователям, что есть на основном REALITY (двойники AmneziaWG и Telegram не подключаются к нему).
  bid=$(jq -r '.id' <<<"$base")
  while read -r c; do
    [[ -n $c ]] || continue
    api POST "clients/$c/attach" "$(jq -nc --argjson i "$id" '{inboundIds: [$i]}')" >/dev/null && n=$((n + 1))
  done < <(clients | jq -r --argjson b "$bid" '.[] | select((.inboundIds // []) | index($b)) | .email')
  say "REALITY-2 создан на порту ${B}$port${N}, подключено пользователей: $n. Подписка у клиентов обновится сама."
  echo "Если у хостера есть свой межсетевой экран (в личном кабинете), откройте в нём порт $port (tcp)."
  echo "Проверить: ${B}kit check --deep${N}. Ссылки: ${B}kit user link имя --all${N}"
}

# ---------- вид: блок ссылок, kit net, меню ----------

# Блок ссылок: основные и запасные по группам, у каждой название, порт и сама ссылка. Печатает и итог установки, и kit user link.
links_block() { # имя subId
  local name=$1 sid=$2 raw
  raw=$(collect_links "$sid" '^[a-z0-9]+://')
  [[ -n $raw ]] || { echo "Отдельных ссылок нет."; return 0; }
  local script
  IFS= read -r -d '' script <<'PY' || true
import base64, json, os, re, subprocess, shutil, sys
from urllib.parse import urlparse, parse_qs, unquote
name = sys.argv[1]
MAIN = ["REALITY", "XHTTP", "Hysteria2"]
items, vpn = [], 0
for line in sys.stdin.read().split():
    sch = line.split("://", 1)[0]
    label, port, net, hint = "", "", "tcp", ""
    try:
        if sch == "vmess":
            d = json.loads(base64.b64decode(line[8:] + "=" * (-len(line[8:]) % 4)))
            label, port = d.get("ps", "VMess"), str(d.get("port", ""))
        elif sch == "vpn":
            vpn += 1
            label, net, hint = ("AmneziaWG" if vpn == 1 else "AmneziaWG 3.1"), "udp", "вставьте в AmneziaVPN"
        elif sch == "tg":
            label, port, hint = "MTProto", parse_qs(urlparse(line).query).get("port", [""])[0], "для Telegram"
        else:
            u = urlparse(line)
            label, port = unquote(u.fragment), str(u.port or "")
            if sch in ("hysteria2", "tuic"):
                net = "udp"
            if sch == "tuic":
                hint = "если приложение ругается на сертификат, включите «Разрешить небезопасный»"
    except Exception:
        continue
    label = re.sub(r"-" + re.escape(name) + r"$", "", label) or sch
    items.append((label, port, net, hint, line))
def show(label, port, net, hint, line):
    where = (port + "/" + net) if port and sch_net_ok(label, net) else (port or net)
    print("  %s  ·  %s%s" % (label, where, ("   → " + hint) if hint else ""))
    print("  " + line)
    print()
def sch_net_ok(label, net):
    return label not in ("Shadowsocks",)
print("ПОДКЛЮЧЕНИЕ  ·  %s" % name)
print()
main = [i for m in MAIN for i in items if i[0] == m]
ORDER = ["REALITY-2", "VLESS-WS", "Trojan-gRPC", "VMess-WS", "Shadowsocks", "TUIC", "AmneziaWG", "AmneziaWG 3.1", "MTProto"]
spare = [i for i in items if i[0] not in MAIN]
spare.sort(key=lambda i: ORDER.index(i[0]) if i[0] in ORDER else len(ORDER))
qr_done = False
for title, group in (("Основные", main), ("Запасные", spare)):
    if not group:
        continue
    print(title)
    for it in group:
        show(*it)
        if not qr_done and it[0] == "REALITY" and shutil.which("qrencode") and not os.environ.get("KIT_NO_QR"):
            sys.stdout.flush()
            subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "1", it[4]])
            print()
            qr_done = True
PY
  python3 -c "$script" "$name" <<<"$raw"
}

# ---------- Hysteria2: ответ сайтом на чужой HTTP/3-запрос (masquerade) ----------

hy_masq_state() { api GET inbounds/list 2>/dev/null | jq -r '[.[] | select(.protocol == "hysteria")][0] | (.streamSettings | if type == "string" then fromjson else . end).hysteriaSettings.masquerade.type // empty' 2>/dev/null || true; }

hy_masq() { # on|off
  local act=${1:-} id page
  [[ $act == on || $act == off ]] || die "kit net masq on|off"
  id=$(api GET inbounds/list | jq -r '[.[] | select(.protocol == "hysteria")][0].id // empty')
  [[ -n $id ]] || die "На сервере нет Hysteria2."
  if [[ $act == on ]]; then
    page=$(cat /var/www/kit/index.html 2>/dev/null || true)
    [[ -n $page ]] || page='<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Cumulo Cloud</title></head><body style="font-family:sans-serif;text-align:center;margin-top:20vh"><h1>Cumulo Cloud</h1><p>Service status: all systems operational.</p></body></html>'
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end) | .hysteriaSettings.masquerade = {type: "string", content: $c, statusCode: 200, headers: {"content-type": "text/html; charset=utf-8"}})' --arg c "$page" \
      || die "Панель не приняла изменение. Ничего не изменилось."
    say "Hysteria2 теперь отвечает на посторонний HTTP/3-запрос страницей сайта."
  else
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end) | del(.hysteriaSettings.masquerade))' || die "Панель не приняла изменение."
    say "Маскировка Hysteria2 выключена."
  fi
}

# ---------- DNS в подписках ----------
# Clash/Mihomo: безопасный dns добавляет kit-sub. Xray JSON: dns берётся из настройки панели subJsonDns (по умолчанию – обычный
# UDP на 8.8.8.8), ставим DoH. Запросы идут по правилам клиента, то есть через прокси.
DNS_XRAY='{"servers":[{"address":"https://1.1.1.1/dns-query","skipFallback":false},{"address":"https://8.8.8.8/dns-query","skipFallback":true}],"queryStrategy":"UseIP","tag":"dns_out"}'

net_dns() { # [on|off]
  local act=${1:-} all cur
  all=$(api POST setting/all '{}')
  cur=$(jq -r '.subJsonDns // ""' <<<"$all")
  case $act in
    "")
      if [[ -n $cur ]]; then echo "DNS в подписках: DoH через прокси (Clash – от kit-sub, Xray JSON – настройка панели). Выключить: kit net dns off"
      else echo "DNS в подписке Xray JSON: обычный UDP 8.8.8.8 (по умолчанию панели). Включить DoH: kit net dns on"; fi ;;
    on)
      [[ -z $cur ]] || { say "DNS уже настроен (DoH)."; return 0; }
      api POST setting/update "$(jq -c --arg d "$DNS_XRAY" '.subJsonDns = $d' <<<"$all")" >/dev/null || die "Панель не приняла настройку."
      systemctl restart x-ui; panel_healthy || warn "Панель не ответила после перезапуска: проверьте kit check."
      say "DNS в подписках: DoH через прокси. Клиенты подхватят при обновлении подписки." ;;
    off)
      api POST setting/update "$(jq -c '.subJsonDns = ""' <<<"$all")" >/dev/null || die "Панель не приняла настройку."
      systemctl restart x-ui; panel_healthy || true
      say "Вернул DNS панели по умолчанию." ;;
    *) die "kit net dns [on|off]" ;;
  esac
}

# ---------- панель и подписка: по IP или по домену ----------
# Со своим доменом (режим «всё на 443») заход по имени домена попадает к сайту-прикрытию. Панель и подписка по
# умолчанию открываются по IP; `kit net panel domain` добавляет их и в блок домена (сертификат Let's Encrypt домена),
# `kit net panel ip` возвращает как было. Пути у них секретные, как и на IP.

PANEL_CONF=/etc/nginx/conf.d/kit.conf

# Разбор и пересборка блока домена в конфиге nginx. info – домен, сертификат, ключ; render – новый текст конфига.
panel_conf_py() {
  python3 - "$@" <<'PY'
import re, sys
op, conf = sys.argv[1], sys.argv[2]
text = open(conf).read()

def match_brace(t, start):
    depth = 0
    for j in range(start, len(t)):
        if t[j] == "{":
            depth += 1
        elif t[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    return -1

def servers(t):
    out, i = [], 0
    while True:
        m = re.search(r"^server\s*\{", t[i:], re.M)
        if not m:
            return out
        a = i + m.start()
        b = match_brace(t, a)
        out.append((a, b))
        i = b

blocks = servers(text)
web = next((b for b in blocks if "server_name _;" in text[b[0]:b[1]]), None)
steal = next((b for b in blocks if "server_name _;" not in text[b[0]:b[1]] and re.search(r"server_name\s+\S+;", text[b[0]:b[1]])), None)
if steal is None:
    sys.exit(2)
sb = text[steal[0]:steal[1]]
domain = re.search(r"server_name\s+(\S+);", sb).group(1)
cert = re.search(r"ssl_certificate\s+(\S+);", sb).group(1)
key = re.search(r"ssl_certificate_key\s+(\S+);", sb).group(1)
port = re.search(r"listen\s+127\.0\.0\.1:(\d+)", sb).group(1)
if op == "info":
    print(domain, cert, key)
    sys.exit(0)
mode, sub_path, panel_path = sys.argv[3], sys.argv[4], sys.argv[5]
def location(t, path):
    m = re.search(r"^[ \t]*location\s+" + re.escape(path) + r"\s*\{", t, re.M)
    if not m:
        return ""
    b = match_brace(t, m.end() - 1)
    return t[m.start():b]
if mode == "domain":
    wb = text[web[0]:web[1]] if web else ""
    locs = "\n".join(x for x in (location(wb, sub_path), location(wb, panel_path)) if x)
    if not locs:
        sys.exit(3)
    new = f"""server {{
    listen 127.0.0.1:{port} ssl http2 proxy_protocol;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    absolute_redirect off;
    access_log off;
    # kit:panel-on-domain
{locs}
    location / {{
        root /var/www/kit;
        index index.html;
    }}
}}"""
else:
    new = f"""server {{
    listen 127.0.0.1:{port} ssl http2;
    server_name {domain};
    ssl_certificate {cert};
    ssl_certificate_key {key};
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    access_log off;
    location / {{
        root /var/www/kit;
        index index.html;
    }}
}}"""
sys.stdout.write(text[:steal[0]] + new + text[steal[1]:])
PY
}

kit_env_set() { # ключ значение: меняет или добавляет строку в /etc/kit/kit.env
  python3 - "$KIT_ENV" "$1" "$2" <<'PY'
import re, shlex, sys
p, k, v = sys.argv[1:4]
lines = open(p).read().splitlines()
new = f"{k}={shlex.quote(v)}"
for i, l in enumerate(lines):
    if l.startswith(k + "="):
        lines[i] = new
        break
else:
    lines.append(new)
open(p, "w").write("\n".join(lines) + "\n")
PY
}

net_panel() { # [domain|ip]
  local want=${1:-} info domain cert key cur new tmp bak rid panel_path old_host new_host all
  [[ ${SINGLE:-no} == yes && -f $PANEL_CONF ]] || die "Работает в режиме «всё на 443» со своим доменом (--domain при установке)."
  info=$(panel_conf_py info "$PANEL_CONF") || die "В настройках nginx нет блока своего домена: панель по домену доступна только при установке с --domain."
  read -r domain cert key <<<"$info"
  cur=${PANEL_ON:-ip}
  if [[ -z $want ]]; then
    if [[ $cur == domain ]]; then echo "Панель и подписка открываются по домену $domain (вернуть на IP: kit net panel ip)"
    else echo "Панель и подписка открываются по IP ${HOST:-?}; домен $domain – сайт-прикрытие (открывать и по домену: kit net panel domain)"; fi
    return 0
  fi
  [[ $want == domain || $want == ip ]] || die "kit net panel [domain|ip]"
  [[ $want != "$cur" ]] || { say "Уже так: панель и подписка по $([[ $want == domain ]] && echo "домену $domain" || echo "IP")."; return 0; }
  panel_path=/${XUI_WEB_BASE_PATH#/}; panel_path=${panel_path%/}/
  if [[ $want == domain ]]; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -qx "$(host_ip)" || die "Домен $domain не указывает на этот сервер ($(host_ip)). Исправьте A-запись и повторите."
    [[ -s $cert && -s $key ]] || die "Нет сертификата домена ($cert) – не трогаю nginx."
  fi
  tmp=$(mktemp); bak=$(mktemp); cp -p "$PANEL_CONF" "$bak"
  panel_conf_py render "$PANEL_CONF" "$want" "$SUB_PATH" "$panel_path" >"$tmp" || { rm -f "$tmp" "$bak"; die "Не удалось собрать настройки nginx. Ничего не изменилось."; }
  rid=$(sni_targets | awk -F'\t' '$2 == "self" && $3 == "REALITY" {print $1; exit}')
  [[ -n $rid ]] || { rm -f "$tmp" "$bak"; die "Не нашёл REALITY со своим доменом."; }
  # Передача настоящего IP клиента сайту домена (PROXY protocol) нужна, чтобы панель видела, кто заходит.
  local xv=0; [[ $want == domain ]] && xv=1
  panel_revert() { cat "$bak" >"$PANEL_CONF"; inbound_patch "$rid" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.xver = $x)' --argjson x "$((1 - xv))" || true; nginx -t >/dev/null 2>&1 && systemctl reload nginx || true; }
  if [[ $want == domain ]]; then
    cat "$tmp" >"$PANEL_CONF"
    nginx -t >/dev/null 2>&1 || { cat "$bak" >"$PANEL_CONF"; rm -f "$tmp" "$bak"; die "nginx не принял настройки. Ничего не изменилось."; }
    inbound_patch "$rid" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.xver = $x)' --argjson x 1 || { cat "$bak" >"$PANEL_CONF"; rm -f "$tmp" "$bak"; die "Панель не приняла изменение. Ничего не изменилось."; }
    systemctl reload nginx || { panel_revert; rm -f "$tmp" "$bak"; die "nginx не перезагрузился. Всё возвращено."; }
  else
    inbound_patch "$rid" '.streamSettings |= ((if type == "string" then fromjson else . end) | .realitySettings.xver = $x)' --argjson x 0 || { rm -f "$tmp" "$bak"; die "Панель не приняла изменение. Ничего не изменилось."; }
    cat "$tmp" >"$PANEL_CONF"
    if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx; then panel_revert; rm -f "$tmp" "$bak"; die "nginx не принял настройки. Всё возвращено."; fi
  fi
  rm -f "$tmp" "$bak"
  # Ссылки: адрес подписки в kit, панели и файле с данными входа.
  old_host=${HOST}; new_host=$domain
  if [[ $want == ip ]]; then old_host=$domain; new_host=${HOST}; fi
  kit_env_set PANEL_ON "$want"
  kit_env_set SUB_BASE "https://$([[ $want == domain ]] && echo "$domain" || echo "$HOST")${SUB_PATH}"
  all=$(api POST setting/all '{}')
  api POST setting/update "$(jq -c --arg u "https://$([[ $want == domain ]] && echo "$domain" || echo "$HOST")${SUB_PATH}" '.subURI = $u' <<<"$all")" >/dev/null || warn "Не обновил адрес подписки в панели."
  [[ -f /root/3x-ui.txt ]] && python3 - /root/3x-ui.txt "https://$old_host" "https://$new_host" <<'PY'
import sys
p, a, b = sys.argv[1:4]
s = open(p).read()
open(p, "w").write(s.replace(a + "/", b + "/").replace(a + ":", b + ":"))
PY
  if [[ $want == domain ]]; then
    say "Панель и подписка теперь открываются и по домену $domain."
    echo "Панель:   https://$domain$panel_path"
    echo "Подписка: https://$domain${SUB_PATH}ПОДПИСКА_ПОЛЬЗОВАТЕЛЯ  (ссылки: kit user link имя)"
    echo "По IP они тоже работают. Вернуть как было: kit net panel ip"
  else
    say "Панель и подписка снова только по IP ${HOST}."
    echo "Панель:   https://${HOST}$panel_path"
  fi
}

# ---------- kit net: протоколы, порты, сайт маскировки, отпечаток ----------

net_main_name() { case $1 in REALITY | XHTTP | Hysteria2) return 0 ;; *) return 1 ;; esac; }

net_resolve() { # короткое имя → название подключения
  case ${1,,} in
    reality) echo REALITY ;; reality2 | reality-2) echo REALITY-2 ;; xhttp) echo XHTTP ;; hy2 | hysteria2 | hysteria) echo Hysteria2 ;;
    ws | vless-ws) echo VLESS-WS ;; grpc | trojan | trojan-grpc) echo Trojan-gRPC ;; vmess | vmess-ws) echo VMess-WS ;;
    ss | shadowsocks) echo Shadowsocks ;; tuic) echo TUIC ;; wg | wireguard) echo WireGuard ;;
    awg | amneziawg) echo AmneziaWG ;; awg3 | amneziawg-3.1) echo AmneziaWG-3.1 ;; mtproto) echo MTProto ;;
    *) echo "$1" ;;
  esac
}

inbound_body_of() { # строка подключения (json) → тело для inbounds/update
  jq -c '{id, remark, enable, listen, port, protocol, expiryTime, total,
    settings: (.settings | if type == "string" then . else tojson end),
    streamSettings: (.streamSettings | if type == "string" then . else tojson end),
    sniffing: (.sniffing | if type == "string" then . else tojson end)}' <<<"$1"
}

inbound_patch() { # id фильтр-jq [аргументы jq...]: меняет подключение, ошибка – код возврата, не выход
  local id=$1 filter=$2 row new
  shift 2
  row=$(api GET inbounds/list | jq -c --argjson id "$id" '.[] | select(.id == $id)')
  [[ -n $row ]] || return 1
  new=$(jq -c "$@" "$filter" <<<"$row") || return 1
  (api POST "inbounds/update/$id" "$(inbound_body_of "$new")" >/dev/null) || return 1
}

net_show() {
  local list name port proto listen en sni fp shown_reality2=no mark note group fpl=""
  list=$(api GET inbounds/list)
  printf '%s %s %s %s\n' "$(padr Протоколы 22)" "$(padr Порт 12)" "$(padr Статус 8)" "Заметка"
  for group in main spare; do
    if [[ $group == main ]]; then echo "Основные"; else echo "Запасные"; fi
    while IFS='|' read -r name port proto listen en sni fp; do
      [[ -n $name ]] || continue
      if net_main_name "$name"; then [[ $group == main ]] || continue; else [[ $group == spare ]] || continue; fi
      [[ $name == REALITY-2 ]] && shown_reality2=yes
      if [[ $listen == 127.0.0.1 ]]; then mark="443/tcp"; else mark="$port/$(port_net "$proto")"; fi
      [[ $(port_net "$proto") == both ]] && mark=$port
      note=""
      [[ -z $sni ]] || note="сайт: $sni"
      [[ -n $fp && -z $fpl ]] && fpl=$fp
      printf '  %s %s %s %s\n' "$(padr "$name" 20)" "$(padr "$mark" 12)" "$(padr "$([[ $en == true ]] && echo вкл || echo выкл)" 8)" "$note"
    done < <(jq -r '.[] | (.streamSettings | if type == "string" then fromjson else . end) as $s
      | [.remark, .port, .protocol, .listen, .enable, ($s.realitySettings.serverNames[0] // ""),
         ($s.realitySettings.settings.fingerprint // $s.tlsSettings.settings.fingerprint // "")] | map(tostring) | join("|")' <<<"$list")
  done
  [[ $shown_reality2 == yes ]] || printf '  %s %s %s %s\n' "$(padr REALITY-2 20)" "$(padr – 12)" "$(padr выкл 8)" "включить: kit net on reality2"
  echo
  echo "Отпечаток клиента: ${fpl:-?} (сменить: kit net fp firefox)"
  if [[ ${SINGLE:-no} == yes && -f $PANEL_CONF ]] && panel_conf_py info "$PANEL_CONF" >/dev/null 2>&1; then
    net_panel
  fi
  if jq -e 'any(.[]; .protocol == "hysteria")' <<<"$list" >/dev/null; then
    if [[ -n $(hy_masq_state) ]]; then echo "Hysteria2 отвечает на посторонний запрос страницей сайта (выключить: kit net masq off)"
    else echo "Hysteria2 без маскировки под сайт (включить: kit net masq on)"; fi
  fi
}

net_toggle() { # on|off имя [-y]
  local act=$1 name row id en listen proto port net yes=no
  shift
  [[ -n ${1:-} ]] || die "kit net $act имя (например: kit net $act vmess-ws). Список: kit net"
  name=$(net_resolve "$1"); [[ ${2:-} == -y || ${2:-} == --yes ]] && yes=yes
  row=$(api GET inbounds/list | jq -c --arg n "${name,,}" '[.[] | select((.remark | ascii_downcase) == $n)][0] // empty')
  if [[ -z $row ]]; then
    if [[ $name == REALITY-2 && $act == on ]]; then reality_add; return; fi
    die "Нет подключения «$name». Список: kit net"
  fi
  id=$(jq -r '.id' <<<"$row"); en=$(jq -r '.enable' <<<"$row"); listen=$(jq -r '.listen' <<<"$row")
  proto=$(jq -r '.protocol' <<<"$row"); port=$(jq -r '.port' <<<"$row"); net=$(port_net "$proto")
  if [[ $act == off ]]; then
    [[ $en == true ]] || { say "$name уже выключен."; return 0; }
    if net_main_name "$name" && [[ $yes == no ]]; then
      if [[ -t 0 ]]; then
        local ans; read -r -p "$name – основной протокол. Выключить? [y/N] " ans
        [[ $ans =~ ^[yYдД]$ ]] || { echo "Отменено."; return 0; }
      else die "$name – основной протокол. Выключить: kit net off $1 -y"; fi
    fi
    (api POST "inbounds/setEnable/$id" '{"enable":false}' >/dev/null) || die "Панель не приняла изменение. Ничего не изменилось."
    if [[ $listen != 127.0.0.1 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then port_ufw delete "$port" "$net"; fi
    if [[ $listen != 127.0.0.1 ]]; then say "$name выключен, порт $port/$net закрыт. Вернуть: kit net on $1"; else say "$name выключен. Вернуть: kit net on $1"; fi
    echo "Из подписки пропадёт при её обновлении в приложении."
  else
    [[ $en == true ]] && { say "$name уже включён."; return 0; }
    if [[ $listen != 127.0.0.1 ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then port_ufw allow "$port" "$net"; fi
    (api POST "inbounds/setEnable/$id" '{"enable":true}' >/dev/null) || die "Панель не приняла изменение. Ничего не изменилось."
    say "$name включён."
  fi
}

net_fp() { # отпечаток
  local f=${1:-} n=0 id old
  [[ -n $f ]] || die "kit net fp отпечаток (chrome, firefox, safari, edge, ios, android, qq, 360, random, randomized)"
  f=${f,,}
  [[ $f =~ ^(chrome|firefox|safari|edge|ios|android|qq|360|random|randomized)$ ]] || die "Неизвестный отпечаток «$f». Доступны: chrome, firefox, safari, edge, ios, android, qq, 360, random, randomized."
  old=$(api GET inbounds/list | jq -r '[.[] | (.streamSettings | if type == "string" then fromjson else . end) | (.realitySettings.settings.fingerprint // .tlsSettings.settings.fingerprint // empty)][0] // "?"')
  while read -r id; do
    inbound_patch "$id" '.streamSettings |= ((if type == "string" then fromjson else . end)
      | (if .realitySettings.settings then .realitySettings.settings.fingerprint = $f else . end)
      | (if .tlsSettings.settings then .tlsSettings.settings.fingerprint = $f else . end)
      | (if .externalProxy then .externalProxy |= map(if has("fingerprint") then .fingerprint = $f else . end) else . end))' --arg f "$f" \
      && n=$((n + 1))
  done < <(api GET inbounds/list | jq -r '.[] | select((.streamSettings | if type == "string" then fromjson else . end) | (.security == "reality" or .security == "tls")) | .id')
  say "Отпечаток $old → ${B}$f${N}, обновлено подключений: $n."
  echo "Подписка обновится сама; вручную сохранённые ссылки замените (kit user link имя)."
  echo "Меняйте, если связь пропала сразу у многих, а не из-за одного неудачного раза."
}

cmd_net() {
  local sub=${1:-}
  [[ -z $sub ]] || shift
  case ${sub,,} in
    "") net_show ;;
    site) [[ $# -gt 0 ]] || set -- --nearby; sni_rotate "$@" ;;
    port) port_set "$@" ;;
    off | on) net_toggle "${sub,,}" "$@" ;;
    fp) net_fp "$@" ;;
    masq) hy_masq "$@" ;;
    dns) net_dns "$@" ;;
    panel) net_panel "$@" ;;
    vision) case ${1:-} in on) cmd_vision --all ;; off) cmd_vision --all off ;; *) die "kit net vision on|off" ;; esac ;;
    *) die "kit net [site | port имя порт | off имя | on имя | fp отпечаток | masq on|off | dns on|off | panel domain|ip | vision on|off]" ;;
  esac
}

# ---------- меню (как у x-ui) ----------

BOX_W=48
box_rule() { local i; for ((i = 0; i < BOX_W; i++)); do printf '─'; done; }
box_top() { printf '╔'; box_rule; printf '╗\n'; }
box_bot() { printf '╚'; box_rule; printf '╝\n'; }
box_sep() { printf '│'; box_rule; printf '│\n'; }
padr() { local n=$(($2 - ${#1})); ((n < 0)) && n=0; printf '%s%*s' "$1" "$n" ''; }  # по символам: printf %-Ns считает байты
box_line() { printf '│  %s│\n' "$(padr "$1" $((BOX_W - 2)))"; }
box() { # заголовок, затем пункты; пустой пункт – разделитель
  local t=$1 l; shift
  box_top; box_line "$t"; box_sep
  for l in "$@"; do if [[ -z $l ]]; then box_sep; else box_line "$l"; fi; done
  box_bot
}
ask_tty() { read -r -p "$1" REPLY </dev/tty || exit 0; }
ask_num() { ask_tty "$1"; REPLY=${REPLY//[[:space:]]/}; }
pause() { read -r -p "${D}Enter – в меню${N} " _ </dev/tty || exit 0; }
run_action() { ( "$@" ) || true; }

menu_status() {
  local sni users st auto
  sni=$(sni_targets 2>/dev/null | awk -F'\t' '$2 == "reality" || $2 == "self" {print $4; exit}' || true)
  users=$(clients 2>/dev/null | jq '[.[] | select(.email | test("-awg[0-9]*$") | not)] | length' 2>/dev/null || echo "?")
  if systemctl is-active -q x-ui; then st="панель работает"; else st="панель НЕ работает"; fi
  if auto_enabled; then auto=вкл; else auto=выкл; fi
  echo "Сервер: ${HOST:-?} · Сайт маскировки: ${sni:--}"
  echo "Состояние: $st · Xray $(xray_version 2>/dev/null || echo '?') · пользователей $users · автообновление $auto"
}

pick_user() {
  cmd_list
  ask_tty "Имя пользователя: "
  PICK=${REPLY//[[:space:]]/}
  [[ -n $PICK ]] || return 1
  valid_name "$PICK"
}

u_add() {
  local name gb days dev a=()
  ask_tty "Имя пользователя: "; name=${REPLY//[[:space:]]/}
  ask_tty "Лимит трафика, ГБ (Enter – без лимита): "; gb=${REPLY//[[:space:]]/}
  ask_tty "Срок, дней (Enter – без срока): "; days=${REPLY//[[:space:]]/}
  ask_tty "Устройств (Enter – без ограничения): "; dev=${REPLY//[[:space:]]/}
  [[ -z $gb ]] || a+=(--gb "$gb"); [[ -z $days ]] || a+=(--days "$days"); [[ -z $dev ]] || a+=(--devices "$dev")
  cmd_add "$name" "${a[@]}"
}
u_link() {
  pick_user || return 0
  ask_num "1 – ссылки, 2 – AmneziaVPN, 3 – Telegram [1]: "
  case ${REPLY:-1} in 2) cmd_link "$PICK" --amnezia ;; 3) cmd_link "$PICK" --telegram ;; *) cmd_link "$PICK" ;; esac
}
u_limit() {
  local gb days dev a=()
  pick_user || return 0
  echo "Enter – не менять, 0 – без ограничения."
  ask_tty "Лимит трафика, ГБ: "; gb=${REPLY//[[:space:]]/}
  ask_tty "Срок, дней: "; days=${REPLY//[[:space:]]/}
  ask_tty "Устройств: "; dev=${REPLY//[[:space:]]/}
  [[ -z $gb ]] || a+=(--gb "$gb"); [[ -z $days ]] || a+=(--days "$days"); [[ -z $dev ]] || a+=(--devices "$dev")
  ((${#a[@]})) || { echo "Ничего не изменено."; return 0; }
  cmd_limit "$PICK" "${a[@]}"
}
u_toggle() {
  pick_user || return 0
  ask_num "1 – выключить, 2 – включить: "
  case $REPLY in 1) cmd_toggle "$PICK" false ;; 2) cmd_toggle "$PICK" true ;; *) echo "Отменено." ;; esac
}
u_del() { pick_user || return 0; cmd_del "$PICK"; }

menu_users() {
  local c
  while :; do
    echo
    box "Пользователи" "1. Список (трафик, срок, статус)" "2. Добавить" "3. Показать ссылки" "4. Изменить лимит" "5. Выключить или включить" "6. Удалить" "" "0. Назад"
    ask_num "Выбор [0-6]: "; c=$REPLY
    case $c in
      1) run_action cmd_list; pause ;;
      2) run_action u_add; pause ;;
      3) run_action u_link; pause ;;
      4) run_action u_limit; pause ;;
      5) run_action u_toggle; pause ;;
      6) run_action u_del; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

pick_proto() { # PICK = название подключения (в том числе ещё не созданный REALITY-2)
  local -a names=(); local i n en
  mapfile -t names < <(api GET inbounds/list | jq -r '.[] | [.remark, (if .enable then "вкл" else "выкл" end)] | @tsv')
  names+=("REALITY-2"$'\t'"создать")
  i=0
  for n in "${names[@]}"; do
    i=$((i + 1))
    if [[ $n == REALITY-2$'\t'* ]] && api GET inbounds/list | jq -e 'any(.[]; .remark == "REALITY-2")' >/dev/null; then names[i-1]=""; i=$((i)); continue; fi
    printf '  %2d  %-16s %s\n' "$i" "${n%%$'\t'*}" "${n#*$'\t'}"
  done
  ask_num "Номер: "
  [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#names[@]})) && [[ -n ${names[REPLY-1]} ]] || { echo "Отменено."; return 1; }
  PICK=${names[REPLY-1]%%$'\t'*}
}

n_site() {
  ask_num "1 – подобрать автоматически (сначала соседи по подсети), 2 – свой сайт [1]: "
  if [[ ${REPLY:-1} == 2 ]]; then
    ask_tty "Адрес сайта (например example.com): "
    [[ -n ${REPLY//[[:space:]]/} ]] || { echo "Отменено."; return 0; }
    sni_rotate "${REPLY//[[:space:]]/}"
  else
    sni_rotate --nearby
  fi
}
n_port() { local p; pick_proto || return 0; p=$PICK; ask_num "Новый порт: "; port_set "$p" "$REPLY"; }
n_toggle() {
  local en
  pick_proto || return 0
  en=$(api GET inbounds/list | jq -r --arg n "$PICK" '[.[] | select(.remark == $n)][0].enable // "none"')
  case $en in
    true) net_toggle off "$PICK" ;;
    false) net_toggle on "$PICK" ;;
    *) net_toggle on "$PICK" ;;
  esac
}
n_panel() {
  net_panel
  ask_num "1 – открывать по домену, 2 – только по IP, Enter – оставить: "
  case $REPLY in 1) net_panel domain ;; 2) net_panel ip ;; esac
}
n_fp() {
  local -a fps=(chrome firefox safari edge ios android qq 360 random randomized); local i
  for i in "${!fps[@]}"; do printf '  %2d  %s\n' "$((i + 1))" "${fps[$i]}"; done
  ask_num "Номер: "
  [[ $REPLY =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= ${#fps[@]})) || { echo "Отменено."; return 0; }
  net_fp "${fps[REPLY-1]}"
}

menu_net() {
  local c
  while :; do
    echo
    box "Протоколы, порты и маскировка" "1. Показать протоколы и порты" "2. Сменить сайт маскировки" "3. Сменить порт протокола" "4. Выключить или включить протокол" "5. Сменить отпечаток клиента" "6. Второй REALITY на высоком порту" "7. Панель и подписка: по IP или по домену" "" "0. Назад"
    ask_num "Выбор [0-7]: "; c=$REPLY
    case $c in
      1) run_action net_show; pause ;;
      2) run_action n_site; pause ;;
      3) run_action n_port; pause ;;
      4) run_action n_toggle; pause ;;
      5) run_action n_fp; pause ;;
      6) run_action net_toggle on reality2; pause ;;
      7) run_action n_panel; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

menu_check() {
  local c
  while :; do
    echo
    box "Проверка сервера" "1. Быстрая проверка" "2. Глубокая (подключиться клиентом)" "3. Исправить безопасное" "" "0. Назад"
    ask_num "Выбор [0-3]: "; c=$REPLY
    case $c in
      1) run_action cmd_check; pause ;;
      2) run_action cmd_check --deep; pause ;;
      3) run_action cmd_fix; pause ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

menu_auto() {
  local ans
  if auto_enabled; then
    ask_tty "Автообновление сейчас включено (ночью, только подписанные релизы). Выключить? [y/N] "
    [[ $REPLY =~ ^[yYдД]$ ]] && auto_off && say "Автообновление выключено. Обновляться вручную: пункт 4."
  else
    ask_tty "Автообновление сейчас выключено. Включить? [y/N] "
    [[ $REPLY =~ ^[yYдД]$ ]] && auto_on && say "Автообновление включено."
  fi
  return 0
}

menu_main() {
  local c
  while :; do
    echo
    box "3X-UI KIT $KIT_VERSION – управление сервером" "1. Пользователи" "2. Протоколы, порты и маскировка" "3. Проверка сервера" "" \
      "4. Обновить kit и подписку" "5. Обновить панель 3X-UI" "6. Автообновление: включить или выключить" "" \
      "7. Резервная копия" "8. Версии" "" "9. Панель 3X-UI (меню x-ui)" "0. Выход"
    echo
    menu_status
    echo
    ask_num "Выбор [0-9]: "; c=$REPLY
    case $c in
      1) menu_users ;;
      2) menu_net ;;
      3) menu_check ;;
      4) run_action cmd_update; pause ;;
      5) run_action panel_update; pause ;;
      6) run_action menu_auto; pause ;;
      7) run_action cmd_backup; pause ;;
      8) run_action cmd_version; pause ;;
      9) command -v x-ui >/dev/null && x-ui || echo "Меню x-ui не найдено." ;;
      0 | "") return 0 ;;
      *) echo "Нет такого пункта." ;;
    esac
  done
}

usage() {
  cat <<EOF
${B}3X-UI KIT $KIT_VERSION${N} – команды (то же самое есть в меню: просто ${B}kit${N})

  kit                        меню
  kit user …                 add, list, link, limit, on, off, del
  kit net …                  протоколы, порты, сайт маскировки, отпечаток
  kit check [--deep|--fix]   проверка сервера
  kit update [--panel]       обновление (--auto и --manual – автообновление)
  kit backup                 копия сервера
  kit version                версии
EOF
}

# Регистр и «users» вместо «user» не должны ломать команду; имя пользователя (третье слово) не трогаем.
cmd_key="${1:-} ${2:-}"; cmd_key=${cmd_key,,}; cmd_key=${cmd_key/users /user }
case "$cmd_key" in
  " ") if [[ -t 0 && -t 1 ]]; then menu_main; else usage; fi ;;
  "user add") shift 2; cmd_add "$@" ;;
  "user list") cmd_list; update_hint ;;
  "user link") shift 2; cmd_link "$@" ;;
  "user limit") shift 2; cmd_limit "$@" ;;
  "user off") cmd_toggle "${3:-}" false ;;
  "user on") cmd_toggle "${3:-}" true ;;
  "user del") shift 2; cmd_del "$@" ;;
  "user enforce") shift 2; cmd_enforce "$@" ;;
  "user vision") shift 2; cmd_vision "$@" ;;
  "net "*) shift; cmd_net "$@" ;;
  "sni rotate") shift 2; sni_rotate "$@" ;;
  "sni "*) [[ -z ${2:-} ]] || die "Команда: kit net site"; sni_show ;;
  "port set") shift 2; port_set "$@" ;;
  "port "*) [[ -z ${2:-} ]] || die "Команда: kit net port имя порт"; net_show ;;
  "reality add") shift 2; reality_add "$@" ;;
  "panel update") shift 2; panel_update "$@" ;;
  "__limit-timer on") limit_timer_on ;;
  "__links "*) links_block "${2:-}" "${3:-}" ;;
  "update "*) shift; cmd_update "$@" ;;
  "backup "*) cmd_backup ;;
  "check "*) shift; cmd_check "$@" ;;
  "fix "*) shift; cmd_fix "$@" ;;
  "version "*|"--version "*|"-v "*) cmd_version ;;
  *) usage; update_hint ;;
esac
