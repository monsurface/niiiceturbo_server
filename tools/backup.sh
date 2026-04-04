#!/usr/bin/env bash
# tools/backup.sh — Backup websites and databases
set -euo pipefail

BACKUP_DIR="${1:-/data/backup}"
DATE=$(date +%Y%m%d)
BACKUP_PATH="${BACKUP_DIR}/${DATE}"

mkdir -p "$BACKUP_PATH"

echo "=== LNMP Backup — ${DATE} ==="

# Backup all databases
echo "Backing up databases..."
if [[ -f /root/.my.cnf ]]; then
    MYSQL_BIN=$(command -v mysql || echo /usr/local/mysql/bin/mysql)
    MYSQLDUMP_BIN=$(command -v mysqldump || echo /usr/local/mysql/bin/mysqldump)

    databases=$($MYSQL_BIN -N -e "SHOW DATABASES;" 2>/dev/null | grep -Ev '^(information_schema|performance_schema|sys)$')
    for db in $databases; do
        echo "  Dumping ${db}..."
        $MYSQLDUMP_BIN --single-transaction --quick "$db" | gzip > "${BACKUP_PATH}/${db}.sql.gz"
    done
    echo "Database backup complete."
else
    echo "  Skipped — /root/.my.cnf not found."
fi

# Backup website files
echo "Backing up website files..."
if [[ -d /home/wwwroot ]]; then
    tar czf "${BACKUP_PATH}/wwwroot.tar.gz" -C /home wwwroot
    echo "  /home/wwwroot → ${BACKUP_PATH}/wwwroot.tar.gz"
fi

# Backup configs
echo "Backing up configs..."
tar czf "${BACKUP_PATH}/configs.tar.gz" \
    /usr/local/nginx/conf/ \
    /usr/local/php/etc/ \
    /etc/my.cnf \
    2>/dev/null
echo "  Configs → ${BACKUP_PATH}/configs.tar.gz"

# Cleanup old backups (keep 7 days)
find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null

echo ""
echo "Backup complete: ${BACKUP_PATH}"
ls -lh "${BACKUP_PATH}/"
