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
        sed -i -E "s|^(${key}=\")([^\"]*)\"|\1\2 ${param}\"|" "$file"
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

    # --- STOP + DISABLE CADDY ---
    log "Останавливаем Caddy..."
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    # --- INSTALL CERTBOT + NGINX ---
    apt update -y
    apt install -y certbot python3-certbot-nginx nginx

    # --- STOP NGINX перед standalone ---
    systemctl stop nginx 2>/dev/null || true

    # --- DOMAIN ---
    read -r -p "Введите домен: " domain
    if [[ -z "$domain" ]]; then
        log "❌ Домен не введен"
        return
    fi

    # --- SSL ---
    certbot certonly --standalone -d "$domain" \
        --non-interactive --agree-tos --email "admin@$domain"

    # --- START NGINX ---
    systemctl start nginx
    systemctl enable nginx

    # --- CONFIG ---
    log "Записываем конфиг nginx..."

    cat > /etc/nginx/sites-available/default <<EOF
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

    nginx -t
    systemctl restart nginx

    log "✅ Certbot + Nginx готово"
}

# --- 3 ---
setup_device_guard() {
    log "=== 3. Device Guard (Remnanode → Telegram Bot) ==="

    local BOT_DOMAIN="bots.snowfall.top"
    local TIME_WINDOW=15
    local INSTALL_DIR="/opt/device-guard"
    local SCRIPT_PATH="${INSTALL_DIR}/report.sh"
    local REMNANODE_LOG_FILE="/var/log/remnanode/access.log"
    local DOCKER_COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

    # --- Шаг 1: Зависимости ---
    log "Шаг 1/5: Установка зависимостей (cron, curl, gawk)..."
    apt-get update -qq
    apt-get install -y cron curl gawk >/dev/null 2>&1
    systemctl enable cron >/dev/null 2>&1 || true
    systemctl start cron >/dev/null 2>&1 || true
    log "✅ Зависимости готовы"

    # --- Шаг 2: Извлечение SECRET_KEY ---
    log "Шаг 2/5: Поиск SECRET_KEY в ${DOCKER_COMPOSE_FILE}..."

    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        log "❌ Файл ${DOCKER_COMPOSE_FILE} не найден. Убедитесь, что remnanode установлен в /opt/remnanode/"
        return 1
    fi

    local SECRET_KEY
    SECRET_KEY="$(grep -E 'SECRET_KEY=' "$DOCKER_COMPOSE_FILE" | head -1 | sed -E 's/.*SECRET_KEY=([^"'\''[:space:]]+).*/\1/' | tr -d '\r')"

    if [[ -z "$SECRET_KEY" ]]; then
        log "❌ SECRET_KEY не найден в ${DOCKER_COMPOSE_FILE}"
        return 1
    fi

    log "✅ SECRET_KEY извлечён (${#SECRET_KEY} символов)"

    # --- Шаг 3: Создание директорий ---
    log "Шаг 3/5: Создание директорий..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p /var/log/remnanode
    touch "$REMNANODE_LOG_FILE"
    chmod 644 "$REMNANODE_LOG_FILE"
    chmod -R 777 /var/log/remnanode/
    log "✅ Директории готовы"

    # --- Шаг 4: Генерация report.sh ---
    log "Шаг 4/5: Генерация ${SCRIPT_PATH}..."

    cat > "$SCRIPT_PATH" <<EOFSCRIPT
#!/bin/bash
# === НАСТРОЙКИ ===
WEBHOOKS=(
  "https://${BOT_DOMAIN}/device-report|${SECRET_KEY}"
)
TIME_WINDOW=${TIME_WINDOW}
LOG_FILE="${REMNANODE_LOG_FILE}"

DATA=\$(tail -n 10000 "\$LOG_FILE" 2>/dev/null | \
  awk -v window="\$TIME_WINDOW" '
  /email:/ {
    split(\$1, d, "/")
    split(\$2, t, ":")
    split(t[3], sec, ".")
    ts = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " sec[1])
    match(\$0, /from ([0-9.]+):/, iparr)
    match(\$0, /email: ([0-9]+)/, emarr)
    if(iparr[1] && emarr[1]) {
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
          users[em] = users[em] ? users[em] ",\"" ip "\"" : "\"" ip "\""
        }
      }
    }
    printf "{\"ts\":%d,\"users\":{", systime()
    first = 1
    for (em in users) {
      if (!first) printf ","
      printf "\"%s\":[%s]", em, users[em]
      first = 0
    }
    print "}}"
  }')

for entry in "\${WEBHOOKS[@]}"; do
  URL="\${entry%%|*}"
  KEY="\${entry##*|}"
  echo "\$DATA" | curl -s -X POST "\$URL" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: \$KEY" \
    -d @- > /dev/null 2>&1 &
done

wait
EOFSCRIPT

    chmod +x "$SCRIPT_PATH"
    log "✅ Скрипт создан: $SCRIPT_PATH"

    # --- Шаг 5: Cron ---
    log "Шаг 5/5: Настройка cron (каждые 2 минуты)..."
    local CRON_JOB="*/2 * * * * $SCRIPT_PATH"
    (
        crontab -l 2>/dev/null | grep -F -v "$SCRIPT_PATH" || true
        echo "$CRON_JOB"
    ) | crontab -
    log "✅ Cron добавлен: $CRON_JOB"

    log "=== ✅ Device Guard установлен ==="
    log "Скрипт:   $SCRIPT_PATH"
    log "Лог:      $REMNANODE_LOG_FILE"
    log "Проверка: crontab -l | grep device-guard"
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
    # ufw limit уже включает разрешение — отдельный allow 22 не нужен
    safe_run ufw limit 22
    safe_run ufw allow 3001
    safe_run ufw allow 80
    safe_run ufw allow 443
    safe_run ufw allow 1443

    # node exporter — доступ только с конкретного IP
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
