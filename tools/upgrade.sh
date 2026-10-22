#!/usr/bin/env bash
# tools/upgrade.sh — Upgrade Nginx, MySQL, or PHP
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
source "${LNMP_DIR}/lnmp.conf"
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"
source "${LNMP_DIR}/lib/common.sh"
source "${LNMP_DIR}/lib/detect.sh"

check_root
detect_os
detect_hardware
calc_tuning_params

TARGET="${1:-}"

case "$TARGET" in
    nginx)
        log_info "Upgrading Nginx to ${NGINX_VER}..."
        source "${LNMP_DIR}/lib/nginx.sh"

        # Backup current binary
        cp /usr/local/nginx/sbin/nginx /usr/local/nginx/sbin/nginx.old

        install_nginx

        systemctl restart nginx
        log_ok "Nginx upgraded to ${NGINX_VER}."
        ;;
    php)
        # 線上編譯完成才切換；保留各站設定、既有擴充與可還原的舊版本。
        exec bash "${LNMP_DIR}/tools/upgrade-php-security.sh"
        ;;
    *)
        echo "Usage: $0 {nginx|php}"
        echo ""
        echo "Edit versions.conf to set target versions before upgrading."
        echo "Database upgrades should be done manually for safety."
        exit 1
        ;;
esac
