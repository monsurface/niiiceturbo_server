#!/usr/bin/env bash
# lib/verify.sh — Post-install verification

verify_all() {
    log_info "=== Running post-install verification ==="
    local fail=0

    # Service checks
    for svc in nginx php-fpm; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_ok "${svc}: running"
        else
            log_err "${svc}: NOT running"; ((fail++))
        fi
    done

    # DB service (mysql or mariadb)
    local db_svc="mysql"
    [[ "${DB_Type}" = 'mariadb' ]] && db_svc="mariadb"
    if systemctl is-active --quiet "$db_svc" 2>/dev/null; then
        log_ok "${db_svc}: running"
    else
        log_err "${db_svc}: NOT running"; ((fail++))
    fi

    # Port checks
    for port in 80 3306; do
        if ss -tlnp | grep -q ":${port} "; then
            log_ok "Port ${port}: listening"
        else
            log_err "Port ${port}: NOT listening"; ((fail++))
        fi
    done

    # Binary checks
    if /usr/local/php/bin/php -v &>/dev/null; then
        local php_ver_str=$(/usr/local/php/bin/php -r 'echo PHP_VERSION;')
        log_ok "PHP ${php_ver_str}: OK"
    else
        log_err "PHP binary check failed"; ((fail++))
    fi

    if /usr/local/nginx/sbin/nginx -t &>/dev/null; then
        log_ok "Nginx config test: OK"
    else
        log_err "Nginx config test: FAILED"; ((fail++))
    fi

    # MySQL connection
    if mysql -u root -e "SELECT 1;" &>/dev/null; then
        log_ok "MySQL connection: OK"
    else
        log_err "MySQL connection: FAILED"; ((fail++))
    fi

    echo ""
    if [[ $fail -eq 0 ]]; then
        log_ok "All checks passed!"
    else
        log_err "${fail} check(s) failed. Review the log: ${LOG_FILE}"
    fi

    return $fail
}
