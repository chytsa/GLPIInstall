#!/usr/bin/env bash
###############################################################################
# GLPI 12 完整安裝腳本  (Ubuntu 24.04 LTS)
#
# 架構:Nginx (Ubuntu 內建) + PHP 8.3-FPM + MariaDB 10.11 (Ubuntu 內建) + GLPI 12
#
# 用法 (以 root 執行):
#   # 內網 / 測試 (自簽憑證):
#   sudo DOMAIN=glpi.corp.local bash install_glpi12.sh
#
#   # 對外網域 + Let's Encrypt (需 DNS 已指向本機且 80 port 可從外部連入):
#   sudo DOMAIN=glpi.example.com ADMIN_EMAIL=admin@example.com \
#        TLS_MODE=letsencrypt bash install_glpi12.sh
#
#   # 只用 HTTP (僅限測試):
#   sudo DOMAIN=192.168.1.100 TLS_MODE=none bash install_glpi12.sh
#
# 可用環境變數 (括號內為預設值):
#   DOMAIN            網域或 IP                      (預設: 本機第一個 IP)
#   TLS_MODE          letsencrypt | selfsigned | none (selfsigned)
#   ADMIN_EMAIL       Let's Encrypt 通知信箱          (TLS_MODE=letsencrypt 時必填)
#   GLPI_VERSION      GLPI 版本                       (12.0.1,請先確認 GitHub 上有此版本)
#   TZ_NAME           時區                            (Asia/Taipei)
#   GLPI_LANG         GLPI 預設語言                   (zh_TW)
#   DB_NAME / DB_USER 資料庫名稱 / 使用者             (glpi / glpi)
#   RELOCATE_DIRS     1=把 config/files/log 移出網站目錄 (官方建議) 0=留在原處 (1)
#   ENABLE_UFW        1=設定並啟用 UFW 防火牆         (1)
#   INSTALL_BACKUP    1=安裝每日備份排程              (1)
#   FORCE_OS          1=略過 Ubuntu 24.04 檢查        (0)
#
# 重複執行是安全的:已存在的帳密會沿用,已安裝的 GLPI 不會被覆蓋。
# 全部輸出會同時記錄在 /var/log/glpi-install.log
###############################################################################

set -Eeuo pipefail

# ----------------------------- 可調參數 --------------------------------------
DOMAIN="${DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
TLS_MODE="${TLS_MODE:-selfsigned}"
GLPI_VERSION="${GLPI_VERSION:-12.0.1}"
TZ_NAME="${TZ_NAME:-Asia/Taipei}"
GLPI_LANG="${GLPI_LANG:-zh_TW}"
DB_NAME="${DB_NAME:-glpi}"
DB_USER="${DB_USER:-glpi}"
PHP_VER="${PHP_VER:-8.3}"
RELOCATE_DIRS="${RELOCATE_DIRS:-1}"
ENABLE_UFW="${ENABLE_UFW:-1}"
INSTALL_BACKUP="${INSTALL_BACKUP:-1}"
FORCE_OS="${FORCE_OS:-0}"

# ----------------------------- 固定路徑 --------------------------------------
GLPI_HOME="/var/www/glpi"
GLPI_URL="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
CRED_FILE="/root/glpi-credentials.txt"
LOG_FILE="/var/log/glpi-install.log"
PHP_SOCK="/run/php/php${PHP_VER}-fpm-glpi.sock"
BACKUP_DIR="/var/backups/glpi"

if [[ "$RELOCATE_DIRS" == "1" ]]; then
    CONFIG_DIR="/etc/glpi"
    VAR_DIR="/var/lib/glpi"
    LOG_DIR="/var/log/glpi"
else
    CONFIG_DIR="${GLPI_HOME}/config"
    VAR_DIR="${GLPI_HOME}/files"
    LOG_DIR="${GLPI_HOME}/files/_log"
fi

# ----------------------------- 工具函式 --------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}==================== $* ====================${NC}"; }

trap 'echo -e "${RED}[ERROR]${NC} 腳本在第 ${LINENO} 行失敗: ${BASH_COMMAND}" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt_install() { apt-get install -y --no-install-recommends "$@"; }

as_www() { sudo -u www-data -H "$@"; }

is_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; }

gen_pw() { openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-24; }

[[ $EUID -eq 0 ]] || die "請以 root 執行 (sudo bash $0)"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

###############################################################################
step "1/10 前置檢查"
###############################################################################
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    [[ "$FORCE_OS" == "1" ]] || die "此腳本針對 Ubuntu 24.04 設計 (目前: ${PRETTY_NAME:-unknown})。要強制執行請加 FORCE_OS=1"
    warn "非 Ubuntu 24.04,PHP 版本與套件名稱可能不同"
fi

case "$TLS_MODE" in letsencrypt|selfsigned|none) ;; *) die "TLS_MODE 必須是 letsencrypt / selfsigned / none";; esac

apt-get update -y
apt_install curl ca-certificates openssl >/dev/null

[[ -n "$DOMAIN" ]] || DOMAIN="$(hostname -I | awk '{print $1}')"
[[ -n "$DOMAIN" ]] || die "無法判斷 DOMAIN,請以 DOMAIN=... 指定"
# DOMAIN 會被寫進 Nginx 設定、sed 與 SQL,所以限制為合法的主機名稱或 IPv4
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "DOMAIN 格式不合法: '$DOMAIN' (只允許英數字、點、連字號)"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "DB_NAME 只允許英數字、底線、連字號"
[[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]  || die "DB_USER 只允許英數字、底線"
if [[ "$TLS_MODE" == "letsencrypt" ]]; then
    [[ -n "$ADMIN_EMAIL" ]] || die "TLS_MODE=letsencrypt 需要設定 ADMIN_EMAIL"
    is_ip "$DOMAIN" && die "Let's Encrypt 不能用 IP 位址,請改用網域名稱,或改 TLS_MODE=selfsigned"
fi

if [[ "$TLS_MODE" == "none" ]]; then SCHEME="http"; else SCHEME="https"; fi

log "網域/IP        : $DOMAIN"
log "TLS 模式       : $TLS_MODE"
log "GLPI 版本      : $GLPI_VERSION"
log "目錄配置       : config=$CONFIG_DIR  var=$VAR_DIR  log=$LOG_DIR"

if [[ ! -f "${CONFIG_DIR}/config_db.php" ]]; then
    curl -fsIL "$GLPI_URL" -o /dev/null \
        || die "找不到 GLPI 下載檔: $GLPI_URL
       請到 https://github.com/glpi-project/glpi/releases 確認版本號,再以 GLPI_VERSION=x.y.z 重新執行"
fi

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CPU_N=$(nproc)
log "硬體偵測       : ${CPU_N} vCPU / ${MEM_MB} MB RAM"
(( MEM_MB >= 3500 )) || warn "記憶體低於 4 GB,GLPI 在多設備下可能吃緊"

###############################################################################
step "2/10 系統初始化"
###############################################################################
apt-get upgrade -y
apt_install unzip tar gzip cron sudo ufw tzdata logrotate jq >/dev/null

timedatectl set-timezone "$TZ_NAME"
timedatectl set-ntp true || warn "無法啟用 NTP 同步,請手動確認時間同步"

# 記憶體小於 4GB 且沒有 swap 時建立 2GB swap
if [[ -z "$(swapon --show --noheadings)" ]] && (( MEM_MB < 4096 )); then
    log "建立 2GB swap"
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if [[ "$ENABLE_UFW" == "1" ]]; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    SSH_PORT="${SSH_PORT:-22}"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    [[ "$TLS_MODE" == "none" ]] || ufw allow 443/tcp comment 'HTTPS'
    ufw --force enable
    log "UFW 已啟用 (SSH 埠 ${SSH_PORT}、80$([[ "$TLS_MODE" == "none" ]] || echo '、443'))"
else
    warn "已略過 UFW 設定"
fi

###############################################################################
step "3/10 安裝並設定 MariaDB"
###############################################################################
apt_install mariadb-server mariadb-client >/dev/null

# --- 讀取或產生密碼 (重複執行時沿用) ---
DB_PASSWORD=""; GLPI_ADMIN_PASSWORD=""
if [[ -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source <(grep -E "^(DB_PASSWORD|GLPI_ADMIN_PASSWORD)=" "$CRED_FILE" || true)
fi
[[ -n "$DB_PASSWORD" ]]         || DB_PASSWORD="$(gen_pw)"
[[ -n "$GLPI_ADMIN_PASSWORD" ]] || GLPI_ADMIN_PASSWORD="$(gen_pw)"

umask 077
cat > "$CRED_FILE" <<EOF
# GLPI 安裝產生的帳密 (請妥善保管,建議存入密碼管理器後刪除此檔)
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASSWORD='${DB_PASSWORD}'
GLPI_ADMIN_USER='glpi'
GLPI_ADMIN_PASSWORD='${GLPI_ADMIN_PASSWORD}'
EOF
chmod 600 "$CRED_FILE"
umask 022

# --- 依記憶體調整 InnoDB (與 PHP-FPM 共用主機,取約 35%) ---
BP_MB=$(( MEM_MB * 35 / 100 ))
(( BP_MB >= 256 )) || BP_MB=256
if (( MEM_MB >= 4096 )); then LOG_FILE_SIZE="512M"; else LOG_FILE_SIZE="256M"; fi

cat > /etc/mysql/mariadb.conf.d/99-glpi.cnf <<EOF
# 由 install_glpi12.sh 產生
[mysqld]
bind-address                = 127.0.0.1
character-set-server        = utf8mb4
collation-server            = utf8mb4_unicode_ci
innodb_file_per_table       = 1
innodb_buffer_pool_size     = ${BP_MB}M
innodb_log_file_size        = ${LOG_FILE_SIZE}
max_connections             = 200
max_allowed_packet          = 64M
slow_query_log              = 1
slow_query_log_file         = /var/log/mysql/slow-query.log
long_query_time             = 2

[client]
default-character-set       = utf8mb4
EOF

systemctl enable --now mariadb
systemctl restart mariadb

# --- 載入時區表 (GLPI 建議) ---
TZ_TOOL="$(command -v mariadb-tzinfo-to-sql || command -v mysql_tzinfo_to_sql || true)"
if [[ -n "$TZ_TOOL" ]]; then
    "$TZ_TOOL" /usr/share/zoneinfo 2>/dev/null | mariadb mysql || warn "時區表載入有警告 (通常可忽略)"
else
    warn "找不到 mariadb-tzinfo-to-sql,略過時區表"
fi

# --- 建立資料庫與使用者 (root 走 unix_socket,不需要密碼) ---
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT SELECT ON mysql.time_zone_name TO '${DB_USER}'@'localhost';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

# 驗證應用程式帳號可以登入
mariadb -u"$DB_USER" -p"$DB_PASSWORD" -h localhost "$DB_NAME" -e "SELECT 1;" >/dev/null \
    || die "資料庫帳號 ${DB_USER} 登入失敗"
log "✓ MariaDB 就緒 (buffer pool ${BP_MB}M)"

###############################################################################
step "4/10 安裝並設定 PHP ${PHP_VER}-FPM"
###############################################################################
apt_install \
    "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-common" \
    "php${PHP_VER}-mysql" "php${PHP_VER}-curl" "php${PHP_VER}-gd" \
    "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-intl" \
    "php${PHP_VER}-zip" "php${PHP_VER}-bz2" "php${PHP_VER}-ldap" \
    "php${PHP_VER}-bcmath" "php${PHP_VER}-opcache" "php-apcu" >/dev/null
apt_install "php${PHP_VER}-imap" >/dev/null 2>&1 \
    || warn "php${PHP_VER}-imap 無法安裝 (僅「郵件收集器」功能需要,可忽略)"

if [[ "$TLS_MODE" == "none" ]]; then COOKIE_SECURE=0; else COOKIE_SECURE=1; fi

PHP_INI_CONTENT="; 由 install_glpi12.sh 產生
memory_limit = 256M
upload_max_filesize = 100M
post_max_size = 100M
max_execution_time = 300
max_input_time = 300
date.timezone = ${TZ_NAME}
expose_php = Off
session.cookie_httponly = 1
session.cookie_secure = ${COOKIE_SECURE}
session.cookie_samesite = Lax
session.use_strict_mode = 1
opcache.enable = 1
opcache.memory_consumption = 128
opcache.max_accelerated_files = 10000
opcache.interned_strings_buffer = 16
"
# FPM (網頁) 與 CLI (bin/console、cron) 都要設定
printf '%s' "$PHP_INI_CONTENT" > "/etc/php/${PHP_VER}/fpm/conf.d/99-glpi.ini"
printf '%s' "$PHP_INI_CONTENT" > "/etc/php/${PHP_VER}/cli/conf.d/99-glpi.ini"

# --- 依記憶體計算 PHP-FPM 子程序數 (每個預留約 128MB) ---
AVAIL_MB=$(( MEM_MB - BP_MB - 1024 ))
MAX_CH=$(( AVAIL_MB / 128 ))
(( MAX_CH >= 8 ))  || MAX_CH=8
(( MAX_CH <= 60 )) || MAX_CH=60
START_SV=$(( MAX_CH / 4 )); (( START_SV >= 4 )) || START_SV=4
MIN_SP=$(( START_SV / 2 )); (( MIN_SP >= 2 )) || MIN_SP=2
MAX_SP=$(( MAX_CH / 2 ))

mkdir -p /var/log/php-fpm
# 停用預設 pool,改用專屬的 glpi pool
[[ -f "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" ]] \
    && mv "/etc/php/${PHP_VER}/fpm/pool.d/www.conf" "/etc/php/${PHP_VER}/fpm/pool.d/www.conf.disabled"

cat > "/etc/php/${PHP_VER}/fpm/pool.d/glpi.conf" <<EOF
; 由 install_glpi12.sh 產生
[glpi]
user = www-data
group = www-data
listen = ${PHP_SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = ${MAX_CH}
pm.start_servers = ${START_SV}
pm.min_spare_servers = ${MIN_SP}
pm.max_spare_servers = ${MAX_SP}
pm.max_requests = 500

request_terminate_timeout = 300
request_slowlog_timeout = 10s
slowlog = /var/log/php-fpm/glpi-slow.log
catch_workers_output = yes
EOF

cat > /etc/logrotate.d/php-fpm-glpi <<'EOF'
/var/log/php-fpm/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

php-fpm${PHP_VER} -t
systemctl enable --now "php${PHP_VER}-fpm"
systemctl restart "php${PHP_VER}-fpm"
[[ -S "$PHP_SOCK" ]] || die "PHP-FPM socket 未建立: $PHP_SOCK"
log "✓ PHP-FPM 就緒 (max_children=${MAX_CH})"

###############################################################################
step "5/10 安裝並設定 Nginx"
###############################################################################
apt_install nginx >/dev/null
systemctl enable --now nginx
# Ubuntu 內建 Nginx 以 www-data 執行,才能讀取 PHP-FPM socket (www-data:www-data)
grep -Eq '^\s*user\s+www-data' /etc/nginx/nginx.conf \
    || warn "Nginx 執行身分不是 www-data (是否裝過 nginx.org 版本?),PHP-FPM socket 可能無法存取"

mkdir -p /var/www/letsencrypt /etc/nginx/snippets

# --- 共用的 GLPI 應用設定片段 ---
cat > /etc/nginx/snippets/glpi-app.conf <<'EOF'
# 由 install_glpi12.sh 產生
root /var/www/glpi/public;
index index.php;

client_max_body_size 100M;
server_tokens off;

# 所有請求交給 GLPI 路由器
location / {
    try_files $uri /index.php$is_args$args;
}

# 只允許 index.php 作為 PHP 入口
location ~ ^/index\.php$ {
    fastcgi_pass unix:@PHP_SOCK@;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_param HTTP_PROXY "";
    fastcgi_read_timeout 300;
}

# 擋隱藏檔案 (保留 Let's Encrypt 驗證路徑)
location ~ /\.(?!well-known) {
    deny all;
    access_log off;
    log_not_found off;
}
EOF
sed -i "s#@PHP_SOCK@#${PHP_SOCK}#g" /etc/nginx/snippets/glpi-app.conf

# --- 產生站台設定: $1 = http | https ---
write_nginx_site() {
    local mode="$1" cert key
    case "$TLS_MODE" in
        letsencrypt) cert="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
                     key="/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ;;
        selfsigned)  cert="/etc/ssl/glpi/glpi.crt"
                     key="/etc/ssl/glpi/glpi.key" ;;
    esac

    if [[ "$mode" == "http" ]]; then
        # 純 HTTP: 申請憑證前的暫時設定,或 TLS_MODE=none 的正式設定
        cat > /etc/nginx/sites-available/glpi <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name @DOMAIN@;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }

    include snippets/glpi-app.conf;

    access_log /var/log/nginx/glpi_access.log;
    error_log  /var/log/nginx/glpi_error.log warn;
}
EOF
    else
        cat > /etc/nginx/sites-available/glpi <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name @DOMAIN@;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # Ubuntu 24.04 的 Nginx 為 1.24,使用 "listen ... http2" 寫法
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name @DOMAIN@;

    ssl_certificate     @CERT@;
    ssl_certificate_key @KEY@;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    include snippets/glpi-app.conf;

    access_log /var/log/nginx/glpi_access.log;
    error_log  /var/log/nginx/glpi_error.log warn;
}
EOF
    fi
    sed -i "s#@DOMAIN@#${DOMAIN}#g; s#@CERT@#${cert:-}#g; s#@KEY@#${key:-}#g" /etc/nginx/sites-available/glpi
    ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

write_nginx_site http
log "✓ Nginx (HTTP) 就緒"

###############################################################################
step "6/10 TLS 憑證 (${TLS_MODE})"
###############################################################################
case "$TLS_MODE" in
    letsencrypt)
        apt_install certbot >/dev/null
        certbot certonly --webroot -w /var/www/letsencrypt \
            -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" \
            --deploy-hook "systemctl reload nginx" \
            || die "Let's Encrypt 申請失敗。請確認 DNS 已指向本機、80 port 可從外部連入;
       內網環境請改用 TLS_MODE=selfsigned 重新執行"
        systemctl enable --now certbot.timer || true
        write_nginx_site https
        log "✓ Let's Encrypt 憑證已安裝,自動續期由 certbot.timer 負責 (webroot 模式,不需停 Nginx)"
        ;;
    selfsigned)
        mkdir -p /etc/ssl/glpi
        if [[ ! -f /etc/ssl/glpi/glpi.crt ]]; then
            if is_ip "$DOMAIN"; then SAN="IP:${DOMAIN}"; else SAN="DNS:${DOMAIN}"; fi
            openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 825 \
                -keyout /etc/ssl/glpi/glpi.key -out /etc/ssl/glpi/glpi.crt \
                -subj "/CN=${DOMAIN}" -addext "subjectAltName=${SAN}" 2>/dev/null
            chmod 600 /etc/ssl/glpi/glpi.key
        fi
        write_nginx_site https
        warn "使用自簽憑證:瀏覽器會顯示警告;GLPI Agent 需設定 ca-cert-file 或改用企業 CA 簽發的憑證"
        ;;
    none)
        warn "TLS_MODE=none:全程使用 HTTP,帳號密碼為明文傳輸,僅適合測試"
        ;;
esac

###############################################################################
step "7/10 下載並部署 GLPI ${GLPI_VERSION}"
###############################################################################
if [[ -f "${CONFIG_DIR}/config_db.php" ]]; then
    warn "偵測到已完成安裝 (${CONFIG_DIR}/config_db.php),略過下載與部署"
else
    TMPD="$(mktemp -d)"
    log "下載 $GLPI_URL"
    curl -fL --retry 3 -o "${TMPD}/glpi.tgz" "$GLPI_URL"
    tar -tzf "${TMPD}/glpi.tgz" >/dev/null || die "下載的壓縮檔損壞"
    tar -xzf "${TMPD}/glpi.tgz" -C "$TMPD"
    [[ -d "${TMPD}/glpi/public" ]] || die "壓縮檔內容不符預期 (找不到 glpi/public)"

    if [[ -e "$GLPI_HOME" ]]; then
        BK="${GLPI_HOME}.bak.$(date +%Y%m%d%H%M%S)"
        warn "$GLPI_HOME 已存在但未完成安裝,移到 $BK"
        mv "$GLPI_HOME" "$BK"
    fi
    mkdir -p /var/www
    mv "${TMPD}/glpi" "$GLPI_HOME"
    rm -rf "$TMPD"

    if [[ "$RELOCATE_DIRS" == "1" ]]; then
        log "將 config / files / log 移到網站目錄之外"
        mkdir -p "$CONFIG_DIR" "$VAR_DIR" "$LOG_DIR"
        [[ -d "${GLPI_HOME}/config" ]] && cp -a "${GLPI_HOME}/config/." "$CONFIG_DIR/" && rm -rf "${GLPI_HOME}/config"
        [[ -d "${GLPI_HOME}/files"  ]] && cp -a "${GLPI_HOME}/files/."  "$VAR_DIR/"    && rm -rf "${GLPI_HOME}/files"

        mkdir -p "${GLPI_HOME}/inc"
        cat > "${GLPI_HOME}/inc/downstream.php" <<EOF
<?php
define('GLPI_CONFIG_DIR', '${CONFIG_DIR}/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOF
        cat > "${CONFIG_DIR}/local_define.php" <<EOF
<?php
define('GLPI_VAR_DIR', '${VAR_DIR}');
define('GLPI_LOG_DIR', '${LOG_DIR}');
EOF
    else
        mkdir -p "$CONFIG_DIR" "$VAR_DIR" "$LOG_DIR"
    fi
fi

# --- 權限:程式碼歸 root (唯讀),只有 config / var / log / marketplace 讓 www-data 可寫 ---
log "設定檔案權限"
chown -R root:root "$GLPI_HOME"
find "$GLPI_HOME" -type d -exec chmod 755 {} +
find "$GLPI_HOME" -type f -exec chmod 644 {} +
mkdir -p "${GLPI_HOME}/marketplace"
for d in "$CONFIG_DIR" "$VAR_DIR" "$LOG_DIR" "${GLPI_HOME}/marketplace"; do
    mkdir -p "$d"
    chown -R www-data:www-data "$d"
    find "$d" -type d -exec chmod 770 {} +
    find "$d" -type f -exec chmod 660 {} +
done

cat > /etc/logrotate.d/glpi <<EOF
${LOG_DIR}/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    su www-data www-data
}
EOF

###############################################################################
step "8/10 GLPI 需求檢查與資料庫初始化"
###############################################################################
cd "$GLPI_HOME"

log "檢查 GLPI 需求"
as_www php bin/console system:check_requirements \
    || die "GLPI 需求檢查未通過,請依上方訊息補齊 (例如缺少的 PHP 擴充),再重新執行腳本"

FRESH_INSTALL=0
if [[ -f "${CONFIG_DIR}/config_db.php" ]]; then
    warn "config_db.php 已存在,略過 db:install"
else
    FRESH_INSTALL=1
    log "執行 db:install (資料表建立約需 1-2 分鐘)"
    as_www php bin/console db:install \
        --db-host=localhost \
        --db-name="$DB_NAME" \
        --db-user="$DB_USER" \
        --db-password="$DB_PASSWORD" \
        --default-language="$GLPI_LANG" \
        --no-interaction --force
    [[ -f "${CONFIG_DIR}/config_db.php" ]] \
        || die "db:install 完成後找不到 ${CONFIG_DIR}/config_db.php。
       若是目錄搬移 (RELOCATE_DIRS=1) 與此 GLPI 版本不相容,請清理後以 RELOCATE_DIRS=0 重跑"
fi

as_www php bin/console database:enable_timezones || warn "啟用時區支援失敗,可稍後手動執行: php bin/console database:enable_timezones"

###############################################################################
step "9/10 安裝後設定 (帳號、庫存、排程、備份)"
###############################################################################
# 以下會直接改寫資料庫內容,只在「本次全新安裝」時執行,
# 避免重跑腳本時覆蓋管理員已在介面中改過的密碼與設定。
if [[ "$FRESH_INSTALL" == "1" ]]; then
    # --- 預設帳號處理: 為 glpi 設定強密碼,其餘預設帳號停用並隨機化密碼 ---
    ADMIN_HASH="$(PW="$GLPI_ADMIN_PASSWORD" php -r 'echo password_hash(getenv("PW"), PASSWORD_DEFAULT);')"
    if mariadb "$DB_NAME" <<SQL
UPDATE glpi_users SET password='${ADMIN_HASH}' WHERE name='glpi';
UPDATE glpi_users SET is_active=0 WHERE name IN ('tech','normal','post-only');
SQL
    then
        for u in tech normal post-only; do
            H="$(PW="$(gen_pw)" php -r 'echo password_hash(getenv("PW"), PASSWORD_DEFAULT);')"
            mariadb "$DB_NAME" -e "UPDATE glpi_users SET password='${H}' WHERE name='${u}';" || true
        done
        log "✓ 預設帳號已處理 (glpi 密碼見 ${CRED_FILE};tech / normal / post-only 已停用)"
    else
        warn "預設帳號處理失敗,請登入後立即手動修改 glpi / tech / normal / post-only 的密碼 (預設與帳號同名)"
    fi

    # --- 啟用庫存功能 (否則 GLPI Agent 傳來的資料會被拒收) 與 URL ---
    mariadb "$DB_NAME" <<SQL || warn "寫入設定失敗,請在介面中確認「管理 > 庫存 > 啟用庫存」"
INSERT INTO glpi_configs (context, name, value) VALUES ('inventory','enable_inventory','1')
ON DUPLICATE KEY UPDATE value='1';
INSERT INTO glpi_configs (context, name, value) VALUES ('core','url_base','${SCHEME}://${DOMAIN}')
ON DUPLICATE KEY UPDATE value='${SCHEME}://${DOMAIN}';
SQL
    log "✓ 已啟用庫存功能並設定 URL: ${SCHEME}://${DOMAIN}"

else
    warn "非全新安裝,略過預設帳號處理與資料庫設定寫入 (保留既有設定)"
fi

# --- 排程 (GLPI 自動動作) ---
if [[ -f "${GLPI_HOME}/front/cron.php" ]]; then
    CRON_CMD="/usr/bin/php ${GLPI_HOME}/front/cron.php"
else
    CRON_CMD="/usr/bin/php ${GLPI_HOME}/bin/console glpi:cron"
fi
echo "* * * * * www-data ${CRON_CMD} >/dev/null 2>&1" > /etc/cron.d/glpi
chmod 644 /etc/cron.d/glpi
# 將自動動作切換為 CLI 模式 (mode 2),由系統 cron 執行
if [[ "$FRESH_INSTALL" == "1" ]]; then
    mariadb "$DB_NAME" -e "UPDATE glpi_crontasks SET mode=2 WHERE mode=1;" \
        || warn "切換自動動作為 CLI 模式失敗,請在「設定 > 自動動作」手動調整"
fi
log "✓ 已建立 /etc/cron.d/glpi"

# --- 每日備份 ---
if [[ "$INSTALL_BACKUP" == "1" ]]; then
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    cat > /usr/local/sbin/glpi-backup.sh <<'EOF'
#!/usr/bin/env bash
# 每日備份 GLPI 資料庫與設定/檔案,保留 14 天。
# 注意: 備份放在同一台主機不算真正的備份,請另外同步到其他主機或儲存空間。
set -euo pipefail
BACKUP_DIR="@BACKUP_DIR@"
DATE="$(date +%Y%m%d_%H%M%S)"
DUMP="$(command -v mariadb-dump || command -v mysqldump)"

"$DUMP" --single-transaction --quick --routines --events "@DB_NAME@" | gzip > "${BACKUP_DIR}/glpi-db-${DATE}.sql.gz"
tar -czf "${BACKUP_DIR}/glpi-files-${DATE}.tar.gz" \
    --exclude='*/_cache' --exclude='*/_sessions' --exclude='*/_tmp' \
    "@CONFIG_DIR@" "@VAR_DIR@" /etc/nginx/sites-available/glpi /etc/nginx/snippets/glpi-app.conf
find "$BACKUP_DIR" -type f -mtime +14 -delete
EOF
    sed -i "s#@BACKUP_DIR@#${BACKUP_DIR}#g; s#@DB_NAME@#${DB_NAME}#g; s#@CONFIG_DIR@#${CONFIG_DIR}#g; s#@VAR_DIR@#${VAR_DIR}#g" /usr/local/sbin/glpi-backup.sh
    chmod 700 /usr/local/sbin/glpi-backup.sh
    echo "30 2 * * * root /usr/local/sbin/glpi-backup.sh >/dev/null 2>&1" > /etc/cron.d/glpi-backup
    chmod 644 /etc/cron.d/glpi-backup
    log "✓ 每日 02:30 備份已設定 (${BACKUP_DIR},保留 14 天)"
fi

###############################################################################
step "10/10 最終驗證"
###############################################################################
for svc in nginx "php${PHP_VER}-fpm" mariadb; do
    systemctl is-active --quiet "$svc" && log "✓ $svc 運行中" || warn "✗ $svc 未運行"
done

HTTP_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" "${SCHEME}://127.0.0.1/" || echo 000)"
if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    log "✓ GLPI 網頁回應 HTTP ${HTTP_CODE}"
else
    warn "GLPI 網頁回應 HTTP ${HTTP_CODE},請檢查: tail -50 /var/log/nginx/glpi_error.log  /  ${LOG_DIR}/php-errors.log"
fi

cat <<EOF

${GREEN}============================================================${NC}
 ✅ GLPI ${GLPI_VERSION} 安裝完成
${GREEN}============================================================${NC}
 網址      : ${SCHEME}://${DOMAIN}/
 管理員    : glpi
 密碼      : 見 ${CRED_FILE} (權限 600)
 安裝記錄  : ${LOG_FILE}

 目錄      : 程式碼  ${GLPI_HOME}   (root 擁有,唯讀)
             設定    ${CONFIG_DIR}
             資料    ${VAR_DIR}
             日誌    ${LOG_DIR}
 備份      : ${BACKUP_DIR}  (每日 02:30,請另外複製到其他主機)

 建議的後續步驟:
  1. 登入後先到「管理 > 使用者」確認 glpi 帳號,並把 ${CRED_FILE} 的內容存入密碼管理器後刪除該檔
  2. 「設定 > 通知 > 郵件追蹤設定」填入 SMTP (多數情況不需要在本機裝 Postfix)
  3. 「管理 > 庫存」確認已啟用庫存;Agent 的伺服器位址填 ${SCHEME}://${DOMAIN}
  4. 「設定 > 自動動作」確認各項任務有在執行 (排程已由系統 cron 觸發)
  5. 安裝 GLPI Agent 前先確認 Agent 的最新版本與安裝參數 (見官方文件)
$([[ "$TLS_MODE" == "selfsigned" ]] && echo "  6. 目前使用自簽憑證:請替 Agent 設定 CA 憑證,或改用企業 CA / Let's Encrypt")
$([[ "$TLS_MODE" == "none" ]] && echo "  6. 目前為純 HTTP:正式環境請改用 TLS_MODE=selfsigned 或 letsencrypt")
EOF
