#!/usr/bin/env bash
# tools/vhost.sh — Virtual host management
set -euo pipefail

VHOST_DIR="/usr/local/nginx/conf/vhost"
WEBROOT_BASE="/home/wwwroot"
REWRITE_DIR="/usr/local/nginx/conf/rewrite"

vhost_add() {
    read -r -p "Domain name (e.g. example.com): " domain
    [[ -n "$domain" ]] || { echo "Domain cannot be empty."; exit 1; }

    read -r -p "More domains (space-separated, or leave empty): " more_domains

    local webroot="${WEBROOT_BASE}/${domain}"
    read -r -p "Web root [${webroot}]: " custom_root
    [[ -n "$custom_root" ]] && webroot="$custom_root"

    # Rewrite rule
    echo "Available rewrite rules:"
    ls "${REWRITE_DIR}/" 2>/dev/null | sed 's/\.conf$//' | while read -r r; do echo "  $r"; done
    read -r -p "Rewrite rule (or 'none'): " rewrite
    rewrite="${rewrite:-none}"

    # SSL
    read -r -p "Enable SSL via Let's Encrypt? [y/N]: " enable_ssl

    # Create webroot
    mkdir -p "$webroot"
    chown www:www "$webroot"

    # Generate vhost config
    local server_names="$domain"
    [[ -n "$more_domains" ]] && server_names="${domain} ${more_domains}"

    local conf_file="${VHOST_DIR}/${domain}.conf"
    cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include rewrite/${rewrite}.conf;

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    # SSL setup
    if [[ "${enable_ssl}" =~ ^[Yy]$ ]]; then
        _setup_ssl "$domain" "$server_names" "$webroot" "$rewrite"
    fi

    # Test and reload
    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
    echo "Virtual host ${domain} created."
    echo "  Config: ${conf_file}"
    echo "  Webroot: ${webroot}"
}

_setup_ssl() {
    local domain="$1" server_names="$2" webroot="$3" rewrite="$4"

    if [[ ! -s /usr/local/acme.sh/acme.sh ]]; then
        echo "acme.sh not found. Installing..."
        curl -sS https://get.acme.sh | sh -s email=admin@${domain}
        ln -sf ~/.acme.sh /usr/local/acme.sh
    fi

    /usr/local/acme.sh/acme.sh --issue -d "$domain" -w "$webroot" --keylength ec-256

    local ssl_dir="/usr/local/nginx/conf/ssl/${domain}"
    mkdir -p "$ssl_dir"
    /usr/local/acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --key-file "${ssl_dir}/key.pem" \
        --fullchain-file "${ssl_dir}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"

    # Append SSL server block
    cat >> "${VHOST_DIR}/${domain}.conf" <<EOF

server {
    listen 443 ssl http2;
    server_name ${server_names};
    root ${webroot};
    index index.html index.htm index.php;

    ssl_certificate ${ssl_dir}/fullchain.pem;
    ssl_certificate_key ${ssl_dir}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000" always;

    access_log /home/wwwlogs/${domain}.log main;
    error_log /home/wwwlogs/${domain}.error.log;

    include rewrite/${rewrite}.conf;

    location ~ \.php\$ {
        fastcgi_pass unix:/tmp/php-cgi.sock;
        fastcgi_index index.php;
        include fastcgi.conf;
    }

    location ~ /\. {
        deny all;
    }
}
EOF
}

vhost_del() {
    read -r -p "Domain to remove: " domain
    [[ -n "$domain" ]] || exit 1

    local conf_file="${VHOST_DIR}/${domain}.conf"
    if [[ -f "$conf_file" ]]; then
        rm -f "$conf_file"
        /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
        echo "Vhost ${domain} removed. (Webroot preserved at ${WEBROOT_BASE}/${domain})"
    else
        echo "Config not found: ${conf_file}"
    fi
}

vhost_list() {
    echo "Virtual hosts:"
    for f in "${VHOST_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        local name=$(basename "$f" .conf)
        local domains=$(grep -m1 'server_name' "$f" | sed 's/.*server_name //;s/;//')
        printf "  %-30s %s\n" "$name" "$domains"
    done
}

case "${1:-}" in
    add)  vhost_add ;;
    del)  vhost_del ;;
    list) vhost_list ;;
    *)    echo "Usage: vhost.sh {add|del|list}"; exit 1 ;;
esac
