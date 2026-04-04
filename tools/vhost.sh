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
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }
}
EOF

    # SSL setup
    if [[ "${enable_ssl}" =~ ^[Yy]$ ]]; then
        local script_dir="$(cd "$(dirname "$0")" && pwd)"
        bash "${script_dir}/ssl.sh" install "$domain" "$more_domains" "$webroot"
    fi

    # Test and reload
    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
    echo "Virtual host ${domain} created."
    echo "  Config: ${conf_file}"
    echo "  Webroot: ${webroot}"
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
