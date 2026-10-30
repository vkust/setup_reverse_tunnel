#!/bin/sh

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then 
    echo "Запустите скрипт от имени root"
    exit 1
fi

# === Определение пакетного менеджера (Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine) ===
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk"
else
    printf "\033[1;31m✗ Ошибка: не найден поддерживаемый пакетный менеджер (apt/dnf/yum/apk)\033[0m\n"
    exit 1
fi

# Установка пакета (тихо, с понятной ошибкой при неудаче)
pkg_install() {
    case $PKG_MGR in
        apt) apt-get install -y "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
        yum) yum install -y "$@" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
    esac
}

# Удаление пакета
pkg_remove() {
    case $PKG_MGR in
        apt) apt-get remove -y "$@" >/dev/null 2>&1 ;;
        dnf) dnf remove -y "$@" >/dev/null 2>&1 ;;
        yum) yum remove -y "$@" >/dev/null 2>&1 ;;
        apk) apk del "$@" >/dev/null 2>&1 ;;
    esac
}

# Перезапуск SSH-сервиса (имя юнита различается: ssh в Debian/Ubuntu, sshd в RHEL;
# на системах без systemd используется service/init-скрипт)
restart_ssh() {
    _ssh_unit=""
    if command -v systemctl >/dev/null 2>&1; then
        for u in ssh sshd; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^$u\.service"; then
                _ssh_unit="$u"; break
            fi
        done
    fi
    if [ -n "$_ssh_unit" ]; then
        systemctl restart "$_ssh_unit"
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null \
            || /etc/init.d/sshd restart 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null
    else
        /etc/init.d/sshd restart 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null
    fi
}

# Активен ли SSH-сервис
ssh_is_active() {
    if command -v systemctl >/dev/null 2>&1 && [ -n "$(systemctl list-unit-files 2>/dev/null | grep -E '^ss?hd?\.service')" ]; then
        for u in ssh sshd; do
            if systemctl is-active --quiet "$u" 2>/dev/null; then return 0; fi
        done
        return 1
    fi
    pgrep -x sshd >/dev/null 2>&1
}

# Чтение с приглашением (POSIX-совместимо: read -p — это bashism,
# который ломается при запуске через sh/busybox ash)
ask() {
    printf "%s" "$1"
    read -r REPLY
}

# Функция для очистки правил firewall
cleanup_firewall() {
    case $fw_choice in
        2)
            # Очистка IPTables
            printf "\033[1;32m→ Очистка правил IPTables...\033[0m\n"
            # Сохраняем текущие правила
            mkdir -p /root/firewall_backup
            timestamp=$(date +%Y%m%d_%H%M%S)
            iptables-save > "/root/firewall_backup/iptables_backup_$timestamp.rules"
            printf "Backup сохранен в: \033[32m/root/firewall_backup/iptables_backup_$timestamp.rules\033[0m\n"
            # Очищаем правила
            iptables -F
            iptables -X
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            ;;
        *)
            # Очистка UFW
            printf "\033[1;32m→ Очистка правил UFW...\033[0m\n"
            # Сохраняем текущие правила
            mkdir -p /root/firewall_backup
            timestamp=$(date +%Y%m%d_%H%M%S)
            ufw status numbered > "/root/firewall_backup/ufw_backup_$timestamp.rules"
            printf "Backup сохранен в: \033[32m/root/firewall_backup/ufw_backup_$timestamp.rules\033[0m\n"
            # Сбрасываем правила
            yes | ufw reset
            ;;
    esac
}

# Запрос портов для туннелей
printf "\n\033[1;34m=== Настройка портов туннелей ===\033[0m\n"
printf "Диапазоны портов:\n"
printf "  0-1023: системные порты (не рекомендуется)\n"
printf "  1024-49151: пользовательские порты (рекомендуется)\n"
printf "  49152-65535: динамические порты (для временных соединений)\n"

# Функция проверки портов
check_ports() {
    ports="$1"
    has_error=0

    for port in $ports; do
        # Валидация: только числа (иначе [ "$port" -lt ... ] падает с ошибкой)
        case $port in
            ''|*[!0-9]*)
                printf "\n\033[1;31m✗ Ошибка: «%s» не является номером порта\033[0m\n" "$port"
                return 1
                ;;
        esac
        if [ "$port" -lt 1024 ]; then
            printf "\n\033[1;31m✗ Ошибка: Порт %s является системным (0-1023)\033[0m\n" "$port"
            printf "Рекомендуется использовать порты из диапазона 1024-49151\n"
            has_error=1
        elif [ "$port" -gt 49151 ]; then
            printf "\n\033[1;33m⚠ Предупреждение: Порт %s находится в диапазоне динамических портов (49152-65535)\033[0m\n" "$port"
            printf "Рекомендуется использовать пользовательские порты (1024-49151)\n"
            ask "Продолжить? (1 - да/2 - нет) [2]: "; continue_anyway=$REPLY
            if [ "$continue_anyway" != "1" ]; then
                has_error=1
            fi
        fi
    done
    
    return $has_error
}

# Цикл ввода портов
while true; do
    ask "Введите порты для туннелей через пробел (например: 10022 10080): "; TUNNEL_PORTS=$REPLY
    
    if check_ports "$TUNNEL_PORTS"; then
        break
    else
        printf "\n\033[1;33mПожалуйста, введите порты заново.\033[0m\n\n"
    fi
done

# Проверка установленных firewall
printf "\n\033[1;34m=== Проверка firewall ===\033[0m\n"
printf "Сканирование системы...\n"
UFW_INSTALLED=0
IPTABLES_INSTALLED=0
UFW_ACTIVE=0

if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status | grep -q "Status: active" && echo "активен" || echo "неактивен")
    UFW_INSTALLED=1
    if [ "$UFW_STATUS" = "активен" ]; then
        UFW_ACTIVE=1
    fi
    printf "\n\033[1;32m→ UFW установлен и %s\033[0m\n" "$UFW_STATUS"
    printf "\033[1mТекущие правила UFW:\033[0m\n"
    ufw status numbered | sed 's/^/  /'
fi

if command -v iptables >/dev/null 2>&1; then
    IPTABLES_RULES=$(iptables -L INPUT -n --line-numbers | grep -E "ACCEPT|DROP" | wc -l)
    IPTABLES_INSTALLED=1
    printf "\n\033[1;32m→ IPTables установлен, найдено правил: %s\033[0m\n" "$IPTABLES_RULES"
    printf "\033[1mТекущие правила IPTables:\033[0m\n"
    iptables -L INPUT -n --line-numbers | sed 's/^/  /'
fi

printf "\n\033[1;34m=== Выбор firewall ===\033[0m\n"
printf "\033[1mДоступные опции:\033[0m\n\n"
printf "\033[1m1) UFW - современный firewall, простой в управлении\033[0m\n"
printf "   - Удобный интерфейс командной строки\n"
printf "   - Простое управление правилами\n"
printf "   - Автоматическое сохранение правил\n\n"

printf "\033[1m2) IPTables - классический firewall Linux\033[0m\n"
printf "   - Более гибкая настройка\n"
printf "   - Низкоуровневый контроль\n"
printf "   - Меньше зависимостей\n"

if [ $UFW_INSTALLED -eq 1 ] && [ $IPTABLES_INSTALLED -eq 1 ]; then
    CHOICE_MADE=0
    # Проверяем наличие активных правил
    UFW_RULES=$(ufw status numbered | grep -E "(ALLOW|DENY)" | wc -l)
    IPTABLES_RULES=$(iptables -L INPUT -n --line-numbers | grep -E "ACCEPT|DROP" | wc -l)
    
    if [ $UFW_RULES -gt 0 ] && [ $IPTABLES_RULES -gt 0 ]; then
        printf "\n\033[1;33m⚠ Внимание: Обнаружены правила в обоих firewall!\033[0m\n"
        printf "Это может привести к конфликтам и непредсказуемому поведению.\n\n"
        printf "\033[1mРекомендуемые действия:\033[0m\n"
        printf "1) Использовать UFW (текущие правила IPTables будут очищены)\n"
        printf "2) Использовать IPTables (UFW будет отключен)\n"
        printf "3) Выйти и разобраться с правилами вручную\n\n"
        ask "Выберите действие (1/2/3): "; clean_choice=$REPLY
        
        case $clean_choice in
            1)
                # Создаем директорию для бэкапов если её нет
                backup_dir="/root/firewall_backup"
                mkdir -p "$backup_dir"
                
                # Создаем бэкап с временной меткой
                timestamp=$(date +%Y%m%d_%H%M%S)
                
                printf "\n\033[1;34m→ Создание резервной копии правил IPTables...\033[0m\n"
                iptables-save > "$backup_dir/iptables_backup_$timestamp.rules"
                printf "Backup сохранен в: \033[32m%s\033[0m\n" "$backup_dir/iptables_backup_$timestamp.rules"
                
                printf "\n\033[1;34m→ Очистка правил IPTables...\033[0m\n"
                iptables -F
                iptables -X
                iptables -P INPUT ACCEPT
                iptables -P FORWARD ACCEPT
                iptables -P OUTPUT ACCEPT
                fw_choice=1
                CHOICE_MADE=1
                ;;
            2)
                # Создаем директорию для бэкапов если её нет
                backup_dir="/root/firewall_backup"
                mkdir -p "$backup_dir"
                
                # Создаем бэкап с временной меткой
                timestamp=$(date +%Y%m%d_%H%M%S)
                
                printf "\n\033[1;34m→ Создание резервной копии правил UFW...\033[0m\n"
                ufw status numbered > "$backup_dir/ufw_backup_$timestamp.rules"
                printf "Backup сохранен в: \033[32m%s\033[0m\n" "$backup_dir/ufw_backup_$timestamp.rules"
                
                printf "\n\033[1;34m→ Отключение UFW...\033[0m\n"
                ufw disable
                printf "\n\033[1;34m→ Удаление UFW...\033[0m\n"
                pkg_remove "$(pkg_name ufw)"
                fw_choice=2
                CHOICE_MADE=1
                ;;
            *)
                printf "\n\033[1;31m✗ Установка прервана.\033[0m\n"
                printf "Пожалуйста, проверьте и очистите правила firewall вручную:\n"
                printf "UFW: ufw status numbered\n"
                printf "IPTables: iptables -L INPUT -n --line-numbers\n"
                printf "\nДля восстановления правил из backup используйте:\n"
                printf "IPTables: iptables-restore < /path/to/backup.rules\n"
                printf "UFW: ufw enable && cat /path/to/backup.rules | while read rule; do ufw \$rule; done\n"
                exit 1
                ;;
        esac
    fi
    
    if [ $CHOICE_MADE -eq 0 ]; then
        printf "\nВыберите firewall для использования:\n"
        printf "1) UFW (рекомендуется, проще в управлении)\n"
        printf "2) IPTables (классический вариант)\n"
        ask "Введите номер (1/2): "; fw_choice=$REPLY
    fi
elif [ $UFW_INSTALLED -eq 1 ]; then
    printf "\nUFW уже установлен. Использовать его? [Y/n]: "
    read -r use_ufw
    if [ "$use_ufw" = "n" ] || [ "$use_ufw" = "N" ]; then
        printf "Установка IPTables...\n"
        pkg_install "$(pkg_name iptables-persistent)"
        fw_choice=2
    else
        fw_choice=1
    fi
elif [ $IPTABLES_INSTALLED -eq 1 ]; then
    printf "\nIPTables уже установлен. Использовать его? [Y/n]: "
    read -r use_iptables
    if [ "$use_iptables" = "n" ] || [ "$use_iptables" = "N" ]; then
        printf "Установка UFW...\n"
        if [ "$(pkg_name ufw)" = "" ]; then
            printf "\033[1;31m✗ Пакет ufw недоступен в вашем дистрибутиве. Используйте IPTables (вариант 2).\033[0m\n"
            fw_choice=2
        else
            pkg_install "$(pkg_name ufw)"
            fw_choice=1
        fi
    else
        fw_choice=2
    fi
else
    printf "\nНи один firewall не установлен. Какой установить?\n"
    printf "1) UFW\n"
    printf "2) IPTables\n"
    ask "Введите номер (1/2) [1]: "; fw_choice=$REPLY
    fw_choice=${fw_choice:-1}
    
    case $fw_choice in
        2)
            printf "Установка IPTables...\n"
            pkg_install "$(pkg_name iptables-persistent)"
            ;;
        *)
            if [ "$(pkg_name ufw)" = "" ]; then
                printf "\033[1;31m✗ Пакет ufw недоступен в вашем дистрибутиве — устанавливаю IPTables.\033[0m\n"
                pkg_install "$(pkg_name iptables-persistent)"
                fw_choice=2
            else
                printf "Установка UFW...\n"
                pkg_install "$(pkg_name ufw)"
            fi
            ;;
    esac
fi

# Предупреждение о конфликтах
if [ $UFW_ACTIVE -eq 1 ] && [ "$fw_choice" = "2" ]; then
    printf "\n\033[1;33m⚠ Внимание: Обнаружен конфликт!\033[0m\n"
    printf "\033[33mUFW активен и управляет правилами iptables!\033[0m\n"
    printf "Использование iptables напрямую может привести к конфликтам.\n\n"
    
    printf "\033[1mВыберите действие:\033[0m\n"
    printf "1) Только отключить UFW\n"
    printf "2) Отключить и удалить UFW\n"
    printf "3) Продолжить с активным UFW\n"
    ask "Выберите действие (1/2/3): "; disable_ufw=$REPLY
    if [ "$disable_ufw" = "1" ]; then
        printf "\n\033[1;34m→ Отключение UFW...\033[0m\n"
        ufw disable
    elif [ "$disable_ufw" = "2" ]; then
        printf "\n\033[1;34m→ Отключение UFW...\033[0m\n"
        ufw disable
        printf "\n\033[1;34m→ Удаление UFW...\033[0m\n"
        pkg_remove "$(pkg_name ufw)"
    else
        printf "\n\033[1;33m⚠ Предупреждение: Продолжение с активным UFW может привести к проблемам!\033[0m\n"
        ask "Продолжить? (1 - да/2 - нет) [2]: "; continue_anyway=$REPLY
        if [ "$continue_anyway" != "1" ]; then
            printf "\n\033[1;31m✗ Установка прервана.\033[0m\n"
            exit 1
        fi
    fi
fi

# Установка необходимых пакетов
printf "\n\033[1;34m=== Установка дополнительных пакетов ===\033[0m\n"

# Функция для проверки и установки пакета
install_package() {
    package="$1"
    # Проверка установленности средствами пакетного менеджера
    case $PKG_MGR in
        apt) _installed=$(dpkg -l "$package" 2>/dev/null | grep -c "^ii") ;;
        dnf|yum) rpm -q "$package" >/dev/null 2>&1 && _installed=1 || _installed=0 ;;
        apk) apk info -e "$package" >/dev/null 2>&1 && _installed=1 || _installed=0 ;;
    esac
    if [ "$_installed" -eq 0 ]; then
        printf "\033[1;32m→ Установка %s...\033[0m\n" "$package"
        pkg_install "$package"
    else
        printf "\033[1;32m✓ Пакет %s уже установлен\033[0m\n" "$package"
    fi
}

# Имена пакетов различаются между семействами дистрибутивов
pkg_name() {
    case "$1" in
        net-tools)
            case $PKG_MGR in
                apt|apk) echo "net-tools" ;;
                *) echo "net-tools" ;;
            esac ;;
        iptables-persistent)
            # iptables-persistent существует только в Debian/Ubuntu (apt);
            # в остальных — сам iptables, правила сохраняем отдельно
            case $PKG_MGR in
                apt) echo "iptables-persistent" ;;
                dnf|yum) echo "iptables-services" ;;
                apk) echo "iptables" ;;
            esac ;;
        ufw)
            case $PKG_MGR in
                apt) echo "ufw" ;;
                *) echo "" ;;
            esac ;;
        *) echo "$1" ;;
    esac
}

# Установка необходимых пакетов
install_package "net-tools"   # netstat (используется мониторингом как fallback)
install_package "cron"        # без cron настройка мониторинга бессмысленна
# nc (netcat-openbsd/bare) — для проверки доступности SSH; не критично, если недоступен
if ! command -v nc >/dev/null 2>&1; then
    pkg_install netcat-openbsd || pkg_install bare-netcat || true
fi

# Настройка SSH
printf "\n\033[1;34m=== Настройка SSH ===\033[0m\n"
printf "\033[1;32m→ Обновление конфигурации SSH...\033[0m\n"

# Создаем резервную копию
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Настраиваем основные параметры SSH
cat > /etc/ssh/sshd_config << EOF
# Основные настройки
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Аутентификация
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Туннелирование
AllowTcpForwarding yes
GatewayPorts clientspecified

# Таймауты
ClientAliveInterval 30
ClientAliveCountMax 3

# Безопасность
MaxAuthTries 6
MaxSessions 10

# Логирование
SyslogFacility AUTH
LogLevel INFO
EOF

# sshd -t может ругаться на устаревший ChallengeResponseAuthentication
# (в OpenSSH >= 8.7 переименован в KbdInteractiveAuthentication) — убираем,
# поведение по умолчанию (no) нас устраивает.
sed -i '/^ChallengeResponseAuthentication/d' /etc/ssh/sshd_config

# Проверяем конфигурацию
printf "\033[1;32m→ Проверка конфигурации SSH...\033[0m\n"

# Создаем необходимые директории
if [ ! -d "/run/sshd" ]; then
    printf "\033[1;32m→ Создание директории /run/sshd...\033[0m\n"
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
fi

if ! sshd -t; then
    printf "\033[1;31m✗ Ошибка в конфигурации SSH! Восстанавливаем backup...\033[0m\n"
    mv /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    restart_ssh
    exit 1
fi

# Перезапускаем SSH
printf "\033[1;32m→ Перезапуск SSH сервера...\033[0m\n"
restart_ssh

# Проверяем статус
if ! ssh_is_active; then
    printf "\033[1;31m✗ SSH сервер не запустился! Восстанавливаем backup...\033[0m\n"
    mv /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    restart_ssh
    exit 1
fi

printf "\033[1;32m✓ SSH настроен успешно\033[0m\n"

# Настройка firewall
printf "\n\033[1;34m=== Настройка firewall ===\033[0m\n"
case $fw_choice in
    2)
        # Показываем текущие правила
        printf "\nТекущие правила IPTables:\n"
        iptables -L INPUT -n --line-numbers | sed 's/^/  /'
        
        printf "\n\033[1;33m▶ Выберите действие:\033[0m\n"
        printf "1) Сохранить существующие правила и добавить новые\n"
        printf "2) Очистить все правила и создать новые\n"
        printf "3) Выйти без изменений\n"
        ask "Выберите действие (1/2/3): "; iptables_action=$REPLY
        
        case $iptables_action in
            1)
                printf "\033[1;32m→ Добавление новых правил к существующим...\033[0m\n"
                # Добавляем только отсутствующие правила
                if ! iptables -L INPUT -n | grep -q "ACCEPT.*state.*RELATED,ESTABLISHED"; then
                    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                fi
                for port in 22 $TUNNEL_PORTS; do
                    if ! iptables -L INPUT -n | grep -q "ACCEPT.*dpt:$port"; then
                        printf "\033[1;32m→ Добавляем порт %s...\033[0m\n" "$port"
                        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                    fi
                done
                # Сохраняем правила
                printf "\033[1;32m→ Сохранение правил...\033[0m\n"
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                ;;
            2)
                cleanup_firewall
                # Настройка IPTables
                printf "\033[1;32m→ Настройка правил IPTables...\033[0m\n"
                # Базовые правила
                iptables -A INPUT -i lo -j ACCEPT
                iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
                # SSH и туннели
                iptables -A INPUT -p tcp --dport 22 -j ACCEPT
                for port in $TUNNEL_PORTS; do
                    printf "\033[1;32m→ Открываем порт %s...\033[0m\n" "$port"
                    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
                done
                # Политика по умолчанию
                iptables -P INPUT DROP
                # Сохраняем правила
                printf "\033[1;32m→ Сохранение правил...\033[0m\n"
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                ;;
            *)
                printf "\n\033[1;31m✗ Установка прервана.\033[0m\n"
                exit 1
                ;;
        esac
        # Настраиваем автоматическое восстановление правил при загрузке
        printf "\033[1;32m→ Настройка автозагрузки правил...\033[0m\n"
        if ! grep -q "iptables-restore" /etc/rc.local 2>/dev/null; then
            # Создаем rc.local если его нет
            if [ ! -f /etc/rc.local ]; then
                echo "#!/bin/sh -e" > /etc/rc.local
                echo "exit 0" >> /etc/rc.local
                chmod +x /etc/rc.local
            fi
            # Добавляем восстановление правил перед exit 0
            sed -i '/exit 0/i\# Восстановление правил IPTables\niptables-restore < /etc/iptables/rules.v4' /etc/rc.local
        fi
        ;;
    *)
        # Очищаем все правила перед настройкой
        cleanup_firewall
        
        # Проверяем существующие правила UFW
        printf "\033[1;32m→ Проверка существующих правил UFW...\033[0m\n"
        NEED_RULES=0
        
        # Проверяем правила для портов
        for port in 22 $TUNNEL_PORTS; do
            if ! ufw status | grep -q "$port/tcp.*ALLOW"; then
                NEED_RULES=1
                break
            fi
        done
        
        if [ $NEED_RULES -eq 1 ]; then
            printf "\033[1;32m→ Добавление новых правил...\033[0m\n"
            ufw --force reset
            
            # Настройка UFW
            printf "\033[1;32m→ Настройка правил UFW...\033[0m\n"
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow 22/tcp
            for port in $TUNNEL_PORTS; do
                printf "\033[1;32m→ Открываем порт %s...\033[0m\n" "$port"
                ufw allow "$port/tcp"
            done
            yes | ufw enable
        else
            printf "\033[1;32m✓ Все необходимые правила уже существуют\033[0m\n"
        fi
        ;;
esac

# Проверка доступности SSH
printf "\n\033[1;34m=== Проверка доступности SSH ===\033[0m\n"
sleep 2  # Даем время на применение правил

if ! nc -zv localhost 22 2>/dev/null; then
    printf "\033[1;31m✗ SSH недоступен! Откат изменений...\033[0m\n"
    # Возвращаем исходную конфигурацию SSH (если sshd -t её не отбраковал ранее,
    # backup всё равно актуален — в нём оригинальный sshd_config)
    if [ -f /etc/ssh/sshd_config.backup ]; then
        mv /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    fi
    # Сбрасываем firewall-политики, чтобы не остаться с INPUT DROP без правил
    case $fw_choice in
        2)
            iptables -P INPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -P OUTPUT ACCEPT
            ;;
        *)
            ufw disable >/dev/null 2>&1 || true
            ;;
    esac
    restart_ssh
    exit 1
fi

printf "\033[1;32m✓ SSH доступен\033[0m\n"

# Настройка параметров ядра
printf "\n\033[1;34m=== Настройка параметров ядра ===\033[0m\n"

if [ ! -f /etc/sysctl.conf ]; then
    touch /etc/sysctl.conf
fi

printf "\033[1;32m→ Очистка дублирующихся параметров...\033[0m\n"

# Создаем временный файл
temp_file=$(mktemp)

# Оставляем только ПОСЛЕДНЕЕ вхождение каждого параметра (так делает сам sysctl:
# при дублях применяется последнее значение; старый awk оставлял первое — некорректно).
# Пустые строки и комментарии сохраняем как есть.
awk '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { lines[++n] = $0; next }
    { key=$1; sub(/[[:space:]]*=.*$/, "", key); if (!(key in last)) order[++m] = key; last[key] = $0 }
    END {
        for (i = 1; i <= n; i++) if (lines[i] ~ /^[[:space:]]*$/) print lines[i]
        for (i = 1; i <= m; i++) print last[order[i]]
    }
' /etc/sysctl.conf > "$temp_file" && mv "$temp_file" /etc/sysctl.conf

# Функция для безопасного добавления параметров
add_sysctl_param() {
    param=$1
    value=$2
    if ! grep -Eq "^${param}[[:space:]]*=" /etc/sysctl.conf; then
        echo "$param=$value" >> /etc/sysctl.conf
    fi
}

# Добавляем параметры только если их нет
add_sysctl_param "net.ipv4.ip_forward" "1"
add_sysctl_param "net.ipv4.tcp_max_syn_backlog" "65535"

# Применяем изменения
sysctl -p 2>/dev/null || true

# Создание скрипта мониторинга
printf "\n\033[1;34m=== Настройка мониторинга ===\033[0m\n"
printf "\033[1;32m→ Создание скрипта мониторинга...\033[0m\n"
cat > /root/check_tunnels.sh << 'EOF'
#!/bin/sh

# Список туннельных портов VPS (заполняется setup_vps.sh при установке)
TUNNEL_PORTS="PORTS_PLACEHOLDER"

printf "Проверка статуса туннелей...\n\n"

if [ -n "$TUNNEL_PORTS" ]; then
    PORTS="$TUNNEL_PORTS"
else
    # Fallback: слушаемые sshd-порты, отличные от 22 (порт самого VPS не является туннелем)
    if command -v ss >/dev/null 2>&1; then
        PORTS=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | grep -v '^22$' | sort -u)
    elif command -v netstat >/dev/null 2>&1; then
        PORTS=$(netstat -tln 2>/dev/null | grep sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | grep -v '^22$' | sort -u)
    else
        printf "\033[31m✗ Не найдены утилиты ss/netstat для проверки портов\033[0m\n"
        exit 1
    fi
fi

if [ -z "$PORTS" ]; then
    printf "Активных SSH туннелей не обнаружено\n"
    logger "No active SSH tunnels found"
    exit 1
fi

printf "Обнаружены порты: %s\n\n" "$PORTS"

# Проверка активных туннелей
FOUND=0
TOTAL=0
for port in $PORTS; do
    TOTAL=$((TOTAL + 1))
    if command -v ss >/dev/null 2>&1; then
        _up=$(ss -tln 2>/dev/null | grep -c ":$port ")
    else
        _up=$(netstat -an 2>/dev/null | grep LISTEN | grep -c ":$port ")
    fi
    if [ "$_up" -eq 0 ]; then
        printf "\033[31m✗ Туннель на порту %s не активен\033[0m\n" "$port"
        logger "Reverse tunnel on port $port is down"
    else
        printf "\033[32m✓ Туннель на порту %s активен\033[0m\n" "$port"
        FOUND=$((FOUND + 1))
    fi
done

printf "\nИтого: активно %d из %d туннелей\n" "$FOUND" "$TOTAL"
[ "$FOUND" -eq "$TOTAL" ] || exit 2
EOF

# Подставляем реально настроенные порты туннелей в скрипт мониторинга
sed -i "s/PORTS_PLACEHOLDER/$TUNNEL_PORTS/" /root/check_tunnels.sh

chmod +x /root/check_tunnels.sh

# Добавление задания в cron
printf "\n\033[1;33m▶ Настройка автоматического мониторинга:\033[0m\n"
printf "Скрипт мониторинга будет проверять состояние туннелей каждые 5 минут\n"
printf "и записывать информацию о проблемах в системный лог\n\n"
ask "Добавить мониторинг в cron? (y - да/n - нет) [Y/n]: "; add_to_cron=$REPLY
add_to_cron=${add_to_cron:-y}

if [ "$add_to_cron" = "y" ] || [ "$add_to_cron" = "Y" ]; then
    if ! command -v crontab >/dev/null 2>&1; then
        printf "\033[1;33m⚠ Предупреждение: утилита crontab недоступна (cron не установлен) — пропускаю автоматический мониторинг.\033[0m\n"
    else
    printf "\033[1;32m→ Добавление задания в cron...\033[0m\n"
    
    # Создаем временный файл
    temp_cron=$(mktemp)
    
    # Получаем текущие задания и добавляем новое
    (crontab -l 2>/dev/null; echo "*/5 * * * * /root/check_tunnels.sh") | \
        # Удаляем пустые строки и комментарии
        grep -v '^#\|^$' | \
        # Сортируем и оставляем только уникальные строки
        sort -u > "$temp_cron"
    
    # Устанавливаем обновленный crontab
    crontab "$temp_cron"
    
    # Удаляем временный файл
    rm -f "$temp_cron"
    
    printf "\033[1;32m→ Текущие задания в cron:\033[0m\n"
    crontab -l | grep -v '^#\|^$' | sed 's/^/  /'
    fi
else
    printf "\n\033[1;33m▶ Для ручного мониторинга используйте команду:\033[0m\n"
    printf "  /root/check_tunnels.sh\n\n"
    printf "Для добавления в cron позже:\n"
    printf "1. Выполните: crontab -e\n"
    printf "2. Добавьте строку: */5 * * * * /root/check_tunnels.sh\n"
fi

printf "\n\033[1;32m"
printf "╔════════════════════════════════════════╗\n"
printf "║         Настройка VPS завершена        ║\n"
printf "╚════════════════════════════════════════╝\033[0m\n"

printf "\nОткрытые порты:\n"
case $fw_choice in
    2)
        printf "\nПравила IPTables:\n"
        iptables -L INPUT -n --line-numbers | sed 's/^/  /'
        printf "\nПолитики по умолчанию:\n"
        iptables -L -n | grep "Chain" | sed 's/^/  /'
        ;;
    *)
        printf "\nПравила UFW:\n"
        ufw status numbered | sed 's/^/  /'
        ;;
esac

printf "\n\033[1;33m▶ Проверьте настройки:\033[0m\n"
echo "1. SSH конфигурация: /etc/ssh/sshd_config"
case $fw_choice in
    2)
        echo "2. Firewall: iptables -L INPUT -n --line-numbers"
        echo "   Сохраненные правила: cat /etc/iptables/rules.v4"
        ;;
    *)
        echo "2. Firewall: ufw status"
        ;;
esac
echo "3. Скрипт мониторинга: /root/check_tunnels.sh"
echo "4. Cron задания: crontab -l" 
