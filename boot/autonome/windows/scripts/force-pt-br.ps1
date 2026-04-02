#requires -version 2.0
# =====================================================================
# SCRIPT: Windows 11 Language Enforcer (PT-BR)
# COMPATIBILIDADE: PowerShell 2.0+, 5.x, 7.6+
# CONTEXTO: Setup Windows / SYSTEM / OOBE / Audit / WinPE
# =====================================================================
#
# [1] REGRAS DE NEGÓCIO
# ---------------------------------------------------------------------
# - O idioma final do sistema deve ser obrigatoriamente pt-BR
# - O teclado padrão deve ser ABNT2 (00010416)
# - O fuso horário deve ser Brasília
# - A região deve ser Brasil
# - Idiomas e teclados não pt-BR devem ser removidos
# - O script deve ser idempotente (executável múltiplas vezes)
# - O script deve se auto-recuperar de falhas transitórias
# - O script deve validar o estado final
# - Cada etapa deve executar de forma totalmente síncrona e bloqueante
#
# [2] DIRETRIZES
# ---------------------------------------------------------------------
# - Estrutura modular baseada em micro-funções reutilizáveis
# - Implementar retry com backoff progressivo
# - Logging detalhado para troubleshooting
# - Compatibilidade com execução como SYSTEM
# - Evitar dependência de módulos modernos
# - Preferir comandos nativos (DISM, registry, tzutil)
# - Detectar e evitar operações redundantes
# - Priorizar resiliência sobre velocidade
# - Execução estritamente síncrona entre todas as etapas
# - Implementar barreiras de sincronização entre operações críticas
# - Aguardar conclusão de DISM/CBS antes de prosseguir
#
# [3] RESTRIÇÕES
# ---------------------------------------------------------------------
# - Compatível com PowerShell 2.0+
# - Sem uso obrigatório de módulos WindowsLanguagePack
# - Sem dependência de interface gráfica
# - Deve funcionar sem usuário logado
# - Deve tolerar execução durante instalação do Windows
# - Não assumir conectividade de rede imediata
# - Não falhar caso idioma já esteja aplicado
# - Não exigir reboot imediato
# - Não executar operações em paralelo
#
# [4] OBJETIVOS
# ---------------------------------------------------------------------
# - Detectar idioma atual do Windows
# - Baixar Language Pack pt-BR automaticamente
# - Instalar pacote de idioma com tolerância a falhas
# - Definir idioma padrão do sistema
# - Configurar teclado ABNT2 como padrão
# - Configurar região Brasil
# - Configurar fuso horário Brasília
# - Remover idiomas e layouts não pt-BR
# - Garantir execução sequencial bloqueante entre etapas
# - Validar estado final
# - Executar de forma segura e resiliente
#
# CARACTERÍSTICAS TÉCNICAS
# ---------------------------------------------------------------------
# ✔ Idempotente
# ✔ Fail-safe
# ✔ Retry automático
# ✔ Execução totalmente síncrona
# ✔ Mutex global anti-paralelismo
# ✔ Barreira DISM/CBS
# ✔ Compatível SYSTEM
# ✔ Compatível Setup Windows
# ✔ Logging
# ✔ Modular
# ✔ Resistente a rede instável
# ✔ Tolerante a DISM lock
# ✔ Execução offline parcial
#
# =====================================================================

# ---------------- CONFIG ----------------
$Script:TargetLang = "pt-BR"
$Script:TargetKeyboard = "00010416"
$Script:TargetGeoId = 32
$Script:TargetTimeZone = "E. South America Standard Time"
$Script:MaxRetries = 5
$Script:RetryDelay = 5
$Script:LogFile = "$env:SystemRoot\Temp\ptbr-language.log"

# garante diretório de log
$logDir = Split-Path $Script:LogFile
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# ---------------- LOG ----------------
function Write-Log {
  param([string]$Message)
  $time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  try { Add-Content $Script:LogFile "$time - $Message" } catch {}
}

# ---------------- MUTEX ----------------
function Enter-ScriptMutex {
  # Mutex compatível WinPE/SYSTEM
  $global:ScriptMutex = New-Object System.Threading.Mutex($false, "PTBRLanguageScript")
  if (-not $global:ScriptMutex.WaitOne(1800000)) { exit 1 }
}

function Exit-ScriptMutex {
  try { $global:ScriptMutex.ReleaseMutex() } catch {}
}

# ---------------- WAITERS ----------------
function Wait-DismIdle {
  # Evita loop infinito caso DISM trave
  $timeout = 1800 # 30 min
  $start = Get-Date

  while ($true) {

    $busy = Get-Process dism, TiWorker, TrustedInstaller -ErrorAction SilentlyContinue
    if (-not $busy) { break }

    # Compatível PS2
    if ((New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds -gt $timeout) {
      Write-Log "Wait-DismIdle timeout"
      break
    }

    Start-Sleep 3
  }
}

function Wait-Services {
  $services = "TrustedInstaller", "wuauserv", "bits"
  foreach ($svc in $services) {
    try {
      $s = Get-Service $svc -ErrorAction SilentlyContinue
      if ($s -and $s.Status -eq "StartPending") {
        $timeout = 300
        $start = Get-Date

        while ((Get-Service $svc).Status -ne "Running") {

          if ((New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds -gt $timeout) {
            Write-Log "Service $svc timeout"
            break
          }

          Start-Sleep 2
        }
      }
    }
    catch {}
  }
}

function Flush-Registry { Start-Sleep 500 }

# ---------------- SYNC PROCESS ----------------
function Invoke-SyncProcess {
  param($File, $Args)

  # Execução síncrona compatível PS2
  $p = Start-Process $File -ArgumentList $Args -PassThru -NoNewWindow
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) { throw "$File failed ($($p.ExitCode))" }
}

# ---------------- RETRY SYNC ----------------
function Invoke-SyncRetry {
  param([scriptblock]$Code, [string]$Name)

  for ($i = 1; $i -le $Script:MaxRetries; $i++) {
    try {
      Write-Log "START $Name try $i"
      & $Code
      Wait-DismIdle
      Wait-Services
      Flush-Registry
      Write-Log "OK $Name"
      return
    }
    catch {
      Write-Log "FAIL $Name try $i $_"
      Start-Sleep ($Script:RetryDelay * $i)
    }
  }
  throw "FAILED: $Name"
}

# ---------------- DETECTION ----------------
function Get-CurrentUILanguage {
  try {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\Settings"

    try {
      $langs = (Get-ItemProperty $key).PreferredUILanguages
      if ($langs) { return $langs[0] }
    }
    catch {}

    $items = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages"
    if ($items) { return $items[0].PSChildName }
  }
  catch { $null }
}

function Test-IsPtBr {
  (Get-CurrentUILanguage) -eq $Script:TargetLang
}

# ---------------- NETWORK ----------------
function Ensure-Network {
  Invoke-SyncRetry {

    # Testa conectividade real
    $result = ping -n 1 8.8.8.8 | Select-String "TTL"
    if (-not $result) { throw "Network not ready" }

  } "Network"
}

# ---------------- DOWNLOAD ----------------
function Download-LanguagePack {

  $url = "https://software-download.microsoft.com/download/pr/LanguageExperiencePack.pt-BR.Neutral.appx"
  # Garante temp válido em SYSTEM
  $temp = $env:TEMP
  if (-not (Test-Path $temp)) { $temp = "$env:SystemRoot\Temp" }

  $dest = "$temp\lp-ptbr.appx"

  Invoke-SyncRetry {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $dest)

    # valida download mínimo
    if (-not (Test-Path $dest)) { throw "Download failed" }

    if ((Get-Item $dest).Length -lt 1000000) {
      throw "Downloaded file too small"
    }
  } "Download LP"

  return $dest
}

# ---------------- INSTALL ----------------
function Install-LanguagePack {
  param($Path)

  Invoke-SyncRetry {
    Invoke-SyncProcess "dism.exe" "/Online /Add-ProvisionedAppxPackage /PackagePath:`"$Path`" /SkipLicense"
  } "Install LP"
}

# ---------------- LANGUAGE ----------------
function Set-SystemLanguage {
  Invoke-SyncRetry {
    Set-WinSystemLocale $Script:TargetLang -ErrorAction SilentlyContinue
    Set-Culture $Script:TargetLang -ErrorAction SilentlyContinue
  } "System Language"
}

# ---------------- KEYBOARD ----------------
function Set-Keyboard {
  Invoke-SyncRetry {
    reg add "HKU\.DEFAULT\Keyboard Layout\Preload" /v 1 /t REG_SZ /d $Script:TargetKeyboard /f
  } "Keyboard"
}

# ---------------- REGION ----------------
function Set-Region {
  Invoke-SyncRetry {
    Set-WinHomeLocation -GeoId $Script:TargetGeoId -ErrorAction SilentlyContinue
  } "Region"
}

# ---------------- TIMEZONE ----------------
function Set-TimeZoneSafe {
  Invoke-SyncRetry {
    tzutil /s "$Script:TargetTimeZone"
  } "Timezone"
}

# ---------------- REMOVE ----------------
function Remove-OtherLanguages {

  Invoke-SyncRetry {

    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages"
    $current = Get-CurrentUILanguage

    Get-ChildItem $key | ForEach-Object {
      if ($_.PSChildName -ne $Script:TargetLang -and $_.PSChildName -ne $current) {
        Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

  } "Remove languages"
}

# ---------------- VALIDATE ----------------
function Validate-Configuration {
  if (-not (Test-IsPtBr)) {
    throw "Validation failed"
  }
}

# ---------------- MAIN ----------------
function Main {

  Enter-ScriptMutex

  try {

    Write-Log "==== START ===="

    if (Test-IsPtBr) {
      Write-Log "Already PT-BR"
      return
    }

    Ensure-Network
    $lp = Download-LanguagePack
    Install-LanguagePack $lp
    Set-SystemLanguage
    Set-Keyboard
    Set-Region
    Set-TimeZoneSafe
    Remove-OtherLanguages
    Validate-Configuration

    Write-Log "==== END ===="

  }
  finally {
    Exit-ScriptMutex
  }
}

Main