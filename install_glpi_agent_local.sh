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
#   CA_CERT_SRC      GLPI 伺服器憑證檔                (/etc/ssl/glpi/glpi.crt)
#   SKIP_CA          1=不設定 ca-cert-file            (0)
#   FORCE_REINSTALL  1=已安裝也重新執行安裝器          (0)
#
# 重複執行是安全的:已安裝且版本相同時,只會重新套用設定並重新驗證。
# 全部輸出會同時記錄在 /var/log/glpi-agent-install.log
###############################################################################

set -Eeuo pipefail

SCRIPT_VERSION="1 (2026-11-11)"
AGENT_VERSION="${AGENT_VERSION:-1.21}"
SERVER_URL="${SERVER_URL:-}"
AGENT_TAG="${AGENT_TAG:-GLPI-Server}"
CA_CERT_SRC="${CA_CERT_SRC:-/etc/ssl/glpi/glpi.crt}"
SKIP_CA="${SKIP_CA:-0}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

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

log "Agent 版本: ${AGENT_VERSION}"
curl -fsIL "$INSTALLER_URL" -o /dev/null \
    || die "找不到安裝器: $INSTALLER_URL
       請到 https://github.com/glpi-project/glpi-agent/releases 確認版本號,再以 AGENT_VERSION=x.y 重新執行"

###############################################################################
step "2/7 驗證 GLPI 連線與憑證 (安裝前先確認,與 Agent 實際會遇到的情況相同)"
###############################################################################
USE_CA=0
CURL_CA=()
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
            warn "請改用憑證涵蓋的位址作為 SERVER_URL,或重新產生憑證 (可重跑 install_glpi12.sh)"
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

log "目前 conf.d 內容:"
for f in "$AGENT_CONF_DIR"/*.cfg; do
    [[ -f "$f" ]] || continue
    echo "  --- $f"
    grep -vE '^[[:space:]]*(#|$)' "$f" | sed 's/^/      /' || true
done

systemctl enable glpi-agent >/dev/null 2>&1 || true
systemctl restart glpi-agent
sleep 2
systemctl is-active --quiet glpi-agent && log "✓ glpi-agent 服務運行中" || warn "glpi-agent 服務未運行:journalctl -u glpi-agent -n 30"

###############################################################################
step "6/7 手動觸發一次庫存並回報到 GLPI"
###############################################################################
RUN_LOG="$(mktemp)"
RC=0
timeout 900 glpi-agent --force --logger=stderr >"$RUN_LOG" 2>&1 || RC=$?
echo "--- Agent 輸出 (最後 25 行) ---"
tail -n 25 "$RUN_LOG"
echo "--- 結束碼: ${RC} ---"
if (( RC != 0 )) || grep -Eqi 'certificate verify failed|unable to connect|SSL|error' "$RUN_LOG"; then
    warn "Agent 輸出含有錯誤字樣,請看上方訊息。常見狀況:"
    warn "  - certificate verify failed   → 憑證與網址主機名稱不符,或 ca-cert-file 沒有生效"
    warn "  - 403 / inventory disabled    → GLPI 尚未啟用庫存 (管理 > 庫存)"
    warn "  - 404                          → SERVER_URL 路徑不對 (可試 https://主機/front/inventory.php)"
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
else
    warn "資料庫中還看不到任何 Agent。請稍候幾十秒後,在 GLPI 介面確認:「管理 > 庫存」或「資產 > 電腦」"
fi

cat <<EOF

${GREEN}============================================================${NC}
 ✅ GLPI Agent 本機部署流程完成
${GREEN}============================================================${NC}
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
