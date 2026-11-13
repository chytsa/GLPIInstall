#!/usr/bin/env bash
###############################################################################
# GLPI Agent 本機部署腳本 —— 把 Agent 裝在「GLPI 伺服器自己」身上 (Ubuntu/Debian)
#
# 作法依據 GLPI Agent 官方文件:使用官方 Perl 安裝器 (glpi-agent-<版本>-linux-installer.pl)。
# 自簽憑證依官方建議以 ca-cert-file 信任,不使用 no-ssl-check。
#
# 用法 (以 root 執行):
#   sudo bash install_glpi_agent_local.sh
#   sudo SERVER_URL=https://140.113.7.106/ AGENT_TAG=GLPI-Server bash install_glpi_agent_local.sh
#
# 可用環境變數 (括號內為預設值):
#   AGENT_VERSION    Agent 版本                       (1.21,請先到 GitHub releases 確認最新版)
#   SERVER_URL       GLPI 網址                        (自動從 Nginx 設定偵測)
#   AGENT_TAG        寫入清單的標籤                   (GLPI-Server)
#   CA_CERT_SRC      GLPI 伺服器憑證檔                (自動讀取 Nginx 的 ssl_certificate)
#   SKIP_CA          1=不設定 ca-cert-file            (0)
#   FORCE_REINSTALL  1=已安裝也重新執行安裝器          (0)
#   OAUTH_CLIENT_ID      GLPI 要求 OAuth 認證時,Agent 使用的 OAuth Client ID
#   OAUTH_CLIENT_SECRET  對應的 Client Secret (不給的話,在終端機執行時會提示輸入;不可含 # 引號 空白)
#
# 重複執行是安全的:已安裝且版本相同時,只會重新套用設定並重新驗證。
# 全部輸出會同時記錄在 /var/log/glpi-agent-install.log
###############################################################################

set -Eeuo pipefail

SCRIPT_VERSION="1 (2026-11-11)"
AGENT_VERSION="${AGENT_VERSION:-1.21}"
SERVER_URL="${SERVER_URL:-}"
AGENT_TAG="${AGENT_TAG:-GLPI-Server}"
CA_CERT_SRC="${CA_CERT_SRC:-}"
SKIP_CA="${SKIP_CA:-0}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-}"
OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"

INSTALLER_URL="https://github.com/glpi-project/glpi-agent/releases/download/${AGENT_VERSION}/glpi-agent-${AGENT_VERSION}-linux-installer.pl"
AGENT_CONF_DIR="/etc/glpi-agent/conf.d"
AGENT_CA_DST="/etc/glpi-agent/glpi-server-ca.crt"
LOG_FILE="/var/log/glpi-agent-install.log"
CRED_FILE="/root/glpi-credentials.txt"
BACKUP_CNF="/root/.glpi-backup.cnf"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}==================== $* ====================${NC}"; }
trap 'echo -e "${RED}[ERROR]${NC} 腳本在第 ${LINENO} 行失敗: ${BASH_COMMAND}" >&2' ERR

export DEBIAN_FRONTEND=noninteractive
[[ $EUID -eq 0 ]] || die "請以 root 執行 (sudo bash $0)"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# 查詢 GLPI 資料庫 (使用備份用的 glpi 應用程式帳號;失敗時不中止,只回傳空字串)
DB_NAME="glpi"
if [[ -f "$CRED_FILE" ]]; then
    _n="$(sed -n "s/^DB_NAME='\(.*\)'$/\1/p" "$CRED_FILE" | tail -n1)"
    [[ -z "$_n" ]] || DB_NAME="$_n"
fi
glpi_sql() {
    [[ -f "$BACKUP_CNF" ]] || return 0
    mariadb --defaults-file="$BACKUP_CNF" -N -B "$DB_NAME" -e "$1" 2>/dev/null || true
}

###############################################################################
step "1/7 前置檢查"
###############################################################################
log "install_glpi_agent_local.sh 版本 ${SCRIPT_VERSION},共 7 個步驟,依序完整執行"
command -v systemctl >/dev/null || die "此腳本需要 systemd"
if ! command -v perl >/dev/null; then
    log "安裝 perl (Agent 安裝器的必要條件)"
    apt-get update -y >/dev/null && apt-get install -y --no-install-recommends perl >/dev/null
fi
command -v curl >/dev/null || { apt-get update -y >/dev/null; apt-get install -y --no-install-recommends curl ca-certificates >/dev/null; }

# ---- 判斷 GLPI 網址 ----
if [[ -z "$SERVER_URL" ]]; then
    _name=""; _scheme="http"
    for f in /etc/nginx/conf.d/glpi.conf /etc/nginx/sites-available/glpi; do
        [[ -f "$f" ]] || continue
        _name="$(awk '/^[[:space:]]*server_name[[:space:]]/{gsub(/;/,"",$2); print $2}' "$f" | tail -n1)"
        grep -Eq 'listen[[:space:]]+(\[::\]:)?443' "$f" && _scheme="https"
        [[ -n "$_name" && "$_name" != "_" ]] && break
        _name=""
    done
    [[ -n "$_name" ]] || _name="$(hostname -I | awk '{print $1}')"
    [[ -n "$_name" ]] || die "無法判斷 GLPI 位址,請以 SERVER_URL=https://... 指定"
    SERVER_URL="${_scheme}://${_name}/"
    log "自動偵測 GLPI 網址: ${SERVER_URL}  (若不正確,請以 SERVER_URL= 覆寫)"
else
    log "使用指定的 GLPI 網址: ${SERVER_URL}"
fi
[[ "$SERVER_URL" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]] || die "SERVER_URL 格式不合法: $SERVER_URL"
SERVER_HOST="${SERVER_URL#*://}"; SERVER_HOST="${SERVER_HOST%%/*}"; SERVER_HOST="${SERVER_HOST%%:*}"

# ---- Agent OAuth 認證 (GLPI 設定了 auth_required=oauth 時需要;GLPI 11+ 才支援) ----
if [[ -n "$OAUTH_CLIENT_ID" ]]; then
    if [[ -z "$OAUTH_CLIENT_SECRET" ]]; then
        if [[ -t 0 ]]; then
            read -rsp "請輸入 OAuth Client Secret (Client ID: ${OAUTH_CLIENT_ID}): " OAUTH_CLIENT_SECRET; echo
        else
            die "已指定 OAUTH_CLIENT_ID,但沒有 OAUTH_CLIENT_SECRET,且目前不是互動式終端機"
        fi
    fi
    # Agent 設定檔對 # 有特殊處理 (會被當成註解而截斷),引號與空白也容易出問題
    [[ "$OAUTH_CLIENT_ID"     =~ ^[A-Za-z0-9._@-]+$ ]]   || die "OAUTH_CLIENT_ID 只允許英數字與 . _ @ -"
    [[ "$OAUTH_CLIENT_SECRET" =~ ^[^#\"\'[:space:]]+$ ]] || die "OAUTH_CLIENT_SECRET 不可含 # 引號 或空白 (Agent 設定檔無法正確處理),請在 GLPI 重新產生 Client Secret"
fi

log "Agent 版本: ${AGENT_VERSION}"
curl -fsIL "$INSTALLER_URL" -o /dev/null \
    || die "找不到安裝器: $INSTALLER_URL
       請到 https://github.com/glpi-project/glpi-agent/releases 確認版本號,再以 AGENT_VERSION=x.y 重新執行"

###############################################################################
step "2/7 驗證 GLPI 連線與憑證 (安裝前先確認,與 Agent 實際會遇到的情況相同)"
###############################################################################
USE_CA=0
CURL_CA=()
# 預設以 Nginx 實際使用的憑證為準,避免檢查到和伺服器送出的不一致的檔案 (可用 CA_CERT_SRC= 覆寫)
if [[ -z "$CA_CERT_SRC" ]]; then
    CA_CERT_SRC="/etc/ssl/glpi/glpi.crt"
    for f in /etc/nginx/conf.d/glpi.conf /etc/nginx/sites-available/glpi; do
        [[ -f "$f" ]] || continue
        _c="$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/{gsub(/;/,"",$2); print $2; exit}' "$f")"
        if [[ -n "$_c" && -f "$_c" ]]; then CA_CERT_SRC="$_c"; break; fi
    done
fi
log "GLPI 伺服器憑證: ${CA_CERT_SRC}"
if [[ "$SERVER_URL" == https://* && "$SKIP_CA" != "1" && -f "$CA_CERT_SRC" ]]; then
    # 只有「自簽憑證」才需要把它設為信任根;公開 CA 簽發的憑證不需要
    if [[ "$(openssl x509 -in "$CA_CERT_SRC" -noout -subject_hash 2>/dev/null)" == \
          "$(openssl x509 -in "$CA_CERT_SRC" -noout -issuer_hash 2>/dev/null)" ]]; then
        USE_CA=1
        CURL_CA=(--cacert "$CA_CERT_SRC")
        log "偵測到自簽憑證 ${CA_CERT_SRC},將設定為 Agent 的信任憑證 (ca-cert-file)"
        if ! openssl x509 -in "$CA_CERT_SRC" -noout -ext subjectAltName 2>/dev/null \
             | grep -qE "(IP Address|DNS):${SERVER_HOST//./\\.}([,[:space:]]|$)"; then
            warn "憑證的 SAN 不含 '${SERVER_HOST}',Agent 會因主機名稱不符而拒絕連線。"
            warn "目前憑證涵蓋的位址: $(openssl x509 -in "$CA_CERT_SRC" -noout -ext subjectAltName 2>/dev/null | tail -n1 | sed 's/^ *//')"
            warn "請以下列指令重新產生憑證並重載 Nginx,再重新執行本腳本:"
            if [[ "$SERVER_HOST" =~ ^[0-9.]+$ ]]; then _san="IP:${SERVER_HOST}"; else _san="DNS:${SERVER_HOST}"; fi
            echo "    sudo mv ${CA_CERT_SRC} ${CA_CERT_SRC}.old"
            echo "    sudo openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 825 \\"
            echo "      -keyout <原金鑰路徑> -out ${CA_CERT_SRC} \\"
            echo "      -subj \"/CN=${SERVER_HOST}\" -addext \"subjectAltName=${_san}\""
            echo "    sudo nginx -t && sudo systemctl reload nginx"
            warn "(金鑰路徑請見 Nginx 設定的 ssl_certificate_key;使用 install_glpi12.sh 建立的環境為 /etc/ssl/glpi/glpi.key)"
        fi
    else
        log "憑證不是自簽,視為公開 CA 簽發,不需設定 ca-cert-file"
    fi
fi

CURL_ERR="$(mktemp)"
HTTP_CODE="$(curl -sS "${CURL_CA[@]}" -o /dev/null -w '%{http_code}' --max-time 20 "$SERVER_URL" 2>"$CURL_ERR" || true)"
if [[ "$HTTP_CODE" == "000" || -z "$HTTP_CODE" ]]; then
    echo "--- curl 錯誤訊息 ---"; cat "$CURL_ERR"; rm -f "$CURL_ERR"
    die "無法以 TLS 驗證連上 ${SERVER_URL}。常見原因:
       - 憑證與網址的主機名稱不符 (SAN)
       - 憑證不受信任 (自簽憑證需要 ca-cert-file)
       - Nginx 沒有在監聽 / 防火牆擋住"
fi
rm -f "$CURL_ERR"
log "✓ ${SERVER_URL} 連線與憑證驗證通過 (HTTP ${HTTP_CODE})"

###############################################################################
step "3/7 檢查 GLPI 端是否已啟用庫存"
###############################################################################
INV="$(glpi_sql "SELECT value FROM glpi_configs WHERE context='inventory' AND name='enable_inventory';")"
case "$INV" in
    1) log "✓ GLPI 已啟用庫存功能" ;;
    0) warn "GLPI 的庫存功能是「停用」狀態,Agent 的資料會被拒收。請登入 GLPI,到「管理 > 庫存」勾選「啟用庫存」" ;;
    *) warn "無法從資料庫確認庫存設定,請登入 GLPI 檢查「管理 > 庫存」是否已啟用庫存" ;;
esac

AUTH_REQ="$(glpi_sql "SELECT value FROM glpi_configs WHERE context='inventory' AND name='auth_required';")"
case "$AUTH_REQ" in
    oauth)
        if [[ -n "$OAUTH_CLIENT_ID" ]]; then
            log "GLPI 要求 Agent 使用 OAuth (Client credentials) 認證,將使用 OAUTH_CLIENT_ID=${OAUTH_CLIENT_ID}"
        else
            warn "GLPI 要求 Agent 使用「OAuth」認證,否則 Agent 會得到 401。"
            warn "請在 GLPI「設定 > OAuth 用戶端 (OAuth Clients)」建立一組 Grants=Client credentials、Scope=inventory 的用戶端,"
            warn "取得 Client ID / Client Secret 後,以 OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET 提供給本腳本"
        fi ;;
    basic_auth)
        warn "GLPI 目前仍設定為「基本認證」(basic_auth),本腳本已改為只處理 OAuth。"
        warn "請到「管理 > 庫存」將 Agent Authentication 改為 OAuth - Client Credentials,再重新執行本腳本"
        ;;
    ""|none) [[ -z "$OAUTH_CLIENT_ID" ]] || warn "GLPI 未要求認證,但你指定了 OAUTH_CLIENT_ID;仍會寫入設定,通常不需要" ;;
    *) warn "GLPI 的庫存認證方式為 '${AUTH_REQ}',本腳本只處理 OAuth (oauth),其他方式需手動設定 Agent" ;;
esac

###############################################################################
step "4/7 安裝 GLPI Agent ${AGENT_VERSION}"
###############################################################################
INSTALLED_VER=""
if command -v glpi-agent >/dev/null; then
    INSTALLED_VER="$(glpi-agent --version 2>&1 || true)"; INSTALLED_VER="${INSTALLED_VER%%$'\n'*}"
fi

if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" == *"$AGENT_VERSION"* && "$FORCE_REINSTALL" != "1" ]]; then
    log "已安裝相同版本 (${INSTALLED_VER}),略過安裝器 (要重新執行請加 FORCE_REINSTALL=1)"
else
    [[ -z "$INSTALLED_VER" ]] || warn "目前已安裝: ${INSTALLED_VER};將以安裝器處理 (版本 ${AGENT_VERSION})"
    TMPD="$(mktemp -d)"
    log "下載 ${INSTALLER_URL}"
    curl -fL --retry 3 -o "${TMPD}/glpi-agent-installer.pl" "$INSTALLER_URL"
    [[ -s "${TMPD}/glpi-agent-installer.pl" ]] || die "安裝器下載結果是空的"
    perl -c "${TMPD}/glpi-agent-installer.pl" >/dev/null 2>&1 || die "安裝器檔案損壞 (perl 語法檢查失敗)"

    INSTALL_ARGS=(--install --server="$SERVER_URL" --tag="$AGENT_TAG" --no-question --verbose)
    [[ "$FORCE_REINSTALL" != "1" ]] || INSTALL_ARGS+=(--force)
    # 刻意不加 --runnow:此時 TLS 信任設定還沒套用,立即執行必定會因憑證不受信任而失敗
    log "執行官方安裝器: perl glpi-agent-installer.pl ${INSTALL_ARGS[*]}"
    perl "${TMPD}/glpi-agent-installer.pl" "${INSTALL_ARGS[@]}"
    rm -rf "$TMPD"
fi

command -v glpi-agent >/dev/null || die "安裝後找不到 glpi-agent 指令,請檢查上方安裝器輸出"
log "✓ 已安裝: $(glpi-agent --version 2>&1 | head -n1 || true)"

###############################################################################
step "5/7 套用設定 (信任自簽憑證)"
###############################################################################
mkdir -p "$AGENT_CONF_DIR"

# 確保 server 有被設定 (安裝器通常已寫入 conf.d;若沒有就補上)
if ! grep -rEqs '^[[:space:]]*server[[:space:]]*=' /etc/glpi-agent/agent.cfg "$AGENT_CONF_DIR"; then
    warn "安裝器沒有寫入 server 設定,改由本腳本寫入"
    cat > "${AGENT_CONF_DIR}/10-glpi-server.cfg" <<EOF
# 由 install_glpi_agent_local.sh 產生
server = ${SERVER_URL}
tag = ${AGENT_TAG}
EOF
fi

if [[ "$USE_CA" == "1" ]]; then
    install -m 0644 "$CA_CERT_SRC" "$AGENT_CA_DST"
    cat > "${AGENT_CONF_DIR}/20-glpi-tls.cfg" <<EOF
# 由 install_glpi_agent_local.sh 產生
# 信任 GLPI 伺服器的自簽憑證 (官方建議做法,不使用 no-ssl-check)
ca-cert-file = ${AGENT_CA_DST}
EOF
    log "✓ 已設定 ca-cert-file = ${AGENT_CA_DST}"
else
    rm -f "${AGENT_CONF_DIR}/20-glpi-tls.cfg"
    log "不需要 ca-cert-file 設定"
fi

if [[ -n "$OAUTH_CLIENT_ID" ]]; then
    umask 077
    cat > "${AGENT_CONF_DIR}/30-glpi-auth.cfg" <<EOF
# 由 install_glpi_agent_local.sh 產生 (含 Client Secret,權限 600)
oauth-client-id = ${OAUTH_CLIENT_ID}
oauth-client-secret = ${OAUTH_CLIENT_SECRET}
EOF
    umask 022
    chown root:root "${AGENT_CONF_DIR}/30-glpi-auth.cfg"; chmod 600 "${AGENT_CONF_DIR}/30-glpi-auth.cfg"
    log "✓ 已寫入 OAuth 認證設定 (oauth-client-id = ${OAUTH_CLIENT_ID},權限 600)"
fi

log "目前 conf.d 內容:"
for f in "$AGENT_CONF_DIR"/*.cfg; do
    [[ -f "$f" ]] || continue
    echo "  --- $f"
    grep -vE '^[[:space:]]*(#|$)' "$f" | sed -E 's/^([[:space:]]*(password|oauth-client-secret)[[:space:]]*=).*/\1 ********/; s/^/      /' || true
done

systemctl enable glpi-agent >/dev/null 2>&1 || true
systemctl restart glpi-agent
sleep 2
systemctl is-active --quiet glpi-agent && log "✓ glpi-agent 服務運行中" || warn "glpi-agent 服務未運行:journalctl -u glpi-agent -n 30"

###############################################################################
step "6/7 手動觸發一次庫存並回報到 GLPI"
###############################################################################
# 失敗時自動收集端點資訊 (全部是唯讀的 GET 與查詢,沒有副作用)
diagnose_endpoint() {
    local u out
    echo "--- 端點探測 (GET):看回應狀態與 WWW-Authenticate 標頭,可判斷是誰要求認證 ---"
    for u in "$SERVER_URL" "${SERVER_URL%/}/front/inventory.php"; do
        echo ">>> GET ${u}"
        out="$(curl -sS "${CURL_CA[@]}" -i --max-time 20 "$u" 2>&1 || true)"
        sed -n '1,14p' <<<"$out" | grep -viE '^(set-cookie|content-security|x-|permissions-policy|referrer)' | sed 's/^/      /' || true
    done
    echo "--- Nginx 記錄到的 Agent 請求 (最近 3 筆:狀態碼與路徑) ---"
    grep -h 'GLPI-Agent' /var/log/nginx/glpi_access.log 2>/dev/null | tail -n 3 | sed 's/^/      /' || echo "      (沒有紀錄)"
    echo "--- GLPI 資料庫中的庫存設定 (context=inventory) ---"
    glpi_sql "SELECT CONCAT(name,' = ',IF(name LIKE '%password%' OR name LIKE '%secret%','********',IFNULL(value,''))) FROM glpi_configs WHERE context='inventory' ORDER BY name;" | sed 's/^/      /' || true
    echo "--- GLPI 日誌目錄中最近更新的檔案 ---"
    ls -lt /var/log/glpi 2>/dev/null | sed -n '1,6p' | sed 's/^/      /' || true
}

RUN_LOG="$(mktemp)"
RC=0
timeout 900 glpi-agent --force --logger=stderr >"$RUN_LOG" 2>&1 || RC=$?
echo "--- Agent 輸出 (最後 25 行) ---"
tail -n 25 "$RUN_LOG"
echo "--- 結束碼: ${RC} ---"

# 注意:Agent 即使回報失敗,結束碼也常常是 0,所以要看輸出中的 [error] 行來判斷
AGENT_FAILED=0
AGENT_UNCONFIRMED=0
if (( RC != 0 )) || grep -Eq '\[error\]' "$RUN_LOG"; then
    AGENT_FAILED=1
    warn "Agent 回報失敗 (判斷依據是輸出中的 [error] 行,而不是結束碼)。常見狀況:"
    warn "  - certificate verify failed        → 憑證與網址主機名稱不符,或 ca-cert-file 沒有生效"
    warn "  - authentication required (401)     → 伺服器端要求認證,與憑證無關:可能是 Web 伺服器的認證設定,"
    warn "                                         或 GLPI 的庫存 Agent 認證設定,請看下方探測結果"
    warn "                                         若 GLPI 的 auth_required 是 oauth,請用 OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET 重新執行本腳本"
    warn "  - 403 / inventory disabled          → GLPI 尚未啟用庫存 (管理 > 庫存)"
    warn "  - 404                                → SERVER_URL 路徑不對 (可改試 https://主機/front/inventory.php)"
    diagnose_endpoint
fi
rm -f "$RUN_LOG"

###############################################################################
step "7/7 確認 GLPI 端已收到資料"
###############################################################################
sleep 3
AGENT_ROWS="$(glpi_sql "SELECT CONCAT(name,'  v',IFNULL(version,'?'),'  last_contact=',IFNULL(last_contact,'-')) FROM glpi_agents ORDER BY id DESC LIMIT 5;")"
COMP_N="$(glpi_sql "SELECT COUNT(*) FROM glpi_computers WHERE is_deleted=0;")"
if [[ -n "$AGENT_ROWS" ]]; then
    log "✓ GLPI 的 Agent 清單 (最近 5 筆):"
    echo "$AGENT_ROWS" | sed 's/^/      /'
    log "GLPI 目前的電腦資產數: ${COMP_N:-?}"
elif (( AGENT_FAILED == 0 )); then
    AGENT_UNCONFIRMED=1
    warn "Agent 沒有回報錯誤,但資料庫中還看不到任何 Agent。請稍候幾十秒後,在 GLPI 介面確認:「管理 > 庫存」或「資產 > 電腦」"
fi

if (( AGENT_FAILED )); then
    BANNER_COLOR="$RED";    BANNER_TITLE="⚠ Agent 已安裝,但回報到 GLPI 失敗 (請看上方錯誤與探測結果)"
elif (( AGENT_UNCONFIRMED )); then
    BANNER_COLOR="$YELLOW"; BANNER_TITLE="⚠ Agent 已安裝並已送出,但尚未在 GLPI 資料庫看到資料"
else
    BANNER_COLOR="$GREEN";  BANNER_TITLE="✅ GLPI Agent 本機部署完成,GLPI 已收到資料"
fi

cat <<EOF

${BANNER_COLOR}============================================================${NC}
 ${BANNER_TITLE}
${BANNER_COLOR}============================================================${NC}
 Agent 版本 : $(glpi-agent --version 2>&1 | head -n1 || true)
 GLPI 網址  : ${SERVER_URL}
 設定目錄   : ${AGENT_CONF_DIR}  (請勿直接改 agent.cfg,升級時會遺失)
 日誌       : /var/log/glpi-agent/  或  journalctl -u glpi-agent
 安裝記錄   : ${LOG_FILE}

 請到 GLPI 網頁確認:
  1. 「資產 > 電腦」應出現這台伺服器 (主機名稱 $(hostname))
  2. 「管理 > 庫存」可以看到 Agent 清單

 備註:
  - Agent 預設只允許 GLPI 伺服器連入它的 62354 埠;此機的防火牆也沒有開放該埠,不需要另外處理。
  - 之後要在其他電腦安裝 Agent,請使用同一個 SERVER_URL,並讓 Agent 信任 ${CA_CERT_SRC}
    (複製憑證檔過去,設定 ca-cert-file;或改用企業 CA / 公開 CA 簽發的憑證)。
EOF

# 失敗時回傳非 0,讓呼叫端 (例如自動化流程) 能察覺
(( AGENT_FAILED == 0 )) || exit 1
