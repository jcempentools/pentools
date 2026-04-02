<#
===============================================================================
AUTONOME INSTALL SCRIPT — SPEC HEADER
===============================================================================

[OBJETIVO]
Provisionamento automatizado, resiliente e idempotente de ambiente Windows,
com suporte offline-first e fallback online, executável em contexto USER ou SYSTEM.

-------------------------------------------------------------------------------
[REGRAS DE NEGÓCIO]
- Execução determinística, sequencial e bloqueante (sync-first).
- Cada etapa deve validar seu próprio sucesso antes de prosseguir.
- Estado final deve ser verificável (confirmação real, não apenas exit code).
- Operações devem ser idempotentes (seguro reexecutar múltiplas vezes).
- Preferência absoluta por fontes offline → fallback online quando necessário.
- Instalações devem evitar duplicidade (checklist + detecção real).
- Execução tolerante a falhas transitórias (retry obrigatório).
- Compatível com ambiente sem interface gráfica (headless).

-------------------------------------------------------------------------------
[DIRETRIZES]
- Priorizar RESILIÊNCIA > VELOCIDADE.
- Preferir comandos nativos do Windows (cmd, msiexec, pnputil, robocopy).
- Evitar dependência de módulos externos ou modernos.
- Compatível com PowerShell 2.0+ (bootstrap) e execução plena em PS 7.6+.
- Suporte completo a execução como SYSTEM.
- Código deve ser modular (micro-funções reutilizáveis).
- Evitar lógica duplicada (centralizar comportamento em funções).
- Logging deve ser detalhado e persistente em arquivo.
- Toda operação crítica deve possuir fallback.

-------------------------------------------------------------------------------
[RESTRIÇÕES / VEDAÇÕES]
- ❌ Não executar operações assíncronas (exceto instalação de drivers).
- ❌ Não depender de interface gráfica.
- ❌ Não confiar apenas em ExitCode como validação.
- ❌ Não assumir conectividade de rede.
- ❌ Não usar módulos PowerShell externos.
- ❌ Não executar etapas sem validação posterior.
- ❌ Não permitir execução paralela (mutex obrigatório).
- ❌ Não prosseguir com sistema em estado inconsistente (DISM/CBS ativo).

-------------------------------------------------------------------------------
[MODUS OPERANDI]
1. Inicialização segura (ExecutionPolicy, TLS, contexto).
2. Garantia de ambiente (logs, diretórios, mutex global).
3. Prevenção de interferência externa (shutdown/sleep).
4. Upgrade/control de runtime (PS7 fallback).
5. Descoberta de origem offline (pendrive/cache).
6. Preparação de cache local (robocopy incremental).
7. Execução de tarefas base:
   - drivers (assíncrono controlado)
   - regionalização
   - wallpapers
8. Preparação e validação do winget.
9. Instalação de aplicações:
   - offline (prioritário)
   - online (fallback)
10. Execução de hooks finais (scripts externos).
11. Validação global.
12. Finalização segura (log + reboot controlado).

-------------------------------------------------------------------------------
[ETAPAS OBRIGATÓRIAS]
- Todas as etapas devem:
  - ser síncronas e bloqueantes
  - possuir retry com backoff progressivo
  - validar resultado antes de continuar
  - registrar log detalhado

EXCEÇÃO:
- Instalação de drivers pode ser assíncrona (background controlado),
  mas extração/preparação deve ser síncrona.

-------------------------------------------------------------------------------
[CARACTERÍSTICAS TÉCNICAS]
- Mutex global anti-paralelismo (uma execução por máquina).
- Barreira DISM/CBS: aguardar ausência de operações pendentes.
- Retry automático com backoff progressivo.
- Timeout controlado para operações críticas.
- Logging estruturado em diretório por execução.
- Execução compatível com:
  - Windows Setup
  - First Logon
  - RunOnce
  - SYSTEM context
- Cache local persistente (TEMP controlado + registry).
- Detecção inteligente de instaladores (offline matching).
- Suporte a include recursivo em listas (.lst).
- Sistema de hooks (scripts externos extensíveis).

-------------------------------------------------------------------------------
[ESTILO DE IMPLEMENTAÇÃO]
- Funções pequenas, específicas e reutilizáveis.
- Nomeação consistente e descritiva.
- Evitar side-effects implícitos.
- Evitar hardcode desnecessário.
- Centralizar lógica crítica (download, execução, validação).
- Logs devem ser humanos + machine-readable.
- Código deve ser autoexplicativo (baixo acoplamento).

-------------------------------------------------------------------------------
[FAIL-SAFE / RESILIÊNCIA]
- Falhas não críticas → log + continuar.
- Falhas críticas → retry → fallback → log → abort seguro.
- Downloads devem validar:
  - existência
  - tamanho mínimo
  - conteúdo (evitar HTML inválido)
- Execuções devem ter fallback:
  - PowerShell → CMD → PowerShell 7
- Sistema deve se auto-recuperar de:
  - falhas de rede
  - corrupção parcial
  - execuções interrompidas

-------------------------------------------------------------------------------
[HOOKS / EXTENSIBILIDADE]
- Suporte a scripts externos:
  - .ps1 / .cmd / .bat / .reg
- Execução ordenada e validada.
- Nome baseado em contexto (ex: in.system, in.useronce).
- Totalmente opcional e desacoplado.

-------------------------------------------------------------------------------
[LOGGING]
- Transcript global + logs individuais por operação.
- Logs devem conter:
  - timestamp
  - comando executado
  - resultado (exit + validação)
- Logs persistentes em:
  %SystemDrive%\autonome-install-LOG\

-------------------------------------------------------------------------------
[COMPATIBILIDADE]
- PowerShell 2.0+ (bootstrap obrigatório)
- PowerShell 7.6+ (execução preferencial)
- Windows 10/11
- Windows Setup / WinPE parcial
- Execução como SYSTEM e USER

-------------------------------------------------------------------------------
[RESUMO OPERACIONAL]
SCRIPT = ORQUESTRADOR RESILIENTE, OFFLINE-FIRST, IDEMPOTENTE
FOCO = CONFIABILIDADE, RECUPERAÇÃO E EXECUÇÃO DETERMINÍSTICA

===============================================================================
#>
Param(
  [string]$is_test
)
$script:__ps7_fallback_used = $false
$path_log = "$env:SystemDrive\autonome-install-LOG"
$pwsh_msi_path = "$env:SystemDrive\pwsh_install.msi"
# $pendrive_autonome_checker: exigido exiência de `unidade:/.pentools/.pentools`
# ou `unidade:/boot/.pentools` para ser válido
$pendrive_autonome_checker = ".pentools"
$pendrive_autonome_root = "boot\autonome"
# instalações dentro da pasta /apps em windows:
$TMP_DIR_NAME = "TMP_JCEM_AutonomeInstall_PS1"
$pendrive_autonome_path = "$pendrive_autonome_root\windows"
$image_folder = "$env:SystemDrive\Users\Default\Pictures"
$pendrive_script_name = "run.ps1"
$url_pwsh = "github.com/PowerShell/PowerShell/releases/download/v7.6.0/PowerShell-7.6.0-win-x64.msi"
$path_params_map = "$pendrive_autonome_path\params-map"
$url_params_map = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$path_params_map".Replace("\", "/")
$url_WallPapers_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/WallPaper.lst".Replace("\", "/")
$url_apps_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/windows".Replace("\", "/")
$url_lockscreen = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/lockscreen.lst".Replace("\", "/")
$url_defWallPaper = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/default.lst".Replace("\", "/")
$appsinstall_folder = "" # manter vazio
$autonome_scripts = "scripts"
$autonome_hooks = "$autonome_scripts/hooks";
$apps_list_dir = "apps-list"
$script:winget_timeout = "" # BUG: manter isso vazio
Write-Host " "
# modo full
# Normaliza a variável: remove espaços e converte para minúsculo
switch ($($Env:install_mode).Trim().ToLower()) {
  "essenciais" { $___file_apps = "essenciais.lst" }
  "basico" { $___file_apps = "basico.lst" }
  "designer" { $___file_apps = "designer.lst" }
  "designer+" { $___file_apps = "designer.plus.lst" }
  "gamer" { $___file_apps = "gamer.lst" }
  "gamer+" { $___file_apps = "gamer.plus.lst" }
  "gamer++" { $___file_apps = "gamer.plus.plus.lst" }
  "dev" { $___file_apps = "dev.lst" }
  "dev+" { $___file_apps = "dev.plus.lst" }
  "dev++" { $___file_apps = "dev.plus.plus.lst" }
  "full" { $___file_apps = "full.lst" }
  default { $___file_apps = $null } # Caso não combine com nenhum
}

# Atualiza a URL apenas se uma correspondência válida foi encontrada
if ($___file_apps) {
  $url_apps_lst = "$url_apps_lst/$apps_list_dir/$___file_apps"
}
try {
  $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
  $in_system_context = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::System)
}
catch {
  # fallback extremamente seguro
  $in_system_context = ($env:USERNAME -eq "SYSTEM" -or $env:USERDOMAIN -eq "NT AUTHORITY")
}
if (-Not ([string]::IsNullOrEmpty($is_test))) {
  $Env:autonome_test = "1"
}
$script:is_test_mode = -not [string]::IsNullOrEmpty($Env:autonome_test)
if (-not $in_system_context) {
  $image_folder = "$env:SystemDrive\Users\${env:USERNAME}\Pictures"
}
try {
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
}
catch {
  show_warn "Falha ao setar ExecutionPolicy (GPO?). Continuando sem alteração."
}

try {
  [Net.ServicePointManager]::SecurityProtocol =
  [Net.SecurityProtocolType]::Tls12 `
    -bor [Net.SecurityProtocolType]::Tls11 `
    -bor [Net.SecurityProtocolType]::Tls
}
catch {}

if (-Not (Test-Path -Path $path_log)) {
  New-Item -Path $path_log -Force -ItemType Directory | Out-Null
}

# CONTEXTO
$local_exec = if (-not [string]::IsNullOrEmpty($Env:LOCAL_EXEC)) {
  $Env:LOCAL_EXEC.ToLower()
}
else {
  if ($in_system_context) { "system" } else { "useronce" }
}

$mode = $local_exec.ToUpper()

# ID incremental baseado em diretórios existentes
$dirs = Get-ChildItem -Path $path_log -Directory -ErrorAction SilentlyContinue
$id = 1
while (Test-Path (Join-Path $path_log "$id-*")) {
  $id++
}

# DATA
$now = Get-Date
$mm = $now.ToString("MM")
$dd = $now.ToString("dd")
$hhmm = $now.ToString("HHmm")

# NOME FINAL
$run_name = "$id-$mm$dd-$hhmm-$mode"
$script:run_log_dir = Join-Path $path_log $run_name

# GARANTE DIRETÓRIOS
New-Item -Path $script:run_log_dir -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $script:run_log_dir "apps") -ItemType Directory -Force | Out-Null

try {
  $name_install_log = $env:USERNAME
  if ([string]::IsNullOrEmpty($name_install_log)) {
    $name_install_log = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Replace("\", "-")
  }

  $transcript_file = Join-Path $script:run_log_dir "auto-install.log"
  Start-Transcript -Append -Path $transcript_file
}
catch {}
Write-Host "-------------------------------------------------" -BackgroundColor blue
Write-Host "             Não Feche esta janela               " -BackgroundColor blue
Write-Host "-------------------------------------------------" -BackgroundColor blue
Write-Host ""
Write-Host "Instalação crua.......: '$Env:install_mode'"
write-host "Em modo teste.........: '$Env:autonome_test'"
write-host "Em contexto de sistema: '$in_system_context'"
write-host "Usuário atual.........: '$name_install_log'"
Write-Host ""
write-host "..."
Start-Sleep -Seconds 1
if (-not $in_system_context) {
  if ([string]::IsNullOrEmpty($Env:autonome_test)) {
    try {
      Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force
      Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    catch {
      show_log "falha ao encerar explorer.exe / msedge.exe"
    }
  }
}
<#
.SYNOPSIS
Exibe um título destacado no console.

.DESCRIPTION
Imprime uma mensagem formatada com fundo colorido e separadores
para indicar início de seção no log visual.

.PARAMETER str_menssagem
Texto a ser exibido como título.
#>
function show_log_title {
  param(
    [string]$str_menssagem
  )
  write-host ""
  write-host ""
  write-host "################################################" -BackgroundColor DarkCyan
  write-host "#### $str_menssagem" -BackgroundColor DarkCyan
  write-host "################################################" -BackgroundColor DarkCyan
  write-host ""
  write-host ""
}
<#
.SYNOPSIS
Exibe mensagem de erro.

.DESCRIPTION
Imprime mensagem formatada com destaque em vermelho
indicando erro no fluxo de execução.

.PARAMETER str_menssagem
Mensagem de erro a ser exibida.
#>
function show_error {
  param(
    [string]$str_menssagem
  )
  Write-Host "[ERROR]:" -BackgroundColor Red
  Write-Host "[ERROR]: $str_menssagem" -BackgroundColor Red
}
<#
.SYNOPSIS
Exibe mensagem de log padrão.

.DESCRIPTION
Imprime mensagem informativa com formatação neutra
para acompanhamento do fluxo de execução.

.PARAMETER str_menssagem
Mensagem a ser exibida.
#>
function show_log {
  param(
    [string]$str_menssagem
  )
  Write-Host "---> $str_menssagem" -BackgroundColor DarkGray
}
<#
.SYNOPSIS
Exibe comando a ser executado.

.DESCRIPTION
Imprime o comando com separadores visuais
para facilitar rastreamento de execução.

.PARAMETER str_menssagem
Comando ou texto a ser exibido.
#>
function show_cmd {
  param(
    [string]$str_menssagem
  )
  Write-Host ""
  Write-Host "---------------------------------------------"
  Write-Host "$str_menssagem" -BackgroundColor Cyan -ForegroundColor Black
  Write-Host "---------------------------------------------"
}
<#
.SYNOPSIS
Exibe mensagem de aviso.

.DESCRIPTION
Imprime mensagem formatada com destaque amarelo
indicando condição não crítica.

.PARAMETER str_menssagem
Mensagem de aviso.
#>
function show_warn {
  param(
    [string]$str_menssagem
  )
  Write-Host "[WARN] " -BackgroundColor Yellow -ForegroundColor Black
  Write-Host "[WARN]: $str_menssagem" -BackgroundColor Yellow -ForegroundColor Black
}
<#
.SYNOPSIS
Exibe mensagem informativa.

.DESCRIPTION
Imprime mensagem com destaque leve
para observações não críticas.

.PARAMETER str_menssagem
Texto a ser exibido.
#>
function show_nota {
  param(
    [string]$str_menssagem
  )
  Write-Host "[NOTA]: $str_menssagem" -BackgroundColor Gray -ForegroundColor Black
}
rand_name
<#
.SYNOPSIS
Gera string aleatória.

.DESCRIPTION
Retorna string com caracteres alfabéticos aleatórios
com tamanho configurável.

.PARAMETER num
Tamanho da string gerada. Default: 18.

.OUTPUTS
String aleatória.
#>
function rand_name {
  param(
    [AllowNull()][int]$num
  )  
  if (-not $num -or $num -le 0) {
    $num = 18
  }
  return -join ((65..90) + (97..122) | Get-Random -Count $num | ForEach-Object { [char]$_ })
}
<#
.SYNOPSIS
Resolve argumentos silenciosos de instalador.

.DESCRIPTION
Busca parâmetros de instalação em mapa local, online
ou utiliza heurística para determinar switches silenciosos.

.PARAMETER filePath
Caminho do instalador.

.PARAMETER type
Tipo do instalador (exe ou msi).

.OUTPUTS
String com argumentos de instalação.
#>
function Resolve-InstallerArgs {
  param(
    [string]$filePath,
    [string]$type # exe | msi
  )

  $fileName = [System.IO.Path]::GetFileName($filePath).ToLower()
  $mapFileName = "$fileName.json"

  # caminhos locais (PRIORIDADE MÁXIMA)
  $local_paths = @(
    (Join-Path $script:appsinstall_folder "$path_params_map\$mapFileName"),
    (Join-Path $script:run_log_dir "$path_params_map\$mapFileName"),
    (Join-Path $script:run_log_dir "$mapFileName")
  )

  # 1. LOCAL FIRST
  foreach ($p in $local_paths) {
    if (Test-Path $p) {
      try {
        $json = Get-Content $p -Raw | ConvertFrom-Json
        if ($json.args) {
          show_log "Args via mapa LOCAL: $($json.args)"
          return $json.args
        }
      }
      catch {
        show_warn "Falha ao ler mapa local '$p'"
      }
    }
  }

  # 2. ONLINE (fallback)
  $remote = "$url_params_map/$mapFileName"
  $tmp = Join-Path $script:run_log_dir "$mapFileName"

  try {
    $dl = download_save $remote $tmp
    if (-not [string]::IsNullOrEmpty($dl) -and (Test-Path $tmp)) {
      $json = Get-Content $tmp -Raw | ConvertFrom-Json
      if ($json.args) {
        show_log "Args via mapa ONLINE: $($json.args)"
        return $json.args
      }
    }
  }
  catch {
    show_warn "Falha ao obter mapa online"
  }

  # 3. HEURÍSTICA (último fallback)
  if ($type -eq "exe") {
    $candidates = @("/verysilent", "/silent", "/S", "/quiet", "/qn")

    foreach ($arg in $candidates) {
      try {
        $proc = Start-Process -FilePath $filePath `
          -ArgumentList "$arg" `
          -PassThru `
          -WindowStyle Hidden `
          -ErrorAction SilentlyContinue

        Start-Sleep -Seconds 2

        if (-not $proc.HasExited) {
          try { $proc.Kill() } catch {}
          show_log "Heurística detectou suporte a '$arg'"
          return $arg
        }
      }
      catch {}
    }
  }

  if ($type -eq "msi") {
    return "/qn"
  }

  return ""
}
<#
.SYNOPSIS
Define valor em chave de registro.

.DESCRIPTION
Cria a chave caso não exista e define o valor informado.

.PARAMETER regKey
Caminho da chave.

.PARAMETER keyName
Nome do valor.

.PARAMETER value
Valor a ser atribuído.
#>
function setrgkey() {
  Param(
    [string]$regKey,
    [string]$keyName,
    $value
  )
  # create the key if it doesn't already exist
  if (!(Test-Path -Path $regKey)) {
    New-Item -Path $regKey
  }
  Set-ItemProperty -Path $regKey -Name $keyName -Value $value -Force
}
<#
.SYNOPSIS
Calcula hash SHA256.

.DESCRIPTION
Gera hash SHA256 a partir de string informada.

.PARAMETER ClearString
Texto a ser convertido.

.OUTPUTS
String com hash SHA256.
#>
function sha256 {
  Param (
    [Parameter(Mandatory = $true)]
    [string] $ClearString
  )
  $hasher = [System.Security.Cryptography.HashAlgorithm]::Create('sha256')
  $hash = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ClearString))
  $hashString = [System.BitConverter]::ToString($hash)
  return $hashString.trim().Replace('-', '')
}
<#
.SYNOPSIS
Instala aplicativos de lista.

.DESCRIPTION
Resolve conteúdo da lista e executa instalação
para cada item único.

.PARAMETER listPath
Caminho da lista.
#>
function Install-AppList {
  param([string]$listPath)

  if ([string]::IsNullOrEmpty($listPath)) {
    show_warn "Lista vazia."
    return
  }

  $resolvedList = Resolve-AppListContent $listPath
  $resolvedList = $resolvedList | Select-Object -Unique

  foreach ($line in $resolvedList) {
    isowin_install_app $line.Trim()
  }
}
<#
.SYNOPSIS
Baixa arquivo.

.DESCRIPTION
Realiza download com múltiplos fallbacks e validação
de integridade do arquivo.

.PARAMETER url
URL do arquivo.

.PARAMETER dest
Destino local.

.OUTPUTS
Caminho do arquivo baixado ou vazio.
#>
function download_save() {
  param(
    [string]$url,
    [string]$dest
  )
  if ([string]::IsNullOrEmpty($url)) {
    show_log "URL vazia '$url'."
    return ""
  }
  $url = $url.trim()
  if ($url -notmatch '^https?://') {
    $url = "https://$url"
  }

  if ($url -notmatch '^https://') {
    show_warn "URL não segura (não HTTPS): $url"
  }
  $destDir = Split-Path -Path $dest -Parent

  if (-Not (Test-Path $destDir)) {
    try {
      New-Item -Path $destDir -ItemType Directory -Force | Out-Null
    }
    catch {
      show_error "Falha ao criar diretório '$destDir'"
      return ""
    }
  }

  if (-Not (Test-Path "$dest")) {
    show_log "Baixando URL..."
    show_cmd "Invoke-WebRequest '$url' -OutFile '$dest'"
    try {
      $max = 3
      $ok = $false

      for ($i = 1; $i -le $max; $i++) {
        try {
          try {
            Invoke-WebRequest "$url" -OutFile "$dest" -TimeoutSec 30 -ErrorAction Stop
          }
          catch {
            show_warn "Invoke-WebRequest falhou, tentando fallback WebClient..."

            try {
              $wc = New-Object System.Net.WebClient
              $wc.DownloadFile($url, $dest)
            }
            catch {
              show_warn "WebClient falhou, tentando BITS..."
              try {
                Start-BitsTransfer -Source $url -Destination $dest -ErrorAction Stop
              }
              catch {
                throw
              }
            }
          }

          if (Test-Path "$dest") {
            $ok = $true
            break
          }
        }
        catch {
          show_warn "Tentativa $i falhou para '$url'"
          Start-Sleep -Seconds 2
        }
      }

      if ($ok -and (Test-Path "$dest")) {

        $file = Get-Item "$dest"
        $size = $file.Length

        if ($size -le 0) {
          Remove-Item "$dest" -Force -ErrorAction SilentlyContinue
          show_error "Arquivo inválido (0 bytes)"
          return ""
        }

        # valida HTML (erro comum de download)
        try {
          $head = Get-Content "$dest" -TotalCount 5 -ErrorAction SilentlyContinue | Out-String
          if ($head -match '<html|<!DOCTYPE') {
            Remove-Item "$dest" -Force -ErrorAction SilentlyContinue
            show_error "Download inválido (HTML retornado)"
            return ""
          }
        }
        catch {}

        show_log "Download válido ($size bytes)"
      }
      else {
        show_error "Falha ao baixar após $max tentativas"
      }      
    }
    catch {
      show_error "Falha ao baixar arquivo"
    }
  }
  else {
    show_log "Arquivo já existente '$dest'"
  }

  if (Test-Path "$dest") {
    try {
      $file = Get-Item "$dest"
      if ($file.Length -gt 1024) {
        return $dest
      }
      else {
        show_warn "Arquivo muito pequeno, possível falha de download"
        Remove-Item "$dest" -Force -ErrorAction SilentlyContinue
      }
    }
    catch {}
  }
  return ""
}
<#
.SYNOPSIS
Escreve log de drivers.

.DESCRIPTION
Adiciona mensagem timestamp no log dedicado de drivers.

.PARAMETER msg
Mensagem a registrar.
#>
function write_driver_log {
  param([string]$msg)

  try {
    $log = Join-Path $path_log "drivers.log"
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $log -Value "[$ts] $msg"
  }
  catch {}
}
<#
.SYNOPSIS
Baixa conteúdo como string.

.DESCRIPTION
Realiza download de conteúdo textual com retry.

.PARAMETER url
URL do conteúdo.

.OUTPUTS
String com conteúdo baixado.
#>
function download_to_string() {
  param(
    [string]$url
  )

  try {
    if ([string]::IsNullOrEmpty($url)) {
      show_log "URL vazia."
      return ""
    }

    $max = 3

    for ($i = 1; $i -le $max; $i++) {
      try {
        if ($url -notmatch '^https?://') {
          $url = "https://$url"
        }

        if ($url -notmatch '^https://') {
          show_warn "URL não segura (não HTTPS): $url"
        }

        $resp = Invoke-WebRequest $url -TimeoutSec 30 -ErrorAction Stop

        if ($resp.StatusCode -eq 200 -and $resp.Content.Length -gt 5) {
          $content = [string]$resp.Content.Trim()
          if ($content -match '<html|<!DOCTYPE') {
            show_warn "Conteúdo inválido (HTML retornado)"
            return ""
          }
          return $content
        }
      }
      catch {
        show_warn "Tentativa $i falhou ao baixar conteúdo"
        Start-Sleep -Seconds 2
      }
    }

    show_error "Falha ao baixar conteúdo após $max tentativas"
    return ""
  }
  catch {
    show_error "Falha ao baixar conteúdo de '$url'"
    return ""
  }
}
<#
.SYNOPSIS
Resolve listas com includes.

.DESCRIPTION
Expande arquivos .lst com suporte a includes
recursivos e proteção contra loops.

.PARAMETER filePath
Caminho da lista.

.PARAMETER visited
Controle interno de loops.

.PARAMETER depth
Profundidade de recursão.

.OUTPUTS
Lista expandida.
#>
function Resolve-AppListContent {
  param(
    [string]$filePath,
    [hashtable]$visited = $( @{} ),
    [int]$depth = 0
  )

  $MAX_DEPTH = 10

  if ($depth -gt $MAX_DEPTH) {
    show_warn "Profundidade máxima de includes atingida ($MAX_DEPTH): $filePath"
    return @()
  }

  function __normKey($p) {
    if ($p -match '^https?://') {
      return $p.Trim().ToLower()
    }
    try {
      return (Resolve-Path $p).Path.ToLower()
    }
    catch {
      return $p.ToLower()
    }
  }

  $result = @()
  $isRemote = $filePath -match '^https?://'

  if (-not $isRemote -and -not (Test-Path $filePath)) {
    show_warn "Lista não encontrada: $filePath"
    return @()
  }

  $realPath = if ($isRemote) { $filePath } else { (Resolve-Path $filePath).Path }
  $key = __normKey $realPath

  if ($visited.ContainsKey($key)) {
    show_warn "Loop detectado em include: $realPath"
    return @()
  }

  $visited[$key] = $true

  # leitura
  $lines = @()

  if ($isRemote) {
    $content = download_to_string $realPath
    if ([string]::IsNullOrEmpty($content)) {
      show_warn "Falha ao baixar lista remota: $realPath"
      return @()
    }
    $lines = $content -split "`n"
  }
  else {
    $lines = Get-Content $realPath
  }

  foreach ($line in $lines) {

    $line = $line.Trim()

    if (
      [string]::IsNullOrEmpty($line) -or
      ($line -match '^\s*$') -or
      ($line -match '^\s*#')
    ) {
      continue
    }

    # ==============================
    # INCLUDE (@...)
    # ==============================
    if ($line -match '^\s*@') {

      $includeName = ($line -replace '^\s*@', '').Trim()

      if (-not $includeName.EndsWith(".lst")) {
        $includeName = "$includeName.lst"
      }

      if ($isRemote) {
        $baseUrl = $realPath -replace '/[^/]+$', ''
        $includePath = "$baseUrl/$includeName"
      }
      else {
        $includePath = Join-Path (Split-Path $realPath -Parent) $includeName
      }

      show_log "Expandindo include: $includePath (depth=$depth)"

      $included = Resolve-AppListContent `
        -filePath $includePath `
        -visited $visited `
        -depth ($depth + 1)

      if ($included -and $included.Count -gt 0) {
        $result += $included
      }
      else {
        show_warn "Include inválido/removido: $includePath"
      }

      continue
    }

    # linha normal (garantia extra: nunca aceitar @ residual)
    if ($line -notmatch '^\s*@') {
      $result += $line
    }
    else {
      show_warn "Linha inválida removida (resíduo @): $line"
    }
  }

  return $result
}
<#
.SYNOPSIS
Impede sleep do sistema.

.DESCRIPTION
Configura flags de execução para evitar suspensão
durante instalação.
#>
function prevent_sleep {
  try {
    $ES_CONTINUOUS = 0x80000000
    $ES_SYSTEM_REQUIRED = 0x00000001
    $ES_AWAYMODE_REQUIRED = 0x00000040

    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Power {
  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

    [Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_AWAYMODE_REQUIRED) | Out-Null
    show_log "Sistema protegido contra sleep/reboot."
  }
  catch {
    show_warn "Falha ao aplicar prevenção de sleep."
  }
}
<#
.SYNOPSIS
Resolve caminho do winget.

.DESCRIPTION
Localiza executável winget em diferentes contextos.

.OUTPUTS
Caminho do winget.
#>
function fixWingetLocation {
  $winget = $null
  try {
    $DesktopAppInstaller = "$env:SystemDrive\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
    $paths = Get-ChildItem "$env:SystemDrive\Program Files\WindowsApps" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe" } | Sort-Object Name -Descending
    if ($paths) {
      $SystemContext = $paths[0].FullName
    }
    $UserContext = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($UserContext) {
      $winget = $UserContext.Source
    }
    elseif (Test-Path "$SystemContext\AppInstallerCLI.exe") {
      $winget = "$SystemContext\AppInstallerCLI.exe"
    }
    elseif (Test-Path "$SystemContext\winget.exe") {
      $winget = "$SystemContext\winget.exe"
    }
    else {
      $winget = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    }
    #if ($null -ne $winget) { "winget content: $winget" }
    # Logs $(env:LOCALAPPDATA)\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir
  }
  catch {
    write-host ""
    write-host "[fixWingetLocation]"
    write-host "$winget"
    show_error "FALHA ao setar winget"
  }
  return $winget
}
<#
.SYNOPSIS
Atualiza pacotes via winget.

.DESCRIPTION
Executa upgrade global com log dedicado.
#>
function isowin_winget_update {
  show_log_title "Atualizando winget..."
  $i = 0
  for (; Test-Path "$script:run_log_dir\apps\winget.update.$i.log"; $i = $i + 1) {}
  $path_log_full = "$script:run_log_dir\apps\winget.update.$i.log"
  winget_run_command "upgrade --all --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1 | Out-File -FilePath '$path_log_full'"
}
<#
.SYNOPSIS
Executa comando no PowerShell 7.

.DESCRIPTION
Executa diretamente se já estiver no PS7
ou relança comando via pwsh.exe.

.PARAMETER cmd_
Comando a executar.
#>
function runInPWSH7() {
  param(
    [string]$cmd_
  )

  $pwshPath = "$env:SystemDrive\Program Files\PowerShell\7\pwsh.exe"

  # Se já estiver no PS7, executa direto
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    show_log "Já estamos no PowerShell 7"
    try {
      Invoke-Expression $cmd_
    }
    catch {
      show_error "Falha ao executar comando no PS7"
    }
    return
  }

  # Se não existir PS7, não tenta fallback infinito
  if (-not (Test-Path $pwshPath)) {
    show_error "PowerShell 7 não encontrado para fallback."
    return
  }

  try {
    show_cmd "$pwshPath -Command $cmd_"

    $proc = Start-Process -FilePath $pwshPath `
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd_`"" `
      -PassThru

    # execução síncrona (seu requisito)
    while (-not $proc.HasExited) {
      Start-Sleep -Seconds 1
    }

    show_nota "Comando executado via PS7."
  }
  catch {
    show_error "Falha ao executar comando via PS7"
  }
}
<#
.SYNOPSIS
Executa comando com fallback.

.DESCRIPTION
Executa comando com detecção de ambiente,
captura logs e fallback para PS7.
run_command faz log apenas no processo principal, em tele.
Não cabe a ele fazer log individualizado em arquivo sepado
se for o caso de log em arquivo, essa atribuiçÃo cabe ao
seu invocador.
run_command printa o comanda a ser executado, e o executa.

.PARAMETER command_
Comando a executar.
#>
function run_command {
  param(
    [string]$command_
  )

  $id_ = rand_name(7)
  show_cmd "[$id_] $command_"

  $success = $false
  $exitCode = -1

  # Detecta se precisa de PowerShell (pipes, Out-File, etc)
  $needsPS = ($command_ -match '\||Out-File|2>&1|>')

  # 1. Execução direta
  try {
    if ($needsPS) {
      $p = Start-Process -FilePath "powershell.exe" `
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command_))
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
      -Wait -PassThru -WindowStyle Hidden
    }
    else {
      $tmpOut = Join-Path $script:run_log_dir "$id_.stdout.log"
      $tmpErr = Join-Path $script:run_log_dir "$id_.stderr.log"

      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr
    }

    $exitCode = $p.ExitCode

    if ($exitCode -eq 0) {
      show_log "[$id_] OK (exit=0)"
      $success = $true
    }
    else {
      show_warn "[$id_] ExitCode: $exitCode"
    }
  }
  catch {
    show_warn "[$id_] Falha na execução direta"
  }

  # 2. fallback CMD puro (se começou em PS)
  if (-not $success -and $needsPS) {
    try {
      $tmpOut = Join-Path $script:run_log_dir "$id_.stdout.log"
      $tmpErr = Join-Path $script:run_log_dir "$id_.stderr.log"

      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr

      $exitCode = $p.ExitCode

      if ($exitCode -eq 0) {
        show_log "[$id_] OK via CMD fallback"
        $success = $true
      }
      else {
        show_warn "[$id_] CMD ExitCode: $exitCode"
      }
    }
    catch {
      show_warn "[$id_] Falha CMD fallback"
    }
  }

  # 3. fallback PS7
  if (-not $success) {
    if (-not $script:__ps7_fallback_used) {
      $script:__ps7_fallback_used = $true
      show_error "[$id_] Falha geral → fallback PS7"
      runInPWSH7 "$command_"
      return
    }
    else {
      show_error "[$id_] Falha definitiva"
    }
  }
}
<#
.SYNOPSIS
Executa comando winget.

.DESCRIPTION
Garante disponibilidade do winget antes da execução.

.PARAMETER command_
Comando winget.
#>
function winget_run_command {
  param(
    [string]$command_
  )
  show_log "Configurando Winget..."
  $winget = fixWingetLocation  
  if ([string]::IsNullOrEmpty($script:winget_timeout) -or -not ($script:winget_timeout -is [datetime])) {
    $script:winget_timeout = [datetime]::Now.AddMinutes(5)
  }
  $attempt = 0
  while ($true) {
    $attempt++
    if ($attempt % 5 -eq 0) {
      show_log "Aguardando winget ficar disponível..."
    }
    $winget = fixWingetLocation
    if (-not [string]::IsNullOrEmpty($winget) -and (Test-Path $winget)) {
      run_command "$winget $command_"
      return ;
    }
    if ( [datetime]::Now -gt $script:winget_timeout) {
      'Winget: File {0} indisponível ainda.' -f $winget | Write-Warning;
      return ;
    }
    Start-Sleep -Seconds 1;
  }
}
<#
.SYNOPSIS
Instala pacote via winget.

.DESCRIPTION
Executa instalação com parâmetros silenciosos
e log dedicado.

.PARAMETER name_id
ID do pacote.

.PARAMETER override
Parâmetros extras.
#>
function isowin_winget_install {
  param(
    [string]$name_id,
    [string]$override
  )
  show_log "Winget: Instalando $name_id"
  $i = 0
  for (; Test-Path "$script:run_log_dir\apps\$name_id.winget.$i.log"; $i = $i + 1) {}
  $path_log_full = "$script:run_log_dir\apps\$name_id.winget.$i.log"
  show_log "Log: '$path_log_full'"
  if (-Not ([string]::IsNullOrEmpty($override))) {
    $override = "--override `"$override`""
  }
  $defaut_parameters = "--verbose --scope machine --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements $override"
  winget_run_command "install --id '$name_id' $defaut_parameters 2>&1 | Out-File -FilePath '$path_log_full'"
}
<#
.SYNOPSIS
Normaliza nome de aplicativo.

.DESCRIPTION
Remove versões, caracteres especiais e gera tokens.

.PARAMETER name
Nome original.

.OUTPUTS
Hashtable com tokens e vendor.
#>
function Normalize-AppName {
  param([string]$name)

  if (-not $name) { return @{ Tokens = @(); Vendor = $null } }

  $n = $name.ToLower()

  # remove versões
  $n = $n -replace '\d+(\.\d+)+', ''
  $n = $n -replace '\b(19|20)\d{2}\b', ''

  # remove lixo comum
  $n = $n -replace '\b(x64|x86|amd64|arm64|win(dows)?|setup|installer|portable|release|final)\b', ''

  # limpa caracteres
  $n = $n -replace '[^a-z0-9]', ' '

  $tokens = $n -split '\s+' | Where-Object { $_ -and $_.Length -ge 3 }

  # vendor = primeiro token apenas se fizer sentido
  $vendor = if ($tokens.Count -ge 2) { $tokens[0] } else { $null }

  return @{
    Tokens = $tokens
    Vendor = $vendor
  }
}
<#
.SYNOPSIS
Localiza pasta offline.

.DESCRIPTION
Procura pendrive contendo estrutura autonoma.

.OUTPUTS
Caminho encontrado.
#>
function appinstall_find_path {
  if (([string]::IsNullOrEmpty($script:appsinstall_folder)) -or (-not (Test-Path $script:appsinstall_folder))) {
    try {
      foreach ($Drive in (Get-PSDrive -PSProvider 'FileSystem' | Where-Object { $_.Root -match '^[A-Z]:\\$' })) {
        $root = "${Drive.Root}"
        # CORREÇÃO: Removido o "Path" solto e a redundância da pasta .pentools
        if ((Test-Path -Path (Join-Path $root $pendrive_autonome_checker)) -and (Test-Path -Path (Join-Path $root $pendrive_autonome_path))) {
          $script:appsinstall_folder = Join-Path $root $pendrive_autonome_path
          break
        }
      }
    }
    catch {
      show_nota 'Falha ao localizar pasta de instalação offline'
      return ""
    }
  }
  return $script:appsinstall_folder
}
<#
.SYNOPSIS
Inicializa cache de instaladores.

.DESCRIPTION
Indexa executáveis offline para busca rápida.
#>
function Initialize-AppFileCache {
  if ($script:AppFileCache) { return }

  $path = appinstall_find_path
  if (-not $path -or -not (Test-Path $path)) {
    $script:AppFileCache = @()
    return
  }

  $folders = @('', 'apps')
  $files = @()

  foreach ($f in $folders) {
    $root = if ($f) { Join-Path $path $f } else { $path }
    if (-not (Test-Path $root)) { continue }
        
    $files += Get-ChildItem -Path $root -Recurse -Include *.exe, *.msi -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer }
  }

  if (-not $files) {
    $script:AppFileCache = @()
    return
  }

  $script:AppFileCache = $files | ForEach-Object {
    $norm = Normalize-AppName $_.BaseName

    [PSCustomObject]@{
      FullName = $_.FullName
      BaseName = $_.BaseName
      Tokens   = $norm.Tokens
      Vendor   = $norm.Vendor
      Flat     = ($norm.Tokens -join ' ')
    }
  }
}
<#
.SYNOPSIS
Encontra melhor correspondência.

.DESCRIPTION
Seleciona arquivo com maior score baseado em tokens.

.PARAMETER inputTokens
Tokens de busca.
#>
function Find-BestMatch {
  param($inputTokens)

  if (-not $script:AppFileCache -or -not $inputTokens) { return $null }

  $bestScore = -1
  $bestMatch = $null

  foreach ($app in $script:AppFileCache) {

    $score = 0

    # matches diretos (forte)
    foreach ($t in $inputTokens) {
      if ($app.Tokens -contains $t) {
        $score += 3
      }
    }

    # match parcial (moderado)
    foreach ($t in $inputTokens) {
      if ($app.Flat -like "*$t*") {
        $score += 1
      }
    }

    # bônus: todos tokens bateram
    if (($inputTokens | Where-Object { $app.Tokens -contains $_ }).Count -eq $inputTokens.Count) {
      $score += 5
    }

    # penalização: nenhum match forte
    if ($score -lt 3) {
      continue
    }

    if ($app.FullName -like "*.msi") {
      $score += 2
    }

    if ($score -gt $bestScore) {
      $bestScore = $score
      $bestMatch = $app
    }
  }

  return $bestMatch
}
<#
.SYNOPSIS
Extrai tokens de ID.

.DESCRIPTION
Gera tokens a partir de nome, URL ou caminho.

.PARAMETER name_id
Identificador.
#>
function Resolve-NameIdTokens {
  param([string]$name_id)

  if (-not $name_id) { return @() }

  $tokens = @()

  if ($name_id -match '^https?://') {
    try {
      $uri = [uri]$name_id

      $tokens += ($uri.Host -split '\.')
      $tokens += ($uri.AbsolutePath -split '[\/\-\._]')

      if ($uri.Query) {
        $tokens += ($uri.Query -split '[=&\-\._]')
      }
    }
    catch {}
  }
  elseif (Test-Path $name_id) {
    $tokens += (Split-Path $name_id -LeafBase)
  }
  else {
    $tokens += ($name_id -split '[.\-_\s]')
  }

  # normalizar igual aos apps
  $tokens = $tokens | ForEach-Object {
    $_.ToLower() -replace '[^a-z0-9]', ''
  } | Where-Object { $_ -and $_.Length -ge 3 }

  return $tokens
}
<#
.SYNOPSIS
Localiza instalador offline.

.DESCRIPTION
Busca executável MSI/EXE usando sistema de score.

.PARAMETER name_id
Nome ou identificador.
#>
function findExeMsiOnFolders {
  param([string]$name_id)

  if (-not $name_id) { return $null }

  # Divide entrada composta
  $parts = $name_id -split '\|'
  $clean_id = $parts[0].Trim()
  $extra = if ($parts.Count -gt 1) { $parts[1] } else { $null }

  # Caminho direto (mais seguro)
  if ([System.IO.Path]::IsPathRooted($clean_id) -and (Test-Path $clean_id -PathType Leaf)) {
    return (Resolve-Path $clean_id).Path
  }

  Initialize-AppFileCache

  # Tokens principais
  $tokens = @()
  $tokens += Resolve-NameIdTokens $clean_id

  # Tokens extras (URL ou complemento)
  if ($extra) {
    $tokens += Resolve-NameIdTokens $extra
  }

  # Remove duplicados
  $tokens = $tokens | Select-Object -Unique

  if (-not $tokens) { return $null }

  $match = Find-BestMatch $tokens

  if ($null -ne $match) {
    return $match.FullName
  }

  return $null
}
<#
.SYNOPSIS
Retorna caminho do checklist global.

.DESCRIPTION
Define arquivo JSON com apps instalados.
#>
function Get-GlobalChecklistPath {
  return Join-Path $path_log "installed_apps.json"
}
<#
.SYNOPSIS
Carrega checklist.

.DESCRIPTION
Lê JSON de aplicativos instalados.
#>
function Load-Checklist {
  $file = Get-GlobalChecklistPath
  if (Test-Path $file) {
    try {
      $json = Get-Content $file -Raw | ConvertFrom-Json
      return @{} + $json
    }
    catch { return @{} }
  }
  return @{}
}
<#
.SYNOPSIS
Salva checklist.

.DESCRIPTION
Grava estado de apps instalados.

.PARAMETER data
Dados do checklist.
#>
function Save-Checklist {
  param($data)
  $file = Get-GlobalChecklistPath
  try {
    $json = $data | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($file, $json, [System.Text.Encoding]::UTF8)
  }
  catch {}
}
<#
.SYNOPSIS
Verifica se app está instalado.

.DESCRIPTION
Consulta winget, registry e PATH.

.PARAMETER name
Nome do aplicativo.
#>
function Test-AppInstalled {
  param([string]$name)

  # 1. winget
  try {
    $winget = fixWingetLocation
    $res = ""
    try {
      $res = & $winget list --id "$name" 2>$null | Out-String
    }
    catch {}

    if ($res -and ($res -notmatch "No installed package") -and ($res -match $name)) {
      return $true
    }

    if ($res -and ($res -notmatch "No installed package")) {
      return $true
    }
  }
  catch {}

  # 2. registry uninstall
  $paths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
  )

  foreach ($p in $paths) {
    try {
      $items = Get-ChildItem $p -ErrorAction SilentlyContinue
      foreach ($i in $items) {
        $dn = (Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue).DisplayName
        if ($dn) {
          $dn_norm = ($dn.ToLower() -replace '[^a-z0-9]', '')
          $name_norm = ($name.ToLower() -replace '[^a-z0-9]', '')
          if ($dn_norm -eq $name_norm -or $dn_norm -like "$name_norm*") {
            return $true
          }
        }
      }
    }
    catch {}
  }

  # 3. PATH / executável conhecido
  try {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      return $true
    }
  }
  catch {}  

  return $false
}
<#
.SYNOPSIS
Instala aplicativo.

.DESCRIPTION
Executa instalação offline, URL ou winget.

.PARAMETER name_id
Identificador.

.PARAMETER override
Parâmetros extras.
#>
function isowin_install_app {
  param(
    [string]$name_id,
    [string]$override
  )
  show_log_title "Instalando '$name_id'"
  $name_id = $name_id.trim()

  $checklist = Load-Checklist

  if ($checklist.ContainsKey($name_id) -and $checklist[$name_id] -eq $true) {

    if (Test-AppInstalled $name_id) {
      show_log "Ignorado (já instalado - checklist confirmado): $name_id"
    
      # reforça consistência
      $checklist = Load-Checklist
      $checklist[$name_id] = $true
      Save-Checklist $checklist

      return
    }
    else {
      show_warn "Checklist inconsistente, reinstalando: $name_id"
      # NÃO retorna → continua fluxo de instalação normalmente
    }
  }
    
  # Separa ID e URL se existirem
  $parts = $name_id -split '\|'
  $id_only = $parts[0]
  $is_url = if ($parts.Count -gt 1) { $parts[-1] } else { "" }

  # Busca no Pendrive usando seu novo sistema de Score
  $nn = findExeMsiOnFolders $id_only
    
  if (-not ([string]::IsNullOrEmpty($nn))) {
    $extencao = [System.IO.Path]::GetExtension($nn).Replace(".", "").ToLower()
    show_log "Arquivo offline found: '$nn'"
        
    # Define caminho do log corretamente
    $current_log = Join-Path $script:run_log_dir "apps\$id_only.log"

    if ("msi" -eq $extencao) {
      $resolved = Resolve-InstallerArgs $nn "msi"

      $msi_args = "/i `"$nn`" $resolved /norestart /L*V `"$current_log`" $override"

      $cmd = "msiexec.exe $msi_args"
      run_command $cmd

      if (-not (Test-AppInstalled $name_id)) {
        show_warn "MSI pode não ter sido instalado corretamente: $name_id"
      }
    }
    elseif ("exe" -eq $extencao) {
      # CORREÇÃO: Agora o log do EXE funciona corretamente
      
      $resolved = Resolve-InstallerArgs $nn "exe"

      $exe_args = $resolved
      if (-not [string]::IsNullOrEmpty($override)) {
        $exe_args = "$exe_args $override"
      }

      try {
        $cmd_exec = "`"$nn`" $exe_args"
        $p = Start-Process -FilePath $nn `
          -ArgumentList $exe_args `
          -PassThru `
          -RedirectStandardOutput $current_log `
          -RedirectStandardError ($current_log + ".err") `
          -WindowStyle Hidden;
      }
      catch {
        try {
          $cmd_exec = "`"$nn`" $exe_args >> `"$current_log`" 2>&1"

          $p = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c $cmd_exec" `
            -PassThru `
            -WindowStyle Hidden
        }
        catch {
          show_error "Falha ao executar '$nn'"
        }
      }

      while (-not $p.HasExited) {
        Start-Sleep -Seconds 1
      }          

      if ($p) {
        show_log "ExitCode EXE: $($p.ExitCode)"
      }
      else {
        show_warn "Processo EXE não retornou objeto válido"
      }

      show_log "Instalação EXE finalizada (verificar confirmação)."          
    }
    if (Test-AppInstalled $name_id) {
      $checklist = Load-Checklist
      $checklist[$name_id] = $true
      Save-Checklist $checklist
      show_log "Confirmado instalado: $name_id"
    }
    else {
      show_warn "Instalação não confirmada: $name_id"
    }    
    return
  }

  # Se não achou no pendrive, segue o fluxo normal
  show_nota "Arquivo offline não encontrado, tentando nuvem..."
  if (-not [string]::IsNullOrEmpty($is_url)) {
    download_msi_install "$is_url" "$override"
  }
  else {
    isowin_winget_install $id_only $override
  }
}
<#
.SYNOPSIS
Instala MSI remoto.

.DESCRIPTION
Baixa arquivo e executa msiexec.

.PARAMETER url
URL do MSI.

.PARAMETER op
Parâmetros adicionais.

.PARAMETER to
Destino opcional.
#>
function download_msi_install {
  Param(
    [string]$url,
    [string]$op,
    [string]$to = $null
  )
  $url = $url.trim()
  if (-Not ("$url" -match "^http.*")) {
    return ""
  }
  if ([string]::IsNullOrEmpty($to)) {
    $tmp = rand_name
    $to = Join-Path $script:run_log_dir "$tmp.tmp"
  }
  try {
    $dl = download_save "$url" "$to"
    if (-not $dl -or -not (Test-Path $to)) {
      show_error "Download inválido, abortando instalação"
      return
    }
    show_cmd "& msiexec.exe /package '$to' /quiet $op | write-host"
    run_command "msiexec.exe /package `"$to`" /quiet $op"
    write-host "Supostamente instalado."
    return ""
  }
  catch {
    show_error "Falha ao instalar da URL: '$url'"
  }
}
<#
.SYNOPSIS
Instala drivers offline.

.DESCRIPTION
Extrai drivers e executa pnputil em background.
#>
function install_offline_drivers_async {
  <#
    EXECUÇÃO ASSÍNCRONA E SILENCIOSA

    - Nenhum log em tela
    - Nenhum log no transcript principal
    - Log exclusivo: $path_log\drivers.log
  #>

  try {

    if ([string]::IsNullOrEmpty($script:appsinstall_folder)) {
      return
    }

    $drivers_zip = Join-Path $script:appsinstall_folder "Drivers.zip"
    $drivers_7z = Join-Path $script:appsinstall_folder "Drivers.7z"
    $drivers_path = Join-Path $script:appsinstall_folder "Drivers"

    # LOG dedicado
    $drivers_log = Join-Path $path_log "drivers.log"

    # garante diretório
    if (-not (Test-Path $path_log)) {
      New-Item -Path $path_log -ItemType Directory -Force | Out-Null
    }

    # função interna de log isolado
    function __drvlog {
      param([string]$msg)
      try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -Path $drivers_log -Value "[$ts] $msg"
      }
      catch {}
    }

    __drvlog "=== START drivers async ==="

    # --- EXTRAÇÃO (IDEMPOTENTE) ---
    $needs_extract = $true

    if (Test-Path $drivers_path) {
      $existing = Get-ChildItem -Path $drivers_path -Recurse -Include *.inf -ErrorAction SilentlyContinue

      if ($existing -and $existing.Count -gt 5) {
        $needs_extract = $false
        __drvlog "Drivers já extraídos previamente (INF suficiente)."
      }
      else {
        __drvlog "Extração anterior insuficiente → reextraindo."
        try {
          Remove-Item $drivers_path -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {}
        $needs_extract = $true
      }
    }

    if ($needs_extract) {

      if (-not (Test-Path $drivers_path)) {
        New-Item -ItemType Directory -Path $drivers_path -Force | Out-Null
      }

      if (Test-Path $drivers_zip) {
        __drvlog "Extraindo Drivers.zip..."

        try {
          Expand-Archive -Path $drivers_zip -DestinationPath $drivers_path -Force
        }
        catch {
          __drvlog "ERRO: falha ao extrair Drivers.zip"
          return
        }
      }
      elseif (Test-Path $drivers_7z) {

        __drvlog "Extraindo Drivers.7z..."

        # =========================================================
        # RESOLVE 7z.exe PRIORITARIAMENTE DO CACHE OFFLINE
        # Caminho esperado:
        #   ${CACHE}\boot\autonome\windows\apps\7-zip\7z.exe
        # Fallback:
        #   usa método antigo (findExeMsiOnFolders)
        # =========================================================

        $sevenZip = ""

        try {
          if (-not [string]::IsNullOrEmpty($script:appsinstall_folder)) {
            $sevenZipCache = Join-Path $script:appsinstall_folder "apps\7-zip\7z.exe"

            if (Test-Path $sevenZipCache) {
              $sevenZip = $sevenZipCache
              __drvlog "7z.exe encontrado no cache: $sevenZip"
            }
          }
        }
        catch {}

        # fallback legado (mantido)
        if ([string]::IsNullOrEmpty($sevenZip)) {
          __drvlog "7z.exe não encontrado no cache, tentando fallback..."
          $sevenZip = findExeMsiOnFolders "7zip"
        }

        if (-not $sevenZip -or -not (Test-Path $sevenZip)) {
          __drvlog "ERRO: 7zip não encontrado"
          return
        }

        $cmd7z = "`"$sevenZip`" x `"$drivers_7z`" -o`"$drivers_path`" -y"

        Start-Process -FilePath "cmd.exe" `
          -ArgumentList "/c $cmd7z >> `"$drivers_log`" 2>&1" `
          -WindowStyle Hidden -Wait
      }
      else {
        __drvlog "Nenhum pacote de drivers encontrado."
        return
      }
    }

    # valida INF
    $maxWait = 30
    $waited = 0
    $infFiles = @()

    while ($waited -lt $maxWait) {
      $infFiles = Get-ChildItem -Path $drivers_path -Recurse -Include *.inf -ErrorAction SilentlyContinue
      if ($infFiles -and $infFiles.Count -gt 0) {
        break
      }
      Start-Sleep -Seconds 1
      $waited++
    }

    if (-not $infFiles -or $infFiles.Count -eq 0) {
      __drvlog "Nenhum .inf encontrado após espera."
      return
    }

    # dispositivos com problema
    $problemDevices = @()

    try {
      $problemDevices = Get-PnpDevice -PresentOnly | Where-Object {
        $_.Status -ne "OK"
      }
    }
    catch {
      __drvlog "ERRO: falha ao consultar PnP"
      return
    }

    if (-not $problemDevices -or $problemDevices.Count -eq 0) {
      __drvlog "Nenhum dispositivo com problema."
      return
    }

    foreach ($dev in $problemDevices) {
      __drvlog "PENDENTE: $($dev.FriendlyName) [$($dev.InstanceId)] ($($dev.Status))"
    }

    if ($script:is_test_mode) {
      __drvlog "TEST MODE - abortado"
      return
    }

    __drvlog "Disparando pnputil async..."

    # execução assíncrona real (sem bloquear)
    $cmd = "pnputil.exe /add-driver `"$drivers_path\*.inf`" /subdirs /install"

    Start-Process -FilePath "cmd.exe" `
      -ArgumentList "/c $cmd >> `"$drivers_log`" 2>&1" `
      -WindowStyle Hidden `
      -PassThru | ForEach-Object {
      __drvlog "PID pnputil: $($_.Id)"
    }

    __drvlog "Processo iniciado (background)."

  }
  catch {
    try {
      Add-Content -Path (Join-Path $path_log "drivers.log") `
        -Value "ERRO FATAL: $($_.Exception.Message)"
    }
    catch {}
  }
}
<#
.SYNOPSIS
Garante execução no PowerShell 7.

.DESCRIPTION
Instala e relança script no PS7 quando necessário.
#>
function Ensure-PS7 {
  $pwshPath = "$env:SystemDrive\Program Files\PowerShell\7\pwsh.exe"

  # Já estamos no PS7? então NÃO faz nada
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    show_log "Já em PowerShell 7 — não é necessário relançar."
    return
  }

  if ($Env:AUTONOME_PS7 -eq "1") {
    show_warn "Já relançado anteriormente — evitando loop."
    return
  }
  else {

    # Se não existe PS7, instala
    if (-Not (Test-Path $pwshPath)) {
      show_log "PowerShell 7 não encontrado. Instalando..."
      download_save "$url_pwsh" "$pwsh_msi_path"
      Start-Process msiexec.exe -ArgumentList "/i `"$pwsh_msi_path`" /qn ADD_PATH=1" -Wait
    }

    # Se existe PS7, relança
    if (Test-Path $pwshPath) {
      show_log "Relançando script em PowerShell 7..."

      # preserva argumentos originais
      # preserva argumentos originais
      # preserva argumentos originais do script (PSBoundParameters)
      $argList = @()

      foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($null -ne $kv.Value -and $kv.Value -ne "") {
          $argList += "-$($kv.Key) `"$($kv.Value)`""
        }
        else {
          $argList += "-$($kv.Key)"
        }
      }

      $argString = $argList -join " "

      [System.Environment]::SetEnvironmentVariable("AUTONOME_PS7", "1", "Process")

      $proc = Start-Process -FilePath $pwshPath `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $argString" `
        -PassThru

      # ⚠️ IMPORTANTE: bloqueia até terminar (seu requisito)
      while (-not $proc.HasExited) {
        Start-Sleep -Seconds 1
      }

      exit
    }
    else {
      show_error "PowerShell 7 não encontrado mesmo após tentativa de instalação."
    }
  }
}
<#
.SYNOPSIS
Inicializa cache local.

.DESCRIPTION
Cria cache TEMP e copia conteúdo do pendrive.
#>
function Initialize-AutonomeCache {

  $regPath = "HKLM:\SOFTWARE\AutonomeInstall"
  $regName = "TempRoot"

  try {
    if (-not (Test-Path $regPath)) {
      New-Item -Path $regPath -Force | Out-Null
    }
  }
  catch {}

  $temp_root = ""
  try {
    $temp_root = (Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue).$regName
  }
  catch {}

  if ([string]::IsNullOrEmpty($temp_root) -or -not (Test-Path $temp_root) -or ((Test-Path $temp_root) -and ((Get-Item $temp_root).CreationTime -lt (Get-Date).AddDays(-7)))) {
    $temp_root = Join-Path "$env:SystemRoot\Temp" $TMP_DIR_NAME

    try {
      if (Test-Path $temp_root) {
        Remove-Item $temp_root -Recurse -Force -ErrorAction SilentlyContinue
      }

      New-Item -Path $temp_root -ItemType Directory -Force | Out-Null
      Set-ItemProperty -Path $regPath -Name $regName -Value $temp_root -Force
    }
    catch {
      show_error "Falha ao criar cache TEMP"
      return ""
    }
  }

  $dest = Join-Path $temp_root $pendrive_autonome_path

  if (-not (Test-Path $dest)) {
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
  }

  $src = appinstall_find_path

  if ([string]::IsNullOrEmpty($src)) {
    show_warn "Pendrive não encontrado para cache."
    return $temp_root
  }

  show_log_title "Preparando cache local (TEMP)"

  run_command "robocopy `"$src`" `"$dest`" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS"

  $drive_root = (Get-Item $src).PSDrive.Root

  # =========================================================
  # MERGE OFFLINE (ROOT DO PENDRIVE → CACHE)
  #
  # Comportamento:
  # - Conteúdo de "unidade:\Drivers\" é mesclado ao cache
  #   no mesmo destino onde os drivers extraídos são usados
  #
  # - Conteúdo de "unidade:\apps\" é mesclado diretamente
  #   em:
  #     ${CACHE}\boot\autonome\windows\apps\
  #
  # - Estratégia:
  #   * Merge incremental (robocopy)
  #   * Sobrescrita controlada (arquivos mais novos prevalecem)
  #   * Permite override manual sem rebuild do pacote principal
  # =========================================================

  $drivers = Join-Path $drive_root "Drivers"
  if (Test-Path $drivers) {
    show_log "Merge Drivers (root) → cache"
    # merge incremental preservando estrutura
    run_command "robocopy `"$drivers`" `"$dest`" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS"
  }

  $apps = Join-Path $drive_root "apps"
  if (Test-Path $apps) {
    show_log "Merge apps (root) → cache"
    # merge direto sobre pasta apps do cache (override permitido)
    run_command "robocopy `"$apps`" `"$dest`" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS"
  }

  return $temp_root
}
<#
.SYNOPSIS
Função principal.

.DESCRIPTION
Controla fluxo principal da instalação,
configura ambiente e inicia execução.
#>
function main {
  write-host "Iniciando..."
  prevent_sleep
  try {
    shutdown.exe /a 2>$null
  }
  catch {}

  # trava tentativas futuras (loop leve em background)
  $timeout = (Get-Date).AddMinutes(30)

  try {
    if ($in_system_context) {
      show_log "SYSTEM context: usando processo leve ao invés de Job."

      $cmd = "while ((Get-Date) -lt '$timeout') { shutdown.exe /a 2>nul; timeout /t 2 >nul }"
      Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $cmd" `
        -WindowStyle Hidden
    }
    else {
      Start-Job -Name "autonome-anti-shutdown" -ScriptBlock {
        param($timeout)
        while ((Get-Date) -lt $timeout) {
          shutdown.exe /a 2>$null
          Start-Sleep -Seconds 2
        }
      } -ArgumentList $timeout | Out-Null
    }
  }
  catch {
    show_warn "Falha ao iniciar loop anti-shutdown."
  }
  #####
  ##### Instala e relança script no PS7 quando necessário.
  #####    
  Ensure-PS7
  Start-Sleep -Seconds 1

  $appsinstall_folder = $script:appsinstall_folder
  Write-Host "Pendrive?: '$appsinstall_folder'"

  #####
  ##### Desabilitando Hibernação
  #####    

  show_log_title "Desabilitando Hibernação."
  try {
    if (-not $script:is_test_mode) {
      powercfg.exe /hibernate off
    }
    else {
      show_log "TEST MODE: hibernação não alterada"
    }
  }
  catch {
    show_log "Falha ao desabilitar hibernação."
  }

  #####
  ##### Initialize-AutonomeCache
  #####      
  $cache_root = Initialize-AutonomeCache

  if (-not ([string]::IsNullOrEmpty($cache_root))) {
    $script:appsinstall_folder = Join-Path $cache_root $pendrive_autonome_path
    $appsinstall_folder = $script:appsinstall_folder
    show_log "Usando cache TEMP: '$appsinstall_folder'"
  }
  
  #####
  ##### INSTALAÇãO DE DRIVER
  #####
  install_offline_drivers_async
  
  #####
  ##### FORCA PT-BR
  #####
  "./$autonome_scripts/force-pt-br.ps1"
  
  #####
  ##### BAIXA WallPaperS
  #####
  . "./$autonome_scripts/get-wallpapers.ps1"

  #####
  ##### WINGET
  #####
  . "./$autonome_scripts/fix-winget.ps1"
  
  #####
  ##### REALIZA INSTALAÇÕES
  #####
  . "./$autonome_scripts/default-installs.ps1"
  
  #####
  ##### INVOCA GATILHHOS (HOOKS)
  #####
  . "./$autonome_scripts/invoke-hooks.ps1"
  
  #####
  ##### FINALIZAÇÃO
  #####
  
  write-host ""
  write-host "CONCLUIDO"
  write-host ""
  show_log_title "Reiniciando..."
  try {
    Stop-Transcript
  }
  catch {}

  try {
    [Power]::SetThreadExecutionState(0x80000000) | Out-Null
  }
  catch {}
  if (-not $in_system_context) {
    if ([string]::IsNullOrEmpty($Env:autonome_test)) {
      Start-Sleep -Seconds 1
      Start-Sleep -Seconds 2
      Restart-Computer
    }
  }
}
main