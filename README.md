<div align="center">

<img alt="3X-UI KIT" src="manuals/assets/banner.svg" width="820">

**Установка 3X-UI одной командой: 11 протоколов, один порт 443, одна подписка на всё**

[![Протоколов](https://img.shields.io/badge/протоколов-11-93E06F?labelColor=221B17)](manuals/3x-ui.md#протоколы)
[![3X-UI](https://img.shields.io/badge/3X--UI-v3.9.0-93E06F?labelColor=221B17)](https://github.com/MHSanaei/3x-ui)
[![Обновлено](https://img.shields.io/github/last-commit/itsnotkubrick/3X-UI_KIT?label=обновлено&color=93E06F&labelColor=221B17)](https://github.com/itsnotkubrick/3X-UI_KIT/commits)

[Возможности](#возможности) · [Установка](#установка) · [Команды](#команды-kit) · [Роутер](#vpn-на-роутере) · [Генератор](#генератор-конфигов-для-роутера) · [Полезное](#полезное) · [Поддержать](#поддержать-проект)

</div>

---

> [!TIP]
> **Вышла версия 1.1.2:** исправление установки на чистом сервере и мелкие починки.
> [Что нового](https://github.com/itsnotkubrick/3X-UI_KIT/releases/tag/v1.1.2) ·
> сервер на 1.1 и 1.1.1 обновится сам этой ночью, а на 1.0 одной командой:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/v1.1.2/scripts/kit.sh -o /usr/local/bin/kit && chmod 755 /usr/local/bin/kit && kit update
> ```

> [!NOTE]
> **Проект – набор скриптов с открытым кодом.** Он не оказывает услуг связи и не предоставляет доступ
> к серверам. Вы ставите его на собственный сервер и сами отвечаете за соблюдение законодательства
> своей страны.

**3X-UI KIT** превращает чистый VPS в готовый VPN-сервер за несколько минут. Скрипт ставит
официальную панель [3X-UI](https://github.com/MHSanaei/3x-ui), настраивает все популярные
протоколы, сертификат и файрвол и выдаёт одну ссылку-подписку. Её можно вставить в любое
приложение – оно само получит подходящие ему протоколы. Домен не нужен.

<div align="center">
<img alt="Конец установки 3X-UI KIT" src="manuals/assets/script-3x-ui.svg" width="760">
</div>

## Возможности

- 🧩 **11 протоколов сразу** – VLESS REALITY, XHTTP, WebSocket, Trojan gRPC, VMess,
  Shadowsocks 2022, Hysteria2, TUIC, AmneziaWG (классика и 3.1) и MTProto для Telegram.
- 🚪 **Всё TCP – через порт 443.** Панель, подписка и протоколы спрятаны за одним портом,
  а на случайный заход сервер показывает обычный сайт.
- 🔗 **Одна подписка на все приложения.** Hiddify, Happ, v2rayN, Karing, Clash Verge и FlClash
  получают свой формат и только те протоколы, которые умеют.
- 👥 **Дополнительные пользователи одной командой** – `kit user add` добавляет пользователя
  сразу во все протоколы с общим лимитом трафика, сроком и числом устройств.
- 🧭 **Меню `kit`, как у x-ui.** Пользователи, протоколы, порты, сайт маскировки, проверка
  и обновление – цифрой, без запоминания команд.
- 🌐 **Сайт для маскировки подбирается среди соседей по подсети**, а со своим доменом на сервере
  стоит ваш собственный сайт.
- 🔄 **Обновляется сам, но только подписанными релизами**, а `kit backup` сохраняет
  копию сервера, которую `--restore` поднимает на чистом VPS.
- 🔒 **Сертификат Let's Encrypt на IP** выпускается и продлевается сам, панель скрыта на
  случайном пути со случайными логином и паролем.
- ✅ **Проверено настоящими клиентами** – каждый протокол на ядрах Xray, Mihomo и sing-box,
  в том числе через интернет к удалённому серверу: [tests/matrix](tests/matrix/).

## Что понадобится

- VPS с **Ubuntu 22.04/24.04** или **Debian 12/13** и доступом root по SSH
- Свободные порты **443** и **80** – на свежем сервере они свободны

Нужен VPS? Я сам использую **[IS Hosting](https://ishosting.io/affiliate/NTg4MiM4)** и рекомендую его
(реферальная ссылка).

## Установка

Подключитесь к серверу по SSH и выполните:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/itsnotkubrick/3X-UI_KIT/main/scripts/3x-ui.sh)
```

Через пару минут скрипт покажет адрес панели, логин, пароль и подписку с QR-кодом.

Подробно – подключение приложений, дополнительные пользователи и параметры –
в **[инструкции](manuals/3x-ui.md)**. Нужен только Hysteria2 – есть
[отдельный скрипт](manuals/hysteria2.md).

> [!WARNING]
> Проект создан в образовательных целях. Убедитесь, что ваши действия
> соответствуют законодательству вашей страны.

## Команды kit

После установки на сервере появляется команда `kit`. Запустите её без аргументов – откроется меню, как у `x-ui`:
выберите цифру, остальное спросит само. Подробности – в [инструкции](manuals/3x-ui.md).

```bash
kit                                                    # меню: пользователи, протоколы, проверка, обновление, копия

kit user add имя [--gb 50] [--days 30] [--devices 3]   # добавить пользователя во все протоколы, показать подписку и ссылки
kit user list                                          # кто сколько израсходовал, до какого числа, когда был в сети
kit user link имя [--all | --amnezia | --telegram]     # подписка, ссылки «открыть в приложении», отдельные ссылки (AmneziaVPN, Telegram – ключами)
kit user limit имя [--gb N] [--days N] [--devices N]   # изменить лимиты (0 – без ограничений)
kit user off имя  /  kit user on имя                   # временно выключить и включить
kit user del имя                                       # удалить пользователя

kit net                                                # протоколы, порты, сайт маскировки, отпечаток – одним экраном
kit net site [--nearby | сайт.com]                     # сменить сайт маскировки (по умолчанию подбирается среди соседей по подсети)
kit net port имя порт                                  # сменить порт подключения (ufw и ссылки обновятся)
kit net off имя  /  kit net on имя                     # выключить и включить протокол; kit net on reality2 – второй REALITY
kit net fp firefox                                     # сменить отпечаток клиента у всех подключений
kit net masq on                                        # Hysteria2 отвечает на чужой запрос страницей сайта
kit net dns on                                         # DNS в подписке по DoH через прокси (ставится при установке)
kit net panel domain | ip                               # панель и подписка по своему домену или по IP (при установке: --panel-on)

kit check [--deep] [--fix]                             # проверить сервер; --deep – ещё и подключиться клиентом, --fix – исправить безопасное
kit update [--panel]                                   # обновить сейчас; --panel – панель 3X-UI до проверенной версии
kit update --auto  /  kit update --manual              # включить и выключить автообновление
kit backup                                             # копия сервера (подключения, ключи, пользователи)
kit version                                            # версии kit, панели и ядра
```

Копию из `kit backup` на новом чистом сервере поднимает `bash 3x-ui.sh --restore файл`.

Для отдельного сервера Hysteria2 есть команда `hy2`, подробнее – в [инструкции по Hysteria2](manuals/hysteria2.md):

```bash
hy2 add имя      # добавить пользователя и показать его ссылку
hy2 del имя      # удалить пользователя
hy2 list         # список пользователей
hy2 link [имя]   # ссылка и QR-код
hy2 status       # версия, адрес, состояние сервиса
hy2 restart      # перезапустить
hy2 update       # обновить скрипт и Hysteria до проверенной версии
hy2 uninstall    # удалить всё
```

Панелью 3X-UI управляет команда `x-ui`.

## VPN на роутере

Через прокси идут только нужные сервисы и выбранные устройства, остальное работает напрямую.
Порядок: **1.** установить программу на роутер → **2.** собрать конфиг в [генераторе](#генератор-конфигов-для-роутера) →
**3.** вставить команду из генератора.

> [!NOTE]
> **🙏 Спасибо автору XKeen.** На роутере работает не моя программа: я только собрал инструкцию
> и генератор конфигов, а всю сложную работу сделал **jameszeroX**.
>
> **[XKeen](https://github.com/jameszeroX/XKeen)** – прокси на Keenetic (Xray и Mihomo, политики для устройств).
> [Репозиторий](https://github.com/jameszeroX/XKeen) · [Вики](https://github.com/jameszeroX/XKeen/wiki) · ⭐ [Поставить звезду](https://github.com/jameszeroX/XKeen)
>
> Вопросы по самой программе задавайте в её репозитории: так автор узнаёт об ошибках. Если что-то не так
> с моей инструкцией или генератором, пишите мне.

<details>
<summary><b>📶 Keenetic: XKeen (jameszeroX) · 8 шагов, 20–30 минут</b></summary>

Нужны роутер **Keenetic** или **Netcraze** с USB-портом, USB-флешка в формате **ext4** и свой сервер с VLESS
(например, из [этой инструкции](manuals/3x-ui.md)).

<details>
<summary><b>1. Компоненты KeeneticOS</b></summary>

В веб-интерфейсе: **Управление → Общие настройки → Изменить набор компонентов**. Отметьте компоненты
с галочками на картинке и установите. Роутер обновится и перезагрузится.

![Нужные компоненты KeeneticOS](manuals/assets/keenetic-components.svg)

</details>

<details>
<summary><b>2. Entware на флешку</b></summary>

1. Отформатируйте флешку в **ext4** и вставьте её в роутер.
2. Откройте её по сети (`\\192.168.x.x\`), создайте папку `install` и положите туда установщик под процессор роутера:
   [mipsel](https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz),
   [mips](https://bin.entware.net/mipssf-k3.4/installer/mips-installer.tar.gz) или
   [aarch64](https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz).
   Не знаете, какой нужен? Модель роутера – в характеристиках на сайте Keenetic.

![Установщик Entware на флешке](manuals/assets/entware-installer.svg)

3. **Управление → OPKG**: выберите флешку и сохраните. Установка займёт несколько минут.

![Выбор накопителя для OPKG](manuals/assets/keenetic-opkg.svg)

</details>

<details>
<summary><b>3. Подключение по SSH</b></summary>

```bash
ssh root@192.168.x.x -p 222
```

Пароль по умолчанию `keenetic`. **Сразу смените его** командой `passwd`.

</details>

<details>
<summary><b>4. Шифрованный DNS</b></summary>

Пропишите шифрованные DNS-серверы (DoT или DoH) по
[инструкции Keenetic](https://support.keenetic.ru/ultra/kn-1811/ru/31543-dot-and-doh-proxy-servers-for-dns-requests-encryption.html):
без этого XKeen работает неправильно.

</details>

<details>
<summary><b>5. Токен для KeeneticOS 5.2 и новее</b></summary>

XKeen нужен токен доступа к роутеру. Создайте его в разделе **Пользователи и доступ**, вставьте в
[шаблон xkeen.json](https://github.com/jameszeroX/XKeen/releases/download/2.0.1_Beta/xkeen.json) и положите файл на роутер
по пути `/opt/etc/xkeen/xkeen.json`. Подробнее – в [вики XKeen](https://github.com/jameszeroX/XKeen/wiki/Порядок-установки).

</details>

<details>
<summary><b>6. Установка XKeen</b></summary>

Подключитесь по SSH и выполните:

```bash
opkg update && opkg upgrade && opkg install curl tar && cd /tmp
sh -c "$(curl -sSL https://raw.githubusercontent.com/jameszeroX/XKeen/main/install.sh)"
```

Если GitHub недоступен, замените адрес на `https://cdn.jsdelivr.net/gh/jameszeroX/XKeen@main/install.sh`.
Установщик спросит ядро (Xray или Mihomo), геобазы и автозагрузку.

Затем соберите конфиг в [генераторе](#генератор-конфигов-для-роутера) (роутер Keenetic, нужное ядро), вставьте команду в SSH-консоль
и нажмите Enter: файлы запишутся, XKeen перезапустится.

![Конфигурационные файлы Xray](manuals/assets/xkeen-configs.svg)

</details>

<details>
<summary><b>7. Какие устройства через прокси</b></summary>

В веб-интерфейсе откройте **Приоритеты подключений → Политики доступа в Интернет**, создайте политику
с именем **`xkeen`** и перенесите в неё нужные устройства.

> [!WARNING]
> Без политики `xkeen` через прокси пойдёт трафик **всех** устройств в сети.

</details>

<details>
<summary><b>8. Проверка</b></summary>

- На роутере: `xkeen -status` – XKeen должен быть запущен.
- На устройстве из политики `xkeen` откройте сайт, показывающий IP-адрес: он должен совпасть с адресом вашего сервера,
  а на остальных устройствах остаться прежним.
- Удобнее управлять настройками из браузера через [XKeen UI](https://github.com/zxc-rv/XKeen-UI).

</details>

Подробная версия с теми же шагами: [инструкция для Keenetic](manuals/xkeen-keenetic.md).

</details>

## Генератор конфигов для роутера

Вставьте ссылку на сервер или подписку, выберите роутер и ядро, отметьте нужные сервисы –
и получите готовый конфиг и одну команду, которая сама положит его на роутер.
Всё считается в браузере, ссылки никуда не отправляются.
Как поставить XKeen на роутер – в разделе [VPN на роутере](#vpn-на-роутере).

| Роутер | Ядро | Что получится | Генератор |
|---|---|---|---|
| Keenetic (XKeen) | Xray | `04_outbounds.json` и `05_routing.json`: серверы, выбор сервисов, реклама, свои сайты | [Открыть →](https://itsnotkubrick.github.io/3X-UI_KIT/tools/?core=xray) |
| Keenetic (XKeen) | Mihomo | `config.yaml` с автовыбором сервера, подпиской, Hysteria2, AmneziaWG и веб-панелью | [Открыть →](https://itsnotkubrick.github.io/3X-UI_KIT/tools/?core=mihomo) |
| OpenWrt (Nikki), бета | Mihomo | профиль для Nikki и команда, которая его включит | [Открыть →](https://itsnotkubrick.github.io/3X-UI_KIT/tools/?router=openwrt) |

## Утечки DNS

Подписка отдаёт приложению безопасный DNS: в Clash/Mihomo – `fake-ip` и DoH, который идёт по правилам (то есть через
прокси), в Xray JSON – DoH вместо обычного UDP. Проверено на сервере: при подключении через REALITY, XHTTP, Shadowsocks
и по JSON-подписке запросы имён наружу обычным DNS не уходят. Но многое решает само приложение, поэтому:

1. Включите режим **TUN** (весь трафик устройства) и **удалённый DNS**, отключите «локальный DNS» и IPv6, если он не нужен.
2. WireGuard и AmneziaWG приложение разрешает по обычному UDP внутри туннеля, поэтому в «Авто» они не входят (выбираются вручную).
3. Проверьте на [dnsleaktest.com](https://dnsleaktest.com) или [ipleak.net](https://ipleak.net): DNS вашего провайдера там появляться не должен.

## Диагностика и перенос сервера

1. `kit check --deep` – проверит сервер и подключится к нему клиентом: так видно, виноват сервер или сеть.
2. `kit net fp firefox` – другой отпечаток клиента одной командой (вернуть: `kit net fp chrome`).
3. `kit net site` – другой сайт для маскировки; `kit net on reality2` – дополнительный REALITY на другом порту.
   Один протокол не подключается – попробуйте соседний: у каждого свои сильные стороны (Hysteria2 работает по UDP, остальные по TCP). В подписке Clash «Авто» выбирает сама, в остальных приложениях – вручную.
4. Не помогло – перенесите сервер на другой адрес: `kit backup`, на новом сервере `bash 3x-ui.sh --restore файл`.
   Если подписка выдавалась на домене, а не на IP, клиентам достаточно сменить адрес в DNS.

## Полезное

- [XKeen](https://github.com/jameszeroX/XKeen) и его [вики](https://github.com/jameszeroX/XKeen/wiki) – документация по маршрутизации на Keenetic
- [XKeen UI](https://github.com/zxc-rv/XKeen-UI) – веб-интерфейс для XKeen
- [IP-адреса для AmneziaWG](https://github.com/RockBlack-VPN/ip-address) – актуальные списки от RockBlack

## Поддержать проект

Скрипты и инструкции бесплатные. Донат добровольный – он помогает оплачивать
тестовые серверы и держать скрипты в актуальном состоянии. Спасибо! 💜

| Способ | |
|---|---|
| Российской картой, СБП, Tinkoff Pay | [CloudTips](https://pay.cloudtips.ru/p/d4f9e3d1) |
| Зарубежной картой, Apple Pay, Google Pay | [Buy Me a Coffee](https://buymeacoffee.com/relo.cate) |
| USDT (TRC-20) | `TS83ViXrdezUpp1eFadqj1rBhGLZaba1c1` |
| TON | `UQBchO4XFPwF9MMa_tjXpwqTo8IL2FhUDyllhYuFo8WM-Qbf` |
| Ethereum (ERC-20) | `0xC06F6B3A029d7Ea00705B7028490744e2BC16799` |

## Благодарности

3X-UI KIT построен на работе авторов этих проектов:
[3X-UI](https://github.com/MHSanaei/3x-ui) ·
[Xray-core](https://github.com/XTLS/Xray-core) ·
[Mihomo](https://github.com/MetaCubeX/mihomo) ·
[Hysteria](https://github.com/apernet/hysteria) ·
[AmneziaWG](https://github.com/amnezia-vpn) ·
[XKeen](https://github.com/jameszeroX/XKeen)
