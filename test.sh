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

#----2------
setup_certbot_nginx() {
    log "=== 2. Certbot + Nginx ==="

    export DEBIAN_FRONTEND=noninteractive

    # --- STOP + DISABLE CADDY ---
    log "Останавливаем Caddy..."
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    # --- INSTALL CERTBOT + NGINX ---
    apt update -y
    apt install -y certbot python3-certbot-dns-cloudflare nginx

    # --- DOMAIN ---
    read -r -p "Введите домен: " domain
    if [[ -z "$domain" ]]; then
        log "❌ Домен не введен"
        return
    fi

    # --- CLOUDFLARE API TOKEN ---
    read -r -p "Введите Cloudflare API Token: " cf_token
    if [[ -z "$cf_token" ]]; then
        log "❌ API Token не введен"
        return
    fi

    # --- СОХРАНЯЕМ CREDENTIALS ---
    mkdir -p /root/.secrets
    cat > /root/.secrets/cloudflare.ini <<EOF
dns_cloudflare_api_token = $cf_token
EOF
    chmod 600 /root/.secrets/cloudflare.ini

    # --- SSL через DNS-01 (A записи не трогаем) ---
    log "Выпускаем сертификат через Cloudflare DNS..."
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 30 \
        -d "$domain" \
        --non-interactive --agree-tos --email "admin@$domain"

    if [[ $? -ne 0 ]]; then
        log "❌ Ошибка выпуска сертификата"
        return
    fi

    # --- START NGINX ---
    systemctl start nginx
    systemctl enable nginx

    # --- CONFIG NGINX ---
    log "Записываем конфиг nginx..."
    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 127.0.0.1:8443 ssl http2 proxy_protocol;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
}
EOF

    nginx -t && systemctl reload nginx

    log "✅ Certbot + Nginx готово. Сертификат: /etc/letsencrypt/live/$domain/"
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

# --- 5 ---
setup_vpn_limits() {
    log "=== 5. VPN Limits (conntrack, sysctl, ulimit, systemd) ==="

    # --- RAM → conntrack max ---
    RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if   [[ $RAM_MB -ge 16000 ]]; then CT_MAX=2097152
    elif [[ $RAM_MB -ge  8000 ]]; then CT_MAX=1048576
    elif [[ $RAM_MB -ge  4000 ]]; then CT_MAX=524288
    else                                CT_MAX=262144
    fi
    CT_BUCKETS=$((CT_MAX / 4))
    log "RAM: ${RAM_MB}MB → conntrack max: ${CT_MAX}"

    # --- sysctl ---
    log "Шаг 1/4: sysctl..."
    cat > /etc/sysctl.d/zzz-vpn-limits.conf << EOF
net.netfilter.nf_conntrack_max = ${CT_MAX}
net.netfilter.nf_conntrack_buckets = ${CT_BUCKETS}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 1000
net.core.netdev_budget_usecs = 8000
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = 524288
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    # Применяем напрямую — sed убирает пробелы только по краям, не внутри значения
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        key=$(echo "$line" | cut -d= -f1 | tr -d ' ')
        val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        sysctl -w "$key=$val" -q 2>/dev/null || \
            log "⚠️ Не применился: $key"
    done < /etc/sysctl.d/zzz-vpn-limits.conf

    log "✅ sysctl применён"

    # --- BBR ---
    log "Шаг 2/4: BBR..."
    modprobe tcp_bbr 2>/dev/null || true
    grep -q tcp_bbr /etc/modules-load.d/bbr.conf 2>/dev/null || \
        echo tcp_bbr >> /etc/modules-load.d/bbr.conf
    safe_run sysctl -w net.ipv4.tcp_congestion_control=bbr -q
    safe_run sysctl -w net.core.default_qdisc=fq -q
    log "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"

    # --- ulimit ---
    log "Шаг 3/4: ulimit..."
    grep -q "nofile 1048576" /etc/security/limits.conf 2>/dev/null || \
    cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS

    grep -q "pam_limits" /etc/pam.d/common-session 2>/dev/null || \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    log "✅ ulimit (вступит после переподключения)"

    # --- systemd LimitNOFILE ---
    log "Шаг 4/4: systemd лимиты..."
    for svc in nginx xray sing-box v2ray rw-core haproxy; do
        systemctl cat "$svc" &>/dev/null || continue
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        cat > "/etc/systemd/system/${svc}.service.d/limits.conf" << 'UNIT'
[Service]
LimitNOFILE=1048576
LimitNPROC=524288
UNIT
        log "  ✅ $svc → LimitNOFILE=1048576"
    done
    safe_run systemctl daemon-reload

    # --- Проверка ---
    log "=== Проверка ==="
    python3 - << 'PYEOF'
import subprocess

def sctl(k):
    try: return subprocess.check_output(['sysctl','-n',k],text=True).strip()
    except: return "н/д"

def r(f):
    try: return open(f).read().strip()
    except: return "н/д"

checks = [
    ("conntrack",           lambda: f"{int(r('/proc/sys/net/netfilter/nf_conntrack_count')):,} / {int(r('/proc/sys/net/netfilter/nf_conntrack_max')):,}", lambda v: int(v.split('/')[0].replace(',',''))*100//int(v.split('/')[1].replace(',','')) < 80),
    ("somaxconn",           lambda: sctl('net.core.somaxconn'),                  lambda v: int(v) >= 8192),
    ("ip_local_port_range", lambda: sctl('net.ipv4.ip_local_port_range'),        lambda v: int(v.split()[1])-int(v.split()[0]) >= 40000),
    ("rmem_max",            lambda: f"{int(sctl('net.core.rmem_max')):,}",       lambda v: int(v.replace(',','')) >= 16777216),
    ("tcp_rmem",            lambda: sctl('net.ipv4.tcp_rmem'),                   lambda v: int(v.split()[2]) >= 16777216),
    ("tcp_wmem",            lambda: sctl('net.ipv4.tcp_wmem'),                   lambda v: int(v.split()[2]) >= 16777216),
    ("tcp_keepalive_time",  lambda: sctl('net.ipv4.tcp_keepalive_time'),         lambda v: int(v) <= 300),
    ("tcp_fin_timeout",     lambda: sctl('net.ipv4.tcp_fin_timeout'),            lambda v: int(v) <= 30),
    ("netdev_max_backlog",  lambda: sctl('net.core.netdev_max_backlog'),         lambda v: int(v) >= 16384),
    ("bbr",                 lambda: sctl('net.ipv4.tcp_congestion_control'),     lambda v: v == 'bbr'),
    ("conntrack timeout",   lambda: sctl('net.netfilter.nf_conntrack_tcp_timeout_established'), lambda v: int(v) <= 3600),
]

print(f"{'Параметр':<24} {'Значение':<32} Статус")
print("─" * 68)
for name, getter, ok_fn in checks:
    try:
        val = getter()
        ok = ok_fn(val)
        print(f"{'✓' if ok else '✗'} {name:<22} {val:<32} {'ОК' if ok else 'ОПАСНО'}")
    except Exception as e:
        print(f"? {name:<22} {'ошибка':<32}")

print()
print("Лимиты процессов:")
for name in ['rw-core','nginx','xray','sing-box','haproxy']:
    try:
        import os
        pid = subprocess.check_output(['pgrep','-o',name],text=True).strip()
        limit = [l for l in open(f'/proc/{pid}/limits').readlines() if 'open files' in l][0].split()[3]
        ok = int(limit) >= 65536
        print(f"  {'✓' if ok else '✗'} {name} (PID {pid}): nofile = {limit}")
    except:
        pass
PYEOF

    log "=== ✅ VPN Limits установлены ==="
    log "⚠️  ulimit для SSH вступит после переподключения"
    log "⚠️  Перезапусти сервисы: systemctl restart nginx xray 2>/dev/null || true"
}

# --- 6 ---
setup_net_optimizer() {
    log "=== 6. VPN Net Optimizer (RPS/RFS/XPS/IRQ/BBR) ==="

    local DEV NUM_CPU RX_QUEUES TX_QUEUES SERVER_TYPE CPU_MASK IRQ_SPREAD

    DEV=$(ip -o route show default | awk '{print $5}' | head -n1)
    [[ -z "$DEV" ]] && { log "❌ Не найден сетевой интерфейс"; return; }

    NUM_CPU=$(nproc)
    RX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/rx-* 2>/dev/null | wc -l)
    TX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/tx-* 2>/dev/null | wc -l)
    SERVER_TYPE=$([[ $RX_QUEUES -gt 1 ]] && echo "dedicated" || echo "vps")

    CPU_MASK=$(python3 -c "
cpus = open('/sys/devices/system/cpu/online').read().strip()
mask = 0
for part in cpus.replace(',', ' ').split():
    if '-' in part:
        a, b = map(int, part.split('-'))
        for i in range(a, b+1): mask |= (1 << i)
    else:
        mask |= (1 << int(part))
print(format(mask, 'x'))
")

    IRQ_SPREAD=$(grep -E "${DEV}|virtio" /proc/interrupts 2>/dev/null | \
        awk '{for(i=2;i<=NF-3;i++) if($i+0>1000) count++} END{print count+0}')

    log "Интерфейс: $DEV | Тип: $SERVER_TYPE | CPU: $NUM_CPU | RX: $RX_QUEUES | TX: $TX_QUEUES | IRQ активных: $IRQ_SPREAD"

    # --- RPS/RFS ---
    # Применяем если: 1 очередь ИЛИ много очередей но IRQ не размазаны по CPU
    if [[ $RX_QUEUES -le 1 ]] || [[ $IRQ_SPREAD -le 2 ]]; then
        [[ $RX_QUEUES -le 1 ]] \
            && log "1 очередь NIC → включаем RPS/RFS" \
            || log "IRQ не привязаны → включаем RPS/RFS"
        for q in /sys/class/net/$DEV/queues/rx-*; do
            printf "%s\n" "$CPU_MASK" > "$q/rps_cpus"
        done
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
        local FLOW_CNT
        FLOW_CNT=$(python3 -c "
n = 32768 // $RX_QUEUES
p = 1
while p < n: p <<= 1
print(p)")
        for q in /sys/class/net/$DEV/queues/rx-*; do
            printf "%s\n" "$FLOW_CNT" > "$q/rps_flow_cnt"
        done
        log "✅ RPS/RFS применён"
    else
        log "⚠️ RPS/RFS пропущен — $RX_QUEUES очередей, IRQ уже на $IRQ_SPREAD CPU"
    fi

    # --- XPS ---
    # round-robin: каждая TX очередь → свой CPU по кругу
    # избегаем переполнения маски при большом числе очередей
    if [[ $TX_QUEUES -gt 1 ]]; then
        local QID=0
        for q in /sys/class/net/$DEV/queues/tx-*; do
            local CPU=$(( QID % NUM_CPU ))
            local MASK
            MASK=$(python3 -c "print(format(1 << $CPU, 'x'))")
            printf "%s\n" "$MASK" > "$q/xps_cpus" 2>/dev/null || true
            QID=$(( QID + 1 ))
        done
        log "✅ XPS применён ($TX_QUEUES TX очередей, round-robin по $NUM_CPU CPU)"
    else
        log "⚠️ XPS пропущен — только 1 TX очередь"
    fi

    # --- IRQ ---
    safe_run apt-get install -y irqbalance -qq
    if [[ "$SERVER_TYPE" == "vps" ]]; then
        systemctl enable --now irqbalance
        log "✅ irqbalance включён (VPS)"
    else
        systemctl stop irqbalance 2>/dev/null || true
        systemctl disable irqbalance 2>/dev/null || true
        log "✅ irqbalance отключён (dedicated)"

        local QID=0
        local IRQS=""

        # Сначала ищем по имени интерфейса (реальные NIC: eno1, eth0)
        IRQS=$(grep -E "${DEV}(-|$|[0-9])" /proc/interrupts 2>/dev/null \
               | awk -F: '{print $1}' | tr -d ' ' || true)

        # Если не нашли — ищем virtio-input (KVM/virtio_net)
        if [[ -z "$IRQS" ]]; then
            IRQS=$(grep -E "virtio[0-9]+-input" /proc/interrupts 2>/dev/null \
                   | awk -F: '{print $1}' | tr -d ' ' || true)
        fi

        if [[ -n "$IRQS" ]]; then
            for IRQ in $IRQS; do
                local CPU=$(( QID % NUM_CPU ))
                echo "$(python3 -c "print(format(1 << $CPU, 'x'))")" \
                    > /proc/irq/$IRQ/smp_affinity 2>/dev/null || true
                QID=$(( QID + 1 ))
            done
            log "✅ IRQ привязаны вручную ($QID очередей → $NUM_CPU CPU)"
        else
            log "⚠️ IRQ не найдены — гипервизор управляет сам"
        fi
    fi

    # --- BBR ---
    modprobe tcp_bbr 2>/dev/null || true
    grep -q tcp_bbr /etc/modules-load.d/bbr.conf 2>/dev/null || \
        echo tcp_bbr >> /etc/modules-load.d/bbr.conf
    safe_run sysctl -w net.ipv4.tcp_congestion_control=bbr -q
    safe_run sysctl -w net.core.default_qdisc=fq -q
    log "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"

    # --- Systemd сервис (та же логика, применяется при перезагрузке) ---
    cat > /usr/local/sbin/vpn-netopt.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DEV=$(ip -o route show default | awk '{print $5}' | head -n1)
RX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/rx-* 2>/dev/null | wc -l)
TX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/tx-* 2>/dev/null | wc -l)
NUM_CPU=$(nproc)

CPU_MASK=$(python3 -c "
cpus = open('/sys/devices/system/cpu/online').read().strip()
mask = 0
for part in cpus.replace(',', ' ').split():
    if '-' in part:
        a, b = map(int, part.split('-'))
        for i in range(a, b+1): mask |= (1 << i)
    else:
        mask |= (1 << int(part))
print(format(mask, 'x'))
")

IRQ_SPREAD=$(grep -E "${DEV}|virtio" /proc/interrupts 2>/dev/null | \
    awk '{for(i=2;i<=NF-3;i++) if($i+0>1000) count++} END{print count+0}')

# RPS/RFS
if [[ $RX_QUEUES -le 1 ]] || [[ $IRQ_SPREAD -le 2 ]]; then
    for q in /sys/class/net/$DEV/queues/rx-*; do
        echo "$CPU_MASK" > "$q/rps_cpus" 2>/dev/null || true
    done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
    FLOW_CNT=$(python3 -c "
n = 32768 // $RX_QUEUES
p = 1
while p < n: p <<= 1
print(p)")
    for q in /sys/class/net/$DEV/queues/rx-*; do
        echo "$FLOW_CNT" > "$q/rps_flow_cnt" 2>/dev/null || true
    done
fi

# XPS — round-robin, избегаем переполнения маски
if [[ $TX_QUEUES -gt 1 ]]; then
    QID=0
    for q in /sys/class/net/$DEV/queues/tx-*; do
        CPU=$(( QID % NUM_CPU ))
        MASK=$(python3 -c "print(format(1 << $CPU, 'x'))")
        echo "$MASK" > "$q/xps_cpus" 2>/dev/null || true
        QID=$(( QID + 1 ))
    done
fi

# IRQ affinity — только dedicated
if [[ $RX_QUEUES -gt 1 ]]; then
    QID=0
    IRQS=""

    IRQS=$(grep -E "${DEV}(-|$|[0-9])" /proc/interrupts 2>/dev/null \
           | awk -F: '{print $1}' | tr -d ' ' || true)

    if [[ -z "$IRQS" ]]; then
        IRQS=$(grep -E "virtio[0-9]+-input" /proc/interrupts 2>/dev/null \
               | awk -F: '{print $1}' | tr -d ' ' || true)
    fi

    if [[ -n "$IRQS" ]]; then
        for IRQ in $IRQS; do
            CPU=$(( QID % NUM_CPU ))
            echo "$(python3 -c "print(format(1 << $CPU, 'x'))")" \
                > /proc/irq/$IRQ/smp_affinity 2>/dev/null || true
            QID=$(( QID + 1 ))
        done
    fi
fi
SCRIPT

    chmod +x /usr/local/sbin/vpn-netopt.sh

    cat > /etc/systemd/system/vpn-netopt.service << 'UNIT'
[Unit]
Description=VPN Node Network Optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-netopt.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now vpn-netopt.service

    log "=== ✅ VPN Net Optimizer установлен ==="
}

    # --- 7 ---
setup_cron_restart() {
    log "=== 7. Cron: еженедельная перезагрузка сервера + обновления ==="

    # --- Шаг 1: NTP ---
    log "Шаг 1/4: настройка NTP..."
    safe_run apt-get install -y chrony -qq
    systemctl enable --now chrony
    chronyc makestep 2>/dev/null || true
    log "✅ Время синхронизировано: $(date -u '+%Y-%m-%d %H:%M:%S UTC') (МСК: $(date -d '+3 hours' -u '+%H:%M'))"

    # --- Шаг 2: unattended-upgrades ---
    log "Шаг 2/4: настройка автообновлений..."
    safe_run apt-get install -y unattended-upgrades -qq
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    log "✅ Автообновления настроены"

    # --- Шаг 3: скрипт перезагрузки ---
    log "Шаг 3/4: создаём скрипт перезагрузки..."

    cat > /usr/local/sbin/vpn-weekly-reboot.sh << 'SCRIPT'
#!/usr/bin/env bash
# Еженедельная перезагрузка сервера
# Воскресенье 4:00 МСК = воскресенье 01:00 UTC
LOG="/var/log/vpn-reboot.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S UTC')] === Еженедельная перезагрузка ===" >> "$LOG"

# Применяем все доступные обновления перед перезагрузкой
echo "[$(date '+%Y-%m-%d %H:%M:%S UTC')] Обновление пакетов..." >> "$LOG"
DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG" 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1 || true

echo "[$(date '+%Y-%m-%d %H:%M:%S UTC')] Уходим на перезагрузку..." >> "$LOG"

# Оставляем только последние 200 строк лога
tail -n 200 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"

# Перезагрузка
/sbin/shutdown -r now "Плановая еженедельная перезагрузка"
SCRIPT

    chmod +x /usr/local/sbin/vpn-weekly-reboot.sh

    # --- Шаг 4: cron ---
    log "Шаг 4/4: устанавливаем cron..."

    # Крон всегда в UTC — 01:00 UTC = 04:00 МСК, независимо от timezone сервера
    rm -f /etc/cron.d/vpn-weekly-reboot
    cat > /etc/cron.d/vpn-weekly-reboot << 'EOF'
# Еженедельная перезагрузка: воскресенье 04:00 МСК = 01:00 UTC
# Крон работает в UTC — timezone сервера не важна
0 1 * * 0 root /usr/local/sbin/vpn-weekly-reboot.sh
EOF
    chmod 644 /etc/cron.d/vpn-weekly-reboot

    log "=== ✅ Еженедельная перезагрузка настроена ==="
    log "Расписание : каждое воскресенье 04:00 МСК (01:00 UTC)"
    log "Скрипт     : /usr/local/sbin/vpn-weekly-reboot.sh"
    log "Лог        : /var/log/vpn-reboot.log"
    log "Проверка   : cat /etc/cron.d/vpn-weekly-reboot"
    log "⚠️  Сервер будет полностью перезагружаться каждое воскресенье в 04:00 МСК"
}

# --- 8 ---
setup_net_admin() {
    log "=== 8. NET_ADMIN: добавляем cap_add в remnanode ==="

    local COMPOSE_FILE="/opt/remnanode/docker-compose.yml"

    # --- Проверяем файл ---
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log "❌ Файл не найден: $COMPOSE_FILE"
        return 1
    fi

    # --- Уже есть? ---
    if grep -q "NET_ADMIN" "$COMPOSE_FILE"; then
        log "✅ NET_ADMIN уже присутствует, ничего не меняем"
        return 0
    fi

    # --- Бэкап ---
    local BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$COMPOSE_FILE" "$BACKUP"
    log "📦 Бэкап создан: $BACKUP"

    # --- Вставляем cap_add с правильным отступом ---
    python3 - << EOF
import re, sys

with open('$COMPOSE_FILE', 'r') as f:
    content = f.read()

# Определяем реальный отступ строки restart: always
match = re.search(r'^([ \t]*)restart:\s*always', content, re.MULTILINE)
if not match:
    print("❌ Строка 'restart: always' не найдена, файл не изменён")
    sys.exit(1)

indent = match.group(1)

# Вставляем с тем же отступом что и restart: always
insert = f"{indent}cap_add:\n{indent}  - NET_ADMIN\n"

new_content = re.sub(
    r'([ \t]*restart:\s*always\n)',
    r'\1' + insert,
    content,
    count=1
)

if new_content == content:
    print("❌ Не удалось вставить, файл не изменён")
    sys.exit(1)

with open('$COMPOSE_FILE', 'w') as f:
    f.write(new_content)

print("✅ cap_add: NET_ADMIN добавлен")
EOF

    # Проверяем что python3 отработал успешно
    if [[ $? -ne 0 ]]; then
        log "❌ Ошибка при изменении файла, восстанавливаем бэкап"
        cp "$BACKUP" "$COMPOSE_FILE"
        return 1
    fi

    # --- Показываем результат ---
    log "Результат вставки:"
    grep -A3 "restart: always" "$COMPOSE_FILE" | \
        while IFS= read -r line; do log "  $line"; done

    # --- Валидация YAML перед перезапуском ---
    if ! docker compose -f "$COMPOSE_FILE" config > /dev/null 2>&1; then
        log "❌ YAML невалиден, восстанавливаем бэкап"
        cp "$BACKUP" "$COMPOSE_FILE"
        return 1
    fi
    log "✅ YAML валиден"

    # --- Перезапускаем контейнер ---
    log "Перезапускаем remnanode..."
    cd /opt/remnanode || { log "❌ Не удалось перейти в /opt/remnanode"; return 1; }

    docker compose down 2>&1 | tail -3 | while IFS= read -r line; do log "  $line"; done
    docker compose up -d 2>&1 | tail -3 | while IFS= read -r line; do log "  $line"; done

    # --- Проверяем что поднялся ---
    sleep 3
    if docker ps | grep -q remnanode; then
        log "✅ remnanode запущен"
        docker ps | grep remnanode | while IFS= read -r line; do log "  $line"; done
    else
        log "❌ remnanode не запустился, проверь: docker logs remnanode"
    fi

    log "=== ✅ NET_ADMIN установлен ==="
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
        echo "5) VPN Limits (conntrack / sysctl / ulimit)"
        echo "6) VPN Net Optimizer (RPS/RFS/XPS/IRQ/BBR)"
        echo "7) Cron: еженедельный перезапуск VPN (04:00 МСК)"
        echo "8) NET_ADMIN: cap_add для remnanode"
        echo "0) Выход"
        read -r -p "Выбор: " choice || true

        case "$choice" in
            1) disable_ipv6 ;;
            2) setup_certbot_nginx ;;
            3) setup_device_guard ;;
            4) setup_ufw ;;
            5) setup_vpn_limits ;;
            6) setup_net_optimizer ;;
            7) setup_cron_restart ;;
            8) setup_net_admin ;;
            0) exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac

        read -r -p "Enter для продолжения..." || true
    done
}

main_menu "$@"
