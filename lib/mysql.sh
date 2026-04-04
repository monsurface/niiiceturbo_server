#!/usr/bin/env bash
# lib/mysql.sh — MySQL/MariaDB binary or compile install

install_mysql() {
    if [[ "${DB_Type}" = 'mariadb' ]]; then
        _install_mariadb
    else
        _install_mysql
    fi
}

# Fix shared library issues for MySQL binary package on Ubuntu 24.04+
_fix_mysql_libs() {
    log_info "Checking MySQL shared library dependencies..."

    apt-get install -y libaio1t64 libncurses6 libtinfo6 libmecab2 2>&1 | tee -a "$LOG_FILE"

    # MySQL 8.0 binary expects libaio.so.1 but Ubuntu 24.04 has libaio.so.1t64
    if [[ ! -e /usr/lib/x86_64-linux-gnu/libaio.so.1 ]] && [[ -e /usr/lib/x86_64-linux-gnu/libaio.so.1t64 ]]; then
        ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
        log_info "Symlinked libaio.so.1t64 → libaio.so.1"
    fi

    # MySQL 8.0 binary expects libncurses.so.5 / libtinfo.so.5 but Ubuntu 24.04 has v6
    if [[ ! -e /usr/lib/x86_64-linux-gnu/libncurses.so.5 ]]; then
        ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
        log_info "Symlinked libncurses.so.6 → libncurses.so.5"
    fi
    if [[ ! -e /usr/lib/x86_64-linux-gnu/libtinfo.so.5 ]]; then
        ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
        log_info "Symlinked libtinfo.so.6 → libtinfo.so.5"
    fi

    ldconfig
}

# Verify MySQL binary can find all shared libraries
_verify_mysql_libs() {
    local bin="$1"
    local missing
    missing=$(ldd "$bin" 2>&1 | grep 'not found' || true)
    if [[ -n "$missing" ]]; then
        log_err "Missing shared libraries for ${bin}:"
        echo "$missing" | tee -a "$LOG_FILE"
        die "Fix library dependencies before continuing."
    fi
    log_ok "Shared library check passed for $(basename "$bin")"
}

_install_mysql() {
    log_info "=== Installing MySQL ${MYSQL_VER} (binary) ==="

    local db_dir="${MySQL_Data_Dir:-/usr/local/mysql/var}"

    id -u mysql &>/dev/null || useradd -s /sbin/nologin -M mysql

    # Ensure required shared libraries
    _fix_mysql_libs

    download_src "MySQL" "$MYSQL_URL"

    cd /usr/local/
    local tarball="$(basename "$MYSQL_URL")"
    tar Jxf "${cur_dir}/src/${tarball}"
    mv "mysql-${MYSQL_VER}-linux-glibc2.17-x86_64" mysql

    mkdir -p "$db_dir"
    chown -R mysql:mysql /usr/local/mysql
    chown -R mysql:mysql "$db_dir"

    # Verify shared libraries before proceeding
    _verify_mysql_libs /usr/local/mysql/bin/mysqld

    # Generate my.cnf from template
    _deploy_mysql_conf "$db_dir"

    # Initialize
    /usr/local/mysql/bin/mysqld --initialize-insecure --user=mysql \
        --basedir=/usr/local/mysql --datadir="$db_dir" 2>&1 | tee -a "$LOG_FILE"

    # Install systemd unit
    cp "${cur_dir}/systemd/mysql.service" /etc/systemd/system/mysql.service
    systemctl daemon-reload
    systemctl enable mysql
    systemctl start mysql

    # Wait for startup
    local i
    for i in $(seq 1 30); do
        /usr/local/mysql/bin/mysqladmin -u root ping &>/dev/null && break
        sleep 1
    done

    # Secure installation
    _secure_mysql "$db_dir"

    # Load timezone tables so named timezones (e.g. Asia/Taipei) work in queries
    _load_mysql_tz

    # Symlinks
    ln -sf /usr/local/mysql/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mysql/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mysql/bin/mysqladmin /usr/bin/mysqladmin

    # Add to library path
    echo "/usr/local/mysql/lib" > /etc/ld.so.conf.d/mysql.conf
    ldconfig

    log_ok "MySQL ${MYSQL_VER} installed."
}

_install_mariadb() {
    log_info "=== Installing MariaDB ${MARIADB_VER} (binary) ==="

    local db_dir="${MariaDB_Data_Dir:-/usr/local/mariadb/var}"

    id -u mysql &>/dev/null || useradd -s /sbin/nologin -M mysql

    download_src "MariaDB" "$MARIADB_URL"

    cd /usr/local/
    local tarball="$(basename "$MARIADB_URL")"
    tar zxf "${cur_dir}/src/${tarball}"
    mv "mariadb-${MARIADB_VER}-linux-systemd-x86_64" mariadb
    ln -sf /usr/local/mariadb /usr/local/mysql

    mkdir -p "$db_dir"
    chown -R mysql:mysql /usr/local/mariadb
    chown -R mysql:mysql "$db_dir"

    _deploy_mysql_conf "$db_dir"

    /usr/local/mariadb/scripts/mysql_install_db --user=mysql \
        --basedir=/usr/local/mariadb --datadir="$db_dir" 2>&1 | tee -a "$LOG_FILE"

    sed "s|/usr/local/mysql|/usr/local/mariadb|g" \
        "${cur_dir}/systemd/mysql.service" > /etc/systemd/system/mariadb.service
    systemctl daemon-reload
    systemctl enable mariadb
    systemctl start mariadb

    local i
    for i in $(seq 1 30); do
        /usr/local/mariadb/bin/mysqladmin -u root ping &>/dev/null && break
        sleep 1
    done

    _secure_mysql "$db_dir"

    ln -sf /usr/local/mariadb/bin/mysql /usr/bin/mysql
    ln -sf /usr/local/mariadb/bin/mysqldump /usr/bin/mysqldump
    ln -sf /usr/local/mariadb/bin/mysqladmin /usr/bin/mysqladmin

    echo "/usr/local/mariadb/lib" > /etc/ld.so.conf.d/mariadb.conf
    ldconfig

    log_ok "MariaDB ${MARIADB_VER} installed."
}

_deploy_mysql_conf() {
    local db_dir="$1"
    local tz="${Timezone:-UTC}"

    # MySQL requires UTC offset format for default-time-zone before timezone tables are loaded
    # Convert named timezone to offset using system date command
    local tz_offset
    tz_offset=$(TZ="$tz" date +%:z 2>/dev/null || echo "+00:00")

    sed -e "s|{{DATA_DIR}}|${db_dir}|g" \
        -e "s|{{INNODB_BUFFER_POOL}}|${MYSQL_INNODB_BUFFER_POOL}M|g" \
        -e "s|{{MAX_CONNECTIONS}}|${MYSQL_MAX_CONNECTIONS}|g" \
        -e "s|{{TIMEZONE}}|${tz_offset}|g" \
        "${cur_dir}/conf/mysql/my.cnf" > /etc/my.cnf

    log_info "MySQL config deployed (buffer_pool=${MYSQL_INNODB_BUFFER_POOL}M, max_conn=${MYSQL_MAX_CONNECTIONS}, tz=${tz_offset})"
}

_load_mysql_tz() {
    local mysql_bin
    if [[ "${DB_Type}" = 'mariadb' ]]; then
        mysql_bin=/usr/local/mariadb/bin/mysql
        /usr/local/mariadb/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | ${mysql_bin} -u root mysql 2>/dev/null
    else
        mysql_bin=/usr/local/mysql/bin/mysql
        /usr/local/mysql/bin/mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | ${mysql_bin} -u root mysql 2>/dev/null
    fi
    log_info "MySQL timezone tables loaded."
}

_secure_mysql() {
    local db_dir="$1"
    local mysql_bin

    if [[ "${DB_Type}" = 'mariadb' ]]; then
        mysql_bin=/usr/local/mariadb/bin/mysql
    else
        mysql_bin=/usr/local/mysql/bin/mysql
    fi

    # Generate random root password
    DB_Root_Password="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)"

    ${mysql_bin} -u root <<-EOSQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_Root_Password}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL

    # Save password to protected file
    cat > /root/.my.cnf <<-EOF
[client]
user=root
password=${DB_Root_Password}
EOF
    chmod 600 /root/.my.cnf

    log_ok "MySQL secured. Root password saved to /root/.my.cnf"
}
