#!/usr/bin/env bash
# lib/common.sh — Common utility functions

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

cur_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="/root/lnmp-install.log"

log_info()  { echo -e "${CYAN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
die()       { log_err "$*"; exit 1; }

# Wait for apt/dpkg lock before running apt commands
wait_apt_lock() {
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
        log_info "Waiting for apt lock..."
        sleep 3
    done
}

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
}

# Download file with retry, optional sha256 verification
# Usage: download_src "Name" "URL" ["sha256"]
download_src() {
    local name="$1" url="$2" sha256="${3:-}"
    local filename dest
    filename="$(basename "$url")"
    dest="${cur_dir}/src/${filename}"

    if [[ -f "$dest" ]]; then
        if [[ -n "$sha256" ]] && verify_sha256 "$dest" "$sha256"; then
            log_info "${name}: ${filename} [cached]"
            return 0
        elif [[ -z "$sha256" ]]; then
            log_info "${name}: ${filename} [cached]"
            return 0
        fi
        rm -f "$dest"
    fi

    log_info "Downloading ${name} from ${url} ..."
    local i
    for i in 1 2 3; do
        if wget -c --progress=dot:giga --prefer-family=IPv4 --no-check-certificate -T 120 -t 1 -O "$dest" "$url" 2>&1 | tee -a "$LOG_FILE"; then
            break
        fi
        log_warn "Retry ${i}/3 for ${name}..."
        sleep 2
    done

    [[ -f "$dest" && -s "$dest" ]] || die "Failed to download ${name}"

    if [[ -n "$sha256" ]]; then
        verify_sha256 "$dest" "$sha256" || die "Checksum mismatch: ${name}"
    fi
    log_ok "${name} downloaded."
}

verify_sha256() {
    local file="$1" expected="$2"
    echo "${expected}  ${file}" | sha256sum -c --quiet 2>/dev/null
}

# Extract tarball and cd into it
# Usage: tar_cd "filename.tar.gz" ["expected_dir_name"]
tar_cd() {
    local file="$1" dir="${2:-}"
    local src_dir="${cur_dir}/src"

    cd "$src_dir" || die "Cannot cd to ${src_dir}"

    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"

    case "$file" in
        *.tar.gz|*.tgz)   tar zxf "$file" ;;
        *.tar.bz2)        tar jxf "$file" ;;
        *.tar.xz)         tar Jxf "$file" ;;
        *)                 die "Unknown archive format: $file" ;;
    esac

    if [[ -n "$dir" ]]; then
        cd "$dir" || die "Cannot cd to ${dir}"
    else
        # Auto-detect extracted directory
        local extracted
        extracted="$(tar tf "$file" 2>/dev/null | head -1 | cut -d/ -f1)"
        [[ -n "$extracted" && -d "$extracted" ]] && cd "$extracted"
    fi
}

# Compile and install with parallel make
make_install() {
    local jobs
    jobs=$(nproc 2>/dev/null || echo 1)

    make -j"$jobs" 2>&1 | tee -a "$LOG_FILE"
    local make_rc=${PIPESTATUS[0]}
    [[ $make_rc -eq 0 ]] || die "make failed (exit code: $make_rc)"

    make install 2>&1 | tee -a "$LOG_FILE"
    local install_rc=${PIPESTATUS[0]}
    [[ $install_rc -eq 0 ]] || die "make install failed (exit code: $install_rc)"
}

# Create symlink if not exists
create_lib_link() {
    if [[ -d /usr/lib64 ]] && [[ ! -L /usr/lib64 ]]; then
        [[ -e /usr/lib64/libpcre.so ]] || ln -sf /usr/local/lib/libpcre.so.1 /usr/lib64/ 2>/dev/null
    fi
    ldconfig
}

# Print banner
print_banner() {
    echo "+---------------------------------------------------+"
    echo "|              LNMP Stack Installer                  |"
    echo "+---------------------------------------------------+"
}
