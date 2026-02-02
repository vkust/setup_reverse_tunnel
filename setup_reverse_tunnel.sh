#!/bin/sh

# Проверка на наличие OpenWrt
IS_OPENWRT=0
[ -f /etc/openwrt_release ] && IS_OPENWRT=1

# Функция для определения, настоящий ли это OpenSSH или Dropbear
get_ssh_type() {
    local ssh_exe=$(which ssh)
    if [ -L "$ssh_exe" ]; then
        ls -l "$ssh_exe" | grep -q "dropbear" && echo "dropbear" && return
    fi
    ssh -V 2>&1 | grep -iq "OpenSSH" && echo "openssh" || echo "dropbear"
}

echo "--- Reverse Tunnel Setup Script ---"

# 1. Установка OpenSSH если нужно
SSH_TYPE=$(get_ssh_type)
if [ "$SSH_TYPE" = "dropbear" ]; then
    echo "Detected Dropbear as default SSH client."
    printf "Do you want to install real OpenSSH-client? (y/n): "
    read install_choice
    if [ "$install_choice" = "y" ]; then
        if [ "$IS_OPENWRT" -eq 1 ]; then
            opkg update && opkg install openssh-client openssh-keygen
        else
            sudo apt-get update && sudo apt-get install -y openssh-client
        fi
        SSH_TYPE="openssh"
    fi
fi

# 2. Генерация ключей
if [ ! -f /root/.ssh/id_rsa ]; then
    echo "Generating SSH keys..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ""
    echo "Key created. Add this public key to your VPS (authorized_keys):"
    cat /root/.ssh/id_rsa.pub
    echo "--------------------------------------------------------"
fi

# 3. Создание UCI конфига (только для OpenWrt)
if [ "$IS_OPENWRT" -eq 1 ]; then
    echo "Configuring UCI /etc/config/reverse-tunnel..."
    [ ! -f /etc/config/reverse-tunnel ] && touch /etc/config/reverse-tunnel
    
    # Записываем базовые настройки, если конфиг пуст
    if [ ! -s /etc/config/reverse-tunnel ]; then
        cat <<EOT > /etc/config/reverse-tunnel
config reverse-tunnel 'general'
    option enabled '1'
    option ssh_port '22'
    option vps_user 'root'
    option vps_ip '109.120.139.47'

config tunnel
    option remote_port '8011'
    option local_port '80'
    option local_host 'localhost'

config tunnel
    option remote_port '2211'
    option local_port '22'
    option local_host 'localhost'
EOT
    fi

    # 4. Создание умного Init-скрипта
    echo "Creating /etc/init.d/reverse-tunnel..."
    cat <<'EOT' > /etc/init.d/reverse-tunnel
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

load_general() {
    config_get VAR_ENABLED "$1" enabled "0"
    config_get VAR_VPS_IP "$1" vps_ip
    config_get VAR_VPS_USER "$1" vps_user "root"
    config_get VAR_SSH_PORT "$1" ssh_port "22"
}

run_tunnel() {
    local section="$1"
    local rport lport lhost
    config_get rport "$section" remote_port
    config_get lport "$section" local_port
    config_get lhost "$section" local_host "localhost"

    [ -z "$rport" ] || [ -z "$lport" ] && return

    procd_open_instance "$section"
    # Используем -o для игнорирования проверки ключей хоста (удобно для скриптов)
    procd_set_param command /usr/bin/ssh -NT \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=3 \
        -i /root/.ssh/id_rsa \
        -R "${rport}:${lhost}:${lport}" \
        "${VAR_VPS_USER}@${VAR_VPS_IP}" -p "$VAR_SSH_PORT"
    
    procd_set_param respawn 30 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

start_service() {
    config_load reverse-tunnel
    config_foreach load_general general
    [ "$VAR_ENABLED" = "1" ] && config_foreach run_tunnel tunnel
}
EOT

    chmod +x /etc/init.d/reverse-tunnel
    /etc/init.d/reverse-tunnel enable
    /etc/init.d/reverse-tunnel restart
    echo "Service started and enabled."
fi

echo "Done! Check logs with 'logread | grep ssh'"
