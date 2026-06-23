#!/usr/bin/env bash
# tools/vhost.sh — Virtual host management
# Interactive or CLI mode
set -euo pipefail

VHOST_DIR="/usr/local/nginx/conf/vhost"
WEBROOT_BASE="/home/wwwroot"
REWRITE_DIR="/usr/local/nginx/conf/rewrite"

# --- per-site PHP-FPM pool（資源硬隔離）---------------------------------------
# 每個站一個獨立 php-fpm pool：獨立 listen socket + pm.max_children 限額 +
# per-pool memory_limit。從源頭防一個站 PHP 暴衝吃滿共用 pool 壓垮鄰居
# (noisy neighbor)。共用 [www] pool（/tmp/php-cgi.sock）仍保留為預設 / fallback，
# 未被本腳本重建 vhost 的舊站繼續沿用，向後相容。
PHP_FPM_DIR="/usr/local/php/etc/php-fpm.d"
PHP_FPM_MAIN_CONF="/usr/local/php/etc/php-fpm.conf"
PHP_FPM_BIN="/usr/local/php/sbin/php-fpm"
# 預設值刻意保守而安全：8 個 worker / 256M per-pool 對單一 WordPress 站足夠，
# 又能讓單機塞下多站。可由 --php-max-children / --php-memory-limit 覆寫。
DEFAULT_PHP_MAX_CHILDREN=8
DEFAULT_PHP_MEMORY_LIMIT="256M"

show_add_usage() {
    echo "Usage: vhost.sh add <domain> [options]"
    echo ""
    echo "Options:"
    echo "  --domains \"d1 d2\"        Additional domains (aliases)"
    echo "  --webroot /path           Custom web root (default: /home/wwwroot/<domain>)"
    echo "  --rewrite name            Rewrite rule: wordpress, laravel, thinkphp, yii2, none"
    echo "  --ssl                     Enable Let's Encrypt SSL"
    echo "  --redirect                Force HTTP→HTTPS 301 redirect"
    echo "  --email addr              ACME registration email (for first SSL on a fresh host)"
    echo "  --php-max-children N      Per-site PHP-FPM pool worker cap (default: ${DEFAULT_PHP_MAX_CHILDREN})"
    echo "  --php-memory-limit M      Per-site PHP-FPM pool memory_limit (default: ${DEFAULT_PHP_MEMORY_LIMIT})"
    echo "  --shared-pool             Use the legacy shared [www] pool instead of a per-site pool"
    echo ""
    echo "Examples:"
    echo "  vhost.sh add example.com --rewrite wordpress --ssl"
    echo "  vhost.sh add example.com --rewrite wordpress --ssl --redirect"
    echo "  vhost.sh add example.com --rewrite wordpress --php-max-children 12 --php-memory-limit 384M"
    echo "  vhost.sh add example.com --domains \"www.example.com\" --rewrite laravel"
}

# 把 php-fpm.d/*.conf 的 include 確保進主 php-fpm.conf（冪等）。
# 原 fork 的 php-fpm.conf 樣板只有 inline [global] + [www]，沒有 include，
# 所以 php-fpm.d/<domain>.conf 不會被載入。這裡在開站時補一行 include，
# 對既有主機與新主機都生效（reload 會重讀含 include 的整份設定）。
ensure_fpm_include() {
    [[ -f "$PHP_FPM_MAIN_CONF" ]] || return 0
    # 已有任何 include = .../php-fpm.d/*.conf 就不重複加
    if grep -Eq '^\s*include\s*=.*php-fpm\.d/\*\.conf' "$PHP_FPM_MAIN_CONF"; then
        return 0
    fi
    printf '\n; per-site pools（vhost.sh 開站時自動建立，資源硬隔離）\ninclude=%s/*.conf\n' "$PHP_FPM_DIR" >> "$PHP_FPM_MAIN_CONF"
    echo "  Added php-fpm.d include to ${PHP_FPM_MAIN_CONF}"
}

# pool 名稱：用 domain 但把點換成底線，避免奇怪字元（pool 名只是標籤）。
fpm_pool_name() {
    echo "$1" | tr '.' '_'
}

fpm_pool_conf_path() {
    echo "${PHP_FPM_DIR}/$1.conf"
}

fpm_pool_socket_path() {
    echo "/tmp/php-cgi-$1.sock"
}

# 寫每站獨立 php-fpm pool 設定檔。沿用共用 [www] 的安全基線
# (disable_functions / expose_php / open_basedir)，但 socket / pm / memory_limit
# 各站獨立。pm=ondemand → 閒置不佔 RAM，平時零成本，被打才起 worker。
write_fpm_pool() {
    local domain="$1" webroot="$2" max_children="$3" memory_limit="$4"
    local pool_name socket conf
    pool_name="$(fpm_pool_name "$domain")"
    socket="$(fpm_pool_socket_path "$domain")"
    conf="$(fpm_pool_conf_path "$domain")"

    mkdir -p "$PHP_FPM_DIR"
    cat > "$conf" <<EOF
; per-site pool for ${domain}（資源硬隔離，vhost.sh 自動產生）
[${pool_name}]
listen = ${socket}
listen.owner = www
listen.group = www
listen.mode = 0660
listen.backlog = 65535

user = www
group = www

; 並發 PHP worker 上限 → 間接限該站 CPU/RAM 佔用，防 noisy neighbor
pm = ondemand
pm.max_children = ${max_children}
pm.process_idle_timeout = 10s
pm.max_requests = 1024
pm.status_path = /fpm-status-${pool_name}

request_terminate_timeout = 300
request_slowlog_timeout = 5
slowlog = /home/wwwlogs/php-fpm-slow-${pool_name}.log

; per-pool RAM 上限（硬隔離核心之一）
php_admin_value[memory_limit] = ${memory_limit}

; 安全基線（與共用 [www] 一致）
php_admin_value[expose_php] = Off
php_admin_value[disable_functions] = passthru,exec,system,chroot,chgrp,chown,shell_exec,popen,proc_open,ini_alter,ini_restore,dl,openlog,syslog,readlink,symlink,imap_open,apache_setenv
php_admin_value[open_basedir] = ${webroot}:/tmp/:/proc/

catch_workers_output = yes
decorate_workers_output = no
rlimit_files = 65535

; TODO(CPU cgroup 硬限)：php-fpm 由單一 systemd service(php-fpm.service)管，
; 所有 pool 跑在同一個 master 進程下，無法用 systemd slice 對「單一 pool」設
; CPUQuota（只能對整個 master）。要做 per-pool CPU 硬限需把每站 pool 拆成
; 各自的 systemd service + slice，風險高、改動大。目前以 pm.max_children +
; memory_limit 做有效隔離（限並發 worker 數＝間接限 CPU 時間佔用），CPU cgroup
; 列為後續強化項，不在本次施作。
EOF
    echo "  PHP-FPM pool: ${conf} (socket=${socket}, max_children=${max_children}, memory_limit=${memory_limit})"
}

# reload php-fpm（先 -t 驗證設定，過了才 reload，避免壞檔打掛全主機）。
reload_fpm() {
    if [[ ! -x "$PHP_FPM_BIN" ]]; then
        echo "  WARN: ${PHP_FPM_BIN} not found, skipping php-fpm reload"
        return 0
    fi
    if ! "$PHP_FPM_BIN" -t 2>/dev/null; then
        echo "  ERROR: php-fpm config test failed; not reloading. Run '${PHP_FPM_BIN} -t' to inspect." >&2
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^php-fpm\.service'; then
        systemctl reload php-fpm
    else
        # fallback：直接送 USR2 給 master（graceful reload）
        local pidfile="/usr/local/php/var/run/php-fpm.pid"
        [[ -f "$pidfile" ]] && kill -USR2 "$(cat "$pidfile")" 2>/dev/null || true
    fi
    echo "  Reloaded php-fpm"
}

vhost_add() {
    local domain="" more_domains="" webroot="" rewrite="none" enable_ssl="n" force_redirect="n" acme_email=""
    local php_max_children="$DEFAULT_PHP_MAX_CHILDREN" php_memory_limit="$DEFAULT_PHP_MEMORY_LIMIT" shared_pool="n"

    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domains)          more_domains="$2"; shift 2 ;;
            --webroot)          webroot="$2"; shift 2 ;;
            --rewrite)          rewrite="$2"; shift 2 ;;
            --ssl)              enable_ssl="y"; shift ;;
            --redirect)         force_redirect="y"; shift ;;
            --email)            acme_email="$2"; shift 2 ;;
            --php-max-children) php_max_children="$2"; shift 2 ;;
            --php-memory-limit) php_memory_limit="$2"; shift 2 ;;
            --shared-pool)      shared_pool="y"; shift ;;
            --help|-h)          show_add_usage; exit 0 ;;
            -*)                 echo "Unknown option: $1"; show_add_usage; exit 1 ;;
            *)                  [[ -z "$domain" ]] && domain="$1" || more_domains="${more_domains:+$more_domains }$1"; shift ;;
        esac
    done

    # Interactive fallback for missing values
    if [[ -z "$domain" ]]; then
        read -r -p "Domain name (e.g. example.com): " domain
        [[ -n "$domain" ]] || { echo "Domain cannot be empty."; exit 1; }

        read -r -p "More domains (space-separated, or empty): " more_domains

        [[ -n "$webroot" ]] || {
            local default_root="${WEBROOT_BASE}/${domain}"
            read -r -p "Web root [${default_root}]: " webroot
            webroot="${webroot:-$default_root}"
        }

        echo "Available rewrite rules:"
        ls "${REWRITE_DIR}/" 2>/dev/null | sed 's/\.conf$//' | while read -r r; do echo "  $r"; done
        read -r -p "Rewrite rule (or 'none') [${rewrite}]: " input_rewrite
        rewrite="${input_rewrite:-$rewrite}"

        read -r -p "Enable SSL via Let's Encrypt? [y/N]: " enable_ssl
    fi

    webroot="${webroot:-${WEBROOT_BASE}/${domain}}"

    # 驗證 max_children 是正整數，否則退回安全預設（避免寫出壞 pool 檔）
    if ! [[ "$php_max_children" =~ ^[1-9][0-9]*$ ]]; then
        echo "  WARN: invalid --php-max-children '${php_max_children}', falling back to ${DEFAULT_PHP_MAX_CHILDREN}"
        php_max_children="$DEFAULT_PHP_MAX_CHILDREN"
    fi

    # Create webroot
    mkdir -p "$webroot"
    chown www:www "$webroot"

    # 決定這個站用哪個 fastcgi socket：
    #  - 預設 → per-site pool（資源硬隔離）
    #  - --shared-pool → 沿用共用 [www]（/tmp/php-cgi.sock），完全等同舊行為
    local fastcgi_socket="/tmp/php-cgi.sock"
    if [[ "$shared_pool" != "y" ]]; then
        ensure_fpm_include
        write_fpm_pool "$domain" "$webroot" "$php_max_children" "$php_memory_limit"
        fastcgi_socket="$(fpm_pool_socket_path "$domain")"
        # 先 reload php-fpm，讓新 pool 的 socket 真正存在，nginx 才連得上
        if ! reload_fpm; then
            echo "  ERROR: php-fpm reload failed; aborting vhost creation for ${domain}." >&2
            rm -f "$(fpm_pool_conf_path "$domain")"
            exit 1
        fi
    fi

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
        fastcgi_pass unix:${fastcgi_socket};
        fastcgi_index index.php;
        include fastcgi.conf;
        fastcgi_param PHP_ADMIN_VALUE "open_basedir=${webroot}:/tmp/:/proc/";
    }

    location ~ /\. {
        deny all;
    }

    location ^~ /.well-known/acme-challenge/ {
        allow all;
    }
}
EOF

    # Reload Nginx so the new vhost is active (required before SSL verification)
    /usr/local/nginx/sbin/nginx -t && systemctl reload nginx

    # SSL setup (needs working vhost to serve .well-known/acme-challenge/)
    if [[ "${enable_ssl}" =~ ^[Yy]$ ]]; then
        local script_dir="$(cd "$(dirname "$0")" && pwd)"
        local ssl_args="$domain --webroot $webroot"
        [[ -n "$more_domains" ]] && ssl_args="$ssl_args --domains \"$more_domains\""
        [[ -n "$acme_email" ]] && ssl_args="$ssl_args --email $acme_email"
        FORCE_REDIRECT="$force_redirect" bash "${script_dir}/ssl.sh" install $ssl_args
    fi

    echo "Virtual host ${domain} created."
    echo "  Config: ${conf_file}"
    echo "  Webroot: ${webroot}"
    if [[ "$shared_pool" != "y" ]]; then
        echo "  PHP-FPM: dedicated pool (max_children=${php_max_children}, memory_limit=${php_memory_limit})"
    else
        echo "  PHP-FPM: shared [www] pool (legacy)"
    fi
}

vhost_del() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || read -r -p "Domain to remove: " domain
    [[ -n "$domain" ]] || exit 1

    local conf_file="${VHOST_DIR}/${domain}.conf"
    if [[ -f "$conf_file" ]]; then
        rm -f "$conf_file"
        /usr/local/nginx/sbin/nginx -t && systemctl reload nginx
        # 一併移除該站的 per-site php-fpm pool（若有），再 reload php-fpm
        local pool_conf
        pool_conf="$(fpm_pool_conf_path "$domain")"
        if [[ -f "$pool_conf" ]]; then
            rm -f "$pool_conf"
            reload_fpm || echo "  WARN: php-fpm reload failed after removing pool ${pool_conf}"
            echo "  Removed PHP-FPM pool: ${pool_conf}"
        fi
        echo "Vhost ${domain} removed. (Webroot preserved at ${WEBROOT_BASE}/${domain})"
    else
        echo "Config not found: ${conf_file}"
    fi
}

vhost_list() {
    echo "Virtual hosts:"
    printf "  %-30s %s\n" "CONFIG" "SERVER_NAME"
    printf "  %-30s %s\n" "------" "-----------"
    for f in "${VHOST_DIR}"/*.conf; do
        [[ -f "$f" ]] || continue
        local name=$(basename "$f" .conf)
        [[ "$name" = "default" ]] && continue
        local domains=$(grep -m1 'server_name' "$f" | sed 's/.*server_name //;s/;//')
        printf "  %-30s %s\n" "$name" "$domains"
    done
}

case "${1:-}" in
    add)  shift; vhost_add "$@" ;;
    del)  shift; vhost_del "$@" ;;
    list) vhost_list ;;
    *)
        echo "Usage: vhost.sh {add|del|list}"
        echo ""
        echo "  add [domain] [options]  — Add virtual host"
        echo "  del [domain]            — Remove virtual host"
        echo "  list                    — List virtual hosts"
        echo ""
        echo "Run 'vhost.sh add --help' for add options."
        exit 1
        ;;
esac
