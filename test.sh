#!/usr/bin/env bash
# ==============================================================
# VPN Node Optimizer — VLESS Reality
# Автоматически определяет тип сервера (VPS / Dedicated)
# и применяет только то, что реально работает
# ==============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
sep()  { echo -e "${BOLD}──────────────────────────────────────${NC}"; }

# ============================================================
# ОПРЕДЕЛЕНИЕ ОКРУЖЕНИЯ
# ============================================================
sep
info "Определяем конфигурацию сервера..."

DEV=$(ip -o route show default | awk '{print $5}' | head -n1)
[[ -z "$DEV" ]] && { echo "[-] Не найден сетевой интерфейс"; exit 1; }

NUM_CPU=$(nproc)
RX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/rx-* 2>/dev/null | wc -l)
TX_QUEUES=$(ls -d /sys/class/net/$DEV/queues/tx-* 2>/dev/null | wc -l)

# Тип сервера
if [[ $RX_QUEUES -gt 1 ]]; then
    SERVER_TYPE="dedicated"
else
    SERVER_TYPE="vps"
fi

# CPU маска — все онлайн ядра
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

sep
info "Интерфейс  : ${BOLD}$DEV${NC}"
info "Тип сервера: ${BOLD}$SERVER_TYPE${NC}"
info "CPU ядер   : ${BOLD}$NUM_CPU${NC}  (mask: 0x$CPU_MASK)"
info "RX очередей: ${BOLD}$RX_QUEUES${NC}"
info "TX очередей: ${BOLD}$TX_QUEUES${NC}"
sep

# ============================================================
# ФУНКЦИЯ: RPS (Receive Packet Steering)
# Нужна ВСЕГДА — распределяет пакеты по CPU в software
# Особенно важна при 1 аппаратной очереди
# ============================================================
apply_rps() {
    log "RPS: распределение приёма пакетов по CPU..."
    for q in /sys/class/net/$DEV/queues/rx-*; do
        printf "%s\n" "$CPU_MASK" > "$q/rps_cpus"
        info "  $(basename $q)/rps_cpus = $CPU_MASK"
    done
}

# ============================================================
# ФУНКЦИЯ: RFS (Receive Flow Steering)
# Нужна ВСЕГДА — направляет пакеты на CPU где живёт приложение
# Критично для VPN: снижает cache miss при шифровании
# ============================================================
apply_rfs() {
    log "RFS: steering потоков на CPU приложения..."

    # Глобальный счётчик (степень 2, ≥ числа одновременных соединений)
    local SOCK_FLOW=32768
    echo $SOCK_FLOW > /proc/sys/net/core/rps_sock_flow_entries
    info "  rps_sock_flow_entries = $SOCK_FLOW"

    # На каждую очередь: flow_cnt = total / кол-во очередей, округляем до степени 2
    local FLOW_CNT
    FLOW_CNT=$(python3 -c "
n = $SOCK_FLOW // $RX_QUEUES
p = 1
while p < n: p <<= 1
print(p)
")

    for q in /sys/class/net/$DEV/queues/rx-*; do
        printf "%s\n" "$FLOW_CNT" > "$q/rps_flow_cnt"
        info "  $(basename $q)/rps_flow_cnt = $FLOW_CNT"
    done
}

# ============================================================
# ФУНКЦИЯ: XPS (Transmit Packet Steering)
# Нужна ТОЛЬКО при >1 TX очереди
# При 1 очереди — не применяется (просто нечего делить)
# ============================================================
apply_xps() {
    if [[ $TX_QUEUES -le 1 ]]; then
        warn "XPS: пропускаем — только $TX_QUEUES TX очередь, нет смысла"
        return
    fi

    log "XPS: привязываем TX очереди к CPU ($TX_QUEUES очередей)..."

    local CPUS_PER_Q=$(( NUM_CPU / TX_QUEUES ))
    [[ $CPUS_PER_Q -lt 1 ]] && CPUS_PER_Q=1

    local QID=0
    for q in /sys/class/net/$DEV/queues/tx-*; do
        local START=$(( QID * CPUS_PER_Q ))
        local END=$(( START + CPUS_PER_Q - 1 ))
        [[ $END -ge $NUM_CPU ]] && END=$(( NUM_CPU - 1 ))

        local MASK
        MASK=$(python3 -c "
mask = 0
for i in range($START, $END + 1):
    mask |= (1 << i)
print(format(mask, 'x'))
")
        printf "%s\n" "$MASK" > "$q/xps_cpus"
        info "  $(basename $q)/xps_cpus = $MASK  (CPU $START-$END)"
        QID=$(( QID + 1 ))
    done
}

# ============================================================
# ФУНКЦИЯ: IRQ Affinity
# VPS (1 очередь)  → irqbalance включён (пусть сам балансирует)
# Dedicated (N оч) → irqbalance ВЫКЛ, ручная привязка IRQ к CPU
#                    (irqbalance конфликтует с ручной настройкой)
# ============================================================
apply_irq() {
    apt-get install -y irqbalance -qq 2>/dev/null

    if [[ "$SERVER_TYPE" == "vps" ]]; then
        log "IRQ: включаем irqbalance (VPS, 1 очередь)"
        systemctl enable --now irqbalance
        return
    fi

    # Dedicated: выключаем irqbalance, вручную привязываем IRQ
    log "IRQ: dedicated — выключаем irqbalance, ручная привязка..."
    systemctl stop irqbalance  2>/dev/null || true
    systemctl disable irqbalance 2>/dev/null || true

    local QID=0
    # Ищем IRQ по имени интерфейса
    local IRQS
    IRQS=$(grep -E "${DEV}(-|$|[0-9])" /proc/interrupts 2>/dev/null \
           | awk -F: '{print $1}' | tr -d ' ' || true)

    if [[ -z "$IRQS" ]]; then
        warn "  IRQ для $DEV не найдены, пропускаем ручную привязку"
        return
    fi

    for IRQ in $IRQS; do
        local CPU=$(( QID % NUM_CPU ))
        local CPU_MASK_IRQ=$(python3 -c "print(format(1 << $CPU, 'x'))")
        echo "$CPU_MASK_IRQ" > /proc/irq/$IRQ/smp_affinity 2>/dev/null || true
        info "  IRQ $IRQ → CPU $CPU"
        QID=$(( QID + 1 ))
    done
}

# ============================================================
# ФУНКЦИЯ: sysctl — применяется ВСЕГДА
# Самое важное для VPN: буферы, BBR, forwarding, TIME_WAIT
# ============================================================
apply_sysctl() {
    log "sysctl: применяем оптимизации для VPN..."

    cat > /etc/sysctl.d/99-vpn-node.conf << 'SYSCTL'
# Сетевые буферы — критично для VPN трафика
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 8388608
net.core.wmem_default = 8388608
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Очередь входящих пакетов
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192

# TCP оптимизации
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Безопасность
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1

# TIME_WAIT: у VPN много коротких соединений
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 1440000

# Forwarding — обязателен для VPN роутинга
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Снижаем задержку
net.ipv4.tcp_low_latency = 1
SYSCTL

    sysctl --system -q
    log "sysctl применён"
}

# ============================================================
# ФУНКЦИЯ: BBR
# ============================================================
apply_bbr() {
    log "BBR: проверяем и включаем..."
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr >> /etc/modules-load.d/bbr.conf 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr -q
    sysctl -w net.core.default_qdisc=fq -q
    local active
    active=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ "$active" == "bbr" ]]; then
        log "BBR активен"
    else
        warn "BBR не поддерживается ядром (активен: $active)"
    fi
}

# ============================================================
# СОХРАНЯЕМ НАСТРОЙКИ КАК SYSTEMD СЕРВИС
# (sysfs сбрасывается при перезагрузке)
# ============================================================
install_service() {
    log "Устанавливаем systemd сервис..."

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

# RPS — всегда
for q in /sys/class/net/$DEV/queues/rx-*; do
    echo "$CPU_MASK" > "$q/rps_cpus" 2>/dev/null || true
done

# RFS — всегда
SOCK_FLOW=32768
echo $SOCK_FLOW > /proc/sys/net/core/rps_sock_flow_entries
FLOW_CNT=$(python3 -c "
n = $SOCK_FLOW // $RX_QUEUES
p = 1
while p < n: p <<= 1
print(p)
")
for q in /sys/class/net/$DEV/queues/rx-*; do
    echo "$FLOW_CNT" > "$q/rps_flow_cnt" 2>/dev/null || true
done

# XPS — только при >1 TX очереди
if [[ $TX_QUEUES -gt 1 ]]; then
    CPUS_PER_Q=$(( NUM_CPU / TX_QUEUES ))
    [[ $CPUS_PER_Q -lt 1 ]] && CPUS_PER_Q=1
    QID=0
    for q in /sys/class/net/$DEV/queues/tx-*; do
        START=$(( QID * CPUS_PER_Q ))
        END=$(( START + CPUS_PER_Q - 1 ))
        [[ $END -ge $NUM_CPU ]] && END=$(( NUM_CPU - 1 ))
        MASK=$(python3 -c "
mask = 0
for i in range($START, $END + 1): mask |= (1 << i)
print(format(mask, 'x'))
")
        echo "$MASK" > "$q/xps_cpus" 2>/dev/null || true
        QID=$(( QID + 1 ))
    done
fi

# IRQ affinity — только при >1 RX очереди
if [[ $RX_QUEUES -gt 1 ]]; then
    QID=0
    for IRQ in $(grep -E "${DEV}(-|$|[0-9])" /proc/interrupts 2>/dev/null \
                 | awk -F: '{print $1}' | tr -d ' ' || true); do
        CPU=$(( QID % NUM_CPU ))
        echo "$(python3 -c "print(format(1 << $CPU, 'x'))")" \
            > /proc/irq/$IRQ/smp_affinity 2>/dev/null || true
        QID=$(( QID + 1 ))
    done
fi
SCRIPT

    chmod +x /usr/local/sbin/vpn-netopt.sh

    cat > /etc/systemd/system/vpn-netopt.service << 'UNIT'
[Unit]
Description=VPN Node Network Optimization (adaptive RPS/RFS/XPS/IRQ)
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
    log "Сервис установлен и запущен"
}

# ============================================================
# ЗАПУСК ВСЕХ ФУНКЦИЙ
# ============================================================
apply_rps
apply_rfs
apply_xps      # умная — сама пропустит при 1 очереди
apply_irq      # умная — irqbalance или ручная привязка
apply_sysctl
apply_bbr
install_service

# ============================================================
# ИТОГОВЫЙ ОТЧЁТ
# ============================================================
sep
echo -e "${BOLD}РЕЗУЛЬТАТ ОПТИМИЗАЦИИ${NC}"
sep
echo -e "Сервер      : ${BOLD}$SERVER_TYPE${NC}"
echo -e "Интерфейс  : ${BOLD}$DEV${NC}"
echo -e "RX очередей: ${BOLD}$RX_QUEUES${NC}"
echo -e "TX очередей: ${BOLD}$TX_QUEUES${NC}"
echo
echo -e "RPS         : ${GREEN}✓ применён${NC}"
echo -e "RFS         : ${GREEN}✓ применён${NC}"
if [[ $TX_QUEUES -gt 1 ]]; then
    echo -e "XPS         : ${GREEN}✓ применён${NC}"
else
    echo -e "XPS         : ${YELLOW}— пропущен (1 TX очередь)${NC}"
fi
if [[ "$SERVER_TYPE" == "dedicated" ]]; then
    echo -e "IRQ affinity: ${GREEN}✓ ручная привязка${NC}"
    echo -e "irqbalance  : ${YELLOW}— отключён${NC}"
else
    echo -e "irqbalance  : ${GREEN}✓ включён${NC}"
fi
echo -e "sysctl/BBR  : ${GREEN}✓ применены${NC}"
sep
echo "Мониторинг:"
echo "  watch -n1 'cat /proc/net/softnet_stat | awk \"{print \\$1, \\$2, \\$3}\"'"
echo "  mpstat -P ALL 1 3"
echo "  ss -s"
