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

# Функция 1: Отключение IPv6 навсегда
disable_ipv6() {
    log "=== 1. Отключение IPv6 навсегда ==="

    local grub_file="/etc/default/grub"
    local param="ipv6.disable=1"

    if [[ ! -f "$grub_file" ]]; then
        log "❌ Ошибка: $grub_file не найден"
        return 1
    fi

    require_cmd sed
    local backup
    backup="$(backup_file "$grub_file")"
    log "Бэкап: $backup"

    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX_DEFAULT" "$param"
    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX" "$param"

    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    else
        log "❌ Не найдена команда обновления grub. Восстанови из $backup при необходимости"
        return 1
    fi

    log "✅ IPv6 отключен. Ребут для применения: reboot"
    grep -E '^(GRUB_CMDLINE_LINUX|GRUB_CMDLINE_LINUX_DEFAULT)=' "$grub_file" || true
}

# Функция 2: Установка Certbot + Nginx с конфигом
setup_certbot_nginx() {
    log "=== 2. Certbot + Nginx SSL ==="

    export DEBIAN_FRONTEND=noninteractive

    # Останавливаем Caddy
    if systemctl list-unit-files | grep -q '^caddy\.service'; then
        if systemctl is-active --quiet caddy; then
            systemctl stop caddy
            log "✅ Caddy остановлен"
        fi
        systemctl disable caddy >/dev/null 2>&1 || true
        log "✅ Caddy отключен"
    else
        log "ℹ️ Caddy не найден"
    fi

    apt update
    apt install -y certbot python3-certbot-nginx nginx

    # Останавливаем nginx (если есть)
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
        log "✅ Nginx остановлен"
    fi

    # Спрашиваем домен
    read -r -p "Введите домен (например, nl.snowfall.top): " domain
    domain="${domain:-}"

    if [[ -z "$domain" ]]; then
        log "❌ Домен не введен"
        return 1
    fi

    log "Домен: $domain"

    # Получаем сертификат standalone
    if certbot certonly --standalone -d "$domain" --non-interactive --agree-tos --email "admin@$domain"; then
        log "✅ Сертификат получен: /etc/letsencrypt/live/$domain/"
    else
        log "❌ Ошибка certbot. Проверьте домен, DNS и порт 80"
        return 1
    fi

    systemctl enable nginx
    systemctl start nginx
    log "✅ Nginx установлен и запущен"

    mkdir -p /var/www/site
    echo "<h1>$(hostname) ready</h1>" > /var/www/site/index.html

    local nginx_conf="/etc/nginx/sites-available/default"
    if [[ ! -f "$nginx_conf" ]]; then
        log "❌ Не найден nginx конфиг: $nginx_conf"
        return 1
    fi

    local backup
    backup="$(backup_file "$nginx_conf")"
    log "Бэкап nginx: $backup"

    cat > "$nginx_conf" <<EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
    ssl_session_cache shared:SSL:10m;
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

    if nginx -t; then
        systemctl reload nginx
        log "✅ Nginx конфиг OK"
        log "⚠️ Учти: обычный curl к 127.0.0.1:8443 может не работать из-за proxy_protocol"
    else
        log "❌ Ошибка nginx -t. Восстанови из $backup"
        return 1
    fi
}

# Функции вывода для Device Guard
print_info()    { echo -e "\033[0;36m[ℹ]\033[0m \033[1;37m$1\033[0m"; }
print_error()   { echo -e "\033[0;31m[✗]\033[0m \033[1;37m$1\033[0m"; }
print_warning() { echo -e "\033[1;33m[⚠]\033[0m \033[1;37m$1\033[0m"; }
print_success() { echo -e "\033[0;32m[✓]\033[0m \033[1;37m$1\033[0m"; }
print_step()    { echo -e "\033[0;35m\033[1m▸ $1\033[0m"; }

# Функция 3: Device Guard (Remnanode → Telegram Bot)
setup_device_guard() {
    log "=== 3. Device Guard (Remnanode → Telegram Bot) ==="

    # НАСТРОЙКИ - ИЗМЕНИ ТОЛЬКО ЭТУ СТРОКУ
    local BOT_DOMAIN="your-bot-domain.com"
    local TIME_WINDOW=15

    local INSTALL_DIR="/opt/device-guard"
    local SCRIPT_PATH="${INSTALL_DIR}/report.sh"
    local REMNANODE_LOG_FILE="/var/log/remnanode/access.log"
    local DOCKER_COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

    clear
    echo ""
    echo "╔═════════════════════════════════════════════════════════════════╗"
    echo "║                      DEVICE GUARD SETUP                        ║"
    echo "╚═════════════════════════════════════════════════════════════════╝"
    echo ""

    print_info "Поиск SECRET_KEY в ${DOCKER_COMPOSE_FILE}..."

    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        print_error "Файл ${DOCKER_COMPOSE_FILE} не найден"
        print_error "Убедитесь, что remnanode установлен в /opt/remnanode/"
        read -r -p "Enter для продолжения..."
        return 1
    fi

    local SECRET_KEY
    SECRET_KEY="$(grep -E 'SECRET_KEY=' "$DOCKER_COMPOSE_FILE" | head -1 | sed -E 's/.*SECRET_KEY=([^"'\''[:space:]]+).*/\1/' | tr -d '\r' || true)"

    if [[ -z "$SECRET_KEY" ]]; then
        print_error "SECRET_KEY не найден в ${DOCKER_COMPOSE_FILE}"
        read -r -p "Enter для продолжения..."
        return 1
    fi

    print_success "SECRET_KEY извлечен (${#SECRET_KEY} символов)"
    echo ""

    print_step "Шаг 1/7: Установка зависимостей"
    apt-get update -qq
    apt-get install -y cron curl >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    print_success "cron и curl готовы"
    echo ""

    print_step "Шаг 2/7: Создание директорий и логов"
    install -d -m 755 "$INSTALL_DIR"
    install -d -m 755 /var/log/remnanode
    touch "$REMNANODE_LOG_FILE"
    chmod 644 "$REMNANODE_LOG_FILE"
    print_success "Директории и лог-файл готовы"
    echo ""

    print_step "Шаг 3/7: Генерация report.sh"

    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
set -Eeuo pipefail
IFS=\$'\n\t'

WEBHOOKS=(
  "https://${BOT_DOMAIN}/device-report|${SECRET_KEY}"
)
TIME_WINDOW=${TIME_WINDOW}
LOG_FILE="${REMNANODE_LOG_FILE}"

DATA=\$(tail -n 10000 "\$LOG_FILE" 2>/dev/null | awk -v window="\$TIME_WINDOW" '
  /email:/ {
    split(\$1, d, "/")
    split(\$2, t, ":")
    split(t[3], sec, ".")
    ts = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " sec[1])
    match(\$0, /from ([0-9.]+):/, iparr)
    match(\$0, /email: ([0-9]+)/, emarr)
    if (iparr[1] && emarr[1]) {
      n = ++total
      all_ts[n] = ts
      all_ip[n] = iparr[1]
      all_em[n] = emarr[1]
      if (ts > global_max) global_max = ts
    }
  }
  END {
    threshold = global_max - window
    for (i = 1; i <= total; i++) {
      if (all_ts[i] >= threshold) {
        em = all_em[i]
        ip = all_ip[i]
        key = em SUBSEP ip
        if (!(key in seen)) {
          seen[key] = 1
          users[em] = users[em] ? users[em] ",\\"" ip "\\"" : "\\"" ip "\\""
        }
      }
    }
    printf "{\\"ts\\":%d,\\"users\\":{", systime()
    first = 1
    for (em in users) {
      if (!first) printf ","
      printf "\\"%s\\":[%s]", em, users[em]
      first = 0
    }
    print "}}"
  }')

for entry in "\${WEBHOOKS[@]}"; do
  URL="\${entry%%|*}"
  KEY="\${entry##*|}"
  curl -s -X POST "\$URL" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: \$KEY" \
    -d "\$DATA" >/dev/null 2>&1 &
done

wait
EOF

    chmod 750 "$SCRIPT_PATH"
    print_success "Скрипт создан: $SCRIPT_PATH"
    echo ""

    print_step "Шаг 4/7: Настройка cron"
    local CRON_JOB="*/2 * * * * $SCRIPT_PATH"
    (
        crontab -l 2>/dev/null | grep -F -v "$SCRIPT_PATH" || true
        echo "$CRON_JOB"
    ) | crontab -
    print_success "Cron добавлен: $CRON_JOB"
    echo ""

    print_step "Шаг 5/7: Проверка файла"
    if [[ -x "$SCRIPT_PATH" ]]; then
        print_success "report.sh исполняемый"
    else
        print_error "report.sh не исполняемый"
        return 1
    fi
    echo ""

    print_step "Шаг 6/7: Финальная информация"
    print_info "Скрипт: $SCRIPT_PATH"
    print_info "Лог: $REMNANODE_LOG_FILE"
    print_info "Cron: */2 * * * *"
    echo ""

    print_step "Шаг 7/7: Готово"
    print_success "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО"
    print_info "Проверить cron: crontab -l | grep device-guard"
}

# Главное меню
main_menu() {
    check_root
    log "=== Bash-комбайн Setup (версия 1.1) ==="
    log "Логи: $LOG_FILE"

    while true; do
        echo ""
        echo "1) Отключить IPv6 навсегда"
        echo "2) Certbot + Nginx SSL (Caddy → Nginx)"
        echo "3) Device Guard (Remnanode → Telegram Bot)"
        echo "0) Выход"
        read -r -p "Выбор: " choice

        case "$choice" in
            1) disable_ipv6 ;;
            2) setup_certbot_nginx ;;
            3) setup_device_guard ;;
            0) log "Пока!"; exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac

        read -r -p "Enter для продолжения..."
    done
}

main_menu "$@"
