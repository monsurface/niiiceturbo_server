#!/usr/bin/env bash
# tools/uninstall.sh — Uninstall LNMP stack
set -euo pipefail

echo "+---------------------------------------------------+"
echo "|          LNMP Stack Uninstaller                    |"
echo "+---------------------------------------------------+"
echo ""
echo "This will remove Nginx, MySQL/MariaDB, PHP and related files."
echo "Website files in /home/wwwroot/ will be PRESERVED."
echo "Database files will be backed up to /root/db_backup_\$(date)."
echo ""
read -r -p "Are you sure? Type 'yes' to confirm: " confirm
[[ "$confirm" = "yes" ]] || { echo "Cancelled."; exit 0; }

# Stop services
for svc in nginx php-fpm mysql mariadb redis; do
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
done

# Backup database directory
for db_dir in /usr/local/mysql/var /usr/local/mariadb/var; do
    if [[ -d "$db_dir" ]]; then
        backup_dir="/root/db_backup_$(date +%Y%m%d_%H%M%S)"
        echo "Backing up database to ${backup_dir}..."
        cp -a "$db_dir" "$backup_dir"
    fi
done

# Remove installations
rm -rf /usr/local/nginx
rm -rf /usr/local/mysql
rm -rf /usr/local/mariadb
rm -rf /usr/local/php
rm -rf /usr/local/redis

# Remove systemd units
rm -f /etc/systemd/system/{nginx,mysql,mariadb,php-fpm,redis}.service
systemctl daemon-reload

# Remove symlinks
rm -f /usr/bin/{nginx,mysql,mysqldump,mysqladmin,php,phpize,php-config,pecl,php-fpm,redis-cli,redis-server,lnmp}

# Remove configs
rm -f /etc/my.cnf
rm -f /etc/ld.so.conf.d/{mysql,mariadb}.conf
ldconfig

echo ""
echo "LNMP stack uninstalled."
echo "Preserved: /home/wwwroot/ (website files), /home/wwwlogs/ (logs)"
[[ -d "/root/db_backup_"* ]] 2>/dev/null && echo "Database backup: /root/db_backup_*"
