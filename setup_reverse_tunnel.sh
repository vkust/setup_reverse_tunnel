#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

# Переменные для хранения общих настроек
VAR_VPS_IP=""
VAR_VPS_USER=""
VAR_SSH_PORT=""
VAR_ENABLED=""

# Функция, которая читает общие настройки
load_general() {
    config_get VAR_ENABLED "$1" enabled "0"
    config_get VAR_VPS_IP "$1" vps_ip
    config_get VAR_VPS_USER "$1" vps_user "root"
    config_get VAR_SSH_PORT "$1" ssh_port "22"
}

# Функция, которая запускает конкретный туннель
run_tunnel() {
    local section="$1"
    local remote_port local_port local_host

    config_get remote_port "$section" remote_port
    config_get local_port "$section" local_port
    config_get local_host "$section" local_host "localhost"

    [ -z "$remote_port" ] || [ -z "$local_port" ] && return

    # Создаем отдельный экземпляр procd для каждого туннеля
    procd_open_instance "$section"
    
    # ВАЖНО: для Dropbear используйте путь к КОНВЕРТИРОВАННОМУ ключу .db
    # Если вы еще не конвертировали, замените на /root/.ssh/id_rsa
    procd_set_param command dbclient -NT \
        -i /root/.ssh/id_rsa.db \
        -R "${remote_port}:${local_host}:${local_port}" \
        "${VAR_VPS_USER}@${VAR_VPS_IP}" \
        -p "$VAR_SSH_PORT" \
        -y # Автоматически принимать ключ сервера

    procd_set_param respawn 30 5 0  # Перезапуск через 5 сек в случае падения
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

start_service() {
    config_load reverse-tunnel
    
    # Сначала загружаем общие настройки
    config_foreach load_general general
    
    # Если сервис выключен в конфиге - выходим
    [ "$VAR_ENABLED" = "0" ] && return

    # Запускаем цикл по всем секциям 'tunnel'
    config_foreach run_tunnel tunnel
}

service_triggers() {
    procd_add_reload_trigger "reverse-tunnel"
}
