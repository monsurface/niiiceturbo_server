# LNMP Stack

Automated LNMP (Linux + Nginx + MySQL/MariaDB + PHP) environment builder for Ubuntu servers.

All software compiled from source or installed via official binaries — no third-party mirrors, no vendor lock-in.

## Features

- **Ubuntu-only** — Supports Ubuntu 22.04 LTS and 24.04 LTS, clean and focused
- **Compile from source** — Nginx with latest OpenSSL (HTTP/2, HTTP/3, TLS 1.3), PHP 8.3 with OPcache JIT
- **Auto-tuning** — Nginx workers, MySQL InnoDB buffer pool, PHP-FPM children automatically calculated based on host CPU/RAM
- **Timezone unified** — Single `Timezone` setting applied across system, PHP (`date.timezone`), and MySQL (`default-time-zone`)
- **PHP extension framework** — Registry-based PECL extension compilation: `./tools/addons.sh install redis`
- **Batch extension install** — Pre-configure extensions in `lnmp.conf`, built automatically during installation
- **Tools included** — Docker, Composer, WP-CLI installed by default (configurable)
- **SSL management** — Let's Encrypt issue/renew/revoke, self-signed certs, expiry monitoring, HTTP→HTTPS redirect
- **Security hardening** — SSH hardening, fail2ban, firewall (UFW or iptables)
- **systemd native** — All services managed via systemd with auto-restart on failure
- **100% official sources** — Every download comes from nginx.org, php.net, cdn.mysql.com, etc.
- **Non-interactive mode** — `--auto` flag for fully automated deployment

## Supported OS

| OS | Version | Status |
|----|---------|--------|
| Ubuntu | 24.04 LTS (Noble) | ✅ Recommended |
| Ubuntu | 22.04 LTS (Jammy) | ✅ Supported |

## Software Stack

| Software | Version | Install Method |
|----------|---------|----------------|
| Nginx | 1.26.3 | Compile (with OpenSSL 3.2.3) |
| MySQL | 8.0.40 | Binary |
| MariaDB | 10.11.11 | Binary (alternative) |
| PHP | 8.3.15 | Compile |
| Redis | 7.2.7 | Compile (optional) |
| Docker | Latest | Official script (get.docker.com) |
| Composer | Latest | Official installer (getcomposer.org) |
| WP-CLI | Latest | Official phar (wp-cli.org) |

## Quick Start

```bash
git clone https://github.com/nczz/lnmp-stack.git
cd lnmp-stack

# Review and customize settings
vim lnmp.conf

# Install full stack
sudo ./install.sh lnmp

# Or non-interactive
sudo ./install.sh --auto lnmp
```

## Configuration

Edit `lnmp.conf` before installation:

```bash
# Database: mysql | mariadb
DB_Type='mysql'

# Timezone (applied to system + PHP + MySQL)
Timezone='Asia/Taipei'

# Memory allocator for Nginx
Memory_Allocator='jemalloc'

# PHP built-in extensions (compiled into PHP)
Enable_PHP_Fileinfo='n'
Enable_PHP_Exif='n'
Enable_PHP_Sodium='n'

# PECL extensions to compile after PHP install (space-separated)
PHP_Extensions_Install='redis imagick apcu'

# Tools
Enable_Composer='y'
Enable_Docker='y'
Enable_WP_CLI='y'

# Firewall: ufw | iptables | n (disabled)
Firewall='n'
Enable_Fail2ban='n'
```

Edit `versions.conf` to change software versions — all download URLs are auto-generated from version numbers.

## Auto-Tuning

Configs are automatically optimized based on server specs:

| Parameter | Formula |
|-----------|---------|
| Nginx `worker_processes` | = CPU cores |
| Nginx `worker_connections` | = CPU cores × 1024 (max 65535) |
| MySQL `innodb_buffer_pool_size` | = 50% of RAM (min 128M) |
| MySQL `max_connections` | 64 ~ 512 based on RAM |
| PHP-FPM `pm.max_children` | = 30% of RAM ÷ 40MB per child |
| PHP `memory_limit` | 64M ~ 512M based on RAM |

Swap is auto-created when RAM < 2GB.

## Install Modes

```bash
sudo ./install.sh lnmp          # Full stack: Nginx + MySQL + PHP
sudo ./install.sh nginx         # Nginx only
sudo ./install.sh db            # Database only
sudo ./install.sh --auto lnmp   # Non-interactive (uses lnmp.conf values)
```

## Service Management

```bash
lnmp start                # Start all services
lnmp stop                 # Stop all services
lnmp restart              # Restart all services
lnmp reload               # Reload Nginx + PHP-FPM configs
lnmp status               # Show service status and ports
lnmp kill                 # Force kill all LNMP processes
```

## Virtual Host Management

```bash
lnmp vhost add            # Add virtual host (interactive, with optional SSL)
lnmp vhost del            # Remove virtual host
lnmp vhost list           # List virtual hosts
```

## SSL Certificate Management

```bash
lnmp ssl install          # Issue & install Let's Encrypt certificate
lnmp ssl renew            # Renew all certificates
lnmp ssl renew example.com  # Renew specific domain
lnmp ssl revoke           # Revoke and remove certificate
lnmp ssl list             # List certificates with expiry status (✅/⚠️/🔴)
lnmp ssl self             # Generate self-signed certificate
```

Features:
- Automatic acme.sh installation from GitHub official
- EC-256 (default) or RSA-2048 key type
- Auto HTTP→HTTPS 301 redirect
- HSTS header
- Expiry monitoring (≤7 days 🔴, ≤30 days ⚠️)

## PHP Extensions

```bash
# Install during build via lnmp.conf
PHP_Extensions_Install='redis imagick apcu swoole'

# Or install/uninstall later
sudo ./tools/addons.sh install redis
sudo ./tools/addons.sh install imagick
sudo ./tools/addons.sh install swoole
sudo ./tools/addons.sh uninstall swoole
sudo ./tools/addons.sh list

# Available PECL extensions:
#   redis, imagick, apcu, swoole, memcached, sodium

# Standalone services:
sudo ./tools/addons.sh install redis-server
sudo ./tools/addons.sh install memcached-server
```

Note: OPcache (with JIT) is a PHP built-in module, compiled and enabled by default — not listed here because it's always included.

## Additional Tools

```bash
sudo ./tools/upgrade.sh nginx      # Upgrade Nginx (edit versions.conf first)
sudo ./tools/upgrade.sh php        # Upgrade PHP
sudo ./tools/backup.sh [dir]       # Backup DB + sites + configs (7-day retention)
sudo ./tools/uninstall.sh          # Uninstall (preserves website files, backs up DB)
```

## Directory Layout

| Path | Description |
|------|-------------|
| `/usr/local/nginx/` | Nginx installation |
| `/usr/local/nginx/conf/vhost/` | Virtual host configs |
| `/usr/local/nginx/conf/ssl/` | SSL certificates |
| `/usr/local/mysql/` | MySQL installation |
| `/usr/local/mysql/var/` | MySQL data (configurable) |
| `/usr/local/php/` | PHP installation |
| `/usr/local/php/etc/php.d/` | PHP extension .ini files |
| `/usr/local/redis/` | Redis (if installed) |
| `/usr/local/acme.sh/` | acme.sh (Let's Encrypt client) |
| `/home/wwwroot/` | Website files |
| `/home/wwwlogs/` | Nginx + PHP-FPM logs |
| `/root/.my.cnf` | MySQL root password (auto-generated) |
| `/root/lnmp-install.log` | Installation log |

## Project Structure

```
lnmp-stack/
├── install.sh              # Main entry point
├── versions.conf           # Software versions + official download URLs
├── lnmp.conf               # Installation configuration
├── lib/
│   ├── common.sh           # Logging, download, extract, build utilities
│   ├── detect.sh           # OS detection, hardware detection, auto-tuning
│   ├── deps.sh             # System deps, timezone, Docker, WP-CLI
│   ├── nginx.sh            # Nginx compile (OpenSSL, jemalloc, Lua)
│   ├── mysql.sh            # MySQL/MariaDB binary install
│   ├── php.sh              # PHP compile + OPcache JIT + Composer
│   ├── extensions.sh       # PECL extension compilation framework
│   ├── security.sh         # SSH, fail2ban, UFW/iptables
│   └── verify.sh           # Post-install health checks
├── conf/
│   ├── nginx/              # Nginx config templates (auto-tuned)
│   ├── mysql/my.cnf        # MySQL config template (auto-tuned)
│   ├── php/                # php.ini + php-fpm.conf templates (auto-tuned)
│   └── rewrite/            # URL rewrite rules (WordPress, Laravel, etc.)
├── systemd/                # Service unit files
├── tools/
│   ├── lnmp                # Service management command
│   ├── vhost.sh            # Virtual host management
│   ├── ssl.sh              # SSL certificate management
│   ├── addons.sh           # PHP extension installer
│   ├── upgrade.sh          # Nginx/PHP upgrade
│   ├── backup.sh           # Full backup (DB + sites + configs)
│   └── uninstall.sh        # Clean uninstall
└── src/                    # Source tarball cache (gitignored)
```

## License

MIT
