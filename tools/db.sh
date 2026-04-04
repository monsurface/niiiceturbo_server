#!/usr/bin/env bash
# tools/db.sh — Database management
set -euo pipefail

LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/lnmp.conf"
[[ -f "${LNMP_DIR}/lnmp.conf.local" ]] && source "${LNMP_DIR}/lnmp.conf.local"

_mysql_cmd() {
    local mysql_bin=""
    for bin in /usr/local/mysql/bin/mysql /usr/local/mariadb/bin/mysql /usr/bin/mysql; do
        [[ -x "$bin" ]] && mysql_bin="$bin" && break
    done
    [[ -n "$mysql_bin" ]] || { echo "MySQL client not found."; exit 1; }

    # Use config password, then /root/.my.cnf fallback
    if [[ -n "${MySQL_Root_Password:-}" && "${MySQL_Root_Password}" != 'your_secure_password_here' ]]; then
        "$mysql_bin" -u root -p"${MySQL_Root_Password}" "$@"
    elif [[ -f /root/.my.cnf ]]; then
        "$mysql_bin" "$@"
    else
        "$mysql_bin" -u root "$@"
    fi
}

db_add() {
    local dbname="${1:-}"
    local dbuser="${2:-}"
    local dbpass="${3:-}"

    [[ -n "$dbname" ]] || read -r -p "Database name: " dbname
    [[ -n "$dbname" ]] || { echo "Database name required."; exit 1; }

    [[ -n "$dbuser" ]] || read -r -p "Username (default: ${dbname}): " dbuser
    dbuser="${dbuser:-$dbname}"

    [[ -n "$dbpass" ]] || read -r -sp "Password: " dbpass
    echo ""
    [[ -n "$dbpass" ]] || { echo "Password required."; exit 1; }

    _mysql_cmd -e "
CREATE DATABASE IF NOT EXISTS \`${dbname}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${dbuser}'@'localhost' IDENTIFIED BY '${dbpass}';
GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${dbuser}'@'localhost';
FLUSH PRIVILEGES;
" 2>&1

    echo "Database '${dbname}' created."
    echo "  User: ${dbuser}@localhost"
    echo "  Pass: ${dbpass}"
}

db_del() {
    local dbname="${1:-}"
    [[ -n "$dbname" ]] || read -r -p "Database to delete: " dbname
    [[ -n "$dbname" ]] || exit 1

    read -r -p "Also drop user '${dbname}'@'localhost'? [Y/n]: " drop_user

    _mysql_cmd -e "DROP DATABASE IF EXISTS \`${dbname}\`;" 2>&1
    if [[ ! "${drop_user}" =~ ^[Nn]$ ]]; then
        _mysql_cmd -e "DROP USER IF EXISTS '${dbname}'@'localhost'; FLUSH PRIVILEGES;" 2>&1
    fi

    echo "Database '${dbname}' deleted."
}

db_list() {
    echo "=== Databases ==="
    _mysql_cmd -e "SHOW DATABASES;" 2>&1
    echo ""
    echo "=== Users ==="
    _mysql_cmd -e "SELECT User, Host FROM mysql.user WHERE User NOT IN ('root','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','debian-sys-maint');" 2>&1
}

db_import() {
    local dbname="${1:-}"
    local sqlfile="${2:-}"

    [[ -n "$dbname" ]] || read -r -p "Database name: " dbname
    [[ -n "$sqlfile" ]] || read -r -p "SQL file path: " sqlfile
    [[ -f "$sqlfile" ]] || { echo "File not found: ${sqlfile}"; exit 1; }

    echo "Importing ${sqlfile} into ${dbname}..."
    case "$sqlfile" in
        *.gz)  zcat "$sqlfile" | _mysql_cmd "$dbname" ;;
        *.sql) _mysql_cmd "$dbname" < "$sqlfile" ;;
        *)     _mysql_cmd "$dbname" < "$sqlfile" ;;
    esac
    echo "Import complete."
}

db_export() {
    local dbname="${1:-}"
    [[ -n "$dbname" ]] || read -r -p "Database name: " dbname

    local dump_bin=""
    for bin in /usr/local/mysql/bin/mysqldump /usr/local/mariadb/bin/mysqldump /usr/bin/mysqldump; do
        [[ -x "$bin" ]] && dump_bin="$bin" && break
    done
    [[ -n "$dump_bin" ]] || { echo "mysqldump not found."; exit 1; }

    local outfile="${dbname}_$(date +%Y%m%d_%H%M%S).sql.gz"

    if [[ -n "${MySQL_Root_Password:-}" && "${MySQL_Root_Password}" != 'your_secure_password_here' ]]; then
        "$dump_bin" -u root -p"${MySQL_Root_Password}" --single-transaction --quick "$dbname" | gzip > "$outfile"
    elif [[ -f /root/.my.cnf ]]; then
        "$dump_bin" --single-transaction --quick "$dbname" | gzip > "$outfile"
    else
        "$dump_bin" -u root --single-transaction --quick "$dbname" | gzip > "$outfile"
    fi

    echo "Exported: ${outfile} ($(du -h "$outfile" | cut -f1))"
}

case "${1:-}" in
    add)    shift; db_add "$@" ;;
    del)    shift; db_del "$@" ;;
    list)   db_list ;;
    import) shift; db_import "$@" ;;
    export) shift; db_export "$@" ;;
    *)
        echo "Usage: $0 {add|del|list|import|export}"
        echo ""
        echo "  add [name] [user] [pass]  — Create database + user"
        echo "  del [name]                — Drop database + user"
        echo "  list                      — List databases and users"
        echo "  import [name] [file.sql]  — Import SQL file (supports .gz)"
        echo "  export [name]             — Export database to .sql.gz"
        exit 1
        ;;
esac
