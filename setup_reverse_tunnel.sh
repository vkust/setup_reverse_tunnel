#!/bin/sh

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функция для цветного вывода
print_msg() {
    local color="$1"
    local msg="$2"
    printf "${color}${msg}${NC}\n"
}

# Функция проверки IP адреса
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

# Функция проверки порта
validate_port() {
    local port="$1"
    if echo "$port" | grep -E '^[0-9]+$' >/dev/null && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

# Функция настройки SSH
setup_ssh() {
    local ssh_type="$1"
    
    if [ "$ssh_type" = "dropbear" ]; then
        if ! command -v dropbear >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка Dropbear..."
            opkg update
            opkg install dropbear
            /etc/init.d/dropbear enable
            /etc/init.d/dropbear start
        else
            print_msg "$GREEN" "Dropbear уже установлен."
        fi
        SSH_CMD="dbclient"
    else
        if ! command -v ssh >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка OpenSSH..."
            opkg update
            opkg install openssh-server openssh-sftp-server openssh-keygen
            /etc/init.d/sshd enable
            /etc/init.d/sshd start
        elif ! command -v ssh-keygen >/dev/null 2>&1; then
            print_msg "$BLUE" "Установка openssh-keygen..."
            opkg update
            opkg install openssh-keygen
        else
            print_msg "$GREEN" "OpenSSH уже установлен."
        fi
        SSH_CMD="/usr/bin/ssh"
    fi
}

# Функция генерации SSH ключей
generate_ssh_keys() {
    local ssh_type="$1"
    
    mkdir -p /root/.ssh
    if [ ! -f /root/.ssh/id_rsa ]; then
        if [ "$ssh_type" = "dropbear" ]; then
            print_msg "$BLUE" "Генерация ключа Dropbear..."
            dropbearkey -t rsa -f /root/.ssh/id_rsa
            dropbearkey -y -f /root/.ssh/id_rsa | grep "^ssh-rsa" > /root/.ssh/id_rsa.pub
            chmod 600 /root/.ssh/id_rsa
            chmod 644 /root/.ssh/id_rsa.pub
        else
            print_msg "$BLUE" "Генерация ключа OpenSSH..."
            if ! command -v ssh-keygen >/dev/null 2>&1; then
                print_msg "$RED" "Ошибка: ssh-keygen не установлен"
                exit 1
            fi
            ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
        fi
    else
        print_msg "$BLUE" "Используется существующий ключ"
    fi
}

# Функция настройки SSH конфигурации
setup_ssh_config() {
    local ssh_type="$1"
    
    mkdir -p /etc/ssh
    
    # Общие настройки SSH клиента
    cat > /etc/ssh/ssh_config << EOF
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking no
EOF

    # Настройки для OpenSSH сервера
    if [ "$ssh_type" != "dropbear" ]; then
        cat > /etc/ssh/sshd_config << EOF
AllowTcpForwarding yes
GatewayPorts yes
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
    fi
}

# Функция копирования SSH ключа
copy_ssh_key() {
    local ssh_type="$1"
    print_msg "$BLUE" "\nКопирование публичного ключа на VPS..."
    printf "Введите пароль для пользователя %s@%s когда появится запрос\n" "$vps_user" "$vps_ip"
    
    if [ "$ssh_type" = "dropbear" ]; then
        # Для Dropbear - копируем ключ и сразу проверяем
        cat /root/.ssh/id_rsa.pub | dbclient -p "$ssh_port" "${vps_user}@${vps_ip}" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
        if [ $? -eq 0 ]; then
            # Проверяем подключение
            if dbclient -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
                print_msg "$GREEN" "✓ Ключ успешно скопирован и подключение работает"
            else
                print_msg "$RED" "Ошибка: не удалось подключиться по ключу"
                print_msg "$YELLOW" "Проверьте права на файлы на VPS:"
                printf "chmod 700 ~/.ssh\n"
                printf "chmod 600 ~/.ssh/authorized_keys\n"
                exit 1
            fi
        else
            print_msg "$RED" "Ошибка: не удалось скопировать ключ"
            exit 1
        fi
    else
        # Для OpenSSH - копируем ключ и сразу проверяем
        cat /root/.ssh/id_rsa.pub | ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && chmod 700 ~/.ssh"
        if [ $? -eq 0 ]; then
            # Проверяем подключение
            if ssh -p "$ssh_port" "${vps_user}@${vps_ip}" "echo OK" 2>/dev/null; then
                print_msg "$GREEN" "✓ Ключ успешно скопирован и подключение работает"
            else
                print_msg "$RED" "Ошибка: не удалось подключиться по ключу"
                print_msg "$YELLOW" "Проверьте права на файлы на VPS:"
                printf "chmod 700 ~/.ssh\n"
                printf "chmod 600 ~/.ssh/authorized_keys\n"
                exit 1
            fi
        else
            print_msg "$RED" "Ошибка: не удалось скопировать ключ"
            exit 1
        fi
    fi
}

# Функция создания init.d скрипта
create_init_script() {
    local ssh_type="$1"

    # Добавим проверку наличия необходимых директорий
    mkdir -p /etc/init.d

    cat > /etc/init.d/reverse-tunnel << EOF
#!/bin/sh /etc/rc.common

START=99
STOP=15
USE_PROCD=1

# Добавим проверку наличия библиотек
[ -f /lib/functions.sh ] && . /lib/functions.sh
[ -f /lib/functions/procd.sh ] && . /lib/functions/procd.sh

start_service() {
    config_load reverse-tunnel
    
    procd_open_instance
    procd_set_param command ${SSH_CMD} -NT -i /root/.ssh/id_rsa \\
EOF

    # Добавление всех туннелей в команду
    for remote_port in $tunnel_ports; do
        local_host=$(echo $local_hosts | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        local_port=$(echo $local_ports | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        echo "        -R ${remote_port}:${local_host}:${local_port} \\" >> /etc/init.d/reverse-tunnel
    done

    cat >> /etc/init.d/reverse-tunnel << EOF
        ${vps_user}@${vps_ip} -y -p ${ssh_port}
    
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
}

# Функция создания конфигурационного файла
create_config() {
    if [ -f /etc/config/reverse-tunnel ]; then
        mv /etc/config/reverse-tunnel /etc/config/reverse-tunnel.backup
        print_msg "$YELLOW" "Существующая конфигурация сохранена как /etc/config/reverse-tunnel.backup"
    fi
    
    mkdir -p /etc/config
    cat > /etc/config/reverse-tunnel << EOF
config reverse-tunnel 'general'
    option enabled '1'
    option ssh_port '${ssh_port}'
    option vps_user '${vps_user}'
    option vps_ip '${vps_ip}'
EOF

    # Добавление туннелей в конфиг
    for remote_port in $tunnel_ports; do
        local_host=$(echo $local_hosts | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        local_port=$(echo $local_ports | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        cat >> /etc/config/reverse-tunnel << EOF
config tunnel
    option remote_port '${remote_port}'
    option local_port '${local_port}'
    option local_host '${local_host}'
EOF
    done
}

# Функция добавления новых туннелей
add_tunnels() {
    echo "Добавление новых туннелей к существующей конфигурации."
    for remote_port in $tunnel_ports; do
        local_host=$(echo $local_hosts | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        local_port=$(echo $local_ports | cut -d' ' -f$(echo $tunnel_ports | tr ' ' '\n' | grep -n $remote_port | cut -d':' -f1))
        cat >> /etc/config/reverse-tunnel << EOF

config tunnel
    option remote_port '${remote_port}'
    option local_port '${local_port}'
    option local_host '${local_host}'
EOF
    done
}

# Добавим новые функции для улучшения интерактивности

# Функция для отображения заголовка
show_header() {
    clear
    printf "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║            Настройка обратного SSH-туннеля                 ║${NC}\n"
    printf "${BLUE}║                      для OpenWRT                           ║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n\n"
}

# Функция для отображения меню выбора
show_menu() {
    local title="$1"
    local opt1="$2"
    local opt2="$3"
    
    printf "${YELLOW}${title}${NC}\n"
    printf "╔═══════════════════════════════════════════════════════════════╗\n"
    printf "║ ${GREEN}1)${NC} %-54s     ║\n" "$opt1"
    printf "║ ${GREEN}2)${NC} %-54s ║\n" "$opt2"
    printf "╚═══════════════════════════════════════════════════════════════╝\n"
}

# Функция для отображения прогресса настройки
show_progress() {
    local step="$1"
    local total="$2"
    local description="$3"
    
    printf "${BLUE}[%d/%d]${NC} %s\n" "$step" "$total" "$description"
}

# Функция для запроса данных с подсказкой
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

# Основная функция
main() {
    show_header

    # Проверка существующей конфигурации
    if [ -f /etc/config/reverse-tunnel ]; then
        print_msg "$YELLOW" "Обнаружена существующая конфигурация:"
        cat /etc/config/reverse-tunnel
        echo
    fi

    # Информация об установленных SSH серверах
    if command -v dropbear >/dev/null 2>&1; then
        print_msg "$GREEN" "Dropbear уже установлен."
    fi
    if command -v ssh >/dev/null 2>&1; then
        print_msg "$GREEN" "OpenSSH уже установлен."
    fi

    # Выбор SSH сервера
    show_menu "Выберите SSH сервер:" \
        "OpenSSH (рекомендуется для максимальной совместимости)" \
        "Dropbear (легковесное решение, меньше нагрузки на систему)"
    
    read -p "Введите номер (1/2): " ssh_choice
    echo

    case "$ssh_choice" in
        2) 
            ssh_type="dropbear"
            print_msg "$BLUE" "→ Выбран Dropbear"
            ;;
        *) 
            ssh_type="openssh"
            print_msg "$BLUE" "→ Выбран OpenSSH"
            ;;
    esac

    setup_ssh "$ssh_type"

    # Запрос параметров подключения
    printf "\n${YELLOW}═══ Настройка подключения к VPS ═══${NC}\n"
    
    while true; do
        get_input "Введите IP-адрес VPS сервера" "" "Пример: 192.168.0.100"
        read vps_ip
        if validate_ip "$vps_ip"; then
            print_msg "$GREEN" "✓ IP-адрес корректен"
            break
        else
            print_msg "$RED" "✗ Некорректный формат IP-адреса"
        fi
    done

    get_input "Введите порт для SSH на VPS" "22" "Стандартный порт SSH: 22"
    read ssh_port
    ssh_port=${ssh_port:-22}
    if ! validate_port "$ssh_port"; then
        print_msg "$RED" "✗ Ошибка: некорректный порт"
        exit 1
    fi

    get_input "Введите имя пользователя на VPS" "root" "Пользователь должен иметь права на создание туннелей"
    read vps_user
    vps_user=${vps_user:-root}

    # Настройка туннелей
    printf "\n${YELLOW}═══ Настройка туннелей ═══${NC}\n"
    get_input "Сколько туннелей вы хотите настроить" "1" "Можно настроить несколько туннелей для разных сервисов"
    read tunnel_count
    tunnel_count=${tunnel_count:-1}

    tunnel_ports=""
    local_ports=""
    local_hosts=""

    i=1
    while [ $i -le $tunnel_count ]; do
        printf "\n${BLUE}╔═══ Настройка туннеля %d ═══╗${NC}\n" "$i"
        
        while true; do
            get_input "Введите удаленный порт" "" "Порт на VPS сервере (1-65535)"
            read remote_port
            if validate_port "$remote_port"; then
                break
            else
                print_msg "$RED" "✗ Некорректный порт"
            fi
        done

        while true; do
            get_input "Введите локальный порт" "" "Порт на локальном устройстве (1-65535)"
            read local_port
            if validate_port "$local_port"; then
                break
            else
                print_msg "$RED" "✗ Некорректный порт"
            fi
        done

        get_input "Введите IP-адрес локального устройства" "localhost" "Оставьте пустым для localhost"
        read local_host
        local_host=${local_host:-localhost}

        tunnel_ports="$tunnel_ports $remote_port"
        local_ports="$local_ports $local_port"
        local_hosts="$local_hosts $local_host"
        i=$((i + 1))
    done

    # Проверка существующей конфигурации
    if [ -f /etc/config/reverse-tunnel ]; then
        print_msg "$YELLOW" "Обнаружена существующая конфигурация."
        read -p "Хотите добавить новые туннели к существующей конфигурации? (y/n): " add_tunnels_choice
        if [ "$add_tunnels_choice" = "y" ] || [ "$add_tunnels_choice" = "Y" ]; then
            add_tunnels
        else
            create_config
        fi
    else
        create_config
    fi

    # Остальные функции с прогрессом настройки
    show_progress 1 4 "Генерация SSH ключей"
    generate_ssh_keys "$ssh_type"
    setup_ssh_config "$ssh_type"

    show_progress 2 4 "Копирование ключа на VPS"
    copy_ssh_key "$ssh_type"

    show_progress 3 4 "Создание конфигурации"
    create_init_script

    show_progress 4 4 "Запуск сервиса"
    /etc/init.d/reverse-tunnel enable
    /etc/init.d/reverse-tunnel start

    # Проверка статуса туннеля
    print_msg "$BLUE" "\nПроверка статуса туннеля..."
    sleep 2

    if [ "$ssh_type" = "dropbear" ]; then
        if pgrep -f "dbclient.*-NT.*-R.*${vps_ip}" > /dev/null; then
            print_msg "$GREEN" "✓ Туннель успешно запущен (Dropbear)"
        else
            print_msg "$RED" "✗ Ошибка запуска туннеля"
            print_msg "$YELLOW" "Проверьте журнал: logread | grep dbclient"
            exit 1
        fi
    else
        if pgrep -f "ssh.*-NT.*-R.*${vps_ip}" > /dev/null; then
            print_msg "$GREEN" "✓ Туннель успешно запущен (OpenSSH)"
        else
            print_msg "$RED" "✗ Ошибка запуска туннеля"
            print_msg "$YELLOW" "Проверьте журнал: logread | grep ssh"
            exit 1
        fi
    fi

    # Вывод информации о настройках
    print_msg "$GREEN" "\nНастройка завершена!"

    print_msg "$YELLOW" "\nУправление службой:"
    printf "Запуск:          \033[32m/etc/init.d/reverse-tunnel start\033[0m\n"
    printf "Остановка:       \033[32m/etc/init.d/reverse-tunnel stop\033[0m\n"
    printf "Перезапуск:      \033[32m/etc/init.d/reverse-tunnel restart\033[0m\n"
    printf "Статус:          \033[32m/etc/init.d/reverse-tunnel status\033[0m\n"
    printf "Включить автозапуск:   \033[32m/etc/init.d/reverse-tunnel enable\033[0m\n"
    printf "Отключить автозапуск:  \033[32m/etc/init.d/reverse-tunnel disable\033[0m\n"

    # Информация о ручном добавлении туннелей
    print_msg "$YELLOW" "\nДля ручного добавления туннелей отредактируйте файл:"
    printf "\033[32m/etc/config/reverse-tunnel\033[0m\n"
}

main "$@"
