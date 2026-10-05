#!/usr/bin/env bash
# Слежение за чужими версиями: сравнивает закреплённые в скриптах версии с последними релизами.
# Ничего не меняет, только печатает. Запуск: tools/check-upstream.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

latest() { # репозиторий шаблон-тега (регулярка)
  git ls-remote --tags --refs "https://github.com/$1" 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' | grep -E "$2" | sort -V | tail -1
}
pinned() { sed -n "s/^$2=\"\(.*\)\"/\1/p" "$1" | head -1; }
row() { # название закреплено последняя
  local mark="  "
  [[ -n $3 && $2 != "$3" ]] && mark="⬆ "
  printf '%s%-12s закреплено %-12s последняя %s\n' "$mark" "$1" "$2" "${3:-?}"
}

echo "Закреплённые версии и последние релизы (⬆ – есть новее, прочитайте список изменений и протестируйте):"
row "3X-UI" "$(pinned scripts/3x-ui.sh XUI_VERSION)" "$(latest MHSanaei/3x-ui '^v[0-9]+\.[0-9]+\.[0-9]+$')"
row "Xray-core" "$(pinned scripts/3x-ui.sh XRAY_CORE)" "$(latest XTLS/Xray-core '^v[0-9]+\.[0-9]+\.[0-9]+$')"
hy=$(pinned scripts/hysteria2.sh HY_VERSION); row "Hysteria" "v$hy" "$(latest apernet/hysteria '^app/v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's#app/##')"
zv=$(sed -n "s#.*zashboard/releases/download/\(v[0-9.]*\)/dist.zip.*#\1#p" tools/lib/mihomo.js | head -1)
row "zashboard" "$zv" "$(latest Zephyruso/zashboard '^v[0-9]+\.[0-9]+\.[0-9]+$')"
printf '  %-12s последняя %s\n' "Mihomo" "$(latest MetaCubeX/mihomo '^v[0-9]+\.[0-9]+\.[0-9]+$')"
printf '  %-12s последняя %s\n' "sing-box" "$(latest SagerNet/sing-box '^v[0-9]+\.[0-9]+\.[0-9]+$')"
echo
echo "Что проверить при новой версии 3X-UI или Xray: tests/matrix (протокол × клиент), kit panel update, kit check."
echo "Новое ядро Xray сначала проверяется клиентами: на тест-сервере с KIT запустите  bash tools/core-compat.sh vX.Y.Z"
echo "(с 26.9.30 REALITY требует от клиента ключ X25519MLKEM768: Mihomo его отправляет, sing-box пока нет). Версия ядра в KIT"
echo "меняется, только когда проверка показывает «работает» у обоих клиентов."
