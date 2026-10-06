# Матрица «протокол × клиент»

Проверяет, что каждый протокол 3X-UI работает с каждым клиентом:
Xray, Mihomo, sing-box и официальным клиентом AmneziaWG. Прогонять на каждой новой версии 3X-UI и Xray.

1. Сервер: чистый Ubuntu в Docker с systemd, на нём `scripts/3x-ui.sh`, затем `mk-inbounds.sh` –
   создаёт через API подключения VLESS XHTTP, WS+TLS, Trojan gRPC, VMess, Shadowsocks 2022,
   Hysteria2, TUIC, WireGuard, AmneziaWG и MTProto.
2. Ссылки: `GET /panel/api/inbounds/allLinks` → `links.txt`.
3. Конфиги клиентов: `PIN=<sha256 сертификата> node matrix-gen.js ../../tools/lib links.txt cases`.
4. Прогон в клиентском контейнере с бинарниками в `/cl`: `bash matrix-run.sh`.
5. AmneziaWG: `awg-set.sh classic|mid|full` меняет обфускацию на сервере.

Без `PIN` (сервер с доверенным сертификатом) клиенты проверяют сертификат как обычно.

## Результат 2026-09-27

3X-UI 3.8.5, Xray 26.6.27, Mihomo 1.19.31, sing-box 1.14.2, amneziawg-tools 3.1.
Сервер поставлен `scripts/3x-ui.sh` с доверенным сертификатом, ссылки взяты из его подписки.

| Протокол | Xray | Mihomo | sing-box |
|---|---|---|---|
| VLESS REALITY | ✓ | ✓ | ✓ |
| Hysteria2 | ✓ | ✓ | ✓ |
| VLESS XHTTP + REALITY | ✓ | ✓ | – |
| VLESS WS + TLS | ✓ | ✓ | ✓ |
| Trojan gRPC + TLS | ✓ | ✓ | ✓ |
| VMess WS + TLS | ✓ | ✓ | ✓ |
| Shadowsocks 2022 | ✓ | ✓ | ✓ |
| TUIC v5 | – | ✓ | ✓ |
| WireGuard | ✓ | ✓ | ✓ | (локально; через интернет к удалённому серверу – ✗ у всех клиентов) |
| AmneziaWG (классика) | – | ✓ | – |
| AmneziaWG 3.1 | – | ✓ | – |

Подписка в формате Clash (User-Agent Clash Verge) – все 11 прокси ✓ в Mihomo.
Официальный клиент AmneziaWG 3.1 подключается к обоим вариантам AmneziaWG.
MTProto: `mtg doctor` – все дата-центры Telegram доступны.
Со своим (самоподписанным) сертификатом подписка Clash от 3X-UI не передаёт Mihomo отпечаток –
TLS-протоколы в ней не работают; ссылки с `pcs` работают.

## Через интернет к удалённому серверу, 2026-09-27

Удалённый сервер Ubuntu 24.04, `scripts/3x-ui.sh` с настоящим сертификатом Let's Encrypt на IP,
клиенты – на Mac через интернет. Подписка-ссылки и подписка Clash: все протоколы ✓, кроме:

- **WireGuard** – ✗ у Xray, Mihomo и sing-box: рукопожатие доходит до сервера, ответ не возвращается.
  Поэтому из набора по умолчанию убран.
- **MTProto** – сервер хостера не достаёт до Telegram, прокси бесполезен; установщик теперь
  проверяет это и пропускает MTProto.
- AmneziaWG (оба варианта) – ✓ в Mihomo и в официальном клиенте AmneziaWG.
