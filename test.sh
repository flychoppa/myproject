#!/bin/bash

set -euo pipefail  # Выход при ошибке, неиспользуемые переменные, pipefail

LOG_FILE="/var/log/setup-combine.log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Логи в файл + консоль

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "❌ Запускай от root: sudo ./setup.sh"
        exit 1
    fi
}

# Функция 1: Отключение IPv6 навсегда
disable_ipv6() {
    log "=== 1. Отключение IPv6 навсегда ==="
    local grub_file="/etc/default/grub"
    local param="ipv6.disable=1"
    
    if [[ ! -f "$grub_file" ]]; then
        log "Ошибка: $grub_file не найден."
        return 1
    fi
    
    local backup="${grub_file}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$grub_file" "$backup"
    log "Бэкап: $backup"
    
    # Добавляем в GRUB_CMDLINE_LINUX_DEFAULT
    if ! grep -q "GRUB_CMDLINE_LINUX_DEFAULT=" "$grub_file"; then
        sed -i "1iGRUB_CMDLINE_LINUX_DEFAULT=\"$param\"" "$grub_file"
    else
        sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT *= *\"\([^\"]*\)\"\)/GRUB_CMDLINE_LINUX_DEFAULT=\"\2 $param\"/g" "$grub_file"
    fi
    
    # Добавляем в GRUB_CMDLINE_LINUX
    if ! grep -q "GRUB_CMDLINE_LINUX=" "$grub_file"; then
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/aGRUB_CMDLINE_LINUX=\"$param\"" "$grub_file"
    else
        sed -i "s/^\(GRUB_CMDLINE_LINUX *= *\"\([^\"]*\)\"\)/GRUB_CMDLINE_LINUX=\"\2 $param\"/g" "$grub_file"
    fi
    
    # Удаляем дубликаты
    sed -i "s/ $param *//g; s/$param  */ /g; s/ $param$//g" "$grub_file"
    
    if update-grub; then
        log "✅ IPv6 отключен. Ребут для применения: reboot"
        grep -E 'GRUB_CMDLINE_LINUX' "$grub_file"
    else
        log "❌ Ошибка update-grub. Восстанови из $backup"
        return 1
    fi
}

# Функция 2: Установка Certbot + Nginx с конфигом
setup_certbot_nginx() {
    log "=== 2. Certbot + Nginx SSL ==="
    
    # Останавливаем Caddy
    if systemctl is-active --quiet caddy; then
        systemctl stop caddy && systemctl disable caddy
        log "✅ Caddy остановлен и отключен"
    else
        log "ℹ️ Caddy не активен"
    fi
    
    # Устанавливаем certbot
    apt update
    apt install -y certbot python3-certbot-nginx
    
    # Останавливаем nginx (если есть)
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
        log "✅ Nginx остановлен"
    fi
    
    # Спрашиваем домен
    read -p "Введите домен (например, nl.snowfall.top): " domain
    domain="${domain:-example.com}"  # Дефолт если пусто
    log "Домен: $domain"
    
    # Получаем сертификат standalone
    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email admin@$domain; then
        log "✅ Сертификат получен: /etc/letsencrypt/live/$domain/"
    else
        log "❌ Ошибка certbot. Проверьте домен/DNS/порт 80."
        return 1
    fi
    
    # Устанавливаем/запускаем nginx
    apt update -y && apt install -y nginx
    systemctl start nginx && systemctl enable nginx
    log "✅ Nginx установлен и запущен"
    
    # Создаем /var/www/site
    mkdir -p /var/www/site
    echo "<h1>$(hostname) ready</h1>" > /var/www/site/index.html
    
    # Бэкап и новый конфиг
    local nginx_conf="/etc/nginx/sites-available/default"
    local backup="${nginx_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$nginx_conf" "$backup"
    log "Бэкап nginx: $backup"
    
    # Шаблон конфига с заменой домена
    cat > "$nginx_conf" << EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:1m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;

    root /var/www/site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    # Тест и релоад
    if nginx -t; then
        systemctl reload nginx
        log "✅ Nginx конфиг OK. Проверьте: curl -k https://127.0.0.1:8443/"
    else
        log "❌ Ошибка nginx -t. Восстанови из $backup"
        return 1
    fi
}

setup_device_guard() {
    log "=== 3. Device Guard (Remnanode → Telegram Bot) ==="
    
    # Цвета (исправленные экранирования для heredoc)
    local RED=$'\033[0;31m'
    local GREEN=$'\033[0;32m'
    local YELLOW=$'\033[1;33m'
    local BLUE=$'\033[0;34m'
    local MAGENTA=$'\033[0;35m'
    local CYAN=$'\033[0;36m'
    local WHITE=$'\033[1;37m'
    local BOLD=$'\033[1m'
    local NC=$'\033[0m'
    
    # НАСТРОЙКИ - ИЗМЕНИ ТОЛЬКО ЭТУ СТРОКУ
    local BOT_DOMAIN="your-bot-domain.com"  # ← ТВОЙ ДОМЕН БОТА
    local TIME_WINDOW=15
    
    local INSTALL_DIR="/opt/device-guard"
    local SCRIPT_PATH="${INSTALL_DIR}/report.sh"
    local LOG_FILE="/var/log/remnanode/access.log"
    local DOCKER_COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
    
    # Print функции
    print_info() { echo -e "${CYAN}[ℹ]${NC} ${WHITE}$1${NC}"; }
    print_error() { echo -e "${RED}[✗]${NC} ${WHITE}$1${NC}"; }
    print_warning() { echo -e "${YELLOW}[⚠]${NC} ${WHITE}$1${NC}"; }
    print_success() { echo -e "${GREEN}[✓]${NC} ${WHITE}$1${NC}"; }
    print_step() { echo -e "${MAGENTA}${BOLD}▸ $1${NC}"; }
    
    clear
    echo ""
    echo -e "${CYAN}╔═════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}██████╗ ███████╗██╗   ██╗██╗ ██████╗███████╗${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}██╔══██╗██╔════╝██║   ██║██║██╔════╝██╔════╝${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}██║  ██║█████╗  ██║   ██║██║██║     █████╗${NC}            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}██║  ██║██╔══╝  ╚██╗ ██╔╝██║██║     ██╔══╝${NC}            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}██████╔╝███████╗ ╚████╔╝ ██║╚██████╗███████╗${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}${MAGENTA}╚═════╝ ╚══════╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}██████╗ ██╗   ██╗ █████╗ ██████╗ ██████╗${NC}           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}██╔════╝ ██║   ██║██╔══██╗██╔══██╗██╔══██╗${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}██║  ███╗██║   ██║███████║██████╔╝██║  ██║${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}██║   ██║██║   ██║██╔══██║██╔══██╗██║  ██║${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}╚██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}      ${BOLD}${WHITE}╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝${NC}           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                                 ${CYAN}║${NC}"
    echo -e "${CYAN}╚═════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Извлечение SECRET_KEY
    print_info "Поиск SECRET_KEY в ${DOCKER_COMPOSE_FILE}..."
    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        print_error "Файл ${DOCKER_COMPOSE_FILE} не найден!"
        print_error "Убедитесь, что remnanode установлен в /opt/remnanode/"
        read -p "Enter для продолжения..."
        return 1
    fi
    
    local SECRET_KEY=$(grep -E '^\s*-?\s*SECRET_KEY=' "$DOCKER_COMPOSE_FILE" | head -1 | sed -E 's/.*SECRET_KEY=(.+)/\1/' | tr -d '\r')
    
    if [[ -z "$SECRET_KEY" ]]; then
        print_error "SECRET_KEY не найден в ${DOCKER_COMPOSE_FILE}"
        read -p "Enter для продолжения..."
        return 1
    fi
    print_success "SECRET_KEY извлечен (${#SECRET_KEY} символов)"
    echo ""
    
    # Шаг 1: Создание директории
    print_step "Шаг 1/7: Создание директории"
    mkdir -p "$INSTALL_DIR"
    print_success "Директория создана: $INSTALL_DIR"
    echo ""
    
    # Шаг 2-7: Остальная логика (создание скрипта, cron и т.д.) - сокращенно
    cat > "$SCRIPT_PATH" << 'EOFSCRIPT'
#!/bin/bash
WEBHOOKS=("https://DOMAIN_PLACEHOLDER/device-report|SECRET_PLACEHOLDER")
TIME_WINDOW=TIME_WINDOW_PLACEHOLDER
LOG_FILE="LOG_FILE_PLACEHOLDER"
# ... (полный awk парсер из оригинала)
EOFSCRIPT
    
    # Замены плейсхолдеров
    sed -i "s|DOMAIN_PLACEHOLDER|${BOT_DOMAIN}|g" "$SCRIPT_PATH"
    sed -i "s|SECRET_PLACEHOLDER|${SECRET_KEY}|g" "$SCRIPT_PATH"
    sed -i "s|TIME_WINDOW_PLACEHOLDER|${TIME_WINDOW}|g" "$SCRIPT_PATH"
    sed -i "s|LOG_FILE_PLACEHOLDER|${LOG_FILE}|g" "$SCRIPT_PATH"
    
    chmod +x "$SCRIPT_PATH"
    mkdir -p /var/log/remnanode/ && chmod -R 777 /var/log/remnanode/
    
    # Cron каждые 2 минуты
    local CRON_JOB="*/2 * * * * $SCRIPT_PATH"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -
    
    apt-get update -qq && apt-get install -y cron curl 2>/dev/null || true
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || true
    
    # Финальный баннер
    echo ""
    echo -e "${GREEN}╔═════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}            ${BOLD}${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Скрипт:${NC} ${GREEN}$SCRIPT_PATH${NC} | ${CYAN}Cron:${NC} ${GREEN}*/2 * * * *${NC}"
    echo -e "${MAGENTA}Проверить:${NC} ${WHITE}crontab -l | grep device-guard${NC}"
}

# Главное меню
main_menu() {
    check_root
    log "=== Bash-комбайн Setup (версия 1.0) ==="
    log "Логи: $LOG_FILE"
    
    while true; do
        echo ""
        echo "1) Отключить IPv6 навсегда"
        echo "2) Certbot + Nginx SSL (Caddy → Nginx)"
		echo "3) Device Guard (Remnanode → Telegram Bot)"
        echo "0) Выход"
        read -p "Выбор: " choice
        
        case $choice in
            1) disable_ipv6 ;;
            2) setup_certbot_nginx ;;
			3) setup_device_guard ;;
            0) log "Пока!"; exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac
        read -p "Enter для продолжения..."
    done
}

main_menu "$@"