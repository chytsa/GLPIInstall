@echo off
REM =============================================================================
REM GLPI Agent 安裝啟動器 (Windows 11) —— 給現場 IT 人員用
REM
REM 用法:
REM   1. 把這個 .bat、install_glpi_agent_win11.ps1,以及 GLPI 伺服器的自簽憑證
REM      (若有,例如 glpi-ca.pem) 放在「同一個資料夾」。
REM   2. 依下方「設定區」填入您環境的連線資訊 (只需改這裡,一次,之後就能重複
REM      複製整個資料夾到各台客戶端 PC 使用)。
REM   3. 在客戶端 PC 上對這個 .bat 按右鍵 -> 「以系統管理員身分執行」即可;
REM      若直接雙擊忘記點「以系統管理員身分執行」,腳本也會自動彈出 UAC 視窗提權。
REM
REM 注意: 若填入 OAUTH_CLIENT_SECRET,代表 Secret 明文會原樣存在這個 .bat 檔案
REM       裡 (以及之後派送的整個資料夾)。發佈前請確認檔案只放在信任的內部網路
REM       路徑或隨身碟,避免外流;正式環境建議個別 PC 限制讀取權限,或改走
REM       GPO/RMM 的加密參數佈署方式。
REM =============================================================================

setlocal

REM ------------------------- 設定區 (請依現場環境修改) -------------------------
set "GLPI_SERVER_URL=https://140.113.7.106/"
set "GLPI_AGENT_TAG=GLPI-Client"
REM 若伺服器用自簽憑證,把憑證檔跟這個 .bat 放一起,檔名改成下面這行對應的名稱;
REM 若伺服器是公開 CA 簽發的憑證,把這行整個刪掉或留空即可。
set "GLPI_CA_CERT_FILE=%~dp0glpi-ca.pem"
REM 若 GLPI 的庫存認證設定是 OAuth,填入下面兩個值 (否則留空):
set "GLPI_OAUTH_CLIENT_ID="
set "GLPI_OAUTH_CLIENT_SECRET="
REM -----------------------------------------------------------------------------

title GLPI Agent 安裝程式

REM --- 檢查目前是否已經有系統管理員權限;沒有的話自動重新以提權方式啟動一次 ---
net session >nul 2>&1
if not "%errorlevel%" == "0" (
    echo [INFO] 需要系統管理員權限,重新以提權方式啟動本程式...
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PS1=%~dp0install_glpi_agent_win11.ps1"
if not exist "%PS1%" (
    echo [ERROR] 找不到 "%PS1%"
    echo         請確認 install_glpi_agent_win11.ps1 跟這個 .bat 放在同一個資料夾。
    pause
    exit /b 1
)

if defined GLPI_CA_CERT_FILE if not exist "%GLPI_CA_CERT_FILE%" (
    echo [WARN] 設定了 GLPI_CA_CERT_FILE=%GLPI_CA_CERT_FILE% 但找不到這個檔案,將忽略此設定。
    set "GLPI_CA_CERT_FILE="
)

echo [INFO] 開始安裝 GLPI Agent,伺服器: %GLPI_SERVER_URL%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "EXITCODE=%errorlevel%"

echo.
if "%EXITCODE%" == "0" (
    echo [完成] 安裝程式執行結束,結束碼: %EXITCODE%
) else (
    echo [注意] 安裝程式回報有問題,結束碼: %EXITCODE% (請往上捲動查看詳細訊息)
)
echo.
pause
exit /b %EXITCODE%
