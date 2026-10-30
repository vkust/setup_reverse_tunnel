# Настройка обратного SSH-туннеля для OpenWRT и дистрибутивов Linux

Набор скриптов для автоматической настройки обратного SSH-туннеля между OpenWRT/Linux и VPS сервером.

## Описание

Эти скрипты автоматизируют процесс настройки безопасного обратного SSH-туннеля, который позволяет получить доступ к устройству OpenWRT/Linux через VPS сервер, даже если устройство находится за NAT.

### Возможности
- Поддержка OpenSSH и Dropbear (на стороне устройства — включая fallback на `dbclient`/`dropbearkey`, когда пакет OpenSSH установить не удалось)
- Работа на старых OpenWrt (opkg), новых OpenWrt 25.x (apk) и обычных Linux (apt/dnf/yum/apk + systemd)
- Автоматическая настройка firewall на VPS (UFW или IPTables — в зависимости от дистрибутива)
- Создание и настройка SSH-ключей, копирование публичного ключа на VPS
- Настройка автозапуска туннеля (procd-служба `/etc/init.d/rtunn` на OpenWrt, unit `rtunn.service` на Linux)
- Мониторинг состояния туннелей на VPS по расписанию cron
- Интерактивный менеджер: повторный запуск скрипта (или команда `tunnel`) показывает текущую конфигурацию и меню управления

## Состав репозитория
| Файл | Назначение |
|---|---|
| `setup_rtunn.sh` | Установка и управление туннелем на устройстве (OpenWrt/Linux). Основной актуальный скрипт. |
| `setup_vps.sh` | Настройка VPS сервера: sshd, firewall, sysctl, мониторинг |
| `setup_fail2ban.sh` | Опциональная установка и настройка Fail2Ban на VPS |
| `check_tunnels.sh` | Скрипт мониторинга туннелей (создаётся на VPS установщиком `setup_vps.sh`) |
| `setup_reverse_tunnel.sh`, `setup_reverse_tunnel2.sh` | Устаревшие версии скрипта для устройства (для справки; используется `setup_rtunn.sh`) |

## Использование

### 1. Настройка VPS
Сначала настройте VPS сервер (поддерживаются Debian/Ubuntu — apt, RHEL/CentOS/Fedora — dnf/yum, Alpine — apk):
```bash
sh <(wget -O - https://raw.githubusercontent.com/vkust/setup_reverse_tunnel/main/setup_vps.sh)
```

Скрипт:
- Настроит SSH сервер (`AllowTcpForwarding yes`, `GatewayPorts clientspecified`, keepalive-параметры; бэкап конфига в `/etc/ssh/sshd_config.backup`)
- Настроит firewall (UFW или IPTables; при недоступности UFW в дистрибутиве автоматически предлагается IPTables; бэкапы правил в `/root/firewall_backup/`)
- Сохранит правила IPTables в `/etc/iptables/rules.v4` с восстановлением через `/etc/rc.local`
- Настроит параметры ядра (sysctl)
- Создаст скрипт мониторинга туннелей `/root/check_tunnels.sh` (проверяет конкретные настроенные порты, порт SSH самого VPS не считается туннелем)
- Добавит мониторинг в cron (каждые 5 минут; по умолчанию — «да», достаточно нажать Enter)

### 2. Настройка OpenWRT/Linux
После настройки VPS, запустите на устройстве:
```bash
sh <(wget -O - https://raw.githubusercontent.com/vkust/setup_reverse_tunnel/main/setup_rtunn.sh)
```

Скрипт:
- Определит ОС и пакетный менеджер (старый OpenWrt/opkg, новый OpenWrt 25.x/apk, Linux apt/dnf/yum/apk)
- Предложит выбрать SSH-клиент: **1) OpenSSH** (рекомендуется для новых VPS) или **2) Dropbear** (если VPS поддерживает RSA-SHA1; ничего устанавливать не нужно)
- Установит SSH-клиент (на OpenWrt 25.x при необходимости доустанавливает отдельный пакет `openssh-keygen`; если установить OpenSSH не удалось — честно сообщит и предложит режим Dropbear)
- Создаст SSH-ключи (`ssh-keygen` или `dropbearkey`)
- Скопирует публичный ключ на VPS и прогреет `known_hosts`
- Настроит обратный туннель (один или несколько) и создаст службу автозапуска
- Создаст команду `tunnel` — интерактивный менеджер (добавить туннель, перезапустить, перенастроить, удалить службу)

### Ручная настройка 📖
Если вы предпочитаете настроить туннель вручную или хотите лучше понять процесс настройки, обратитесь к [подробному руководству](MANUAL.md).

## Требования
- VPS с root доступом (Linux с apt/dnf/yum/apk; скрипт `setup_vps.sh` НЕ рассчитан на OpenWrt)
- Устройство с OpenWrt (любой версии) или Linux с root доступом
- Доступ к интернету на обоих устройствах (для скачивания скриптов и установки пакетов)

## После установки

1. Проверьте статус туннеля на OpenWRT/Linux:
```bash
# OpenWrt
/etc/init.d/rtunn status
# Linux (systemd)
systemctl status rtunn.service
```

2. Проверьте состояние туннелей на VPS:
```bash
/root/check_tunnels.sh
```

## Управление туннелем

Проще всего — интерактивная команда `tunnel` на устройстве (создаётся установщиком; при каждом запуске обновляется до свежей версии скрипта через wget или curl):
```bash
tunnel
# Меню: 1) добавить туннель  2) перезапустить службу
#       3) полностью перенастроить  4) удалить службу  0) выход
```

Команды службы на OpenWrt:
```bash
/etc/init.d/rtunn start     # Запуск туннеля
/etc/init.d/rtunn stop      # Остановка туннеля
/etc/init.d/rtunn restart   # Перезапуск туннеля
/etc/init.d/rtunn enable    # Включить автозапуск
/etc/init.d/rtunn disable   # Отключить автозапуск
/etc/init.d/rtunn status    # Статус
```

Команды службы на Linux (systemd):
```bash
systemctl start rtunn.service      # Запуск туннеля
systemctl stop rtunn.service       # Остановка туннеля
systemctl restart rtunn.service    # Перезапуск туннеля
systemctl enable rtunn.service     # Включить автозапуск
systemctl disable rtunn.service    # Отключить автозапуск
systemctl status rtunn.service     # Статус
```

Конфигурация на OpenWrt хранится в UCI-файле `/etc/config/rtunn` (секция `general` + секции `tunnel`), на Linux — в `/etc/systemd/system/rtunn.service`.
