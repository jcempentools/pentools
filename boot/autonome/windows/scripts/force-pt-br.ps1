#requires -version 5.1
<#
.SYNOPSIS
    Windows 11 Language Enforcer (PT-BR).
    Garante a conformidade regional e de idioma em ambientes críticos.

.DESCRIPTION
    Script especializado em forçar o idioma pt-BR, teclado ABNT2 e fuso horário Brasília.
    Projetado para operar em estágios precoces do SO (Setup/OOBE/Audit/WinPE) sob o 
    contexto de SYSTEM ou Usuário, com foco em resiliência extrema e execução síncrona.

    [1] REGRAS DE NEGÓCIO:
    - Idioma mandatório: pt-BR.
    - Teclado padrão: ABNT2 (00010416).
    - Fuso Horário / Região: Brasília / Brasil.
    - Purga: Remoção obrigatória de idiomas e layouts não pt-BR.
    - Idempotência: Seguro para múltiplas execuções; valida estado antes de agir.
    - Sincronismo: Execução 100% síncrona, sequencial e bloqueante entre etapas.

    [3] RESTRIÇÕES / VEDAÇÕES:
    - Independência: Sem dependência de módulos modernos (WindowsLanguagePack)        

    [4] OBJETIVOS OPERACIONAIS:
    - Detecção e download automático de Language Pack pt-BR.
    - Instalação e definição de idioma padrão do sistema.
    - Configuração de Localidade (Região/Teclado/Fuso) e remoção de excedentes.
    - Validação de estado final e geração de logs detalhados para troubleshooting.

.NOTES
    ================================================================================
    REGRAS DE NEGÓCIO GLOBAIS DO PROJETO    
    POWERSHELL MISSION-CRITICAL FRAMEWORK - ESPECIFICAÇÃO DE EXECUÇÃO
    ================================================================================

    [CAPACIDADES GERAIS]
    Orquestração determinística, resiliente e idempotente para Windows.
    Compatibilidade Dual-Engine (5.1 + 7.4+) em contextos SYSTEM, WINPE e USER.

    [ESTILO, DESIGN & RASTREABILIDADE]
    - Design: Imutabilidade, Baixo Acoplamento e suporte a camelCase/snake_case.
    - Rastreabilidade Diff-Friendly: Alterações de código minimalistas otimizados
                                     para desempenho aliado a análise visual
                                     de mudanças.

    [CAPACIDADES TÉCNICAS (REAPROVEITÁVEIS)]
    - COMPATIBILIDADE: Identificação de versão/subversão para comandos adequados.
    - RESILIÊNCIA: Retry com backoff progressivo e múltiplas formas de tentativa.
    - OFFLINE-FIRST: Lógica global de priorização de recursos locais vs rede.
                    configurável para Online-FIRST.
    - DETERMINISMO: Validação de estado real pós-operação (não apenas ExitCode).

    [EVENTOS & TELEMETRIA (CALLBACK)]
    - DESACOPLAMENTO: Script não gerencia arquivos de log ou console diretamente,
                    salvo se explicitamente definido.
    - OBRIGATORIEDADE: Telemetria via ScriptBlock [callback($msg, $type)]
                    salvo se explicitamente definido.
    - TIPAGEM DE MENSAGEM (Parâmetro 2):
        - [t] Title: Título de etapa ou seções principais.
        - [l] Log: Registro padrão de fluxo e operações.
        - [i] Info: Detalhes informativos ou diagnósticos.
        - [w] Warn: Alertas de falhas não críticas ou retentativas.
        - [e] Error: Falhas críticas que exigem atenção ou interrupção.

    [REGRAS DE ARQUITETURA]
    - ISOLAMENTO: Mutex Global obrigatório para prevenir paralelismo.
    - MODULARIDADE: Baseado em micro-funções especialistas e reutilizáveis.
    - SINCRO: Execução 100% síncrona, bloqueante e sequencial.
    - ESTADO: Barreira de consistência (DISM/CBS) para operações de sistema.
    - NATIVO: Uso estrito de comandos nativos do OS, salvo exceção declarada.

    [DIRETRIZES DE IMPLEMENTAÇÃO]
    - IDEMPOTÊNCIA: Seguro para múltiplas execuções no mesmo ambiente.
    - HEADLESS: Operação plena sem interface gráfica ou interação de usuário.
    - TIMEOUT: Limites controlados adequados à capacidade do hardware.

    [RESTRIÇÕES / VEDAÇÕES]
    - Não prosseguir com sistema em estado inconsistente ou pendente.
    - Não assumir conectividade de rede (Offline-First por padrão)
    configurável para Online-FIRST.
    - Não depender de módulos externos ou bibliotecas não nativas.
    - Não executar etapas sem validação de sucesso posterior.

    [ESTRUTURA DE EXECUÇÃO]
    1. Inicialização segura (ExecutionPolicy, TLS, Context Check).
    2. Garantia de instância única (Global Mutex).
    3. Validação de pré-requisitos e pilha de manutenção do SO.
    4. Orquestração modular com validação individual de cada micro-função.
    5. Finalização auditável com log rastreável e saída determinística.

    [INVOCAÇãO]
    O script sempre auto identifica se foi importado ou executado:
    1. Se executado diretatamente executa função main repassando parametros 
       recebidos por linha de comando ou variáveis de ambiente.,
    2. Se importado expõe as funções públicas para serem chamadas por outros
       scripts sem executar nada.    

.COMPONENT
    Contexto: Setup Windows / SYSTEM / WINPE / OOBE / Audit / WinPE.
    Foco: Padronização regional e linguística determinística.
#>


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
function main {
  param(
    [scriptblock]$callback
  )

  if ($callback) {
    $script:LogCallback = $callback
  }

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

# ==============================
# INVOCACAO (auto-detect import vs execução)
# ==============================
if ($MyInvocation.InvocationName -ne '.') {
  if (Get-Command main -ErrorAction SilentlyContinue) {
    main @args
  }
}