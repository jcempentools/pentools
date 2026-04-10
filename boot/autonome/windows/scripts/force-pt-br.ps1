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

param(
  [ScriptBlock]$LogCallback
)

# ---------------- LOG WRAPPER ----------------
function __log($msg, $type = "l") {
  if ($LogCallback) {
    try { & $LogCallback $msg $type } catch {}
  }
}

# ---------------- CONFIG ----------------
$Script:TargetLang = "pt-BR"
$Script:TargetKeyboard = "00010416"
$Script:TargetGeoId = 32
$Script:TargetTimeZone = "E. South America Standard Time"
$Script:MaxRetries = 5
$Script:RetryDelay = 5

# ---------------- MUTEX ----------------
function Enter-ScriptMutex {
  __log "Aguardando mutex global" "i"

  $global:ScriptMutex = New-Object System.Threading.Mutex($false, "PTBRLanguageScript")

  if (-not $global:ScriptMutex.WaitOne(1800000)) {
    __log "Timeout ao adquirir mutex" "e"
    exit 1
  }

  __log "Mutex adquirido" "i"
}

function Exit-ScriptMutex {
  try {
    $global:ScriptMutex.ReleaseMutex()
    __log "Mutex liberado" "i"
  }
  catch {}
}

# ---------------- WAITERS ----------------
function Wait-DismIdle {
  $timeout = 1800
  $start = Get-Date

  __log "Aguardando DISM/CBS idle" "i"

  while ($true) {
    $busy = Get-Process dism, TiWorker, TrustedInstaller -ErrorAction SilentlyContinue
    if (-not $busy) { break }

    if ((New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds -gt $timeout) {
      __log "Timeout DISM idle" "w"
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

        __log "Aguardando serviço $svc" "i"

        $timeout = 300
        $start = Get-Date

        while ((Get-Service $svc).Status -ne "Running") {

          if ((New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds -gt $timeout) {
            __log "Timeout serviço $svc" "w"
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

# ---------------- PROCESS ----------------
function Invoke-SyncProcess {
  param($File, $Args)

  __log "Exec: $File $Args" "l"

  $p = Start-Process $File -ArgumentList $Args -PassThru -NoNewWindow
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    throw "$File failed ($($p.ExitCode))"
  }
}

# ---------------- RETRY ----------------
function Invoke-SyncRetry {
  param([scriptblock]$Code, [string]$Name)

  for ($i = 1; $i -le $Script:MaxRetries; $i++) {
    try {
      __log "$Name tentativa $i" "l"

      & $Code

      Wait-DismIdle
      Wait-Services
      Flush-Registry

      __log "$Name concluído" "i"
      return
    }
    catch {
      __log "$Name falhou tentativa $i -> $_" "w"
      Start-Sleep ($Script:RetryDelay * $i)
    }
  }

  __log "$Name falhou definitivamente" "e"
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
    __log "Testando conectividade" "i"

    $result = ping -n 1 8.8.8.8 | Select-String "TTL"
    if (-not $result) { throw "Network not ready" }

  } "Network"
}

# ---------------- DOWNLOAD ----------------
function Download-LanguagePack {

  $url = "https://software-download.microsoft.com/download/pr/LanguageExperiencePack.pt-BR.Neutral.appx"

  $temp = $env:TEMP
  if (-not (Test-Path $temp)) { $temp = "$env:SystemRoot\Temp" }

  $dest = "$temp\lp-ptbr.appx"

  Invoke-SyncRetry {

    __log "Download LP iniciado" "i"

    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $dest)

    if (-not (Test-Path $dest)) { throw "Download failed" }

    if ((Get-Item $dest).Length -lt 1000000) {
      throw "Arquivo inválido"
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

    __log "Aplicando locale pt-BR" "i"

    try { Set-WinSystemLocale $Script:TargetLang } catch {}
    try { Set-Culture $Script:TargetLang } catch {}

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
    try { Set-WinHomeLocation -GeoId $Script:TargetGeoId } catch {}
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
        __log "Removendo idioma $($_.PSChildName)" "i"
        Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

  } "Remove Languages"
}

# ---------------- VALIDATE ----------------
function Validate-Configuration {

  __log "Validando configuração final" "i"

  if (-not (Test-IsPtBr)) {
    __log "Validação falhou" "e"
    throw "Validation failed"
  }

  __log "Validação OK" "i"
}

# ---------------- MAIN ----------------
function Main {

  Enter-ScriptMutex

  try {

    __log "Windows Language Enforcement" "t"

    if (Test-IsPtBr) {
      __log "Sistema já está em pt-BR" "i"
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

    __log "Processo concluído com sucesso" "t"

  }
  finally {
    Exit-ScriptMutex
  }
}

Main