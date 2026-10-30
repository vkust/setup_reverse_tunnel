# Руководство по ручной настройке обратного SSH-туннеля

В этом руководстве описан процесс ручной настройки обратного SSH-туннеля между устройством OpenWRT/Linux и VPS сервером. Автоматизированная версия этой настройки — скрипты `setup_vps.sh` (VPS) и `setup_rtunn.sh` (устройство), см. [README](README.md).

## Содержание
- [Настройка VPS сервера](#настройка-vps-сервера)
  - [Настройка SSH](#1-настройка-ssh)
  - [Настройка Firewall](#2-настройка-firewall)
  - [Настройка параметров ядра](#3-настройка-параметров-ядра)
  - [Настройка Fail2Ban](#4-настройка-fail2ban)
- [Настройка OpenWRT / Linux](#настройка-openwrt--linux)
  - [Установка SSH](#1-установка-ssh)
  - [Генерация SSH ключей](#2-генерация-ssh-ключей)
  - [Копирование ключа на VPS](#3-копирование-ключа-на-vps)
  - [Создание init.d скрипта](#4-создание-initd-скрипта)
  - [Настройка прав и запуск](#5-настройка-прав-и-запуск)
  - [Мониторинг туннеля](#6-мониторинг-туннеля-на-vps)
  - [Проверка работы](#7-проверка-работы)

## Настройка VPS сервера

> **Поддерживаемые дистрибутивы VPS:** Debian/Ubuntu (apt), RHEL/CentOS/Fedora (dnf/yum), Alpine (apk). Автоматизированный установщик `setup_vps.sh` работает на любом из них; в примерах ниже команды приведены для apt — заменяйте `apt install` на `dnf/yum install` или `apk add` по необходимости. Скрипт `setup_vps.sh` НЕ рассчитан на OpenWrt (для роутера служит `setup_rtunn.sh`).

### 1. Настройка SSH

1. Откройте конфигурационный файл:
```bash
nano /etc/ssh/sshd_config
```

2. Добавьте или измените следующие параметры:
```
AllowTcpForwarding yes
GatewayPorts clientspecified
ClientAliveInterval 30
ClientAliveCountMax 3
PermitRootLogin yes
PasswordAuthentication yes
```

> `GatewayPorts clientspecified` означает, что форвард слушает тот адрес, который явно запросил клиент (`-R 0.0.0.0:порт:...` — на внешнем интерфейсе, `-R порт:...` — только на localhost). Это безопаснее устаревшего `GatewayPorts yes`, включающего все форварды на 0.0.0.0. Установщик устройства (`setup_rtunn.sh`) формирует аргументы `-R` с учётом этого режима. Параметр `ChallengeResponseAuthentication` в новых OpenSSH (≥8.7) исключён — вместо него используется `KbdInteractiveAuthentication`.

3. Перезапустите SSH сервер:
```bash
# Debian/Ubuntu (юнит называется ssh):
systemctl restart ssh
# RHEL/Fedora/Alpine (юнит sshd):
systemctl restart sshd
# Системы без systemd:
service ssh restart   # или /etc/init.d/sshd restart
```

### 2. Настройка Firewall

#### Вариант с UFW:
```bash
# Установка UFW
apt install ufw

# Настройка базовых правил
ufw default deny incoming
ufw default allow outgoing

# Открытие портов
ufw allow 22/tcp
ufw allow ПОРТ_ТУННЕЛЯ/tcp

# Включение UFW
ufw enable
```

#### Вариант с IPTables:
```bash
# Очистка правил
iptables -F
iptables -X

# Базовые правила
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Открытие портов
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport ПОРТ_ТУННЕЛЯ -j ACCEPT

# Политика по умолчанию
iptables -P INPUT DROP

# Сохранение правил
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4

# Автозагрузка правил при старте системы (если нет iptables-persistent/netfilter-persistent)
# установщик добавляет в /etc/rc.local перед exit 0:
#   iptables-restore < /etc/iptables/rules.v4
```

> Автоматический установщик `setup_vps.sh` дополнительно сохраняет бэкап текущих правил перед изменениями в `/root/firewall_backup/iptables_backup_<дата_время>.rules` (для UFW — `ufw_backup_<дата_время>.rules`). В дистрибутивах без UFW (RHEL/Fedora, Alpine) установщик автоматически предлагает IPTables. Пакеты сохранения правил называются по-разному: Debian/Ubuntu — `iptables-persistent`, RHEL/Fedora — `iptables-services`, Alpine — `iptables`.

### 3. Настройка параметров ядра
```bash
# Редактируем sysctl.conf
nano /etc/sysctl.conf

# Добавляем параметры
net.ipv4.ip_forward=1
net.ipv4.tcp_max_syn_backlog=65535

# Применяем изменения
sysctl -p
```

### 4. Настройка Fail2Ban

1. Установка Fail2Ban:
```bash
apt update
apt install -y fail2ban
```

2. Создание конфигурации:
```bash
nano /etc/fail2ban/jail.local
```

3. Добавьте следующую конфигурацию:
```
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 300
bantime = 3600
```

4. Перезапустите службу:
```bash
systemctl restart fail2ban
```

5. Проверка статуса:
```bash
fail2ban-client status sshd
```

Полезные команды Fail2Ban:
```bash
# Просмотр логов
tail -f /var/log/fail2ban.log

# Список заблокированных IP
fail2ban-client get sshd banip

# Разблокировать IP
fail2ban-client set sshd unbanip IP_АДРЕС
```

## Настройка OpenWRT / Linux

> Актуальный автоматизированный установщик для устройства — `setup_rtunn.sh` (раздел «Использование» в [README](README.md)). Он поддерживает старые версии OpenWrt (opkg), **OpenWrt 25.x, где opkg заменён на apk**, и обычный Linux (apt/dnf/yum/apk + systemd). Ниже — ручные шаги для понимания процесса.

### 1. Установка SSH

#### Для OpenSSH:
```bash
# Старый OpenWrt (до 25.x):
opkg update
opkg install openssh-client openssh-keygen

# OpenWrt 25.x (пакетный менеджер apk; openssh-keygen — отдельный пакет):
apk update
apk add openssh-client
apk add openssh-keygen   # без него /usr/bin/ssh-keygen остаётся апплетом Dropbear

# Обычный Linux (демон sshd на роутере не нужен, достаточно клиента):
apt install openssh-client    # Debian/Ubuntu
dnf install openssh-clients   # Fedora/RHEL
```

> Важно: в базовой системе любого OpenWrt `/usr/bin/ssh`, `/usr/bin/ssh-keygen` могут быть симлинками на апплеты Dropbear. Пока не установлен пакет `openssh-client` (+ `openssh-keygen` на apk-сборках), команда `ssh-keygen -t rsa -b 4096 ...` упадёт с ошибкой `Unknown argument -b` — флаги `-b/-N` понимает только настоящий OpenSSH keygen. Альтернатива — использовать режим Dropbear (см. ниже), он не требует установки пакетов.

#### Для Dropbear:
```bash
# Dropbear (ssh-сервер dbclient/dropbearkey) входит в базовую систему OpenWrt —
# отдельно устанавливать ничего не нужно. Проверка:
dbclient -V
dropbearkey -h
```

### 2. Генерация SSH ключей

#### Для OpenSSH:
```bash
mkdir -p /root/.ssh
ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
```

#### Для Dropbear:
```bash
mkdir -p /root/.ssh
dropbearkey -t rsa -f /root/.ssh/id_rsa
dropbearkey -y -f /root/.ssh/id_rsa | grep "^ssh-rsa" > /root/.ssh/id_rsa.pub
chmod 600 /root/.ssh/id_rsa
chmod 644 /root/.ssh/id_rsa.pub
```

### 3. Копирование ключа на VPS
```bash
# Для OpenSSH
cat /root/.ssh/id_rsa.pub | ssh -p ПОРТ user@VPS_IP "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"

# Для Dropbear
cat /root/.ssh/id_rsa.pub | dbclient -p ПОРТ user@VPS_IP "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
```

### 4. Создание init.d скрипта

1. Создайте файл конфигурации:
```bash
mkdir -p /etc/config
nano /etc/config/rtunn
```

2. Добавьте конфигурацию:
```
config rtunn 'general'
    option enabled '1'
    option ssh_port 'SSH_ПОРТ'
    option vps_user 'ИМЯ_ПОЛЬЗОВАТЕЛЯ'
    option vps_ip 'IP_АДРЕС_VPS'

config rtunn 'tunnel'
    option remote_port 'УДАЛЕННЫЙ_ПОРТ'
    option local_port 'ЛОКАЛЬНЫЙ_ПОРТ'
    option local_host 'localhost'
```

3. Создайте init.d скрипт:
```bash
nano /etc/init.d/rtunn
```

4. Добавьте содержимое:
```bash
#!/bin/sh /etc/rc.common

START=99
STOP=15
USE_PROCD=1

append_tunnel() {
    local cfg="$1"
    local remote_port local_port local_host
    config_get remote_port "$cfg" remote_port
    config_get local_port "$cfg" local_port
    config_get local_host "$cfg" local_host "localhost"
    procd_append_param command -R "${remote_port}:${local_host}:${local_port}"
}

start_service() {
    config_load rtunn
    local enabled vps_user vps_ip ssh_port ssh_cmd
    config_get_bool enabled general enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get vps_user general vps_user "root"
    config_get vps_ip general vps_ip
    config_get ssh_port general ssh_port "22"

    # OpenSSH, если реально установлен; иначе dbclient (есть в любой сборке OpenWrt)
    if command -v ssh >/dev/null 2>&1 && ! ssh -V 2>&1 | grep -qi dropbear; then
        ssh_cmd="$(command -v ssh)"
    elif command -v dbclient >/dev/null 2>&1; then
        ssh_cmd="$(command -v dbclient)"
    else
        echo "rtunn: не найден ни ssh, ни dbclient" >&2
        return 1
    fi

    procd_open_instance
    procd_set_param command "$ssh_cmd"
    procd_append_param command -NT -i /root/.ssh/id_rsa

    case "$ssh_cmd" in
        */dbclient)
            procd_append_param command -o KeepAlive=30
            ;;
        *)
            procd_append_param command -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
                -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
                -o UserKnownHostsFile=/root/.ssh/known_hosts
            ;;
    esac

    config_foreach append_tunnel tunnel
    case "$ssh_cmd" in
        */dbclient) procd_append_param command "${vps_user}@${vps_ip}" -p "${ssh_port}" ;;
        *)          procd_append_param command "${vps_user}@${vps_ip}" -p "${ssh_port}" ;;
    esac

    procd_set_param respawn 3600 5 0
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}

service_triggers() { procd_add_reload_trigger "rtunn"; }
reload_service() { stop; start; }
```

> Примечания: у `dbclient` нет флагов `-o ServerAliveInterval` и `-y` — для Dropbear используется `-o KeepAlive=30`; OpenSSH-клиенту в демоне (без TTY) нужны `StrictHostKeyChecking=no` и заранее прогретый `known_hosts`. Флаг `-y` у OpenSSH означает «использовать системный ключ хоста» и к известным хостам отношения не имеет — не используйте его здесь.

На Linux (systemd) вместо init.d создаётся unit `/etc/systemd/system/rtunn.service` с `ExecStart=/usr/bin/ssh -NT -i /root/.ssh/id_rsa -o ServerAliveInterval=30 ... -R УДАЛЕННЫЙ_ПОРТ:ЛОКАЛЬНЫЙ_ХОСТ:ЛОКАЛЬНЫЙ_ПОРТ user@VPS_IP -p SSH_ПОРТ` и `Restart=always`.

### 5. Настройка прав и запуск
```bash
chmod +x /etc/init.d/rtunn
/etc/init.d/rtunn enable
/etc/init.d/rtunn start
```

### 6. Мониторинг туннеля на VPS

1. Создайте скрипт мониторинга:
```bash
nano /root/check_tunnels.sh
```

2. Добавьте содержимое:
```bash
#!/bin/sh

printf "Проверка статуса туннелей...\n\n"

# Список портов туннелей задаёт установщик setup_vps.sh (или укажите вручную):
TUNNEL_PORTS="10022 10080"

if [ -n "$TUNNEL_PORTS" ]; then
    PORTS="$TUNNEL_PORTS"
else
    # Fallback: все слушающие ssh-порты, КРОМЕ порта SSH самого VPS (22) —
    # иначе обычный sshd учитывался бы как «туннель»
    PORTS=$( (ss -tlpn 2>/dev/null || netstat -tlpn 2>/dev/null) | grep ssh | awk '{print $4}' | cut -d: -f2 | grep -vx 22 | sort -u)
fi

if [ -z "$PORTS" ]; then
    printf "Активных SSH туннелей не обнаружено\n"
    logger "No active SSH tunnels found"
    exit 1
fi

printf "Обнаружены порты: %s\n\n" "$PORTS"

FOUND=0
TOTAL=0
for port in $PORTS; do
    TOTAL=$((TOTAL + 1))
    if ! netstat -an 2>/dev/null | grep "LISTEN" | grep ":$port " > /dev/null; then
        printf "\033[31m✗ Туннель на порту %s не активен\033[0m\n" "$port"
        logger "Reverse tunnel on port $port is down"
    else
        printf "\033[32m✓ Туннель на порту %s активен\033[0m\n" "$port"
        FOUND=$((FOUND + 1))
    fi
done

printf "\nИтого: активно %d из %d туннелей\n" "$FOUND" "$TOTAL"
[ "$FOUND" -gt 0 ] || exit 2
```

> Смысл: проверяются конкретные настроенные порты туннелей (их подставляет `setup_vps.sh` при генерации скрипта), а не «все ssh-порты» — порт 22 самого VPS туннелем не является. Значения exit-кодов: 0 — всё в порядке, 1 — список портов пуст, 2 — ни один туннель не активен (удобно для алертов из cron).

3. Настройте права и добавьте в cron:
```bash
chmod +x /root/check_tunnels.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /root/check_tunnels.sh") | crontab -
```

### 7. Проверка работы
```bash
# На OpenWRT
/etc/init.d/rtunn status
# На Linux
systemctl status rtunn.service

# На VPS
netstat -tlpn | grep ssh
/root/check_tunnels.sh
```

## Дополнительные рекомендации

### Безопасность
1. Используйте нестандартный порт для SSH
2. Настройте fail2ban для защиты от брутфорса
3. Регулярно обновляйте систему
4. Используйте сложные пароли
5. Ограничьте доступ по IP если возможно

### Мониторинг
1. Регулярно проверяйте логи
2. Настройте оповещения при падении туннеля
3. Следите за нагрузкой на систему

### Обслуживание
1. Делайте резервные копии конфигурации
2. Документируйте все изменения
3. Проверяйте работу туннеля после обновлений системы

## Устранение неполадок

### Проблемы с подключением
1. Проверьте статус SSH сервера:
```bash
systemctl status ssh    # Debian/Ubuntu (юнит называется ssh)
systemctl status sshd   # RHEL/Fedora/Alpine
```

2. Проверьте открытые порты:
```bash
netstat -tlpn | grep ssh
```

3. Проверьте правила firewall:
```bash
# Для UFW
ufw status numbered

# Для IPTables
iptables -L INPUT -n --line-numbers
```

4. Проверьте логи:
```bash
tail -f /var/log/auth.log
tail -f /var/log/fail2ban.log
```

### Проблемы с производительностью
1. Мониторинг системы:
```bash
top
htop
```

2. Проверка сети:
```bash
iftop
nethogs
```

3. Проверка туннелей:
```bash
/root/check_tunnels.sh
```

## Заключение

Это полное руководство по настройке обратного SSH-туннеля. Рекомендуется адаптировать конфигурацию под конкретные требования и регулярно проверять работоспособность системы.

## Полезные команды

### Управление туннелем на OpenWRT / Linux (службы создаёт setup_rtunn.sh)
```bash
# Быстрое управление — интерактивный менеджер (создаётся установщиком):
tunnel

# OpenWrt (procd-служба rtunn):
/etc/init.d/rtunn start     # Запуск туннеля
/etc/init.d/rtunn stop      # Остановка туннеля
/etc/init.d/rtunn restart   # Перезапуск туннеля
/etc/init.d/rtunn enable    # Включить автозапуск
/etc/init.d/rtunn disable   # Отключить автозапуск
/etc/init.d/rtunn status    # Статус

# Linux (systemd unit rtunn.service):
systemctl restart rtunn.service
systemctl status rtunn.service
journalctl -u rtunn.service -f
```

### Управление Fail2Ban на VPS
```bash
fail2ban-client status              # Общий статус
fail2ban-client status sshd         # Статус SSH jail
fail2ban-client set sshd unbanip IP # Разблокировать IP
```

### Мониторинг на VPS
```bash
/root/check_tunnels.sh             # Проверка туннелей
tail -f /var/log/auth.log          # Мониторинг логов SSH
tail -f /var/log/fail2ban.log      # Мониторинг логов Fail2Ban
``` 