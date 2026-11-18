#!/usr/bin/env bash
###############################################################################
# GLPI Agent 遠端部署腳本 —— 裝在「一般客戶端電腦」上 (Ubuntu/Debian)
#
# 這是 install_glpi_agent_local.sh 的精簡版:拿掉所有「只能在 GLPI 伺服器本機
# 才查得到」的自動偵測 (讀 Nginx 設定、直接連 GLPI 的 MariaDB)。
# 因此 SERVER_URL 必須明確指定;若 GLPI 用自簽憑證,CA_CERT_SRC 也必須明確指定
# (把憑證檔先複製到這台電腦上)。
#
# 用法 (以 root 執行):
#   sudo SERVER_URL=https://glpi.example.com/ bash install_glpi_agent_client.sh
#   sudo SERVER_URL=https://140.113.7.106/ CA_CERT_SRC=/root/glpi-server-ca.crt \
#        AGENT_TAG=Lab-PC-01 bash install_glpi_agent_client.sh
#
# 可用環境變數 (括號內為預設值):
#   SERVER_URL       GLPI 網址                        (必填,無法自動偵測)
#   AGENT_VERSION    Agent 版本                       (1.21,請先到 GitHub releases 確認最新版)
#   AGENT_TAG        寫入清單的標籤                   (本機 hostname)
#   CA_CERT_SRC      GLPI 伺服器的憑證檔 (自簽憑證才需要;需先把檔案複製到這台電腦)
#   SKIP_CA          1=不設定 ca-cert-file            (0)
#   FORCE_REINSTALL  1=已安裝也重新執行安裝器          (0)
#   OAUTH_CLIENT_ID      GLPI 要求 OAuth 認證時,Agent 使用的 OAuth Client ID
#   OAUTH_CLIENT_SECRET  對應的 Client Secret (不給的話,在終端機執行時會提示輸入;不可含 # 引號 空白)
#
# 和 install_glpi_agent_local.sh 的差異:
#   - 不會自動偵測 SERVER_URL / CA_CERT_SRC (本機沒有 GLPI 的 Nginx 設定可讀)
#   - 不會查詢 GLPI 資料庫確認「庫存是否啟用」「Agent 是否已入庫」
#     (本機沒有 GLPI 的 DB 連線憑證),這兩項請改到 GLPI 網頁介面確認
#
# 重複執行是安全的:已安裝且版本相同時,只會重新套用設定並重新驗證。
# 全部輸出會同時記錄在 /var/log/glpi-agent-install.log
###############################################################################

set -Eeuo pipefail

SCRIPT_VERSION="1 (2026-11-18)"
AGENT_VERSION="${AGENT_VERSION:-1.21}"
SERVER_URL="${SERVER_URL:-}"
AGENT_TAG="${AGENT_TAG:-$(hostname)}"
CA_CERT_SRC="${CA_CERT_SRC:-}"
SKIP_CA="${SKIP_CA:-0}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
OAUTH_CLIENT_ID="${OAUTH_CLIENT_ID:-}"
OAUTH_CLIENT_SECRET="${OAUTH_CLIENT_SECRET:-}"

INSTALLER_URL="https://github.com/glpi-project/glpi-agent/releases/download/${AGENT_VERSION}/glpi-agent-${AGENT_VERSION}-linux-installer.pl"
AGENT_CONF_DIR="/etc/glpi-agent/conf.d"
AGENT_CA_DST="/etc/glpi-agent/glpi-server-ca.crt"
LOG_FILE="/var/log/glpi-agent-install.log"

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

###############################################################################
step "1/5 前置檢查"
###############################################################################
log "install_glpi_agent_client.sh 版本 ${SCRIPT_VERSION},共 5 個步驟,依序完整執行"
command -v systemctl >/dev/null || die "此腳本需要 systemd"
if ! command -v perl >/dev/null; then
    log "安裝 perl (Agent 安裝器的必要條件)"
    apt-get update -y >/dev/null && apt-get install -y --no-install-recommends perl >/dev/null
fi
command -v curl >/dev/null || { apt-get update -y >/dev/null; apt-get install -y --no-install-recommends curl ca-certificates >/dev/null; }

[[ -n "$SERVER_URL" ]] || die "請以 SERVER_URL=https://<GLPI主機>/ 指定 GLPI 網址 (這台電腦無法自動偵測)"
[[ "$SERVER_URL" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]] || die "SERVER_URL 格式不合法: $SERVER_URL"
SERVER_HOST="${SERVER_URL#*://}"; SERVER_HOST="${SERVER_HOST%%/*}"; SERVER_HOST="${SERVER_HOST%%:*}"
log "GLPI 網址: ${SERVER_URL}"
log "Agent 標籤 (tag): ${AGENT_TAG}"

if [[ -n "$CA_CERT_SRC" ]]; then
    [[ -f "$CA_CERT_SRC" ]] || die "找不到 CA_CERT_SRC 指定的憑證檔: ${CA_CERT_SRC} (請先把 GLPI 伺服器的憑證複製到這台電腦)"
fi

# ---- Agent OAuth 認證 (GLPI 設定了 auth_required=oauth 時需要;GLPI 11+ 才支援) ----
if [[ -n "$OAUTH_CLIENT_ID" ]]; then
    if [[ -z "$OAUTH_CLIENT_SECRET" ]]; then
        if [[ -t 0 ]]; then
            read -rsp "請輸入 OAuth Client Secret (Client ID: ${OAUTH_CLIENT_ID}): " OAUTH_CLIENT_SECRET; echo
        else
            die "已指定 OAUTH_CLIENT_ID,但沒有 OAUTH_CLIENT_SECRET,且目前不是互動式終端機"
        fi
    fi
    [[ "$OAUTH_CLIENT_ID"     =~ ^[A-Za-z0-9._@-]+$ ]]   || die "OAUTH_CLIENT_ID 只允許英數字與 . _ @ -"
    [[ "$OAUTH_CLIENT_SECRET" =~ ^[^#\"\'[:space:]]+$ ]] || die "OAUTH_CLIENT_SECRET 不可含 # 引號 或空白 (Agent 設定檔無法正確處理),請在 GLPI 重新產生 Client Secret"
fi

log "Agent 版本: ${AGENT_VERSION}"
curl -fsIL "$INSTALLER_URL" -o /dev/null \
    || die "找不到安裝器: $INSTALLER_URL
       請到 https://github.com/glpi-project/glpi-agent/releases 確認版本號,再以 AGENT_VERSION=x.y 重新執行"

###############################################################################
step "2/5 驗證 GLPI 連線與憑證 (安裝前先確認,與 Agent 實際會遇到的情況相同)"
###############################################################################
USE_CA=0
CURL_CA=()
if [[ "$SERVER_URL" == https://* && "$SKIP_CA" != "1" && -n "$CA_CERT_SRC" ]]; then
    # 只有「自簽憑證」才需要把它設為信任根;公開 CA / 企業 CA 簽發的憑證不需要
    if [[ "$(openssl x509 -in "$CA_CERT_SRC" -noout -subject_hash 2>/dev/null)" == \
          "$(openssl x509 -in "$CA_CERT_SRC" -noout -issuer_hash 2>/dev/null)" ]]; then
        USE_CA=1
        CURL_CA=(--cacert "$CA_CERT_SRC")
        log "偵測到自簽憑證 ${CA_CERT_SRC},將設定為 Agent 的信任憑證 (ca-cert-file)"
        if ! openssl x509 -in "$CA_CERT_SRC" -noout -ext subjectAltName 2>/dev/null \
             | grep -qE "(IP Address|DNS):${SERVER_HOST//./\\.}([,[:space:]]|$)"; then
            warn "憑證的 SAN 不含 '${SERVER_HOST}',Agent 會因主機名稱不符而拒絕連線。"
            warn "目前憑證涵蓋的位址: $(openssl x509 -in "$CA_CERT_SRC" -noout -ext subjectAltName 2>/dev/null | tail -n1 | sed 's/^ *//')"
            warn "請回到 GLPI 伺服器重新產生涵蓋 '${SERVER_HOST}' 的憑證,再重新複製過來執行本腳本"
        fi
    else
        log "憑證不是自簽,視為公開 CA / 企業 CA 簽發,不需設定 ca-cert-file"
    fi
elif [[ "$SERVER_URL" == https://* && "$SKIP_CA" != "1" ]]; then
    warn "沒有提供 CA_CERT_SRC,將使用系統內建的信任清單驗證憑證。"
    warn "若 GLPI 使用自簽憑證,下面的連線測試會失敗;請把 GLPI 伺服器的憑證複製到這台電腦,"
    warn "再以 CA_CERT_SRC=/path/to/glpi-server-ca.crt 重新執行"
fi

CURL_ERR="$(mktemp)"
HTTP_CODE="$(curl -sS "${CURL_CA[@]}" -o /dev/null -w '%{http_code}' --max-time 20 "$SERVER_URL" 2>"$CURL_ERR" || true)"
if [[ "$HTTP_CODE" == "000" || -z "$HTTP_CODE" ]]; then
    echo "--- curl 錯誤訊息 ---"; cat "$CURL_ERR"; rm -f "$CURL_ERR"
    die "無法以 TLS 驗證連上 ${SERVER_URL}。常見原因:
       - 憑證與網址的主機名稱不符 (SAN)
       - 憑證不受信任 (自簽憑證需要用 CA_CERT_SRC 指定憑證檔)
       - 這台電腦到 GLPI 伺服器的網路/防火牆不通"
fi
rm -f "$CURL_ERR"
log "✓ ${SERVER_URL} 連線與憑證驗證通過 (HTTP ${HTTP_CODE})"

###############################################################################
step "3/5 安裝 GLPI Agent ${AGENT_VERSION}"
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
step "4/5 套用設定 (信任自簽憑證、OAuth)"
###############################################################################
mkdir -p "$AGENT_CONF_DIR"

# 確保 server 有被設定 (安裝器通常已寫入 conf.d;若沒有就補上)
if ! grep -rEqs '^[[:space:]]*server[[:space:]]*=' /etc/glpi-agent/agent.cfg "$AGENT_CONF_DIR"; then
    warn "安裝器沒有寫入 server 設定,改由本腳本寫入"
    cat > "${AGENT_CONF_DIR}/10-glpi-server.cfg" <<EOF
# 由 install_glpi_agent_client.sh 產生
server = ${SERVER_URL}
tag = ${AGENT_TAG}
EOF
fi

if [[ "$USE_CA" == "1" ]]; then
    install -m 0644 "$CA_CERT_SRC" "$AGENT_CA_DST"
    cat > "${AGENT_CONF_DIR}/20-glpi-tls.cfg" <<EOF
# 由 install_glpi_agent_client.sh 產生
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
# 由 install_glpi_agent_client.sh 產生 (含 Client Secret,權限 600)
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
step "5/5 手動觸發一次庫存並回報到 GLPI"
###############################################################################
# 失敗時自動收集端點資訊 (全部是唯讀的 GET,沒有副作用)
diagnose_endpoint() {
    local u out
    echo "--- 端點探測 (GET):看回應狀態與標頭,可判斷是誰要求認證 ---"
    for u in "$SERVER_URL" "${SERVER_URL%/}/front/inventory.php"; do
        echo ">>> GET ${u}"
        out="$(curl -sS "${CURL_CA[@]}" -i --max-time 20 "$u" 2>&1 || true)"
        sed -n '1,14p' <<<"$out" | grep -viE '^(set-cookie|content-security|x-|permissions-policy|referrer)' | sed 's/^/      /' || true
    done
}

RUN_LOG="$(mktemp)"
RC=0
timeout 900 glpi-agent --force --logger=stderr >"$RUN_LOG" 2>&1 || RC=$?
echo "--- Agent 輸出 (最後 25 行) ---"
tail -n 25 "$RUN_LOG"
echo "--- 結束碼: ${RC} ---"

# 注意:Agent 即使回報失敗,結束碼也常常是 0,所以要看輸出中的 [error] 行來判斷
AGENT_FAILED=0
if (( RC != 0 )) || grep -Eq '\[error\]' "$RUN_LOG"; then
    AGENT_FAILED=1
    warn "Agent 回報失敗 (判斷依據是輸出中的 [error] 行,而不是結束碼)。常見狀況:"
    warn "  - certificate verify failed        → 憑證與網址主機名稱不符,或 CA_CERT_SRC 沒有生效"
    warn "  - authentication required (401)     → 伺服器端要求認證,與憑證無關:"
    warn "                                         請登入 GLPI「管理 > 庫存」確認 Agent Authentication 設定,"
    warn "                                         若是 oauth,請用 OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET 重新執行本腳本"
    warn "  - 403 / inventory disabled          → GLPI 尚未啟用庫存 (管理 > 庫存)"
    warn "  - 404                                → SERVER_URL 路徑不對 (可改試 https://主機/front/inventory.php)"
    diagnose_endpoint
fi
rm -f "$RUN_LOG"

if (( AGENT_FAILED == 0 )); then
    BANNER_COLOR="$GREEN";  BANNER_TITLE="✅ GLPI Agent 部署完成,請到 GLPI 網頁確認已收到資料"
else
    BANNER_COLOR="$RED";    BANNER_TITLE="⚠ Agent 已安裝,但回報到 GLPI 失敗 (請看上方錯誤與探測結果)"
fi

cat <<EOF

${BANNER_COLOR}============================================================${NC}
 ${BANNER_TITLE}
${BANNER_COLOR}============================================================${NC}
 Agent 版本 : $(glpi-agent --version 2>&1 | head -n1 || true)
 GLPI 網址  : ${SERVER_URL}
 Agent 標籤 : ${AGENT_TAG}
 設定目錄   : ${AGENT_CONF_DIR}  (請勿直接改 agent.cfg,升級時會遺失)
 日誌       : /var/log/glpi-agent/  或  journalctl -u glpi-agent
 安裝記錄   : ${LOG_FILE}

 請到 GLPI 網頁確認 (這台電腦無法直接查 GLPI 的資料庫):
  1. 「資產 > 電腦」應出現這台電腦 (主機名稱 $(hostname),標籤 ${AGENT_TAG})
  2. 「管理 > 庫存」可以看到這個 Agent

 備註:
  - Agent 預設只允許 GLPI 伺服器連入它的 62354 埠,一般不需要在這台電腦上另外開防火牆。
  - 要在更多電腦上安裝,重複使用同一個 SERVER_URL,並把同一份 ${CA_CERT_SRC:-<GLPI 憑證檔>} 複製過去即可;
    AGENT_TAG 建議改成每台電腦各自的識別名稱。
EOF

(( AGENT_FAILED == 0 )) || exit 1
