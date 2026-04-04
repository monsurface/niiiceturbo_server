#!/usr/bin/env bash
# lib/mysql.sh — MySQL/MariaDB binary or compile install

install_mysql() {
    if [[ "${DB_Type}" = 'mariadb' ]]; then
        _install_mariadb
    else
        _install_mysql
    fi
}

_install_mysql() {
    log_info "=== Installing MySQL ${MYSQL_VER} (binary) ==="

    local db_dir="${MySQL_Data_Dir:-/usr/local/mysql/var}"

    id -u mysql &>/dev/null || useradd -s /sbin/nologin -M mysql

    download_src "MySQL" "$MYSQL_URL"

    cd /usr/local/
    local tarball="$(basename "$MYSQL_URL")"
    tar Jxf "${cur_dir}/src/${tarball}"
    mv "mysql-${MYSQL_VER}-linux-glibc2.17-x86_64" mysql

    mkdir -p "$db_dir"
    chown -R mysql:mysql /usr/local/mysql
    chown -R mysql:mysql "$db_dir"

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

    sed -e "s|{{DATA_DIR}}|${db_dir}|g" \
        -e "s|{{INNODB_BUFFER_POOL}}|${MYSQL_INNODB_BUFFER_POOL}M|g" \
        -e "s|{{MAX_CONNECTIONS}}|${MYSQL_MAX_CONNECTIONS}|g" \
        -e "s|{{TIMEZONE}}|${tz}|g" \
        "${cur_dir}/conf/mysql/my.cnf" > /etc/my.cnf

    log_info "MySQL config deployed (buffer_pool=${MYSQL_INNODB_BUFFER_POOL}M, max_conn=${MYSQL_MAX_CONNECTIONS})"
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
