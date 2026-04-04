#!/usr/bin/env bash
# tools/ssl.sh — SSL certificate management
set -euo pipefail

ACME_HOME="/usr/local/acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
SSL_DIR="/usr/local/nginx/conf/ssl"
VHOST_DIR="/usr/local/nginx/conf/vhost"

_ensure_acme() {
    if [[ -s "$ACME_BIN" ]]; then
        return 0
    fi

    echo "Installing acme.sh..."
    local email="${1:-}"
    [[ -z "$email" ]] && read -r -p "Email for Let's Encrypt registration: " email
    [[ -n "$email" ]] || { echo "Email required."; exit 1; }

    curl -sS https://get.acme.sh | sh -s email="$email"
    ln -sf ~/.acme.sh "$ACME_HOME"

    # Auto-upgrade
    "$ACME_BIN" --upgrade --auto-upgrade

    echo "acme.sh installed to ${ACME_HOME}"
}

ssl_install() {
    _ensure_acme

    local domain="${1:-}"
    local more_domains="${2:-}"
    local webroot="${3:-}"

    [[ -n "$domain" ]] || read -r -p "Domain (e.g. example.com): " domain
    [[ -n "$domain" ]] || { echo "Domain required."; exit 1; }

    if [[ -z "$more_domains" && -z "${1:-}" ]]; then
        read -r -p "More domains (space-separated, or empty): " more_domains
    fi

    # Detect webroot from existing vhost
    if [[ -z "$webroot" ]]; then
        local vhost_conf="${VHOST_DIR}/${domain}.conf"
        if [[ -f "$vhost_conf" ]]; then
            webroot=$(grep -m1 'root ' "$vhost_conf" | awk '{print $2}' | tr -d ';')
        fi
        [[ -z "$webroot" ]] && webroot="/home/wwwroot/${domain}"
        if [[ -z "${1:-}" ]]; then
            read -r -p "Webroot [${webroot}]: " custom_root
            [[ -n "$custom_root" ]] && webroot="$custom_root"
        fi
    fi

    read -r -p "Key type (ec-256 / rsa-2048) [ec-256]: " keytype
    keytype="${keytype:-ec-256}"

    # Build domain args
    local domain_args="-d ${domain}"
    for d in $more_domains; do
        domain_args+=" -d ${d}"
    done

    # Issue certificate
    echo "Issuing certificate for ${domain}..."
    "$ACME_BIN" --issue ${domain_args} -w "$webroot" --keylength "$keytype" \
        || { echo "Certificate issuance failed."; exit 1; }

    # Install certificate
    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"

    local ecc_flag=""
    [[ "$keytype" == ec-* ]] && ecc_flag="--ecc"

    "$ACME_BIN" --install-cert -d "$domain" $ecc_flag \
        --key-file "${cert_dir}/key.pem" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"

    echo ""
    echo "Certificate installed:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    # Ask to configure vhost
    read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
    if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
        _apply_ssl_vhost "$domain" "$more_domains" "$webroot" "$cert_dir"
    fi
}

ssl_renew() {
    _ensure_acme

    local domain="${1:-}"
    if [[ -n "$domain" ]]; then
        echo "Renewing certificate for ${domain}..."
        "$ACME_BIN" --renew -d "$domain" --force
    else
        echo "Renewing all certificates..."
        "$ACME_BIN" --renew-all
    fi
    systemctl reload nginx
    echo "Done."
}

ssl_revoke() {
    _ensure_acme

    read -r -p "Domain to revoke: " domain
    [[ -n "$domain" ]] || exit 1

    "$ACME_BIN" --revoke -d "$domain"
    "$ACME_BIN" --remove -d "$domain"

    local cert_dir="${SSL_DIR}/${domain}"
    [[ -d "$cert_dir" ]] && rm -rf "$cert_dir"

    echo "Certificate for ${domain} revoked and removed."
    echo "Remember to update the Nginx vhost config."
}

ssl_list() {
    _ensure_acme
    echo "=== Installed Certificates ==="
    "$ACME_BIN" --list 2>/dev/null

    echo ""
    echo "=== Expiry Check ==="
    for cert_dir in "${SSL_DIR}"/*/; do
        [[ -f "${cert_dir}fullchain.pem" ]] || continue
        local domain=$(basename "$cert_dir")
        local expiry=$(openssl x509 -enddate -noout -in "${cert_dir}fullchain.pem" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

        local status="✅"
        [[ $days_left -le 7 ]] && status="🔴"
        [[ $days_left -le 30 && $days_left -gt 7 ]] && status="⚠️"

        printf "  %s %-30s expires: %s (%d days)\n" "$status" "$domain" "$expiry" "$days_left"
    done
}

ssl_self() {
    read -r -p "Domain for self-signed cert: " domain
    [[ -n "$domain" ]] || exit 1

    local cert_dir="${SSL_DIR}/${domain}"
    mkdir -p "$cert_dir"

    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${cert_dir}/key.pem" \
        -out "${cert_dir}/fullchain.pem" \
        -subj "/CN=${domain}" 2>/dev/null

    echo "Self-signed certificate created:"
    echo "  Key:       ${cert_dir}/key.pem"
    echo "  Fullchain: ${cert_dir}/fullchain.pem"

    read -r -p "Update Nginx vhost config for SSL? [Y/n]: " update_vhost
    if [[ ! "${update_vhost}" =~ ^[Nn]$ ]]; then
        _apply_ssl_vhost "$domain" "" "/home/wwwroot/${domain}" "$cert_dir"
    fi
}

_apply_ssl_vhost() {
    local domain="$1" more_domains="$2" webroot="$3" cert_dir="$4"
    local server_names="$domain"
    [[ -n "$more_domains" ]] && server_names="${domain} ${more_domains}"

    local vhost_conf="${VHOST_DIR}/${domain}.conf"

    # Remove existing SSL block if any
    if grep -q 'listen 443' "$vhost_conf" 2>/dev/null; then
        echo "SSL block already exists in ${vhost_conf}, skipping."
        return 0
    fi

    # Detect rewrite rule from existing config
    local rewrite="none"
    local rewrite_line=$(grep -m1 'include rewrite/' "$vhost_conf" 2>/dev/null | sed 's/.*include //' | tr -d ';')
    [[ -n "$rewrite_line" ]] && rewrite="$rewrite_line"

    # Add 301 redirect to existing HTTP block
    sed -i '/^server {/,/^}/ {
        /index/a\
\
    # Redirect HTTP to HTTPS\
    return 301 https://$host$request_uri;
    }' "$vhost_conf" 2>/dev/null

    # Append SSL server block
    cat >> "$vhost_conf" <<EOF

server {
    listen 443 ssl http2;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include ${rewrite};

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
    echo "Nginx vhost updated with SSL + HTTP→HTTPS redirect."
}

# --- Main ---
case "${1:-}" in
    install)  ssl_install ;;
    renew)    ssl_renew "${2:-}" ;;
    revoke)   ssl_revoke ;;
    list)     ssl_list ;;
    self)     ssl_self ;;
    *)
        echo "Usage: $0 {install|renew|revoke|list|self}"
        echo ""
        echo "  install  — Issue & install Let's Encrypt certificate"
        echo "  renew    — Renew certificate (or all: renew without domain)"
        echo "  revoke   — Revoke and remove certificate"
        echo "  list     — List certificates with expiry status"
        echo "  self     — Generate self-signed certificate"
        exit 1
        ;;
esac
