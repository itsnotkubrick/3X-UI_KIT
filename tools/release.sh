#!/usr/bin/env bash
# Подпись релиза 3X-UI KIT. Запускает только автор, на своём компьютере, перед тегом:
#
#   tools/release.sh [~/.ssh/3xui_kit_release]
#
# Проверяет, что версии сходятся и установщик 3X-UI не подменили, пишет SHA256SUMS,
# подписывает его закрытым ключом (ssh-keygen спросит пароль ключа) и сразу проверяет
# подпись открытым ключом, записанным в kit. Сервер 3X-UI KIT ставит обновление, только
# если эта проверка у него тоже сошлась. Закрытый ключ никуда не отправляется.

set -euo pipefail
cd "$(dirname "$0")/.."

die() { printf '✗  %s\n' "$*" >&2; exit 1; }
ok()  { printf '✓  %s\n' "$*"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

key=${1:-$HOME/.ssh/3xui_kit_release}
[[ -f $key ]] || die "Нет закрытого ключа $key. Создать: ssh-keygen -t ed25519 -C \"3X-UI KIT releases\" -f $key"
NS="3x-ui-kit-release"
ID="releases@3x-ui-kit"
FILES=(scripts/3x-ui.sh scripts/hysteria2.sh scripts/kit.sh scripts/kit-sub.py VERSION)

v=$(tr -d '[:space:]' <VERSION)
[[ $v =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "VERSION: $v"
for f in scripts/3x-ui.sh scripts/hysteria2.sh scripts/kit.sh; do
  grep -qx "KIT_VERSION=\"$v\"" "$f" || die "$f: KIT_VERSION не $v"
done
grep -q "^## v$v" CHANGELOG.md || die "В CHANGELOG.md нет раздела ## v$v"
ok "Версия $v во всех скриптах и в CHANGELOG"

[[ -z $(git status --porcelain -- "${FILES[@]}" CHANGELOG.md) ]] || die "Есть незакоммиченные изменения в файлах релиза – сначала коммит."

# Установщик 3X-UI: хеш в скрипте должен совпадать с тем, что сейчас лежит на GitHub.
xv=$(sed -n 's/^XUI_VERSION="\(.*\)"/\1/p' scripts/3x-ui.sh)
xs=$(sed -n 's/^XUI_INSTALL_SHA256="\(.*\)"/\1/p' scripts/3x-ui.sh)
got=$(curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/$xv/install.sh" | sha | awk '{print $1}')
[[ $got == "$xs" ]] || die "Установщик 3X-UI $xv изменился: $got вместо $xs. Проверьте, что поменялось, прежде чем выпускать."
ok "Установщик 3X-UI $xv совпадает с закреплённым SHA256"

# Суммы архивов ядра Xray в скрипте должны совпадать с официальными (.dgst релиза Xray-core).
xc=$(sed -n 's/^XRAY_CORE="\(.*\)"/\1/p' scripts/3x-ui.sh)
for a in 64 arm64-v8a; do
  pin=$(sed -n "s/^  \[$a\]=\([0-9a-f]\{64\}\)\$/\1/p" scripts/3x-ui.sh)
  off=$(curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/$xc/Xray-linux-$a.zip.dgst" | awk '/^SHA2-256=/ {print $2}')
  [[ -n $pin && $pin == "$off" ]] || die "Сумма ядра Xray $xc ($a) в 3x-ui.sh не совпадает с официальной: «$pin» вместо «$off»."
done
ok "Суммы архивов ядра Xray $xc совпадают с официальными"

# Проверенная панель и ядро в kit.sh (kit panel update, kit check): те же версии, что в установщике,
# а суммы архива панели и скрипта меню x-ui – официальные.
kp=$(sed -n 's/^XUI_PIN="\(.*\)"/\1/p' scripts/kit.sh)
[[ $kp == "$xv" ]] || die "XUI_PIN в kit.sh ($kp) не совпадает с XUI_VERSION в 3x-ui.sh ($xv)."
kx=$(sed -n 's/^XRAY_PIN="\(.*\)"/\1/p' scripts/kit.sh)
[[ $kx == "$xc" ]] || die "XRAY_PIN в kit.sh ($kx) не совпадает с XRAY_CORE в 3x-ui.sh ($xc)."
for a in amd64 arm64; do
  pin=$(sed -n "s/^  \[$a\]=\([0-9a-f]\{64\}\)\$/\1/p" scripts/kit.sh)
  off=$(curl -fsSL "https://github.com/MHSanaei/3x-ui/releases/download/$kp/x-ui-linux-$a.tar.gz.sha256" | awk 'NR == 1 {print $1}')
  [[ -n $pin && $pin == "$off" ]] || die "Сумма архива панели $kp ($a) в kit.sh не совпадает с официальной: «$pin» вместо «$off»."
done
shs=$(sed -n 's/^XUI_SH_SHA256=\(.*\)/\1/p' scripts/kit.sh)
got=$(curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/$kp/x-ui.sh" | sha | awk '{print $1}')
[[ $shs == "$got" ]] || die "Сумма x-ui.sh $kp в kit.sh не совпадает с официальной: «$shs» вместо «$got»."
ok "Панель $kp и ядро $kx в kit.sh совпадают с установщиком и официальными суммами"

# В kit записан открытый ключ, которым подписываем.
signers() { awk '/^KIT_SIGNERS=\(/ {on = 1; next} on && /^\)/ {exit} on && /^ *"/ {gsub(/^ *"|"$/, ""); print}' "$1"; }
[[ -n $(signers scripts/kit.sh) ]] || die "В scripts/kit.sh пустой KIT_SIGNERS: впишите туда открытую часть ключа ($key.pub)."
pub=$(ssh-keygen -y -f "$key" | awk '{print $1, $2}')
signers scripts/kit.sh | awk '{print $1, $2}' | grep -qxF "$pub" || die "Ключа $key нет в KIT_SIGNERS – серверы не примут такую подпись."
ok "Ключ подписи записан в kit"

{ echo "# 3X-UI KIT $v"; sha "${FILES[@]}"; } >SHA256SUMS
rm -f SHA256SUMS.sig
ssh-keygen -Y sign -f "$key" -n "$NS" SHA256SUMS >/dev/null
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
signers scripts/kit.sh | while read -r k; do printf '%s namespaces="%s" %s\n' "$ID" "$NS" "$k"; done >"$tmp"
ssh-keygen -Y verify -f "$tmp" -I "$ID" -n "$NS" -s SHA256SUMS.sig <SHA256SUMS >/dev/null || die "Подпись не прошла проверку."
ok "SHA256SUMS подписан и проверен так же, как это сделает сервер"
echo
cat SHA256SUMS
echo
echo "Дальше:"
echo "  git add SHA256SUMS SHA256SUMS.sig && git commit -m \"Релиз v$v: подпись\""
echo "  git tag v$v && git push origin main v$v"
