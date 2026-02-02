#!/bin/sh

# ==========================================
# OpenWRT Reverse SSH Tunnel Setup Wizard
# ==========================================

CONFIG_FILE="/etc/config/reverse-tunnel"
INIT_SCRIPT="/etc/init.d/reverse-tunnel"

# Цвета
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Проверка, что скрипт запущен в интерактивном терминале или доступен tty
if [ ! -c /dev/tty ]; then
    echo "Ошибка: Невозможно получить доступ к /dev/tty."
    echo "Этот скрипт требует интерактивного ввода."
    exit 1
fi

# === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===

print_msg() {
    printf "${1}${2}${NC}\n"
}

# Функция чтения ввода специально для запуска через pipe (sh <(wget...))
get_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    
    local input
    
    if [ -n "$default" ]; then
        printf "${prompt} [${GREEN}${default}${NC}]: "
    else
        printf "${prompt}: "
    fi
    
    # Читаем строго из /dev/tty, так как stdin занят pipe-ом скрипта
    read -r input < /dev/tty
    
    if [ -z "$input" ] && [ -n "$default" ]; then
        export "$var_name"="$default"
    else
        export "$var_name"="$input"
    fi
}

validate_ip() {
    echo "$1" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
    ! echo "$1" | grep -E '25[6-9]|2[6-9][0-9]|[3-9][0-9]{2}' >/dev/null
}

validate_port() {
    echo "$1" | grep -E '^[0-9]+$' >/dev/null && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# === УСТАНОВКА ПО ===

check_and_install_software() {
    local type="$1"
    
    print_msg "$BLUE" "Проверка установленных пакетов..."

    # Обновляем списки пакетов, если они старые (опционально, но надежнее)
    if [ -z "$(ls -A /var/opkg-lists 2>/dev/null)" ]; then
        print_msg "$YELLOW" "Обновление списков пакетов (opkg update)..."
        opkg update >/dev/null 2>&1
    fi

    if [ "$type" = "dropbear" ]; then
        if ! command -v dbclient >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка Dropbear..."
            opkg install dropbear
        else
            print_msg "$GREEN" "Dropbear уже установлен."
        fi
    else
        # OpenSSH Client
        if ! command -v ssh >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка openssh-client..."
            opkg install openssh-client
        else
             print_msg "$GREEN" "OpenSSH client уже установлен."
        fi
        
        # OpenSSH Keygen (часто идет отдельным пакетом в OpenWRT)
        if ! command -v ssh-keygen >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка openssh-keygen..."
            opkg install openssh-keygen
        fi
    fi
}

# === ГЕНЕРАЦИЯ КЛЮЧЕЙ ===

generate_keys() {
    local type="$1"
    local key_path="/root/.ssh/id_rsa"
    
    mkdir -p /root/.ssh
    
    if [ -f "$key_path" ]; then
        print_msg "$YELLOW" "Найден существующий ключ ($key_path). Пропускаем генерацию."
        return
    fi

    print_msg "$BLUE" "Генерация SSH ключей..."
    
    if [ "$type" = "dropbear" ]; then
        dropbearkey -t rsa -f "$key_path"
        # Создаем .pub файл в формате OpenSSH для authorized_keys
        dropbearkey -y -f "$key_path" | grep "^ssh-rsa" > "${key_path}.pub"
    else
        if ! command -v ssh-keygen >/dev/null 2>&1; then
            print_msg "$RED" "Ошибка: ssh-keygen не найден!"
            exit 1
        fi
        ssh-keygen -t rsa -b 4096 -f "$key_path" -N ""
    fi
    
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    print_msg "$GREEN" "Ключи созданы."
}

# === КОНФИГУРАЦИЯ UCI ===

init_config() {
    touch "$CONFIG_FILE"
    
    # Создаем секцию general, если нет
    if ! uci -q get reverse-tunnel.general >/dev/null; then
        uci set reverse-tunnel.general=globals
        uci set reverse-tunnel.general.enabled='1'
        uci set reverse-tunnel.general.identity_file='/root/.ssh/id_rsa'
    fi
    
    uci set reverse-tunnel.general.ssh_type="$INPUT_SSH_TYPE"
    uci set reverse-tunnel.general.vps_ip="$INPUT_VPS_IP"
    uci set reverse-tunnel.general.vps_user="$INPUT_VPS_USER"
    uci set reverse-tunnel.general.ssh_port="$INPUT_SSH_PORT"
    
    uci commit reverse-tunnel
}

add_tunnel_entry() {
    local r_port="$1"
    local l_port="$2"
    local l_host="$3"
    local name="tunnel_${r_port}"
    
    uci set reverse-tunnel."$name"=tunnel
    uci set reverse-tunnel."$name".remote_port="$r_port"
    uci set reverse-tunnel."$name".local_port="$l_port"
    uci set reverse-tunnel."$name".local_host="$l_host"
    uci commit reverse-tunnel
}

# === INIT SCRIPT ===

create_init_script() {
    print_msg "$BLUE" "Создание службы /etc/init.d/reverse-tunnel..."

    cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    config_load reverse-tunnel
    
    local enabled
    config_get_bool enabled general enabled 1
    [ "$enabled" -eq 1 ] || return 0
    
    local vps_ip vps_user ssh_port ssh_type identity_file
    config_get vps_ip general vps_ip
    config_get vps_user general vps_user
    config_get ssh_port general ssh_port '22'
    config_get ssh_type general ssh_type 'openssh'
    config_get identity_file general identity_file '/root/.ssh/id_rsa'
    
    [ -z "$vps_ip" ] && return 1

    local cmd args
    local tunnel_args=""

    if [ "$ssh_type" = "dropbear" ]; then
        cmd="/usr/bin/dbclient"
        args="-y -K 30 -i $identity_file"
    else
        cmd="/usr/bin/ssh"
        args="-i $identity_file -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
    fi

    handle_tunnel() {
        local config="$1"
        local remote_port local_port local_host
        config_get remote_port "$config" remote_port
        config_get local_port "$config" local_port
        config_get local_host "$config" local_host 'localhost'
        
        if [ -n "$remote_port" ] && [ -n "$local_port" ]; then
            tunnel_args="$tunnel_args -R ${remote_port}:${local_host}:${local_port}"
        fi
    }
    
    config_foreach handle_tunnel tunnel

    if [ -z "$tunnel_args" ]; then
        return 1
    fi

    procd_open_instance
    procd_set_param command $cmd -N -T -p "$ssh_port" $args $tunnel_args "${vps_user}@${vps_ip}"
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "reverse-tunnel"
}
EOF
    chmod +x "$INIT_SCRIPT"
}

# === КОПИРОВАНИЕ ID ===

copy_id_to_vps() {
    print_msg "$BLUE" "\nКопирование ключа на VPS..."
    print_msg "$YELLOW" "Введите пароль пользователя ${INPUT_VPS_USER}@${INPUT_VPS_IP} если будет запрос:"
    
    local pub_key=$(cat /root/.ssh/id_rsa.pub)
    # Команда, которая выполнится на сервере
    local remote_cmd="mkdir -p ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
    
    if [ "$INPUT_SSH_TYPE" = "dropbear" ]; then
        # Dropbear не имеет ssh-copy-id, делаем вручную
        # Важно: используем < /dev/tty для ввода пароля, если dbclient его запросит
        dbclient -p "$INPUT_SSH_PORT" "${INPUT_VPS_USER}@${INPUT_VPS_IP}" "$remote_cmd" < /dev/tty
    else
        ssh -p "$INPUT_SSH_PORT" -o StrictHostKeyChecking=no "${INPUT_VPS_USER}@${INPUT_VPS_IP}" "$remote_cmd" < /dev/tty
    fi
    
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "✓ Ключ успешно скопирован."
    else
        print_msg "$RED" "✗ Ошибка копирования ключа. Проверьте пароль или доступность VPS."
        print_msg "$YELLOW" "Вы можете скопировать ключ вручную из /root/.ssh/id_rsa.pub"
    fi
}

# === ГЛАВНАЯ ФУНКЦИЯ ===

main() {
    clear
    print_msg "$BLUE" "╔════════════════════════════════════════╗"
    print_msg "$BLUE" "║   OpenWRT Reverse Tunnel Setup Tool    ║"
    print_msg "$BLUE" "╚════════════════════════════════════════╝"
    echo

    # 1. Выбор SSH клиента
    print_msg "$YELLOW" "Выберите тип SSH клиента:"
    echo "1) OpenSSH (Рекомендуется)"
    echo "2) Dropbear (Легкий)"
    
    while true; do
        get_input "Ваш выбор" "SEL" "1"
        case "$SEL" in
            1) INPUT_SSH_TYPE="openssh"; break ;;
            2) INPUT_SSH_TYPE="dropbear"; break ;;
            *) print_msg "$RED" "Неверный выбор";;
        esac
    done

    # 2. Установка зависимостей
    check_and_install_software "$INPUT_SSH_TYPE"
    
    # 3. Генерация ключей
    generate_keys "$INPUT_SSH_TYPE"

    # 4. Настройка параметров VPS
    print_msg "$YELLOW" "\n--- Параметры VPS сервера ---"
    
    while true; do
        get_input "IP адрес VPS" "INPUT_VPS_IP" ""
        if validate_ip "$INPUT_VPS_IP"; then break; fi
        print_msg "$RED" "Некорректный IP формат."
    done

    while true; do
        get_input "SSH порт VPS" "INPUT_SSH_PORT" "22"
        if validate_port "$INPUT_SSH_PORT"; then break; fi
        print_msg "$RED" "Некорректный порт."
    done

    get_input "Пользователь VPS" "INPUT_VPS_USER" "root"

    # 5. Сохранение основного конфига
    init_config

    # 6. Настройка туннелей
    while true; do
        print_msg "$YELLOW" "\n--- Добавление туннеля ---"
        
        while true; do
            get_input "Удаленный порт (VPS)" "R_PORT" ""
            if validate_port "$R_PORT"; then break; fi
            print_msg "$RED" "Введите корректный порт (1-65535)."
        done
        
        get_input "Локальный хост" "L_HOST" "localhost"
        
        while true; do
            get_input "Локальный порт (Роутер/LAN)" "L_PORT" "80"
            if validate_port "$L_PORT"; then break; fi
        done
        
        add_tunnel_entry "$R_PORT" "$L_PORT" "$L_HOST"
        
        get_input "Добавить еще туннель? (y/n)" "MORE" "n"
        if [ "$MORE" != "y" ] && [ "$MORE" != "Y" ]; then
            break
        fi
    done

    # 7. Копирование ключа
    get_input "Скопировать ключ на VPS автоматически? (y/n)" "COPY_KEY" "y"
    if [ "$COPY_KEY" = "y" ] || [ "$COPY_KEY" = "Y" ]; then
        copy_id_to_vps
    fi

    # 8. Создание и запуск службы
    create_init_script
    
    print_msg "$BLUE" "\nЗапуск службы..."
    /etc/init.d/reverse-tunnel enable
    /etc/init.d/reverse-tunnel restart
    
    sleep 2
    
    if pgrep -f "$INPUT_VPS_IP" >/dev/null; then
        print_msg "$GREEN" "✓ Служба успешно запущена!"
    else
        print_msg "$RED" "⚠ Внимание: Процесс не обнаружен."
        print_msg "$YELLOW" "Проверьте логи командой: logread -e reverse-tunnel"
    fi
    
    print_msg "$YELLOW" "\nГотово! Конфигурация находится в /etc/config/reverse-tunnel"
}

main
