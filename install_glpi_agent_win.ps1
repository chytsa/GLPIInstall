#Requires -RunAsAdministrator
<#
###############################################################################
 GLPI Agent 安裝腳本 —— for Windows 11 (用來把 Agent 裝到客戶端 PC 上)

 作法依據 GLPI Agent 官方文件:使用官方 MSI 安裝器 (GLPI-Agent-<版本>-x64.msi),
 以 msiexec /quiet 搭配命令列參數做無人值守安裝。
 參考: https://github.com/glpi-project/doc-agent/blob/master/source/installation/windows-command-line.rst

 用法 (以系統管理員 PowerShell 執行):
   .\install_glpi_agent_win11.ps1
   .\install_glpi_agent_win11.ps1 -ServerUrl "https://140.113.7.106/" -AgentTag "GLPI-Client"

 也可用環境變數覆寫 (與參數對應,方便用 GPO / RMM 批次佈署時用環境變數帶入):
   GLPI_AGENT_VERSION, GLPI_SERVER_URL, GLPI_AGENT_TAG, GLPI_CA_CERT_FILE,
   GLPI_SKIP_CA (1=不設定 CA_CERT_FILE), GLPI_FORCE_REINSTALL (1=強制重跑安裝器),
   GLPI_OAUTH_CLIENT_ID, GLPI_OAUTH_CLIENT_SECRET

 重複執行是安全的:已安裝且版本相同時,只會重新套用設定並重新驗證連線。
 全部輸出同時記錄在 C:\ProgramData\glpi-agent-install.log
###############################################################################
#>

[CmdletBinding()]
param(
    [string]$AgentVersion       = $(if ($env:GLPI_AGENT_VERSION)      { $env:GLPI_AGENT_VERSION }      else { '1.21' }),
    [string]$ServerUrl          = $(if ($env:GLPI_SERVER_URL)         { $env:GLPI_SERVER_URL }         else { '' }),
    [string]$AgentTag           = $(if ($env:GLPI_AGENT_TAG)          { $env:GLPI_AGENT_TAG }          else { 'GLPI-Client' }),
    [string]$CaCertFile         = $(if ($env:GLPI_CA_CERT_FILE)       { $env:GLPI_CA_CERT_FILE }       else { '' }),
    [switch]$SkipCa             = [bool]($env:GLPI_SKIP_CA -eq '1'),
    [switch]$ForceReinstall     = [bool]($env:GLPI_FORCE_REINSTALL -eq '1'),
    [string]$OAuthClientId      = $(if ($env:GLPI_OAUTH_CLIENT_ID)     { $env:GLPI_OAUTH_CLIENT_ID }     else { '' }),
    [string]$OAuthClientSecret  = $(if ($env:GLPI_OAUTH_CLIENT_SECRET) { $env:GLPI_OAUTH_CLIENT_SECRET } else { '' })
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1 (2026-11-18)'
$LogFile       = 'C:\ProgramData\glpi-agent-install.log'
# 記錄檔用 Append 模式持續累積,避免無限長大與新舊紀錄混淆,超過 5MB 就留一份備份後重開新檔。
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
    Move-Item -Path $LogFile -Destination "$LogFile.bak" -Force -ErrorAction SilentlyContinue
}
Start-Transcript -Path $LogFile -Append | Out-Null

function Write-Info { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn { param($Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Step { param($Msg) Write-Host "`n==================== $Msg ====================" -ForegroundColor Cyan }

# 注意: Start-Transcript 會把啟動時的完整命令列 (Host Application) 原樣寫進記錄檔,
# 若 OAuth Client Secret 是用 -OAuthClientSecret 參數直接帶入,明文就會永久留在
# C:\ProgramData\glpi-agent-install.log 裡 (該檔案一般使用者也讀得到)。
# 這裡在每次結束前,把記錄檔裡所有出現過的 Secret 明文都覆寫成 ********。
function Protect-Log {
    param([string]$Path, [string]$Secret)
    if (-not $Secret -or -not (Test-Path $Path)) { return }
    try {
        $content = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ($content -match [regex]::Escape($Secret)) {
            ($content -replace [regex]::Escape($Secret), '********') |
                Set-Content -Path $Path -NoNewline -ErrorAction Stop
        }
    } catch {
        Write-Warning "無法清除記錄檔中的敏感字串,請自行檢查並手動清除 $Path 內的 Secret 明文: $($_.Exception.Message)"
    }
}

function Die        { param($Msg) Write-Err $Msg; Stop-Transcript | Out-Null; Protect-Log -Path $LogFile -Secret $OAuthClientSecret; exit 1 }

###############################################################################
Write-Step '1/5 前置檢查'
###############################################################################
Write-Info "install_glpi_agent_win11.ps1 版本 $ScriptVersion"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die '請以系統管理員身分執行 PowerShell (以系統管理員身分執行)' }

if (-not $ServerUrl) {
    Die 'SERVER_URL 未指定,請以 -ServerUrl "https://glpi.example.org/" 指定 (或設定 GLPI_SERVER_URL 環境變數)'
}
if ($ServerUrl -notmatch '^https?://[A-Za-z0-9._:-]+(/.*)?$') {
    Die "SERVER_URL 格式不合法: $ServerUrl"
}
Write-Info "GLPI 伺服器網址: $ServerUrl"

if ($OAuthClientId -and -not $OAuthClientSecret) {
    $sec = Read-Host -Prompt "請輸入 OAuth Client Secret (Client ID: $OAuthClientId)" -AsSecureString
    $OAuthClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
} elseif ($OAuthClientSecret -and $PSBoundParameters.ContainsKey('OAuthClientSecret')) {
    Write-Warn '以 -OAuthClientSecret 參數直接帶入 Secret 會明文出現在命令列紀錄與 PowerShell 歷史中。'
    Write-Warn '建議改用 -OAuthClientId 搭配留空 -OAuthClientSecret (腳本會安全提示輸入),或用環境變數 GLPI_OAUTH_CLIENT_SECRET。'
}
if ($OAuthClientId -and $OAuthClientId -notmatch '^[A-Za-z0-9._@-]+$') {
    Die 'OAUTH_CLIENT_ID 只允許英數字與 . _ @ -'
}
if ($OAuthClientSecret -and $OAuthClientSecret -match '[#"''\s]') {
    Die 'OAUTH_CLIENT_SECRET 不可含 # 引號 或空白 (Agent 設定檔無法正確處理),請在 GLPI 重新產生 Client Secret'
}

$InstallerUrl = "https://github.com/glpi-project/glpi-agent/releases/download/$AgentVersion/GLPI-Agent-$AgentVersion-x64.msi"
Write-Info "Agent 版本: $AgentVersion"
try {
    $resp = Invoke-WebRequest -Uri $InstallerUrl -Method Head -UseBasicParsing -TimeoutSec 20
} catch {
    Die "找不到安裝器: $InstallerUrl`n       請到 https://github.com/glpi-project/glpi-agent/releases 確認版本號,再以 -AgentVersion x.y 重新執行"
}

###############################################################################
Write-Step '2/5 驗證 GLPI 連線與憑證'
###############################################################################
if ($SkipCa -and $CaCertFile) {
    Write-Warn "已指定 -SkipCa,將忽略 -CaCertFile ($CaCertFile),不會匯入任何憑證。"
} elseif ($ServerUrl.StartsWith('https://') -and -not $SkipCa -and $CaCertFile) {
    if (-not (Test-Path $CaCertFile)) {
        Die "指定的 -CaCertFile 找不到檔案: $CaCertFile (請確認路徑是否正確)"
    }
    Write-Info "將匯入憑證到 Windows 信任的根憑證授權單位存放區: $CaCertFile"
    # 注意: Windows 版 GLPI Agent 的 [ssl-keystore] 模組只會從 Windows 憑證存放區 (LocalMachine\Root / CA)
    # 讀取信任清單,實測不會套用 ca-cert-file 設定 (那是給 Linux/Perl 原生 IO::Socket::SSL 用的)。
    # 所以自簽憑證一定要先匯入 Windows 的憑證存放區,Agent 才認得。
    try {
        $imported = Import-Certificate -FilePath $CaCertFile -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop
        Write-Info "✓ 已匯入憑證到 LocalMachine\Root (Thumbprint: $($imported.Thumbprint))"
    } catch {
        Write-Warn "匯入憑證到 Windows 憑證存放區失敗: $($_.Exception.Message)"
    }
} elseif ($ServerUrl.StartsWith('https://') -and -not $SkipCa -and -not $CaCertFile) {
    Write-Warn '未指定 -CaCertFile。若 GLPI 伺服器使用自簽憑證,Agent 連線會因憑證不受信任而失敗。'
    Write-Warn '請用 -CaCertFile "C:\path\to\glpi-ca.pem" 指定伺服器憑證 (需為 .pem 格式),腳本會自動匯入 Windows 信任存放區;或確認伺服器是公開 CA 簽發的憑證。'
}

# 先用目前的 TLS 設定實際測試連線一次 (不用 Agent,先排除網路 / 憑證問題)
# 注意: Windows PowerShell 5.1 沒有 -SkipCertificateCheck 參數,這裡只在明確要求跳過憑證檢查時,
# 暫時放寬目前 session 的憑證驗證 (不影響系統信任庫)。
$origCertCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
try {
    if ($SkipCa) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    $testResp = Invoke-WebRequest -Uri $ServerUrl -Method Get -UseBasicParsing -TimeoutSec 20
    Write-Info "✓ $ServerUrl 連線驗證通過 (HTTP $($testResp.StatusCode))"
} catch {
    Write-Warn "連線測試失敗: $($_.Exception.Message)"
    Write-Warn '常見原因: 憑證與網址主機名稱不符 (SAN) / 憑證不受信任 (自簽憑證需要 -CaCertFile) / 伺服器未監聽或防火牆阻擋'
    Write-Warn '將繼續安裝,但 Agent 執行時可能遇到相同問題,請排除後再重跑一次本腳本。'
} finally {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCertCallback
}

###############################################################################
Write-Step '3/5 安裝 GLPI Agent'
###############################################################################
$InstallDir = 'C:\Program Files\GLPI-Agent'
$installedVersion = $null
$pkg = Get-Package -Name 'GLPI-Agent*' -ErrorAction SilentlyContinue
if ($pkg) { $installedVersion = $pkg.Version }

if ($installedVersion -and ($installedVersion -eq $AgentVersion) -and -not $ForceReinstall) {
    Write-Info "已安裝相同版本 ($installedVersion),略過安裝器 (要重新執行請加 -ForceReinstall)。設定一律會在下一步重新套用。"
} else {
    if ($installedVersion) { Write-Warn "目前已安裝: $installedVersion;將以安裝器覆蓋安裝 (版本 $AgentVersion)" }

    $tmpDir = Join-Path $env:TEMP 'glpi-agent-install'
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $msiPath = Join-Path $tmpDir "GLPI-Agent-$AgentVersion-x64.msi"
    Write-Info "下載 $InstallerUrl"
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $msiPath -UseBasicParsing
    if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -eq 0) { Die '安裝器下載結果是空的' }

    # 注意: SERVER/TAG/CA_CERT_FILE 等屬性只有「全新安裝」時才會被 MSI 寫入登錄檔;
    # 對已安裝的產品執行 msiexec /i 不會重新套用這些屬性 (即使加上 REINSTALL/REINSTALLMODE 也一樣),
    # 所以這裡只負責安裝程式本體與服務,實際連線設定一律在下一步改用 Windows 登錄檔管理 (每次執行都會覆寫,可靠且可重複執行)。
    $msiArgs = @(
        '/i', "`"$msiPath`"",
        '/quiet', '/norestart',
        'EXECMODE=1',
        'RUNNOW=0',
        'ADD_FIREWALL_EXCEPTION=1'
    )
    if ($installedVersion) { $msiArgs += 'REINSTALL=ALL'; $msiArgs += 'REINSTALLMODE=vomus' }

    Write-Info "執行官方安裝器: msiexec $($msiArgs -join ' ')"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) { Die "msiexec 安裝失敗,結束碼: $($proc.ExitCode)" }
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 真正的入口是最外層的 glpi-agent.bat (它負責呼叫 perl\bin 內的直譯器執行 perl 腳本本體)。
# perl\bin\glpi-agent.exe 只是被重新命名的 Perl 直譯器,不能直接傳 --force 這類 Agent 參數給它。
if (-not (Test-Path $InstallDir)) {
    Die "安裝後找不到安裝目錄 $InstallDir,msiexec 可能靜默失敗。請重跑並加上詳細記錄診斷:`n       msiexec /i `"$msiPath`" /quiet /norestart /l*v `"$env:TEMP\glpi-agent-msi.log`" SERVER=$ServerUrl"
}
$glpiAgentExe = Join-Path $InstallDir 'glpi-agent.bat'
if (-not (Test-Path $glpiAgentExe)) {
    Die "安裝後找不到 $glpiAgentExe,請檢查 $LogFile 與 %TEMP%\glpi-agent-install\ 底下的 MSI 安裝紀錄 (可用 msiexec /i ... /l*v install.log 重跑取得詳細記錄)"
}
$versionOutput = & cmd.exe /c "`"$glpiAgentExe`" --version" 2>&1 | Select-Object -First 1
Write-Info "✓ 已安裝: $versionOutput (路徑: $glpiAgentExe)"

###############################################################################
Write-Step '3b/5 套用連線設定 (寫入 Windows 登錄檔,每次執行都會覆寫)'
###############################################################################
# 重要: GLPI Agent 官方文件明載 "registry: read configuration from the registry (default on Windows)"。
# 也就是說 Windows 上不論是手動執行或 Windows 服務,預設一律讀 HKLM\SOFTWARE\GLPI-Agent 底下的值,
# 完全不會讀 etc\agent.cfg / etc\conf.d\*.cfg (那是給 --conf-file / Linux 版用的)。
# 鍵名與設定檔參數名稱相同 (server、tag、oauth-client-id、oauth-client-secret ...),字串值 (REG_SZ)。
$regKeyPath = 'HKLM:\SOFTWARE\GLPI-Agent'
New-Item -Path $regKeyPath -Force | Out-Null

Set-ItemProperty -Path $regKeyPath -Name 'server' -Value $ServerUrl -Type String
Set-ItemProperty -Path $regKeyPath -Name 'tag'    -Value $AgentTag  -Type String

if ($SkipCa) {
    Set-ItemProperty -Path $regKeyPath -Name 'no-ssl-check' -Value '1' -Type String
} else {
    Remove-ItemProperty -Path $regKeyPath -Name 'no-ssl-check' -ErrorAction SilentlyContinue
}
# 不寫入 ca-cert-file: 自簽憑證改由上一步 Import-Certificate 匯入 Windows 的
# LocalMachine\Root 存放區處理 ([ssl-keystore] 模組只信任這裡,不吃 ca-cert-file 設定)。

if ($OAuthClientId) {
    Set-ItemProperty -Path $regKeyPath -Name 'oauth-client-id'     -Value $OAuthClientId     -Type String
    Set-ItemProperty -Path $regKeyPath -Name 'oauth-client-secret' -Value $OAuthClientSecret -Type String
    Write-Info '✓ 已寫入 OAuth 認證設定 (登錄檔)'
} else {
    Remove-ItemProperty -Path $regKeyPath -Name 'oauth-client-id'     -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $regKeyPath -Name 'oauth-client-secret' -ErrorAction SilentlyContinue
}

Write-Info "✓ 已寫入 $regKeyPath"
Write-Host '目前登錄檔內容 (節錄):'
Get-ItemProperty -Path $regKeyPath |
    Select-Object server, tag, 'no-ssl-check', 'oauth-client-id', 'oauth-client-secret' |
    Format-List |
    Out-String -Width 200 |
    ForEach-Object {
        ($_ -split "`r?`n") | Where-Object { $_.Trim() } |
            ForEach-Object { ($_ -replace '(oauth-client-secret\s*:\s*).*', '$1********') -replace '^', '  ' }
    }

###############################################################################
Write-Step '4/5 確認服務狀態並手動觸發一次庫存'
###############################################################################
$svc = Get-Service -Name 'GLPI-Agent' -ErrorAction SilentlyContinue
$serviceWasRunning = $false
if ($svc) {
    if ($svc.Status -ne 'Running') {
        Write-Warn 'GLPI-Agent 服務未運行,嘗試啟動'
        Start-Service -Name 'GLPI-Agent'
        Start-Sleep -Seconds 2
        $svc.Refresh()
    }
    if ($svc.Status -eq 'Running') { Write-Info '✓ GLPI-Agent 服務運行中'; $serviceWasRunning = $true }
    else { Write-Warn 'GLPI-Agent 服務未運行,請檢查事件檢視器或 C:\Program Files\GLPI-Agent\logs\glpi-agent.log' }
} else {
    Write-Warn '找不到 GLPI-Agent 服務 (可能安裝為 Task 或 Manual 模式,EXECMODE 不是 1)'
}

Write-Info '手動觸發一次庫存回報 (最多等待 15 分鐘)'
# 服務本身也會佔用 Agent 的執行鎖定與 62354 埠,手動觸發前先暫停服務,結束後再復原
if ($serviceWasRunning) { Stop-Service -Name 'GLPI-Agent' -Force; Start-Sleep -Seconds 2 }
$runLog = Join-Path $env:TEMP 'glpi-agent-run.log'
Remove-Item -Path $runLog -Force -ErrorAction SilentlyContinue
$runProc = Start-Process -FilePath $glpiAgentExe -ArgumentList '--force', '--logger=file', "--logfile=$runLog" -Wait -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
if ($serviceWasRunning) { Start-Service -Name 'GLPI-Agent' }
if (Test-Path $runLog) {
    Write-Host '--- Agent 輸出 (最後 25 行) ---'
    Get-Content $runLog -Tail 25
} else {
    Write-Warn "找不到執行記錄 $runLog,Agent 可能沒有正常啟動"
}
$agentFailed = $false
$hasErrorLine = (Test-Path $runLog) -and (Select-String -Path $runLog -Pattern '\[error\]' -Quiet)
if ($runProc.ExitCode -ne 0 -or $hasErrorLine) {
    $agentFailed = $true
    Write-Warn 'Agent 回報失敗。常見狀況:'
    Write-Warn '  - certificate verify failed   → 憑證與網址主機名稱不符,或 CA_CERT_FILE 沒有生效'
    Write-Warn '  - authentication required(401) → GLPI 的庫存認證設定要求 OAuth,請用 -OAuthClientId / -OAuthClientSecret 重新執行'
    Write-Warn '  - 403 / inventory disabled     → GLPI 尚未啟用庫存 (管理 > 庫存)'
    Write-Warn '  - 404                          → SERVER_URL 路徑不對'
}

###############################################################################
Write-Step '5/5 完成'
###############################################################################
$bannerTitle = if ($agentFailed) { '⚠ Agent 已安裝,但回報到 GLPI 似乎失敗 (請看上方錯誤)' } else { '✅ GLPI Agent 安裝完成,已嘗試回報到 GLPI' }
$bannerColor = if ($agentFailed) { 'Red' } else { 'Green' }

Write-Host "`n============================================================" -ForegroundColor $bannerColor
Write-Host " $bannerTitle" -ForegroundColor $bannerColor
Write-Host '============================================================' -ForegroundColor $bannerColor
Write-Host " Agent 版本 : $versionOutput"
Write-Host " GLPI 網址  : $ServerUrl"
Write-Host ' 安裝目錄   : C:\Program Files\GLPI-Agent'
Write-Host ' 日誌       : C:\Program Files\GLPI-Agent\logs\glpi-agent.log'
Write-Host " 安裝記錄   : $LogFile"
Write-Host ''
Write-Host ' 請到 GLPI 網頁確認:'
Write-Host "  1. 「資產 > 電腦」應出現這台電腦 (主機名稱 $env:COMPUTERNAME)"
Write-Host '  2. 「管理 > 庫存」可以看到 Agent 清單'

Stop-Transcript | Out-Null
Protect-Log -Path $LogFile -Secret $OAuthClientSecret
if ($agentFailed) { exit 1 }
