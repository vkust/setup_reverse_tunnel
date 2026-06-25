#!/bin/sh

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
IS_INSTALLED=0

print_msg() {
    local color="$1"
    local msg="$2"
    printf "${color}${msg}${NC}\n"
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
        PKG_MGR="opkg"
    elif command -v systemctl >/dev/null 2>&1; then
        OS_TYPE="systemd"
        if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt-get"
        elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
        elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
        elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
        else print_msg "$RED" "Не удалось определить пакетный менеджер."; exit 1; fi
    else print_msg "$RED" "Поддерживается только OpenWRT или systemd."; exit 1; fi
}

check_installation() {
    if [ "$OS_TYPE" = "openwrt" ] && [ -f /etc/config/reverse-tunnel ]; then
        IS_INSTALLED=1
    elif [ "$OS_TYPE" = "systemd" ] && [ -f /etc/systemd/system/reverse-tunnel.service ]; then
        IS_INSTALLED=1
    fi
}

create_tunnel_alias() {
    if [ ! -f /usr/bin/tunnel ]; then
        cat > /usr/bin/tunnel << 'EOF'
#!/bin/sh
wget -qO - https://raw.githubusercontent.com/vkust/setup_reverse_tunnel/main/setup_reverse_tunnel.sh | sh
EOF
        chmod +x /usr/bin/tunnel
        print_msg "$YELLOW" "💡 В систему добавлена команда 'tunnel'. Теперь вы можете вызывать это меню в любой момент!"
    fi
}

# --- 2. Функции управления текущей конфигурацией ---
show_current_config() {
    local current_client="OpenSSH"
    if [ "$OS_TYPE" = "openwrt" ]; then
        if command -v ssh >/dev/null 2>&1 && ssh -V 2>&1 | grep -qi dropbear; then current_client="Dropbear"
        elif ! command -v ssh >/dev/null 2>&1; then current_client="Dropbear"; fi
    fi

    print_msg "$CYAN" "\nТекущая конфигурация службы:"
    echo "------------------------------------------------"
    printf "SSH Клиент:  ${GREEN}%s${NC}\n" "$current_client"
    
    if [ "$OS_TYPE" = "openwrt" ]; then
        local v_ip=$(uci -q get reverse-tunnel.general.vps_ip)
        local v_user=$(uci -q get reverse-tunnel.general.vps_user)
        local v_port=$(uci -q get reverse-tunnel.general.ssh_port)
        printf "VPS Сервер:  ${GREEN}%s@%s${NC} (Порт: %s)\n" "$v_user" "$v_ip" "$v_port"
        echo "Туннели:"
        for section in $(uci show reverse-tunnel 2>/dev/null | grep '=tunnel' | cut -d= -f1); do
            local r=$(uci -q get ${section}.remote_port)
            local l=$(uci -q get ${section}.local_port)
            local h=$(uci -q get ${section}.local_host)
            printf "  ► VPS порт ${YELLOW}%-5s${NC} -> Локально ${YELLOW}%s:%s${NC}\n" "$r" "$h" "$l"
        done
        printf "Статус: "
        /etc/init.d/reverse-tunnel status
    else
        local exec_line=$(grep "^ExecStart=" /etc/systemd/system/reverse-tunnel.service)
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
        systemctl is-active reverse-tunnel.service
    fi
    echo "------------------------------------------------"
}

uninstall_service() {
    print_msg "$YELLOW" "\nОстановка и удаление службы..."
    if [ "$OS_TYPE" = "openwrt" ]; then
        /etc/init.d/reverse-tunnel stop >/dev/null 2>&1
        /etc/init.d/reverse-tunnel disable >/dev/null 2>&1
        rm -f /etc/init.d/reverse-tunnel
        rm -f /etc/config/reverse-tunnel
    else
        systemctl stop reverse-tunnel.service >/dev/null 2>&1
        systemctl disable reverse-tunnel.service >/dev/null 2>&1
        rm -f /etc/systemd/system/reverse-tunnel.service
        systemctl daemon-reload
    fi
    print_msg "$GREEN" "✓ Служба успешно удалена из системы."
    IS_INSTALLED=0
}

add_tunnel_to_existing() {
    print_msg "$BLUE" "\n--- Добавление нового туннеля ---"
    while true; do
        printf "Удаленный порт (на VPS): "; read r_port
        validate_port "$r_port" && break || print_msg "$RED" "✗ Некорректный порт"
    done
    while true; do
        printf "Локальный порт (на устройстве): "; read l_port
        validate_port "$l_port" && break || print_msg "$RED" "✗ Некорректный порт"
    done
    printf "Локальный хост [localhost]: "; read l_host; l_host=${l_host:-localhost}

    if [ "$OS_TYPE" = "openwrt" ]; then
        local section=$(uci add reverse-tunnel tunnel)
        uci set reverse-tunnel.${section}.remote_port="$r_port"
        uci set reverse-tunnel.${section}.local_port="$l_port"
        uci set reverse-tunnel.${section}.local_host="$l_host"
        uci commit reverse-tunnel
        print_msg "$YELLOW" "Перезапуск службы..."
        /etc/init.d/reverse-tunnel restart
    else
        local exec_line=$(grep "^ExecStart=" /etc/systemd/system/reverse-tunnel.service)
        local new_exec=$(echo "$exec_line" | sed "s/ \([^ ]*@[^ ]* -p [0-9]*\)$/ -R ${r_port}:${l_host}:${l_port} \1/")
        sed -i "s|^ExecStart=.*|$new_exec|" /etc/systemd/system/reverse-tunnel.service
        print_msg "$YELLOW" "Перезапуск службы..."
        systemctl daemon-reload && systemctl restart reverse-tunnel.service
    fi
    print_msg "$GREEN" "✓ Туннель успешно добавлен и запущен!"
}

# --- 3. Базовые функции установки ---
setup_ssh() {
    local ssh_type="$1"
    if [ "$OS_TYPE" = "openwrt" ]; then
        if [ "$ssh_type" = "dropbear" ]; then
            if ! command -v dbclient >/dev/null 2>&1; then opkg update && opkg install dropbear || exit 1; fi
            SSH_CMD="dbclient"
        else
            local needs_install=0
            if ! command -v ssh >/dev/null 2>&1 || ssh -V 2>&1 | grep -qi dropbear; then needs_install=1; fi
            if ! command -v ssh-keygen >/dev/null 2>&1 || ssh-keygen 2>&1 | grep -qi dropbear; then needs_install=1; fi
            if [ "$needs_install" -eq 1 ]; then opkg update && opkg install openssh-client openssh-keygen || exit 1; fi
            SSH_CMD="/usr/bin/ssh"
        fi
    else
        if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
            if [ "$PKG_MGR" = "apt-get" ]; then apt-get update && apt-get install -y openssh-client
            elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then $PKG_MGR install -y openssh-clients
            elif [ "$PKG_MGR" = "apk" ]; then apk add openssh-client; fi
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
            dropbearkey -t rsa -f /root/.ssh/id_rsa
            dropbearkey -y -f /root/.ssh/id_rsa | grep "^ssh-rsa" > /root/.ssh/id_rsa.pub
        else
            ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
        fi
        if [ ! -f /root/.ssh/id_rsa ] || [ ! -f /root/.ssh/id_rsa.pub ]; then
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
}

copy_ssh_key() {
    local ssh_type="$1"
    local PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
    if [ -z "$PUB_KEY" ]; then print_msg "$RED" "✗ Ошибка ключа!"; exit 1; fi

    print_msg "$YELLOW" "\nКопирование ключа на VPS (введите пароль от $vps_user@$vps_ip)..."
    local REMOTE_CMD="mkdir -p ~/.ssh && echo \"$PUB_KEY\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    
    if [ "$ssh_type" = "dropbear" ]; then
        dbclient -p "$ssh_port" "${vps_user}@${vps_ip}" "$REMOTE_CMD"
        print_msg "$BLUE" "Проверка входа по ключу..."
        # Закрываем поток ввода, чтобы Dropbear не запрашивал пароль снова, если ключ отвергнут
        if dbclient -y -i /root/.ssh/id_rsa -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" < /dev/null 2>&1 | grep -q "OK"; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        else
            print_msg "$RED" "\n✗ Ошибка: VPS отклонил вход по ключу."
            print_msg "$YELLOW" "ℹ Скорее всего, ваш VPS использует современный Linux (Ubuntu 22.04+), который блокирует старые ключи Dropbear (RSA-SHA1)."
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
    cat > /etc/config/reverse-tunnel << EOF
config reverse-tunnel 'general'
    option enabled '1'
    option ssh_port '${ssh_port}'
    option vps_user '${vps_user}'
    option vps_ip '${vps_ip}'
EOF
    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1); l_host=$(echo "$t" | cut -d':' -f2); l_port=$(echo "$t" | cut -d':' -f3)
        cat >> /etc/config/reverse-tunnel << EOF

config tunnel
    option remote_port '${r_port}'
    option local_port '${l_port}'
    option local_host '${l_host}'
EOF
    done

    cat > /etc/init.d/reverse-tunnel << 'EOF'
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
    config_load reverse-tunnel
    local enabled vps_user vps_ip ssh_port
    config_get_bool enabled general enabled 1
    [ "$enabled" -eq 1 ] || return 0
    config_get vps_user general vps_user "root"
    config_get vps_ip general vps_ip
    config_get ssh_port general ssh_port "22"
    
    local ssh_cmd="/usr/bin/ssh"
    if command -v ssh >/dev/null 2>&1 && ssh -V 2>&1 | grep -qi dropbear; then ssh_cmd="$(command -v dbclient)"
    elif ! command -v ssh >/dev/null 2>&1; then ssh_cmd="$(command -v dbclient)"; fi
    
    procd_open_instance
    procd_set_param command "$ssh_cmd"
    procd_append_param command -NT -i /root/.ssh/id_rsa
    config_foreach append_tunnel tunnel
    procd_append_param command "${vps_user}@${vps_ip}" -y -p "${ssh_port}"
    procd_set_param respawn 5 10 5
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}
service_triggers() { procd_add_reload_trigger "reverse-tunnel"; }
reload_service() { stop; start; }
EOF
    chmod +x /etc/init.d/reverse-tunnel
    /etc/init.d/reverse-tunnel enable
    /etc/init.d/reverse-tunnel start
}

setup_systemd() {
    local TUNNEL_ARGS=""
    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1); l_host=$(echo "$t" | cut -d':' -f2); l_port=$(echo "$t" | cut -d':' -f3)
        TUNNEL_ARGS="$TUNNEL_ARGS -R ${r_port}:${l_host}:${l_port}"
    done
    cat > /etc/systemd/system/reverse-tunnel.service << EOF
[Unit]
Description=Reverse SSH Tunnel Service
After=network.target

[Service]
Environment="AUTOSSH_GATETIME=0"
ExecStart=${SSH_CMD} -NT -i /root/.ssh/id_rsa -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -o "ExitOnForwardFailure yes" -o "StrictHostKeyChecking no" ${TUNNEL_ARGS} ${vps_user}@${vps_ip} -p ${ssh_port}
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable reverse-tunnel.service
    systemctl restart reverse-tunnel.service
}

# --- Интерфейс пользователя ---
show_header() {
    clear
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
        read -p "Ваш выбор (1/2) [1]: " ssh_choice
        [ "$ssh_choice" = "2" ] && ssh_type="dropbear"
    fi

    setup_ssh "$ssh_type"

    printf "\n${YELLOW}═══ Подключение к VPS ═══${NC}\n"
    while true; do
        get_input "IP-адрес VPS сервера" ""
        read vps_ip
        validate_ip "$vps_ip" && break || print_msg "$RED" "✗ Некорректный IP-адрес"
    done
    get_input "Порт SSH на VPS" "22"; read ssh_port; ssh_port=${ssh_port:-22}
    get_input "Пользователь на VPS" "root"; read vps_user; vps_user=${vps_user:-root}

    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    get_input "Сколько туннелей настроить?" "1"; read tunnel_count; tunnel_count=${tunnel_count:-1}
    i=1
    while [ $i -le $tunnel_count ]; do
        printf "\n${CYAN}--- Туннель %d ---${NC}\n" "$i"
        while true; do get_input "Удаленный порт (на VPS)" ""; read remote_port; validate_port "$remote_port" && break || print_msg "$RED" "✗ Ошибка"; done
        while true; do get_input "Локальный порт (на устройстве)" ""; read local_port; validate_port "$local_port" && break || print_msg "$RED" "✗ Ошибка"; done
        get_input "Локальный хост" "localhost"; read local_host; local_host=${local_host:-localhost}
        TUNNELS="${TUNNELS}${remote_port}:${local_host}:${local_port} "
        i=$((i + 1))
    done

    printf "\n${BLUE}Настройка системы...${NC}\n"
    generate_ssh_keys "$ssh_type"
    setup_ssh_config
    copy_ssh_key "$ssh_type"

    if [ "$OS_TYPE" = "openwrt" ]; then setup_openwrt
    else setup_systemd; fi
    print_msg "$GREEN" "\n✓ Настройка завершена!"
}

# === Главный цикл ===
main() {
    show_header
    detect_os
    create_tunnel_alias
    check_installation

    if [ "$IS_INSTALLED" -eq 1 ]; then
        show_current_config
        printf "\n${YELLOW}Меню управления:${NC}\n"
        printf "  1) Добавить новый туннель к текущим\n"
        printf "  2) Полностью перенастроить службу (заменить все)\n"
        printf "  3) ${RED}Удалить службу из системы${NC}\n"
        printf "  0) Выход\n"
        
        while true; do
            printf "\nВыберите действие: "
            read action
            case "$action" in
                1) add_tunnel_to_existing; break;;
                2) print_msg "$YELLOW" "Запуск первоначальной настройки..."; run_wizard; break;;
                3) uninstall_service; break;;
                0) exit 0;;
                *) print_msg "$RED" "Неверный выбор. Введите 1, 2, 3 или 0.";;
            esac
        done
    else
        print_msg "$BLUE" "Служба не найдена. Запуск мастера установки..."
        run_wizard
    fi
}

main "$@"
