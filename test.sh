#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/setup-combine.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
trap 'log "❌ Ошибка на строке $LINENO: команда завершилась с кодом $?"' ERR

# --- SAFE EXEC ---
safe_run() {
    "$@" || log "⚠️ Команда завершилась с ошибкой (игнор): $*"
}

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log "❌ Запускай от root: sudo ./setup.sh"
        exit 1
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
        grep -Eq "${param}" "$file" || \
        sed -i -E "s|^(${key}=\")([^\"]*)\"|\\1\\2 ${param}\"|" "$file"
    else
        echo "${key}=\"${param}\"" >> "$file"
    fi
}

# --- 1 ---
disable_ipv6() {
    log "=== 1. Отключение IPv6 ==="

    local grub_file="/etc/default/grub"
    [[ -f "$grub_file" ]] || { log "❌ grub не найден"; return; }

    local backup
    backup="$(backup_file "$grub_file")"
    log "Бэкап: $backup"

    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX_DEFAULT" "ipv6.disable=1"
    append_grub_param "$grub_file" "GRUB_CMDLINE_LINUX" "ipv6.disable=1"

    safe_run update-grub
    safe_run grub-mkconfig -o /boot/grub/grub.cfg

    log "✅ IPv6 отключен (нужен reboot)"
}

# --- 2 ---
setup_certbot_nginx() {
    log "=== 2. Certbot + Nginx ==="

    export DEBIAN_FRONTEND=noninteractive

        # --- УБИВАЕМ CADDY ---
    log "Проверка Caddy..."
    
    if systemctl status caddy >/dev/null 2>&1; then
        if systemctl is-active --quiet caddy; then
            log "Останавливаем Caddy..."
            safe_run systemctl stop caddy
        fi
    
        log "Отключаем Caddy..."
        safe_run systemctl disable caddy
    
        log "Удаляем Caddy..."
        safe_run apt purge -y caddy
        safe_run apt autoremove -y
    
        log "✅ Caddy удалён"
    else
        log "ℹ️ Caddy не найден"
    fi
    
    safe_run apt update
    safe_run apt install -y certbot python3-certbot-nginx nginx

    read -r -p "Введите домен: " domain
    [[ -z "$domain" ]] && { log "❌ Домен не введен"; return; }

    safe_run certbot certonly --standalone -d "$domain" \
        --non-interactive --agree-tos --email "admin@$domain"

    safe_run systemctl enable nginx
    safe_run systemctl start nginx

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

    safe_run nginx -t
    safe_run systemctl reload nginx

    log "✅ Nginx готов"
}

# --- 3 ---
setup_device_guard() {
    log "=== 3. Device Guard (Remnanode → Telegram Bot) ==="
    
    # Цвета (ПРАВИЛЬНЫЙ синтаксис)
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
    local BOT_DOMAIN="your-bot-domain.com"
    local TIME_WINDOW=15
    

    local INSTALL_DIR="/opt/device-guard"
    local SCRIPT_PATH="${INSTALL_DIR}/report.sh"
    local LOG_FILE="/var/log/remnanode/access.log"
    local REMNANODE_LOG_FILE="/var/log/remnanode/access.log"
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
    echo "╔═════════════════════════════════════════════════════════════════╗"
    echo "║                      DEVICE GUARD SETUP                        ║"
    echo "╚═════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Извлечение SECRET_KEY

    print_info "Поиск SECRET_KEY в ${DOCKER_COMPOSE_FILE}..."

    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        print_error "Файл ${DOCKER_COMPOSE_FILE} не найден!"
        print_error "Файл ${DOCKER_COMPOSE_FILE} не найден"
        print_error "Убедитесь, что remnanode установлен в /opt/remnanode/"
        read -p "Enter для продолжения..."
        read -r -p "Enter для продолжения..."
        return 1
    fi
    
    local SECRET_KEY=$(grep -E '^\s*-?\s*SECRET_KEY=' "$DOCKER_COMPOSE_FILE" | head -1 | sed -E 's/.*SECRET_KEY=(.+)/\1/' | tr -d '\r')
    

    local SECRET_KEY
    SECRET_KEY="$(grep -E 'SECRET_KEY=' "$DOCKER_COMPOSE_FILE" | head -1 | sed -E 's/.*SECRET_KEY=([^"'\''[:space:]]+).*/\1/' | tr -d '\r' || true)"

    if [[ -z "$SECRET_KEY" ]]; then
        print_error "SECRET_KEY не найден в ${DOCKER_COMPOSE_FILE}"
        read -p "Enter для продолжения..."
        read -r -p "Enter для продолжения..."
        return 1
    fi

    print_success "SECRET_KEY извлечен (${#SECRET_KEY} символов)"
    echo ""
    
    # Шаг 1: Создание директории
    print_step "Шаг 1/7: Создание директории"
    mkdir -p "$INSTALL_DIR"
    print_success "Директория создана: $INSTALL_DIR"

    print_step "Шаг 1/7: Установка зависимостей"
    apt-get update -qq
    apt-get install -y cron curl >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    print_success "cron и curl готовы"
    echo ""
    
    # Создание полного скрипта report.sh
    cat > "$SCRIPT_PATH" << 'EOFSCRIPT'

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
  "https://DOMAIN_PLACEHOLDER/device-report|SECRET_PLACEHOLDER"
  "https://${BOT_DOMAIN}/device-report|${SECRET_KEY}"
)
TIME_WINDOW=TIME_WINDOW_PLACEHOLDER
LOG_FILE="LOG_FILE_PLACEHOLDER"
TIME_WINDOW=${TIME_WINDOW}
LOG_FILE="${REMNANODE_LOG_FILE}"

DATA=$(tail -n 10000 "$LOG_FILE" 2>/dev/null | \
  awk -v window="$TIME_WINDOW" '
DATA=\$(tail -n 10000 "\$LOG_FILE" 2>/dev/null | awk -v window="\$TIME_WINDOW" '
  /email:/ {
    split($1, d, "/")
    split($2, t, ":")
    split(\$1, d, "/")
    split(\$2, t, ":")
    split(t[3], sec, ".")
    ts = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " sec[1])
    match($0, /from ([0-9.]+):/, iparr)
    match($0, /email: ([0-9]+)/, emarr)
    if(iparr[1] && emarr[1]) {
    match(\$0, /from ([0-9.]+):/, iparr)
    match(\$0, /email: ([0-9]+)/, emarr)
    if (iparr[1] && emarr[1]) {
      n = ++total
      all_ts[n] = ts
      all_ip[n] = iparr[1]
@@ -255,82 +284,89 @@ DATA=$(tail -n 10000 "$LOG_FILE" 2>/dev/null | \
        key = em SUBSEP ip
        if (!(key in seen)) {
          seen[key] = 1
          users[em] = users[em] ? users[em] ",\"" ip "\"" : "\"" ip "\""
          users[em] = users[em] ? users[em] ",\\"" ip "\\"" : "\\"" ip "\\""
        }
      }
    }
    printf "{\"ts\":%d,\"users\":{", systime()
    printf "{\\"ts\\":%d,\\"users\\":{", systime()
    first = 1
    for (em in users) {
      if (!first) printf ","
      printf "\"%s\":[%s]", em, users[em]
      printf "\\"%s\\":[%s]", em, users[em]
      first = 0
    }
    print "}}"
  }')

for entry in "${WEBHOOKS[@]}"; do
  URL="${entry%%|*}"
  KEY="${entry##*|}"
  echo "$DATA" | curl -s -X POST "$URL" \
for entry in "\${WEBHOOKS[@]}"; do
  URL="\${entry%%|*}"
  KEY="\${entry##*|}"
  curl -s -X POST "\$URL" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $KEY" \
    -d @- > /dev/null 2>&1 &
    -H "X-Api-Key: \$KEY" \
    -d "\$DATA" >/dev/null 2>&1 &
done

wait
EOFSCRIPT
    
    # Замены плейсхолдеров
    sed -i "s|DOMAIN_PLACEHOLDER|${BOT_DOMAIN}|g" "$SCRIPT_PATH"
    sed -i "s|SECRET_PLACEHOLDER|${SECRET_KEY}|g" "$SCRIPT_PATH"
    sed -i "s|TIME_WINDOW_PLACEHOLDER|${TIME_WINDOW}|g" "$SCRIPT_PATH"
    sed -i "s|LOG_FILE_PLACEHOLDER|${LOG_FILE}|g" "$SCRIPT_PATH"
    
    chmod +x "$SCRIPT_PATH"
    mkdir -p /var/log/remnanode/ && chmod -R 777 /var/log/remnanode/
    
    # Cron каждые 2 минуты
EOF

    chmod 750 "$SCRIPT_PATH"
    print_success "Скрипт создан: $SCRIPT_PATH"
    echo ""

    print_step "Шаг 4/7: Настройка cron"
    local CRON_JOB="*/2 * * * * $SCRIPT_PATH"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_JOB") | crontab -
    
    apt-get update -qq && apt-get install -y cron curl 2>/dev/null || true
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || true
    
    # Финальный баннер
    (
        crontab -l 2>/dev/null | grep -F -v "$SCRIPT_PATH" || true
        echo "$CRON_JOB"
    ) | crontab -
    print_success "Cron добавлен: $CRON_JOB"
    echo ""
    echo -e "${GREEN}╔═════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}            ${BOLD}${WHITE}✓ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}                   ${GREEN}║${NC}"
    echo -e "${GREEN}╚═════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Скрипт:${NC} ${GREEN}$SCRIPT_PATH${NC} | ${CYAN}Cron:${NC} ${GREEN}*/2 * * * *${NC}"
    echo -e "${MAGENTA}Проверить:${NC} ${WHITE}crontab -l | grep device-guard${NC}"

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

# --- 4 ---
setup_ufw() {
    log "=== 4. UFW + Node Exporter ==="

    export DEBIAN_FRONTEND=noninteractive

    safe_run apt update
    safe_run apt install -y ufw curl

    # reset безопасно
    safe_run ufw --force reset

    safe_run ufw default deny incoming
    safe_run ufw default allow outgoing

    # порты
    safe_run ufw allow 22
    safe_run ufw limit 22
    safe_run ufw allow 3001
    safe_run ufw allow 80
    safe_run ufw allow 443
    safe_run ufw allow 1443

    # node exporter доступ только с IP
    safe_run ufw allow proto tcp from 193.23.194.101 to any port 9100

    safe_run ufw --force enable

    log "✅ UFW настроен"
    ufw status verbose || true

    # --- Установка node exporter ---
    log "=== Установка Node Exporter ==="
    safe_run bash <(curl -fsSL https://raw.githubusercontent.com/hteppl/sh/master/node_install.sh)

    log "✅ Node Exporter установлен"
}

# --- MENU ---
main_menu() {
    check_root
    log "=== Setup ==="

    while true; do
        echo ""
        echo "1) Отключить IPv6"
        echo "2) Certbot + Nginx"
        echo "3) Device Guard"
        echo "4) UFW + Node Exporter"
        echo "0) Выход"
        read -r -p "Выбор: " choice || true

        case "$choice" in
            1) disable_ipv6 ;;
            2) setup_certbot_nginx ;;
            3) setup_device_guard ;;
            4) setup_ufw ;;
            0) exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac

        read -r -p "Enter для продолжения..." || true
    done
}

main_menu "$@"
