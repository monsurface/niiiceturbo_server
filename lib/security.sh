#!/usr/bin/env bash
# lib/security.sh — Security hardening

apply_security() {
    log_info "Applying security hardening..."

    _harden_ssh
    _harden_nginx

    [[ "${Enable_Fail2ban}" = 'y' ]] && _install_fail2ban

    case "${Firewall}" in
        ufw)      _setup_ufw ;;
        iptables) _setup_iptables ;;
    esac

    log_ok "Security hardening applied."
}

_harden_ssh() {
    local sshd_conf="/etc/ssh/sshd_config"
    [[ -f "$sshd_conf" ]] || return 0

    # Disable root password login (keep key-based)
    if ! grep -q '^PermitRootLogin prohibit-password' "$sshd_conf"; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$sshd_conf"
    fi
    # Disable empty passwords
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$sshd_conf"

    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    log_info "SSH hardened."
}

_harden_nginx() {
    # Hide version
    local nginx_conf="/usr/local/nginx/conf/nginx.conf"
    [[ -f "$nginx_conf" ]] || return 0

    if ! grep -q 'server_tokens off' "$nginx_conf"; then
        sed -i '/http {/a\    server_tokens off;' "$nginx_conf"
    fi
}

_install_fail2ban() {
    log_info "Installing fail2ban..."
    apt-get install -y fail2ban 2>&1 | tee -a "$LOG_FILE"

    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /home/wwwlogs/*.log
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    log_ok "fail2ban installed."
}

_setup_ufw() {
    log_info "Configuring UFW firewall..."
    apt-get install -y ufw 2>&1 | tee -a "$LOG_FILE"

    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable

    log_ok "UFW configured (SSH + HTTP + HTTPS allowed)."
}

_setup_iptables() {
    log_info "Configuring iptables firewall..."
    apt-get install -y iptables-persistent 2>&1 | tee -a "$LOG_FILE"

    # Flush
    iptables -F
    iptables -X

    # Default policy
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # SSH
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    # HTTP / HTTPS
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

    # Save
    netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

    log_ok "iptables configured (SSH + HTTP + HTTPS allowed)."
}
