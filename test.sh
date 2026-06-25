#!/bin/bash
# ═══════════════════════════════════════════════════════════
#  Секция 7 для kombain — Firewall Hardening
#  Snow VPN
#
#  Что делает:
#    - Ставит iptables-persistent (правила переживут ребут)
#    - Блокирует TCP/25 (SMTP) для VPN-трафика → анти-спам
#    - Блокирует TCP/6660-6669, 6697 (IRC) → анти-C&C ботнетов
#    - Ограничивает доступ на TCP/3001 (Remnawave node API)
#      ТОЛЬКО с мастер-IP 171.22.31.136
#    - Сохраняет конфиг в /etc/iptables/rules.v{4,6}
#    - Идемпотентно — можно запускать многократно без дублей
# ═══════════════════════════════════════════════════════════

# --- 7 ---
setup_firewall_hardening() {
    log "=== 7. Firewall Hardening ==="
    log "    - блок SMTP (25) + IRC (6660-6697) для VPN-трафика"
    log "    - порт 3001 (Remnawave API) только для мастер-панели"

    local MASTER_IP="171.22.31.136"
    local NODE_API_PORT="3001"

    # --- Шаг 1: iptables-persistent ---
    log "Шаг 1/5: установка iptables-persistent..."
    if ! command -v netfilter-persistent &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        safe_run apt-get update -qq
        safe_run apt-get install -y iptables-persistent netfilter-persistent -qq
    fi
    mkdir -p /etc/iptables
    log "✅ iptables-persistent готов"

    # --- helpers: идемпотентная вставка правил ---
    add_rule_v4() {
        # $1=chain, остальное — параметры правила
        local chain="$1"; shift
        iptables -C "$chain" "$@" 2>/dev/null || \
            iptables -I "$chain" "$@"
    }
    add_rule_v6() {
        local chain="$1"; shift
        ip6tables -C "$chain" "$@" 2>/dev/null || \
            ip6tables -I "$chain" "$@" 2>/dev/null || true
    }

    has_chain() {
        # $1=chain — проверка существования цепочки
        iptables -L "$1" -n &>/dev/null
    }

    # --- Шаг 2: SMTP block (port 25) ---
    log "Шаг 2/5: блокировка SMTP (TCP/25)..."

    add_rule_v4 FORWARD -p tcp --dport 25 -j DROP
    add_rule_v6 FORWARD -p tcp --dport 25 -j DROP

    if has_chain DOCKER-USER; then
        add_rule_v4 DOCKER-USER -p tcp --dport 25 -j DROP
        log "  ✅ FORWARD + DOCKER-USER: dport 25 → DROP"
    else
        log "  ✅ FORWARD: dport 25 → DROP (DOCKER-USER нет, пропуск)"
    fi

    # --- Шаг 3: IRC block (порты ботнетов C&C) ---
    log "Шаг 3/5: блокировка IRC (TCP/6660-6669, 6697)..."

    add_rule_v4 FORWARD -p tcp --dport 6660:6669 -j DROP
    add_rule_v4 FORWARD -p tcp --dport 6697 -j DROP
    add_rule_v6 FORWARD -p tcp --dport 6660:6669 -j DROP
    add_rule_v6 FORWARD -p tcp --dport 6697 -j DROP

    if has_chain DOCKER-USER; then
        add_rule_v4 DOCKER-USER -p tcp --dport 6660:6669 -j DROP
        add_rule_v4 DOCKER-USER -p tcp --dport 6697 -j DROP
    fi
    log "  ✅ IRC порты заблокированы"

    # --- Шаг 4: Port 3001 — только мастер-IP ---
    log "Шаг 4/5: ограничение TCP/$NODE_API_PORT на $MASTER_IP..."

    # Снимаем все старые правила на 3001 — чтобы избежать дублей и противоречий
    # (могут остаться от прошлых запусков скрипта или ручных правок)
    while iptables -D INPUT -p tcp --dport "$NODE_API_PORT" -s "$MASTER_IP" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$NODE_API_PORT" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p tcp --dport "$NODE_API_PORT" -j ACCEPT 2>/dev/null; do :; done

    # Применяем нужные правила — в правильном порядке
    # 1) ACCEPT для мастера (вверху, обрабатывается первым)
    iptables -I INPUT 1 -p tcp --dport "$NODE_API_PORT" -s "$MASTER_IP" -j ACCEPT
    # 2) DROP для всех остальных (после ACCEPT)
    iptables -A INPUT -p tcp --dport "$NODE_API_PORT" -j DROP

    log "  ✅ Порт $NODE_API_PORT: ACCEPT только с $MASTER_IP, остальные DROP"

    # --- Шаг 5: Сохранение ---
    log "Шаг 5/5: сохранение правил в /etc/iptables/rules.v{4,6}..."
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    # Активируем systemd-сервис чтобы при ребуте автозагрузка
    systemctl enable netfilter-persistent &>/dev/null || true
    log "✅ Правила сохранены — переживут ребут"

    # --- Проверка ---
    echo ""
    log "=== Проверка применённых правил ==="
    echo ""
    echo "▸ FORWARD chain — фильтр VPN-трафика:"
    iptables -L FORWARD -n --line-numbers 2>/dev/null \
        | grep -E "dpt:25|dpts:6660|dpt:6697" \
        | sed 's/^/    /'

    if has_chain DOCKER-USER; then
        echo ""
        echo "▸ DOCKER-USER chain — фильтр контейнеров:"
        iptables -L DOCKER-USER -n --line-numbers 2>/dev/null \
            | grep -E "dpt:25|dpts:6660|dpt:6697" \
            | sed 's/^/    /'
    fi

    echo ""
    echo "▸ INPUT chain — порт $NODE_API_PORT:"
    iptables -L INPUT -n --line-numbers 2>/dev/null \
        | grep "dpt:$NODE_API_PORT" \
        | sed 's/^/    /'

    # --- Функциональная проверка SMTP-блока ---
    echo ""
    log "Тест: попытка SMTP с самой ноды наружу (должна не пройти если есть OUTPUT-блок, иначе пройдёт — это норма, FORWARD блокирует только VPN-юзеров):"
    timeout 5 bash -c 'cat < /dev/tcp/smtp.gmail.com/25' &>/dev/null \
        && log "  ⚠ С ноды напрямую 25 порт открыт (норма — блок только для VPN-трафика)" \
        || log "  ✅ С ноды 25 порт уже не доступен"

    echo ""
    log "=== ✅ Firewall Hardening завершён ==="
    log "    Спам через VPN на 25 порт — невозможен"
    log "    IRC C&C-каналы заблокированы"
    log "    Порт 3001 доступен только с $MASTER_IP"
    log ""
    log "    Проверить можно так:"
    log "      iptables -L FORWARD -n -v | grep dpt:25"
    log "      iptables -L INPUT -n -v | grep dpt:$NODE_API_PORT"
}

# ═══════════════════════════════════════════════════════════
#  ОБНОВЛЁННОЕ МЕНЮ (без пунктов 2 и 3, с новым пунктом 5)
# ═══════════════════════════════════════════════════════════
main_menu() {
    check_root
    log "=== Setup ==="

    while true; do
        echo ""
        echo "1) Отключить IPv6"
        echo "2) VPN Limits (conntrack / sysctl / ulimit)"
        echo "3) VPN Net Optimizer (RPS/RFS/XPS/IRQ/BBR)"
        echo "4) Cron: еженедельный перезапуск VPN (04:00 МСК)"
        echo "5) Firewall Hardening (SMTP/IRC block + master-only 3001)"
        echo "0) Выход"
        read -r -p "Выбор: " choice || true

        case "$choice" in
            1) disable_ipv6 ;;
            2) setup_vpn_limits ;;
            3) setup_net_optimizer ;;
            4) setup_cron_restart ;;
            5) setup_firewall_hardening ;;
            0) exit 0 ;;
            *) log "❌ Неверный пункт" ;;
        esac

        read -r -p "Enter для продолжения..." || true
    done
}
