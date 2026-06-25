#!/bin/sh

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Глобальные переменные
OS_TYPE=""
PKG_MGR=""
TUNNELS=""

print_msg() {
    local color="$1"
    local msg="$2"
    printf "${color}${msg}${NC}\n"
}

validate_ip() {
    local ip="$1"
    if echo "$ip" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null; then
        for octet in $(echo "$ip" | tr '.' ' '); do
            if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_port() {
    local port="$1"
    if echo "$port" | grep -E '^[0-9]+$' >/dev/null && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# --- 1. Определение архитектуры и ОС ---
detect_os() {
    if [ -f /etc/openwrt_release ]; then
        OS_TYPE="openwrt"
        PKG_MGR="opkg"
    elif command -v systemctl >/dev/null 2>&1; then
        OS_TYPE="systemd"
        if command -v apt-get >/dev/null 2>&1; then
            PKG_MGR="apt-get"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MGR="yum"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        elif command -v apk >/dev/null 2>&1; then
            PKG_MGR="apk"
        else
            print_msg "$RED" "Не удалось определить пакетный менеджер Linux."
            exit 1
        fi
    else
        print_msg "$RED" "Скрипт поддерживает только OpenWRT или системы с systemd."
        exit 1
    fi
    print_msg "$BLUE" "→ Обнаружена система: $OS_TYPE (Пакетный менеджер: $PKG_MGR)"
}

# --- 2. Установка зависимостей ---
setup_ssh() {
    local ssh_type="$1"
    
    if [ "$OS_TYPE" = "openwrt" ]; then
        if [ "$ssh_type" = "dropbear" ]; then
            if ! command -v dbclient >/dev/null 2>&1; then
                print_msg "$BLUE" "Установка Dropbear..."
                opkg update && opkg install dropbear
            fi
            SSH_CMD="dbclient"
        else
            if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
                print_msg "$BLUE" "Установка OpenSSH..."
                opkg update && opkg install openssh-client openssh-keygen
            fi
            SSH_CMD="/usr/bin/ssh"
        fi
    else
        # Для стандартного Linux используем OpenSSH
        if ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка OpenSSH Client..."
            if [ "$PKG_MGR" = "apt-get" ]; then
                apt-get update && apt-get install -y openssh-client
            elif [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
                $PKG_MGR install -y openssh-clients
            elif [ "$PKG_MGR" = "apk" ]; then
                apk add openssh-client
            fi
        fi
        SSH_CMD="$(command -v ssh)"
        ssh_type="openssh"
    fi
}

# --- 3. Генерация ключей ---
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
        chmod 600 /root/.ssh/id_rsa
        chmod 644 /root/.ssh/id_rsa.pub
    else
        print_msg "$GREEN" "Используется существующий SSH ключ."
    fi
}

# --- 4. Безопасная настройка конфига SSH ---
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
        print_msg "$GREEN" "Настройки SSH клиента обновлены."
    fi
}

# --- 5. Копирование ключа ---
copy_ssh_key() {
    local ssh_type="$1"
    print_msg "$YELLOW" "\nКопирование публичного ключа на VPS..."
    printf "Потребуется ввести пароль от %s@%s\n" "$vps_user" "$vps_ip"
    
    local PUB_KEY=$(cat /root/.ssh/id_rsa.pub)
    local REMOTE_CMD="mkdir -p ~/.ssh && echo \"$PUB_KEY\" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    
    if [ "$ssh_type" = "dropbear" ]; then
        dbclient -p "$ssh_port" "${vps_user}@${vps_ip}" "$REMOTE_CMD"
        if dbclient -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        else
            print_msg "$RED" "✗ Ошибка проверки ключа."
            exit 1
        fi
    else
        ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "$REMOTE_CMD"
        if ssh -p "$ssh_port" -i /root/.ssh/id_rsa "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
            print_msg "$GREEN" "✓ Ключ успешно настроен!"
        else
            print_msg "$RED" "✗ Ошибка проверки ключа."
            exit 1
        fi
    fi
}

# --- 6A. Настройка для OpenWRT (Procd + UCI) ---
setup_openwrt() {
    # 1. Запись конфига UCI
    mkdir -p /etc/config
    cat > /etc/config/reverse-tunnel << EOF
config reverse-tunnel 'general'
    option enabled '1'
    option ssh_port '${ssh_port}'
    option vps_user '${vps_user}'
    option vps_ip '${vps_ip}'
EOF

    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1)
        l_host=$(echo "$t" | cut -d':' -f2)
        l_port=$(echo "$t" | cut -d':' -f3)
        cat >> /etc/config/reverse-tunnel << EOF

config tunnel
    option remote_port '${r_port}'
    option local_port '${l_port}'
    option local_host '${l_host}'
EOF
    done

    # 2. Создание динамического init.d скрипта
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
    [ -x "/usr/bin/dbclient" ] && ssh_cmd="/usr/bin/dbclient"
    
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

service_triggers() {
    procd_add_reload_trigger "reverse-tunnel"
}

reload_service() {
    stop
    start
}
EOF
    chmod +x /etc/init.d/reverse-tunnel
    /etc/init.d/reverse-tunnel enable
    /etc/init.d/reverse-tunnel start
}

# --- 6B. Настройка для Linux (Systemd) ---
setup_systemd() {
    local TUNNEL_ARGS=""
    for t in $TUNNELS; do
        r_port=$(echo "$t" | cut -d':' -f1)
        l_host=$(echo "$t" | cut -d':' -f2)
        l_port=$(echo "$t" | cut -d':' -f3)
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
    printf "${BLUE}║      Настройка универсального обратного SSH-туннеля        ║${NC}\n"
    printf "${BLUE}║               (OpenWRT & Standard Linux)                   ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n\n"
}

get_input() {
    local prompt="$1"
    local default="$2"
    local hint="$3"
    
    if [ -n "$hint" ]; then
        printf "${YELLOW}ℹ ${hint}${NC}\n"
    fi
    
    if [ -n "$default" ]; then
        printf "${prompt} [${GREEN}%s${NC}]: " "$default"
    else
        printf "${prompt}: "
    fi
}

# === Главный цикл ===
main() {
    show_header
    detect_os
    
    ssh_type="openssh"
    if [ "$OS_TYPE" = "openwrt" ]; then
        printf "\n${YELLOW}Выберите SSH клиент для OpenWRT:${NC}\n"
        printf "1) OpenSSH (рекомендуется)\n"
        printf "2) Dropbear (меньше памяти)\n"
        read -p "Ваш выбор (1/2) [1]: " ssh_choice
        [ "$ssh_choice" = "2" ] && ssh_type="dropbear"
    fi

    setup_ssh "$ssh_type"

    printf "\n${YELLOW}═══ Настройка подключения к VPS ═══${NC}\n"
    while true; do
        get_input "IP-адрес VPS сервера" "" "Например: 192.168.0.100 или 8.8.8.8"
        read vps_ip
        validate_ip "$vps_ip" && break
        print_msg "$RED" "✗ Некорректный IP-адрес"
    done

    get_input "Порт SSH на VPS" "22"
    read ssh_port
    ssh_port=${ssh_port:-22}

    get_input "Пользователь на VPS" "root"
    read vps_user
    vps_user=${vps_user:-root}

    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    get_input "Сколько туннелей настроить?" "1"
    read tunnel_count
    tunnel_count=${tunnel_count:-1}

    i=1
    while [ $i -le $tunnel_count ]; do
        printf "\n${BLUE}--- Туннель %d ---${NC}\n" "$i"
        
        while true; do
            get_input "Удаленный порт (на VPS)" ""
            read remote_port
            validate_port "$remote_port" && break
            print_msg "$RED" "✗ Некорректный порт"
        done

        while true; do
            get_input "Локальный порт (на устройстве)" ""
            read local_port
            validate_port "$local_port" && break
            print_msg "$RED" "✗ Некорректный порт"
        done

        get_input "Локальный хост" "localhost"
        read local_host
        local_host=${local_host:-localhost}

        # Собираем туннели в безопасную строку
        TUNNELS="${TUNNELS}${remote_port}:${local_host}:${local_port} "
        i=$((i + 1))
    done

    printf "\n${BLUE}Настройка системы...${NC}\n"
    generate_ssh_keys "$ssh_type"
    setup_ssh_config
    copy_ssh_key "$ssh_type"

    if [ "$OS_TYPE" = "openwrt" ]; then
        setup_openwrt
        print_msg "$GREEN" "\n✓ Готово! Управление (OpenWRT):"
        printf "Статус: /etc/init.d/reverse-tunnel status\n"
        printf "Рестарт: /etc/init.d/reverse-tunnel restart\n"
        printf "Конфиг: /etc/config/reverse-tunnel\n"
    else
        setup_systemd
        print_msg "$GREEN" "\n✓ Готово! Управление (Systemd):"
        printf "Статус: systemctl status reverse-tunnel.service\n"
        printf "Рестарт: systemctl restart reverse-tunnel.service\n"
        printf "Конфиг: /etc/systemd/system/reverse-tunnel.service\n"
    fi
}

main "$@"
