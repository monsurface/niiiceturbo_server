#!/usr/bin/env bash
# install.sh — Main entry point
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
AUTO_MODE='n'
INSTALL_TARGET=''
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO_MODE='y' ;;
        lnmp|nginx|db) INSTALL_TARGET="$arg" ;;
        *) echo "Usage: $0 [--auto] {lnmp|nginx|db}"; exit 1 ;;
    esac
done
[[ -n "$INSTALL_TARGET" ]] || { echo "Usage: $0 [--auto] {lnmp|nginx|db}"; exit 1; }

# Load config (lnmp.conf = defaults, lnmp.conf.local = user overrides)
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"
source "${LNMP_DIR}/lib/deps.sh"
source "${LNMP_DIR}/lib/nginx.sh"
source "${LNMP_DIR}/lib/mysql.sh"
source "${LNMP_DIR}/lib/php.sh"
source "${LNMP_DIR}/lib/extensions.sh"
source "${LNMP_DIR}/lib/security.sh"
source "${LNMP_DIR}/lib/verify.sh"

[[ "$AUTO_MODE" = 'y' ]] && Auto_Install='y'

# Start
print_banner
check_root

START_TIME=$(date +%s)
echo "Install log: ${LOG_FILE}"
echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"

# Detect environment
detect_os
check_os_support
detect_hardware
calc_tuning_params

# Interactive prompts (skip if --auto)
if [[ "${Auto_Install}" != 'y' && "$INSTALL_TARGET" = 'lnmp' ]]; then
    echo ""
    echo "Current configuration:"
    echo "  Database: ${DB_Type} (${MYSQL_VER}/${MARIADB_VER})"
    echo "  PHP: ${PHP_VER}"
    echo "  Nginx: ${NGINX_VER}"
    echo "  Timezone: ${Timezone}"
    echo ""
    read -r -p "Press Enter to start installation, or Ctrl+C to cancel..."
fi

# Prepare system
prepare_system

# Batch install PHP extensions from config
_install_php_extensions() {
    [[ -n "${PHP_Extensions_Install:-}" ]] || return 0
    log_info "Installing PHP extensions: ${PHP_Extensions_Install}"
    for ext in ${PHP_Extensions_Install}; do
        install_extension "$ext"
    done
}

# Step verification — stop on failure
verify_step() {
    local name="$1"
    shift
    if "$@"; then
        log_ok "${name}: verified"
    else
        die "${name}: verification FAILED. Check ${LOG_FILE} and fix before re-running."
    fi
}

verify_nginx() {
    /usr/local/nginx/sbin/nginx -t 2>/dev/null
}

verify_mysql() {
    local db_svc="mysql"
    [[ "${DB_Type}" = 'mariadb' ]] && db_svc="mariadb"
    systemctl is-active --quiet "$db_svc" && \
    /usr/local/mysql/bin/mysqladmin -u root ping &>/dev/null
}

verify_php() {
    /usr/local/php/bin/php -v &>/dev/null && \
    [[ -f /usr/local/php/etc/php-fpm.conf ]]
}

# Install based on target
case "$INSTALL_TARGET" in
    lnmp)
        install_nginx
        verify_step "Nginx" verify_nginx

        install_mysql
        verify_step "MySQL" verify_mysql

        install_php
        verify_step "PHP" verify_php

        install_wp_cli
        _install_php_extensions
        ;;
    nginx)
        install_nginx
        verify_step "Nginx" verify_nginx
        ;;
    db)
        install_mysql
        verify_step "MySQL" verify_mysql
        ;;
esac

# Security hardening
apply_security

# Start services
case "$INSTALL_TARGET" in
    lnmp)
        systemctl start nginx
        systemctl start php-fpm
        ;;
    nginx)
        systemctl start nginx
        ;;
esac

# Install lnmp management command
cp "${LNMP_DIR}/tools/lnmp" /usr/bin/lnmp
chmod +x /usr/bin/lnmp

# Verify
verify_all

# Summary
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS_REMAIN=$(( ELAPSED % 60 ))

echo ""
echo "+---------------------------------------------------+"
echo "|          Installation Complete!                    |"
echo "+---------------------------------------------------+"
echo "  Time elapsed: ${MINUTES}m ${SECONDS_REMAIN}s"
echo "  Nginx: /usr/local/nginx/"
[[ "$INSTALL_TARGET" != 'nginx' ]] && echo "  MySQL: /usr/local/mysql/"
[[ "$INSTALL_TARGET" = 'lnmp' ]] && echo "  PHP:   /usr/local/php/"
echo "  Web root: ${Default_Website_Dir:-/home/wwwroot/default}"
echo "  Logs: /home/wwwlogs/"
echo "  Install log: ${LOG_FILE}"
[[ -f /root/.my.cnf ]] && echo "  MySQL root password: /root/.my.cnf"
command -v docker &>/dev/null && echo "  Docker: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
[[ -x /usr/local/bin/composer ]] && echo "  Composer: $(composer --version 2>/dev/null | awk '{print $3}')"
[[ -x /usr/local/bin/wp ]] && echo "  WP-CLI: $(wp --version 2>/dev/null)"
[[ -n "${PHP_Extensions_Install:-}" ]] && echo "  PHP extensions: ${PHP_Extensions_Install}"
echo ""
echo "  Management: lnmp {start|stop|restart|status}"
echo "+---------------------------------------------------+"
