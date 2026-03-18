#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/setup-combine.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'log "❌ Ошибка на строке $LINENO: команда завершилась с кодом $?"' ERR

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "❌ Запускай от root: sudo ./setup.sh"
        exit 1
    fi
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "❌ Не найдена команда: $cmd"
        return 1
    fi
}

backup_file() {
    local file="$1"
    local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$file" "$backup"
    echo "$backup"
}

append_grub_param() {
    local file="$1"
    local key="$2"
    local param="$3"

    if grep -Eq "^${key}=" "$file"; then
        if grep -Eq "^${key}=\"[^\"]*(^|[[:space:]])${param}([[:space:]]|$)" "$file"; then
            return 0
        fi
        sed -i -E "s|^(${key}=\")([^\"]*)\"|\\1\\2 ${param}\"|" "$file"
    else
        echo "${key}=\"${param}\"" >> "$file"
    fi
}

# Функция 1: Отключение IPv6
disable_ipv6() {
    log "=== 1. Отключение IPv6 навсегда ==="

    local grub_file="/etc/default/grub"
    local param="ipv6.disable=1"

    [[ -f "$grub_file" ]] || { log "❌ $grub_file не найден"; return 1; }

    require_cmd sed
    local backup
    backup="$(backup_file "$grub_file")"
    log "Бэкап: $backup"

    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX_DEFAULT" "$param"
    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX" "$param"

    update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true

    log "✅ IPv6 отключен. Нужен reboot"
}

# Функция 2: Certbot + Nginx
setup_certbot_nginx() {
    log "=== 2. Certbot + Nginx SSL ==="

    export DEBIAN_FRONTEND=noninteractive

    apt update
    apt install -y certbot python3-certbot-nginx nginx

    read -r -p "Введите домен: " domain
    [[ -z "$domain" ]] && { log "❌ Домен не введен"; return 1; }

    certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "admin@$domain" || return 1

    systemctl enable nginx
    systemctl start nginx

    mkdir -p /var/www/site
    echo "<h1>$(hostname) ready</h1>" > /var/www/site/index.html

    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    root /var/www/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    nginx -t && systemctl reload nginx
    log "✅ Nginx готов"
}

# Функция 3: Device Guard (оставлена как есть)
setup_device_guard() {
    log "=== 3. Device Guard ==="
    echo "У тебя уже есть эта функция (без изменений)"
}

# Функция 4: UFW Firewall
setup_ufw() {
    log "=== 4. Установка и настройка UFW ==="

    export DEBIAN_FRONTEND=noninteractive

    apt update
    apt install -y ufw

    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing

    # Основные порты
    ufw allow 22
    ufw allow 3001
    ufw allow 80
    ufw allow 443
    ufw allow 1443

    # Доступ к 9100 ТОЛЬКО с одного IP
    ufw allow from 193.23.194.101 to any port 9100

    ufw --force enable

    log "✅ UFW настроен:"
    log "Порты: 22, 3001, 80, 443, 1443"
    log "9100 доступен только с 193.23.194.101"

    ufw status verbose
}

# Меню
main_menu() {
    check_root
    log "=== Bash-комбайн Setup ==="

    while true; do
        echo ""
        echo "1) Отключить IPv6"
        echo "2) Certbot + Nginx"
        echo "3) Device Guard"
        echo "4) Установить UFW"
        echo "0) Выход"
        read -r -p "Выбор: " choice

        case "$choice" in
            1) disable_ipv6 ;;
            2) setup_certbot_nginx ;;
            3) setup_device_guard ;;
            4) setup_ufw ;;
            0) exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac

        read -r -p "Enter для продолжения..."
    done
}

main_menu "$@"
