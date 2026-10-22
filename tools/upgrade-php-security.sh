#!/usr/bin/env bash
# 同一 PHP 8.3 分支安全更新：線上編譯、保留設定及外掛擴充，切換失敗自動還原。
set -Eeuo pipefail
LNMP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${LNMP_DIR}/versions.conf"
[[ ${EUID} -eq 0 ]] || { echo '需要 root 權限'; exit 1; }
[[ ${PHP_VER} == 8.3.* && ${PHP_SHA256} =~ ^[0-9a-f]{64}$ ]] || exit 1
PREFIX=/usr/local/php
[[ -x ${PREFIX}/bin/php && -x ${PREFIX}/bin/php-config ]] || exit 1
OLD_VERSION="$(${PREFIX}/bin/php -n -r 'echo PHP_VERSION;')"
[[ ${OLD_VERSION} == 8.3.* ]] || { echo '僅支援原有 PHP 8.3 主機'; exit 1; }
if [[ ${OLD_VERSION} == "${PHP_VER}" ]]; then
    "${PREFIX}/sbin/php-fpm" -t
    systemctl is-active --quiet php-fpm
    echo "已使用 PHP ${PHP_VER}"
    exit 0
fi
systemctl is-active --quiet php-fpm
ROOT="/usr/local/.php-security/${PHP_VER}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${ROOT}/build" "${ROOT}/stage"
[[ $(stat -c %d /usr/local) == "$(stat -c %d "${ROOT}")" ]] || exit 1
printf '%s\n' "舊版本=${OLD_VERSION}" "目標版本=${PHP_VER}" "備份=${ROOT}"
"${PREFIX}/bin/php" -m | LC_ALL=C sort > "${ROOT}/modules.before"
"${PREFIX}/sbin/php-fpm" -t
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "${PHP_URL}" -o "${ROOT}/php.tar.xz"
printf '%s  %s\n' "${PHP_SHA256}" "${ROOT}/php.tar.xz" | sha256sum -c -
tar -xJf "${ROOT}/php.tar.xz" -C "${ROOT}/build"
cd "${ROOT}/build/php-${PHP_VER}"
# 重用原機已驗證的編譯參數；以 NUL 分隔，保留參數中的空白而不執行 eval。
mapfile -d '' ARGS < <("${PREFIX}/bin/php-config" --configure-options | python3 -c 'import shlex,sys; sys.stdout.buffer.write(b"\0".join(s.encode() for s in shlex.split(sys.stdin.read()))+b"\0")')
./configure "${ARGS[@]}" > "${ROOT}/configure.log" 2>&1
nice -n 19 make -j"${PHP_SECURITY_BUILD_JOBS:-2}" > "${ROOT}/make.log" 2>&1
make INSTALL_ROOT="${ROOT}/stage" install > "${ROOT}/install.log" 2>&1
STAGED="${ROOT}/stage${PREFIX}"
[[ $("${STAGED}/bin/php" -n -r 'echo PHP_VERSION;') == "${PHP_VER}" ]]
# 保留原機全部 extension 與各站 pool；只覆蓋本次編譯產出的程式。
cp -a "${PREFIX}" "${ROOT}/new-php"
cp -a "${STAGED}/." "${ROOT}/new-php/"
cp -a "${PREFIX}/etc/." "${ROOT}/new-php/etc/"
"${ROOT}/new-php/sbin/php-fpm" -t -y "${PREFIX}/etc/php-fpm.conf"
STOPPED=0
SWITCHED=0
rollback() {
    local code=$?
    trap - ERR
    if [[ ${SWITCHED} == 1 ]]; then
        systemctl stop php-fpm || true
        mv "${PREFIX}" "${ROOT}/failed-php"
        mv "${ROOT}/old-php" "${PREFIX}"
    elif [[ ! -d ${PREFIX} && -d ${ROOT}/old-php ]]; then
        mv "${ROOT}/old-php" "${PREFIX}"
    fi
    if [[ ${STOPPED} == 1 ]]; then systemctl start php-fpm || true; fi
    echo "安全更新失敗，已嘗試還原；詳見 ${ROOT}"
    exit "${code}"
}
trap rollback ERR
# 編譯與驗證完成後才短暫停止；原目錄保留為可直接還原的備份。
STOPPED=1
systemctl stop php-fpm
mv "${PREFIX}" "${ROOT}/old-php"
mv "${ROOT}/new-php" "${PREFIX}"
SWITCHED=1
"${PREFIX}/sbin/php-fpm" -t
"${PREFIX}/bin/php" -m | LC_ALL=C sort > "${ROOT}/modules.after"
diff -u "${ROOT}/modules.before" "${ROOT}/modules.after"
[[ $("${PREFIX}/bin/php" -n -r 'echo PHP_VERSION;') == "${PHP_VER}" ]]
systemctl start php-fpm
systemctl is-active --quiet php-fpm
trap - ERR
printf '%s\n' "PHP ${PHP_VER} 更新完成；原版本保存在 ${ROOT}/old-php" | tee "${ROOT}/SUCCESS"
