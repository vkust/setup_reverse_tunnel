#!/bin/sh

# Ссылка на этот скрипт (используется для команды tunnel)
# По умолчанию — URL того же файла, из которого скрипт был запущен
# (корректно работает и при переименовании файла в репозитории).
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/vkust/setup_reverse_tunnel/main/setup_rtunn.sh}"

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Глобальные переменные
OS_TYPE=""
PKG_MGR=""
OPENWRT_25=0
IS_INSTALLED=0
# Каталог, где хранится отметка о выбранном SSH-клиенте (openssh|dropbear).
# Нужен, чтобы последующие запуски (в т.ч. команда 'tunnel') корректно
# определяли установленную службу даже при перепрошивке/сбое PATH.
STATE_DIR="/etc/rtunn"

# ВНИМАНИЕ: msg не должен содержать символ % (иначе printf воспримет его как формат)
# Поддержка \n: вызывающий код может передавать literal "\n" (например "\nЗаголовок"),
# print_msg преобразует их в реальные переводы строки через printf '%b'.
print_msg() {
    local color="$1"
    local msg="$2"
    # shellcheck disable=SC2059
    printf "${color}%b${NC}\n" "$msg"
}

validate_ip() {
    local ip="$1"
    if echo "$ip" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null; then
        for octet in $(echo "$ip" | tr '.' ' '); do
            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then return 1; fi
        done
        return 0
    fi
    if echo "$ip" | grep -E '^[a-zA-Z0-9.-]+$' >/dev/null; then return 0; fi
    return 1
}

validate_port() {
    local port="$1"
    if echo "$port" | grep -E '^[0-9]+$' >/dev/null && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return 0; fi
    return 1
}

# --- 1. Определение архитектуры и статуса ---
detect_os() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        # В OpenWrt 25.x классический пакетный менеджер opkg заменён на apk (Alpine).
        # Проверяем наличие именно opkg, иначе используем apk.
        if command -v opkg >/dev/null 2>&1; then
            PKG_MGR="opkg"
        elif command -v apk >/dev/null 2>&1; then
            PKG_MGR="apk"
            OPENWRT_25=1
            print_msg "$YELLOW" "ℹ Обнаружен OpenWrt с apk вместо opkg (начиная с 25.x пакеты ставятся через 'apk'). Использую apk."
        else
            print_msg "$RED" "✗ Ошибка: не найден ни opkg, ни apk — непонятно, как устанавливать пакеты."
            exit 1
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        OS_TYPE="systemd"
        if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
        elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
        elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
        elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
        else print_msg "$RED" "Не удалось определить пакетный менеджер."; exit 1; fi
    else
        # Раньше здесь был безусловный exit 1 — из-за этого команда 'tunnel' не работала
        # в окружениях, где нет ни /etc/openwrt_release, ни systemctl (например, LiveCD,
        # chroot/контейнер без systemd, нестандартный PATH), даже если служба уже была
        # установлена. Теперь: если служба на диске найдена — продолжаем работу, тип
        # службы определится позже по файлам (service_kind); пакетный менеджер для
        # управления службой не нужен.
        local kind
        kind="$(installed_kind)"
        if [ -n "$kind" ]; then
            case "$kind" in
                openwrt|openwrt-legacy) OS_TYPE="openwrt"; PKG_MGR="" ;;
                systemd)                OS_TYPE="systemd"; PKG_MGR="" ;;
            esac
            print_msg "$YELLOW" "ℹ ОС не определена стандартными средствами, но служба ($kind) найдена — продолжаю в режиме $kind."
        else
            print_msg "$RED" "Поддерживается только OpenWRT или Linux со systemd."
            exit 1
        fi
    fi
}

# Универсальная установка пакетов: pkg_install <пакет...>
pkg_install() {
    case "$PKG_MGR" in
        opkg)   opkg update && opkg install "$@" ;;
        apk)    apk update 2>/dev/null; apk add "$@" ;;
        apt-get) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        yum|dnf) $PKG_MGR install -y "$@" ;;
        *) return 1 ;;
    esac
}

# Установка OpenSSH клиента И генератора ключей.
# ВАЖНО про имена пакетов:
#  - старый OpenWrt (opkg): openssh-client + отдельный openssh-keygen;
#  - OpenWrt 25.x (apk): ssh-keygen входит в openssh-client (отдельного пакета нет);
#  - Debian/Ubuntu/Alpine-linux: ssh-keygen входит в openssh-client;
#  - RHEL/Fedora: всё в openssh-clients (отдельного openssh-keygen обычно нет).
install_openssh_pkgs() {
    if ! command -v ssh >/dev/null 2>&1 || ssh -V 2>&1 | grep -qi dropbear \
       || ! command -v ssh-keygen >/dev/null 2>&1 || is_dropbear_ssh_keygen; then
        case "$PKG_MGR" in
            opkg) pkg_install openssh-client openssh-keygen || exit 1 ;;
            *)    pkg_install openssh-client || exit 1 ;;
        esac
    fi
    # на случай, если в репозитории есть отдельный пакет с ключогенератором
    if command -v ssh-keygen >/dev/null 2>&1 && is_dropbear_ssh_keygen; then
        case "$PKG_MGR" in
            apk) pkg_install openssh-keygen 2>/dev/null || true ;;
        esac
    fi
}

# Определяет, является ли доступный ssh-keygen апплетом Dropbear (есть в базовой
# системе любого OpenWrt). Апплет Dropbear НЕ поддерживает флаги OpenSSH (-b, -N),
# и печатает "Unknown argument -b". Возвращает 0, если это Dropbear-апплет.
is_dropbear_ssh_keygen() {
    command -v ssh-keygen >/dev/null 2>&1 || return 1
    # вариант 1: вывод версии содержит dropbear
    if ssh-keygen -V 2>&1 | grep -qi dropbear; then return 0; fi
    # вариант 2: вызов с заведомо неизвестным флагом — у OpenSSH это "unknown option",
    # у Dropbear-апплета — строка "Unknown argument"
    if ssh-keygen -% 2>&1 | grep -q "Unknown argument"; then return 0; fi
    return 1
}

# Определяет, установлен ли сервис, по признакам на диске.
# Возвращает строку "openwrt" | "systemd" | "" (не установлен).
# ВАЖНО: определяется НЕ по PATH, а по фактическим файлам — чтобы команда
# 'tunnel' видела службу даже если PATH/окружение отличаются от интерактивного шелла.
installed_kind() {
    if [ -f /etc/init.d/rtunn ] || [ -f /etc/config/rtunn ]; then echo "openwrt"; return; fi
    if [ -f /etc/systemd/system/rtunn.service ]; then echo "systemd"; return; fi
    # Поддержка старой схемы именования (reverse-tunnel) — чтобы после обновления
    # прошивки/скрипта ранее созданные службы тоже распознавались.
    if [ -f /etc/init.d/reverse-tunnel ] || [ -f /etc/config/reverse-tunnel ]; then echo "openwrt-legacy"; return; fi
    echo ""
}

check_installation() {
    local kind
    kind="$(installed_kind)"
    case "$kind" in
        openwrt|openwrt-legacy)
            IS_INSTALLED=1
            # На устройстве может стоять и OpenWrt, и systemd-версия одновременно
            # (например, контейнер); приоритет — init-скрипт OpenWrt.
            ;;
        systemd)
            IS_INSTALLED=1
            ;;
        *)
            IS_INSTALLED=0
            ;;
    esac
}

# Сохраняет выбранный SSH-клиент, чтобы последующие запуски ('tunnel')
# показывали корректную информацию о клиенте.
save_state() {
    local ssh_type="$1"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    [ -n "$ssh_type" ] && printf '%s\n' "$ssh_type" > "$STATE_DIR/client" 2>/dev/null || true
}

load_state_client() {
    if [ -f "$STATE_DIR/client" ]; then
        cat "$STATE_DIR/client" 2>/dev/null
    fi
}

create_tunnel_alias() {
    # Всегда перезаписываем ярлык актуальной версией: старые версии ярлыка
    # могли быть битыми (wget -qO, отсутствие fallback на curl и т.п.),
    # из-за чего 'tunnel' не запускал менеджер и «не видел» службу.
    cat > /usr/bin/tunnel << EOF
#!/bin/sh
# Менеджер обратных SSH-туннелей: всегда скачивает свежую версию скрипта
# и запускает её локальным шеллом (sh), а не через pipe из wget/curl —
# это важно, т.к. 'sh <(wget ...)' требует bash-процессы и ломается на BusyBox.
CACHE=/tmp/rtunn_setup.sh
dl() {
    rm -f "\$CACHE"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "\$CACHE" "$SCRIPT_URL" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "\$CACHE" "$SCRIPT_URL" 2>/dev/null
    else
        return 1
    fi
    [ -s "\$CACHE" ]
}
if ! dl; then sleep 2; dl; fi
if [ -s "\$CACHE" ]; then
    exec sh "\$CACHE" "\$@"
else
    printf "\033[1;31m✗ Ошибка: не удалось скачать скрипт менеджера (проверьте интернет/DNS на устройстве).\033[0m\n"
    exit 1
fi
EOF
    chmod 755 /usr/bin/tunnel
    print_msg "$YELLOW" "💡 Команда 'tunnel' обновлена/установлена. Теперь вы можете вызывать это меню в любой момент!"
}

# --- 2. Функции управления текущей конфигурацией ---

# Тип установленной службы ("openwrt" | "systemd") — берётся из фактических
# файлов на диске, а НЕ из OS_TYPE: при запуске через 'tunnel' система может
# определяться иначе (или не определяться вовсе), но служба-то на месте.
service_kind() {
    local kind
    kind="$(installed_kind)"
    case "$kind" in
        openwrt|openwrt-legacy) echo "openwrt" ;;
        systemd)                echo "systemd" ;;
        *)                      echo "" ;;
    esac
}

show_current_config() {
    local current_client="OpenSSH"
    if [ "$(service_kind)" = "openwrt" ]; then
        # Сначала смотрим сохранённую отметку о выбранном клиенте, затем PATH.
        local saved
        saved="$(load_state_client)"
        if [ "$saved" = "dropbear" ]; then
            current_client="Dropbear"
        elif [ -n "$saved" ]; then
            current_client="OpenSSH"
        elif command -v ssh >/dev/null 2>&1 && ssh -V 2>&1 | grep -qi dropbear; then
            current_client="Dropbear"
        elif ! command -v ssh >/dev/null 2>&1; then
            current_client="Dropbear"
        fi
    fi

    print_msg "$CYAN" "\nТекущая конфигурация службы:"
    echo "------------------------------------------------"
    printf "SSH Клиент:  ${GREEN}%s${NC}\n" "$current_client"
    
    if [ "$(service_kind)" = "openwrt" ]; then
        local v_ip=$(uci -q get rtunn.general.vps_ip)
        local v_user=$(uci -q get rtunn.general.vps_user)
        local v_port=$(uci -q get rtunn.general.ssh_port)
        printf "VPS Сервер:  ${GREEN}%s@%s${NC} (Порт: %s)\n" "$v_user" "$v_ip" "$v_port"
        echo "Туннели:"
        for section in $(uci show rtunn 2>/dev/null | grep '=tunnel' | cut -d= -f1); do
            local r=$(uci -q get ${section}.remote_port)
            local l=$(uci -q get ${section}.local_port)
            local h=$(uci -q get ${section}.local_host)
            printf "  ► VPS порт ${YELLOW}%-5s${NC} -> Локально ${YELLOW}%s:%s${NC}\n" "$r" "$h" "$l"
        done
        printf "Статус: "
        /etc/init.d/rtunn status
    else
        local exec_line=$(grep "^ExecStart=" /etc/systemd/system/rtunn.service)
        local v_ip=$(echo "$exec_line" | grep -oE '@[a-zA-Z0-9.-]+' | tr -d '@' | head -n1)
        local v_user=$(echo "$exec_line" | grep -oE ' [a-zA-Z0-9_-]+@' | tr -d ' @' | head -n1)
        local v_port=$(echo "$exec_line" | grep -oE -- '-p [0-9]+' | awk '{print $2}')
        printf "VPS Сервер:  ${GREEN}%s@%s${NC} (Порт: %s)\n" "$v_user" "$v_ip" "$v_port"
        echo "Туннели:"
        echo "$exec_line" | grep -oE -- '-R [0-9]+:[a-zA-Z0-9.-]+:[0-9]+' | while read -r tunnel; do
            local ports=$(echo "$tunnel" | awk '{print $2}')
            local r=$(echo "$ports" | cut -d: -f1)
            local h=$(echo "$ports" | cut -d: -f2)
            local l=$(echo "$ports" | cut -d: -f3)
            printf "  ► VPS порт ${YELLOW}%-5s${NC} -> Локально ${YELLOW}%s:%s${NC}\n" "$r" "$h" "$l"
        done
        printf "Статус: "
        systemctl is-active rtunn.service
    fi
    echo "------------------------------------------------"
}

restart_service() {
    print_msg "$YELLOW" "\nПерезапуск службы..."
    if [ "$(service_kind)" = "openwrt" ]; then
        /etc/init.d/rtunn restart
    else
        systemctl restart rtunn.service
    fi
    print_msg "$GREEN" "✓ Служба успешно перезапущена."
}

uninstall_service() {
    print_msg "$YELLOW" "\nОстановка и удаление службы..."
    if [ "$(service_kind)" = "openwrt" ]; then
        /etc/init.d/rtunn stop >/dev/null 2>&1
        /etc/init.d/rtunn disable >/dev/null 2>&1
        rm -f /etc/init.d/rtunn
        rm -f /etc/config/rtunn
    else
        systemctl stop rtunn.service >/dev/null 2>&1
        systemctl disable rtunn.service >/dev/null 2>&1
        rm -f /etc/systemd/system/rtunn.service
        systemctl daemon-reload
    fi
    # Удаляем отметку о клиенте, чтобы следующий мастер настройки не наследовал старое значение
    rm -rf "$STATE_DIR" 2>/dev/null || true
    print_msg "$GREEN" "✓ Служба успешно удалена из системы."
    IS_INSTALLED=0
}

add_tunnel_to_existing() {
    print_msg "$BLUE" "\n--- Добавление нового туннеля ---"
    while true; do
        printf "Удаленный порт (на VPS): "; read -r r_port < /dev/tty
        validate_port "$r_port" && break || print_msg "$RED" "✗ Некорректный порт"
    done
    while true; do
        printf "Локальный порт (на устройстве): "; read -r l_port < /dev/tty
        validate_port "$l_port" && break || print_msg "$RED" "✗ Некорректный порт"
    done
    printf "Локальный хост [localhost]: "; read -r l_host < /dev/tty; l_host=${l_host:-localhost}

    if [ "$(service_kind)" = "openwrt" ]; then
        local section=$(uci add rtunn tunnel)
        uci set rtunn.${section}.remote_port="$r_port"
        uci set rtunn.${section}.local_port="$l_port"
        uci set rtunn.${section}.local_host="$l_host"
        uci commit rtunn
        print_msg "$YELLOW" "Перезапуск службы..."
        /etc/init.d/rtunn restart
    else
        local exec_line=$(grep "^ExecStart=" /etc/systemd/system/rtunn.service)
        local new_exec=$(echo "$exec_line" | sed "s/ \([^ ]*@[^ ]* -p [0-9]*\)$/ -R ${r_port}:${l_host}:${l_port} \1/")
        sed -i "s|^ExecStart=.*|$new_exec|" /etc/systemd/system/rtunn.service
        print_msg "$YELLOW" "Перезапуск службы..."
        systemctl daemon-reload && systemctl restart rtunn.service
    fi
    print_msg "$GREEN" "✓ Туннель успешно добавлен и запущен!"
}

# --- 3. Базовые функции установки ---
setup_ssh() {
    local ssh_type="$1"
    if [ "$OS_TYPE" = "openwrt" ]; then
        if [ "$ssh_type" = "dropbear" ]; then
            # В новых OpenWrt (25.x) dbclient входит в базовую систему, opkg там отсутствует
            if ! command -v dbclient >/dev/null 2>&1; then
                pkg_install dropbear || exit 1
            fi
            SSH_CMD="$(command -v dbclient)"
        else
            # Ставим openssh-client и (если нужен) openssh-keygen — имена пакетов
            # для opkg/apk/apt/yum корректно подбираются в install_openssh_pkgs.
            install_openssh_pkgs
            SSH_CMD="$(command -v ssh)"
            # Если пакетный менеджер не смог поставить ssh (например, нет интернета) —
            # не глушим службу пустым путём: падаем сразу с понятной ошибкой.
            if [ -z "$SSH_CMD" ] || ssh -V 2>&1 | grep -qi dropbear; then
                print_msg "$RED" "✗ Ошибка: после установки настоящий OpenSSH 'ssh' так и не найден в PATH."
                exit 1
            fi
            # OpenSSH ssh-keygen обязателен для генерации ключей в режиме OpenSSH
            if ! command -v ssh-keygen >/dev/null 2>&1 || is_dropbear_ssh_keygen; then
                print_msg "$RED" "✗ Ошибка: OpenSSH 'ssh-keygen' не найден (в PATH остался апплет Dropbear)."
                print_msg "$YELLOW" "→ Проверьте установку пакета openssh-keygen, либо выберите Dropbear (пункт 2)."
                exit 1
            fi
        fi
    else
        if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
            case "$PKG_MGR" in
                apt-get) pkg_install openssh-client || exit 1 ;;
                yum|dnf) pkg_install openssh-clients || exit 1 ;;
                apk)     install_openssh_pkgs ;;
            esac
        fi
        SSH_CMD="$(command -v ssh)"
        ssh_type="openssh"
    fi
}

generate_ssh_keys() {
    local ssh_type="$1"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        print_msg "$BLUE" "Генерация ключа..."
        if [ "$ssh_type" = "dropbear" ]; then
            # dropbearkey есть в базовой системе любого OpenWrt (даже 25.x, где нет opkg)
            if command -v dropbearkey >/dev/null 2>&1; then
                dropbearkey -t rsa -f /root/.ssh/id_rsa
                dropbearkey -y -f /root/.ssh/id_rsa | grep "^ssh-rsa" > /root/.ssh/id_rsa.pub
            elif command -v ssh-keygen >/dev/null 2>&1; then
                print_msg "$YELLOW" "ℹ dropbearkey не найден — генерирую ключ через ssh-keygen."
                # Флаги подбираем по типу ssh-keygen: апплет Dropbear не понимает -b/-N
                if is_dropbear_ssh_keygen; then
                    ssh-keygen -t rsa -f /root/.ssh/id_rsa
                    ssh-keygen -y -f /root/.ssh/id_rsa > /root/.ssh/id_rsa.pub
                else
                    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" </dev/null
                fi
            else
                print_msg "$RED" "✗ Ошибка: нет ни dropbearkey, ни ssh-keygen для генерации ключа!"
                exit 1
            fi
        else
            # ВАЖНО: в базовой системе OpenWrt /usr/bin/ssh-keygen — это апплет Dropbear,
            # который НЕ понимает флаги OpenSSH (-b 4096, -N ""). Он умеет только
            # -t rsa|ed25519 -f FILE [-s bits] [-C comment]. Поэтому ключ генерируется
            # через dropbearkey (тот же формат, что и у dropbear-апплета ssh-keygen),
            # а настоящий OpenSSH ssh-keygen используется только если это именно он.
            if command -v dropbearkey >/dev/null 2>&1 && is_dropbear_ssh_keygen; then
                print_msg "$BLUE" "ℹ Обнаружен Dropbear ssh-keygen — использую dropbearkey для совместимости."
                dropbearkey -t rsa -f /root/.ssh/id_rsa
                dropbearkey -y -f /root/.ssh/id_rsa | sed -n 's/^ssh-rsa /ssh-rsa /p' > /root/.ssh/id_rsa.pub
            elif is_dropbear_ssh_keygen; then
                print_msg "$RED" "✗ Ошибка: ssh-keygen в системе — апплет Dropbear, но dropbearkey не найден!"
                exit 1
            else
                ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N "" </dev/null
            fi
        fi
        # Пустой .pub = падение генерации (например, unsupported key type) — удаляем,
        # чтобы при следующем запуске ключ пересоздался корректно.
        if [ -f /root/.ssh/id_rsa.pub ] && [ ! -s /root/.ssh/id_rsa.pub ]; then
            rm -f /root/.ssh/id_rsa /root/.ssh/id_rsa.pub
        fi
        if [ ! -f /root/.ssh/id_rsa ] || [ ! -s /root/.ssh/id_rsa.pub ]; then
            print_msg "$RED" "✗ Ошибка: не удалось сгенерировать SSH ключи!"; exit 1
        fi
        chmod 600 /root/.ssh/id_rsa
        chmod 644 /root/.ssh/id_rsa.pub
    fi
}

setup_ssh_config() {
    mkdir -p /etc/ssh
    [ ! -f /etc/ssh/ssh_config ] && touch /etc/ssh/ssh_config
    if ! grep -q "ServerAliveInterval" /etc/ssh/ssh_config; then
        cat >> /etc/ssh/ssh_config << EOF

Host *
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking no
EOF
    fi
    # OpenSSH не пишет known_hosts в /root/.ssh, если каталога нет (а служба стартует
    # до создания ~/.ssh) — создаём заранее и прогреваем ключ хоста VPS интерактивно.
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    if command -v ssh >/dev/null 2>&1 && ! ssh -V 2>&1 | grep -qi dropbear; then
        ssh -p "${ssh_port:-22}" -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/root/.ssh/known_hosts \
            -o BatchMode=yes -o ConnectTimeout=10 \
            "${vps_user:-root}@${vps_ip}" "true" </dev/null >/dev/null 2>&1 || true
    fi
}

copy_ssh_key() {
    local ssh_type="$1"
    local PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
    if [ -z "$PUB_KEY" ]; then print_msg "$RED" "✗ Ошибка ключа!"; exit 1; fi

    print_msg "$YELLOW" "\nКопирование ключа на VPS (введите пароль от $vps_user@$vps_ip)..."
    local REMOTE_CMD="mkdir -p ~/.ssh && echo \"$PUB_KEY\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    
    if [ "$ssh_type" = "dropbear" ]; then
        DBCLIENT="$(command -v dbclient)"
        # Первый запуск: разрешаем интерактивный ввод пароля (StrictHostKeyChecking=no
        # dbclient берёт из /etc/ssh/ssh_config, созданного setup_ssh_config)
        "$DBCLIENT" -p "$ssh_port" "${vps_user}@${vps_ip}" "$REMOTE_CMD"
        print_msg "$BLUE" "Проверка входа по ключу..."
        # Проверяем вход именно по ключу. Сначала с -B (не запрашивать пароль);
        # если флаг не поддерживается старой версией dbclient — повторяем без него.
        if "$DBCLIENT" -n -B -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" < /dev/null 2>/dev/null | grep -q "OK"; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        elif "$DBCLIENT" -n -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" < /dev/null 2>/dev/null | grep -q "OK"; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        else
            print_msg "$RED" "\n✗ Ошибка: VPS отклонил вход по ключу."
            print_msg "$YELLOW" "ℹ Скорее всего, ваш VPS блокирует ключи Dropbear (RSA-SHA1)."
            print_msg "$YELLOW" "→ Решение: Выберите OpenSSH (пункт 1) при настройке клиента.\n"
            exit 1
        fi
    else
        ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "$REMOTE_CMD"
        print_msg "$BLUE" "Проверка входа по ключу..."
        if ssh -p "$ssh_port" -i /root/.ssh/id_rsa -o BatchMode=yes -o PasswordAuthentication=no "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null | grep -q "OK"; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        else
            print_msg "$RED" "✗ Ошибка проверки ключа."; exit 1
        fi
    fi
}

setup_openwrt() {
    mkdir -p /etc/config
    cat > /etc/config/rtunn << EOF
config rtunn 'general'
    option enabled '1'
    option ssh_port '${ssh_port}'
    option vps_user '${vps_user}'
    option vps_ip '${vps_ip}'
EOF
    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1); l_host=$(echo "$t" | cut -d':' -f2); l_port=$(echo "$t" | cut -d':' -f3)
        cat >> /etc/config/rtunn << EOF

config tunnel
    option remote_port '${r_port}'
    option local_port '${l_port}'
    option local_host '${l_host}'
EOF
    done

    cat > /etc/init.d/rtunn << 'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=15
USE_PROCD=1
[ -f /lib/functions.sh ] && . /lib/functions.sh

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
    local enabled vps_user vps_ip ssh_port
    config_get_bool enabled general enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get vps_user general vps_user "root"
    config_get vps_ip general vps_ip
    config_get ssh_port general ssh_port "22"
    
    local ssh_cmd=""
    # Предпочитаем OpenSSH, если он реально установлен (не symlink на dbclient)
    if command -v ssh >/dev/null 2>&1 && ! ssh -V 2>&1 | grep -qi dropbear; then
        ssh_cmd="$(command -v ssh)"
    elif command -v dbclient >/dev/null 2>&1; then
        # Dropbear входит в базовую систему любого OpenWrt (старого и нового)
        ssh_cmd="$(command -v dbclient)"
    else
        echo "rtunn: не найден ни ssh, ни dbclient" >&2
        return 1
    fi

    procd_open_instance
    procd_set_param command "$ssh_cmd"
    procd_append_param command -NT -i /root/.ssh/id_rsa
    
    # Флаги поддержания активности соединения в зависимости от клиента
    case "$ssh_cmd" in
        */dbclient)
            # keepalive каждые 30 сек; -o KeepAlive поддерживается всеми версиями Dropbear
            procd_append_param command -o KeepAlive=30
            ;;
        *)
            procd_append_param command -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes
            ;;
    esac

    config_foreach append_tunnel tunnel
    # dbclient не понимает OpenSSH-флаги; для OpenSSH задаём явный known_hosts,
    # т.к. в procd нет TTY и интерактивное подтверждение ключа хоста невозможно
    case "$ssh_cmd" in
        */dbclient) procd_append_param command "${vps_user}@${vps_ip}" -p "${ssh_port}" ;;
        *) procd_append_param command -o "UserKnownHostsFile=/root/.ssh/known_hosts" "${vps_user}@${vps_ip}" -p "${ssh_port}" ;;
    esac
    
    # OpenWrt 25 respawn (порог_времени таймаут кол-во_попыток) - 0 для бесконечного рестарта
    procd_set_param respawn 3600 5 0
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}
service_triggers() { procd_add_reload_trigger "rtunn"; }
reload_service() { stop; start; }
EOF
    chmod +x /etc/init.d/rtunn
    /etc/init.d/rtunn enable
    /etc/init.d/rtunn start
}

setup_systemd() {
    local TUNNEL_ARGS=""
    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1); l_host=$(echo "$t" | cut -d':' -f2); l_port=$(echo "$t" | cut -d':' -f3)
        TUNNEL_ARGS="$TUNNEL_ARGS -R ${r_port}:${l_host}:${l_port}"
    done
    cat > /etc/systemd/system/rtunn.service << EOF
[Unit]
Description=Reverse SSH Tunnel Service
After=network.target

[Service]
Environment="AUTOSSH_GATETIME=0"
ExecStart=${SSH_CMD} -NT -i /root/.ssh/id_rsa -o "ServerAliveInterval=30" -o "ServerAliveCountMax=3" -o "ExitOnForwardFailure=yes" -o "StrictHostKeyChecking=no" ${TUNNEL_ARGS} ${vps_user}@${vps_ip} -p ${ssh_port}
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable rtunn.service
    systemctl restart rtunn.service
}

# --- Интерфейс пользователя ---
show_header() {
    # clear может отсутствовать в минимальных системах (BusyBox без coreutils)
    command -v clear >/dev/null 2>&1 && clear || printf '\033[2J\033[H'
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║      Менеджер обратных SSH-туннелей (OpenWRT & Linux)      ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

get_input() {
    local prompt="$1"
    local default="$2"
    if [ -n "$default" ]; then printf "${prompt} [${GREEN}%s${NC}]: " "$default"
    else printf "${prompt}: "; fi
}

run_wizard() {
    TUNNELS=""
    ssh_type="openssh"
    if [ "$OS_TYPE" = "openwrt" ]; then
        printf "\n${YELLOW}Выберите SSH клиент:${NC}\n"
        printf "1) OpenSSH (рекомендуется для новых VPS серверов)\n2) Dropbear (только если VPS поддерживает RSA-SHA1)\n"
        printf "Ваш выбор (1/2) [1]: "
        read -r ssh_choice < /dev/tty
        [ "$ssh_choice" = "2" ] && ssh_type="dropbear"
    fi

    setup_ssh "$ssh_type"

    printf "\n${YELLOW}═══ Подключение к VPS ═══${NC}\n"
    while true; do
        get_input "IP-адрес VPS сервера" ""
        read -r vps_ip < /dev/tty
        validate_ip "$vps_ip" && break || print_msg "$RED" "✗ Некорректный IP-адрес"
    done
    get_input "Порт SSH на VPS" "22"; read -r ssh_port < /dev/tty; ssh_port=${ssh_port:-22}
    get_input "Пользователь на VPS" "root"; read -r vps_user < /dev/tty; vps_user=${vps_user:-root}

    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    get_input "Сколько туннелей настроить?" "1"; read -r tunnel_count < /dev/tty; tunnel_count=${tunnel_count:-1}
    i=1
    while [ $i -le $tunnel_count ]; do
        printf "\n${CYAN}--- Туннель %d ---${NC}\n" "$i"
        while true; do get_input "Удаленный порт (на VPS)" ""; read -r remote_port < /dev/tty; validate_port "$remote_port" && break || print_msg "$RED" "✗ Ошибка"; done
        while true; do get_input "Локальный порт (на устройстве)" ""; read -r local_port < /dev/tty; validate_port "$local_port" && break || print_msg "$RED" "✗ Ошибка"; done
        get_input "Локальный хост" "localhost"; read -r local_host < /dev/tty; local_host=${local_host:-localhost}
        TUNNELS="${TUNNELS}${remote_port}:${local_host}:${local_port} "
        i=$((i + 1))
    done

    printf "\n${BLUE}Настройка системы...${NC}\n"
    generate_ssh_keys "$ssh_type"
    setup_ssh_config
    copy_ssh_key "$ssh_type"

    if [ "$OS_TYPE" = "openwrt" ]; then setup_openwrt
    else setup_systemd; fi
    save_state "$ssh_type"
    print_msg "$GREEN" "\n✓ Настройка завершена!"
}

# === Главный цикл ===
main() {
    show_header
    detect_os
    create_tunnel_alias
    check_installation

    if [ "$IS_INSTALLED" -eq 1 ]; then
        # Если служба найдена на диске, но текущая ОС определена иначе
        # (например, запуск через 'tunnel' в нестандартном окружении) —
        # приводим OS_TYPE к типу найденной службы, чтобы меню работало корректно.
        local skind
        skind="$(service_kind)"
        if [ "$skind" = "openwrt" ] && [ "$OS_TYPE" != "openwrt" ]; then
            OS_TYPE="openwrt"
        elif [ "$skind" = "systemd" ] && [ "$OS_TYPE" != "systemd" ]; then
            OS_TYPE="systemd"
        fi
        show_current_config
        printf "\n${YELLOW}Меню управления:${NC}\n"
        printf "  1) Добавить новый туннель к текущим\n"
        printf "  2) Перезапустить службу\n"
        printf "  3) Полностью перенастроить службу (заменить все)\n"
        printf "  4) ${RED}Удалить службу из системы${NC}\n"
        printf "  0) Выход\n"
        
        while true; do
            printf "\nВыберите действие: "
            read -r action < /dev/tty
            case "$action" in
                1) add_tunnel_to_existing; break;;
                2) restart_service; break;;
                3) print_msg "$YELLOW" "Запуск первоначальной настройки..."; run_wizard; break;;
                4) uninstall_service; break;;
                0) exit 0;;
                *) print_msg "$RED" "Неверный выбор. Введите 1, 2, 3, 4 или 0.";;
            esac
        done
    else
        print_msg "$BLUE" "Служба не найдена. Запуск мастера установки..."
        run_wizard
    fi
}

main "$@"
