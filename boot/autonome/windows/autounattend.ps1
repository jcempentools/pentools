# =========================================================
# AUTONOME INSTALL SCRIPT
# =========================================================
# Objetivo:
# Preparar ambiente Windows de forma automática,
# previsível e rastreável.
#
# Princípios:
# - Idempotente: não reinstala o que já foi instalado
#   (checklist global)
# - Híbrido: prioriza offline (pendrive/cache), usa online
#   como fallback
# - Resiliente: múltiplos métodos de execução e verificação
# - Rastreável: cada execução gera log isolado
# - Compatível: funciona em PS antigo com fallback
#   automático para PS7+
#
# Logs:
# - Raiz: %SystemDrive%\autonome-install-LOG
# - Execução: ID-MMDD-HHMM-MODE (SYSTEM|USER)
# - Conteúdo:
#     auto-install.log  → log geral (transcript)
#     /apps/            → logs por aplicação
#
# Checklist:
# - Arquivo global: installed_apps.json
# - Evita reinstalações
# - Persistente entre execuções
# - Apenas uma versão do software, não deve-se controlar
#   versões (Ex. Adobe Photoshop, ignore-se a versão)
#
# Fluxo:
# 0. Totalmente síncrono, com apenas uma única exceção
#    (drivers)
# 1. Detecta contexto (SYSTEM/USER)
# 2. Garante PowerShell 7+
# 3. Prepara cache local (TEMP persistente via registry)
# 4. Instala drivers offline (assíncrono)
# 5. Configura ambiente (energia, wallpaper, etc)
# 6. Atualiza winget
# 7. Instala apps:
#    - offline (preferencial)
#    - URL direta
#    - winget (fallback)
#
# Detecção de instalação:
# - winget list
# - registry (Uninstall)
# - PATH (Get-Command)
#
# Cache:
# - %SystemRoot%\Temp\<ID_RANDOM>
# - Controlado via HKLM:\SOFTWARE\AutonomeInstall
# - Sincronização incremental via robocopy
#
# Execução:
# - Padrão: cmd.exe
# - Fallback: PowerShell 7
# - Execução síncrona para etapas críticas
#
# Diretrizes:
# - Espera privilégio administrativo
# - Ambiente controlado (ex: pendrive)
# - Foco em confiabilidade e previsibilidade
# - Falhas pontuais não devem interromper o fluxo
#
# Codificação:
# - Mudanças mínimas para implementar correções e melhorias
# - Garantir rastreabilidade com git
#
# Boas práticas de CORRÇÕES E APRIMORAMENTOS:
# Toda e qualquer alteração de primar por alterações
# minimas objetivando um fácil rastreo git, mas com bom 
# senso, afim de obter eficiência e gestão de código.
#
# TO-DO[1]: Implementar/atualizar instalação de drivers, agora
# compactados.
#
# Originalmente, os drivers offline residiam na pasta
# 'Drivers' localizada sob a raiz do pendrive ou sob
# $pendrive_autonome_path, entretanto, agora, os drivers
# estão compactados em "$pendrive_autonome_path\Drivers.zip"
# ou "$pendrive_autonome_path\Drivers.7z" com compactação
# LZMA2, modo ultra. A função de atualização de driver que
# utiliza o cache local (que é uma cópia do pendrive), deve
# localizar o arquivo compactado no cache, descompactá-lo
# para a mesma localização dele sob pasta .\Drivers\. E
# então usar esta pasta para atualizar os drivers de
# hardware.
#
# Importante, apenas hardware não reconhecido deve ser
# atualizado, ou aqueles que o Windows identifique como
# com mau funcionamento.
#
# TO-DO[2]: Ajuste de $in_system_context aliado a
#           $Env:LOCAL_EXEC
#
# Antes da execução deste script, $Env:LOCAL_EXEC é
# definido e pode assumir 4 valores string (UPPERCASE), que
# indicam em que estágio da instalação do Windows o script
# foi invocado:
# - "System": Scripts rodam no contexto de sistema, antes
#   da criação de contas de usuário.
# - "DefaultUser": Scripts para modificar a hive do usuário
#   padrão (C:\Users\Default\NTUSER.DAT). Afetam todas as
#   contas criadas.
# - "FirstLogon": Scripts rodam no primeiro logon após a
#   instalação, tipicamente com privilégios elevados.
# - "UserOnce": Scripts rodam sempre que um usuário faz
#   logon pela primeira vez.
#
# 1. Precisamos unificar ou deixar de usar a ideia de
#    $in_system_context, ou então usá-la apenas como um
#    validador lógico adicional, mas sem deixar de fazer
#    o que é feito quando ela é usada, ou seja, apenas
#    vamos aprimorar a forma de verificação;
# 2. Precisamos garantir a existência de gatilhos
#    customizáveis opcionais que executem scripts antes da
#    conclusão. Se existentes, não vazios e não em branco
#    (content.trim() != ""), localizados no cache sob:
#    "$pendrive_autonome_path\scripts".
#    O padrão do nome deve ser "in.{$Env:LOCAL_EXEC}.ps1",
#    em letras totalmente minúsculas.
# 3. Garantir que apenas funcionalidades do script sejam 
#    executadas nas etapas em que fazem sentido (são
#    possíveis de serem executadas)
#    Por exemplo: não é possivel criar um arquivo dentro da 
#    pasta de usuário, se estamos numa etapa em que não
#    existem usuários, nem mesmo o default.
# =========================================================


Param(
  [string]$is_test
)
$script:__ps7_fallback_used = $false
$path_log = "$env:SystemDrive\autonome-install-LOG"
$pwsh_msi_path = "$env:SystemDrive\pwsh_install.msi"
# exigido exiência de unidade:/.pentools/.pentools
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
$script:winget_timeout = "" # BUG: manter isso vazio
Write-Host " "
# modo full
if ("$Env:install_mode" -eq "dev") {
  $url_apps_lst = "$url_apps_lst/apps.dev.lst"
}
elseif ("$Env:install_mode" -eq "gamer") {
  $url_apps_lst = "$url_apps_lst/apps.gamer.lst"
}
elseif ("$Env:install_mode" -eq "designer") {
  $url_apps_lst = "$url_apps_lst/apps.designer.lst"
}
elseif ("$Env:install_mode" -eq "basic") {
  $url_apps_lst = "$url_apps_lst/apps.basic.lst"
  # modo dev
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
$mode = if ($in_system_context) { "SYSTEM" } else { "USER" }

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
Write-Host "Instação crua.........: '$Env:install_mode'"
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
#######################################################
#######################################################
#####
##### FUNCOES
#####
#######################################################
#######################################################
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_error {
  param(
    [string]$str_menssagem
  )
  Write-Host "[ERROR]:" -BackgroundColor Red
  Write-Host "[ERROR]: $str_menssagem" -BackgroundColor Red
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_log {
  param(
    [string]$str_menssagem
  )
  Write-Host "---> $str_menssagem" -BackgroundColor DarkGray
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_cmd {
  param(
    [string]$str_menssagem
  )
  Write-Host ""
  Write-Host "---------------------------------------------"
  Write-Host "$str_menssagem" -BackgroundColor Cyan -ForegroundColor Black
  Write-Host "---------------------------------------------"
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_warn {
  param(
    [string]$str_menssagem
  )
  Write-Host "[WARN] " -BackgroundColor Yellow -ForegroundColor Black
  Write-Host "[WARN]: $str_menssagem" -BackgroundColor Yellow -ForegroundColor Black
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_nota {
  param(
    [string]$str_menssagem
  )
  Write-Host "[NOTA]: $str_menssagem" -BackgroundColor Gray -ForegroundColor Black
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function rand_name {
  param(
    [AllowNull()][int]$num
  )  
  if (-not $num -or $num -le 0) {
    $num = 18
  }
  return -join ((65..90) + (97..122) | Get-Random -Count $num | ForEach-Object { [char]$_ })
}
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
          -WindowStyle Hidden

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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
  if ($url -notmatch '^http.+') {
    $url = "https://$url"
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
    return $dest
  }
  return ""
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
        if ($url -notmatch '^http') { $url = "https://$url" }
        $resp = Invoke-WebRequest $url -TimeoutSec 30 -ErrorAction Stop

        if ($resp.StatusCode -eq 200 -and $resp.Content.Length -gt 5) {
          return $resp.Content.ToString().Trim()
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function isowin_winget_update {
  show_log_title "Atualizando winget..."
  $i = 0
  for (; Test-Path "$script:run_log_dir\apps\winget.update.$i.log"; $i = $i + 1) {}
  $path_log_full = "$script:run_log_dir\apps\winget.update.$i.log"
  winget_run_command "upgrade --all --silent --disable-interactivity --accept-package-agreements --accept-source-agreements 2>&1 | Out-File -FilePath '$path_log_full'"
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@~
# run_command faz log apenas no processo principal, em tele.
# Não cabe a ele fazer log individualizado em arquivo sepado
# se for o caso de log em arquivo, essa atribuiçÃo cabe ao
# seu invocador.
# run_command printa o comanda a ser executado, e o executa.
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
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$command_`"" `
        -Wait -PassThru -WindowStyle Hidden
    }
    else {
      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden
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
      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden

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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function winget_run_command {
  param(
    [string]$command_
  )
  show_log "Configurando Winget..."
  $winget = fixWingetLocation  
  if (-not ($script:winget_timeout -is [datetime])) {
    $script:winget_timeout = [datetime]::Now.AddMinutes(5)
  }
  $attempt = 0
  while ($true) {
    $attempt++
    if ($attempt % 5 -eq 0) {
      show_log "Aguardando winget ficar disponível..."
    }
    if (Test-Path $winget) {
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function Get-GlobalChecklistPath {
  return Join-Path $path_log "installed_apps.json"
}

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function Save-Checklist {
  param($data)
  $file = Get-GlobalChecklistPath
  try {
    $data | ConvertTo-Json -Depth 5 | Set-Content $file
  }
  catch {}
}

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function Test-AppInstalled {
  param([string]$name)

  # 1. winget
  try {
    $winget = fixWingetLocation
    if (Test-Path $winget) {
      $res = & $winget list --id "$name" 2>$null
    }
    if ($res -and $res -notmatch "No installed package") {
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
  $id_only = $name_id
  $is_url = ""
  if ($name_id -match "\|") {
    $id_only = $name_id.Split("|")[0]
    $is_url = $name_id.Split("|")[-1]
  }

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
    }
    elseif ("exe" -eq $extencao) {
      # CORREÇÃO: Agora o log do EXE funciona corretamente
      try {
        $resolved = Resolve-InstallerArgs $nn "exe"

        $exe_args = $resolved
        if (-not [string]::IsNullOrEmpty($override)) {
          $exe_args = "$exe_args $override"
        }

        $cmd_exec = "`"$nn`" $exe_args"
        $p = Start-Process -FilePath $nn `
          -ArgumentList $exe_args `
          -Wait -PassThru `
          -RedirectStandardOutput $current_log `
          -RedirectStandardError $current_log `
          -WindowStyle Hidden

        show_log "ExitCode EXE: $($p.ExitCode)"

        show_log "Instalação EXE finalizada (verificar confirmação)."
      }
      catch {
        show_error "Falha ao executar '$nn'"
      }
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
    download_save "$url" "$to"
    show_cmd "& msiexec.exe /package '$to' /quiet $op | write-host"
    run_command "msiexec.exe /package `"$to`" /quiet $op"
    write-host "Supostamente instalado."
    return ""
  }
  catch {
    show_error "Falha ao instalar da URL: '$url'"
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function install_offline_drivers_async {
  <#
    EXECUÇÃO ASSÍNCRONA (INTENCIONAL)

    Esta é a ÚNICA parte do script que roda de forma assíncrona.
    Motivo:
      - instalação de drivers pode ser demorada
      - não deve bloquear o fluxo principal
      - não deve impedir conclusão do setup

    Comportamento:
      - varre pasta "Drivers" na raiz do pendrive
      - instala todos os .inf (subpastas incluídas)
      - executa em background
      - não gera erro fatal

    Observação:
      - falhas aqui NÃO devem interromper o script principal
      - não depende de rede
  #>

  show_log_title "Instalando drivers offline (modo assíncrono)"

  try {
    if ([string]::IsNullOrEmpty($script:appsinstall_folder)) {
      show_log "Pasta base do pendrive não definida."
      return
    }

    $drive_root = (Get-Item $script:appsinstall_folder).PSDrive.Root
    $drivers_path = Join-Path $drive_root "Drivers"

    if (-Not (Test-Path $drivers_path)) {
      show_log "Nenhuma pasta 'Drivers' encontrada."
      return
    }

    show_log "Disparando instalação assíncrona de drivers em '$drivers_path'"

    if ($script:is_test_mode) {
      show_log "TEST MODE: staging de drivers (sem instalar no sistema ativo)"
      $cmd = "pnputil.exe /add-driver `"$drivers_path\*.inf`" /subdirs"
    }
    else {
      $cmd = "pnputil.exe /add-driver `"$drivers_path\*.inf`" /subdirs /install & pnputil.exe /scan-devices"
    }

    Start-Process -FilePath "cmd.exe" `
      -ArgumentList "/c $cmd" `
      -WindowStyle Hidden

    show_log "Instalação de drivers iniciada em background."

  }
  catch {
    show_error "Falha ao iniciar instalação assíncrona de drivers."
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
      $argList = @()

      foreach ($a in $args) {
        $argList += "`"$a`""
      }

      $argString = $argList -join " "

      $env:AUTONOME_PS7 = "1"

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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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

  $drivers = Join-Path $drive_root "Drivers"
  if (Test-Path $drivers) {
    show_log "Merge Drivers → cache"
    run_command "robocopy `"$drivers`" `"$dest`" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS"
  }

  $apps = Join-Path $drive_root "apps"
  if (Test-Path $apps) {
    show_log "Merge apps → cache"
    run_command "robocopy `"$apps`" `"$dest`" /E /XO /R:1 /W:1 /NFL /NDL /NJH /NJS"
  }

  return $temp_root
}
#######################################################
#######################################################
#####
##### INICIO
#####
#######################################################
#######################################################
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
Ensure-PS7
Start-Sleep -Seconds 1
$script:appsinstall_folder = appinstall_find_path
$appsinstall_folder = $script:appsinstall_folder
Write-Host "Pendrive?: '$appsinstall_folder'"
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
$cache_root = Initialize-AutonomeCache

if (-not ([string]::IsNullOrEmpty($cache_root))) {
  $appsinstall_folder = Join-Path $cache_root $pendrive_autonome_path
  show_log "Usando cache TEMP: '$appsinstall_folder'"
}
install_offline_drivers_async
#######################################################
#######################################################
#####
##### WallPaperS
#####
#######################################################
#######################################################
show_log_title "### WallPapers"
$WallPapers_path = ""
if (-Not ([string]::IsNullOrEmpty($appsinstall_folder))) {
  $WallPapers_path = (get-item $appsinstall_folder).Parent.FullName
  $WallPapers_path = "$WallPapers_path\WallPapers\images"
}
if ([string]::IsNullOrEmpty($image_folder)) { $image_folder = "$env:SystemDrive\Users\Default\Pictures" }
$image_folder = "$image_folder\WallPapers"
$img_count = 0
if ((-Not ([string]::IsNullOrEmpty($WallPapers_path))) -And (Test-Path -Path "$WallPapers_path")) {
  show_log "Obtendo WallPapers do pendrive, se exitir..."
  foreach ($ee in @('png', 'jpg')) {
    Get-ChildItem -Path "$WallPapers_path" -Filter "*.$ee" -Recurse -File | ForEach-Object {
      try {
        $nome = $_.BaseName
        Copy-Item $_ "$image_folder\$nome.$ee" -Force
        $img_count = $img_count + 1
      }
      catch {
        # ignore
      }
    }
  }
  show_log "'$img_count' WallPaper(s) obdito(s) offline."
}
if (("$Env:install_mode" -ne "cru") -And ($img_count -le 0)) {
  show_log "Obtendo WallPapers ONLINE..."
  if (-Not (Test-Path -Path "$image_folder")) {
    New-Item -Path "$image_folder" -Force -ItemType Directory
  }
  download_save "$url_WallPapers_lst" "$image_folder\download.lst"
  if (Test-Path "$image_folder\download.lst") {
    $i = 0
    $ext = "png"
    foreach ($line in Get-Content "$image_folder\download.lst") {
      $line = $line.trim()
      if ([string]::IsNullOrEmpty($line) -Or ($line -match '^\s*$')) {
        continue
      }
      #$destname = $i
      $destname = sha256($line)
      #$destname = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($line))
      download_save "$line" "$image_folder\$destname.$ext"
      #$shaname = (Get-FileHash "$image_folder\$i.$ext" -Algorithm SHA256).Hash
      #try {
      #  if (Test-Path "$image_folder\$shaname.$ext") {
      #    Remove-Item "$image_folder\$shaname.$ext" -Force
      #  }
      #  Move-Item -Path "$image_folder\$i.$ext" "$image_folder\$shaname.$ext"
      #}
      #catch {
      #}
      $i = $i + 1
    }
  }
  show_log_title "Definindo tela de bloqueio personalizada"
  # now set the registry entry
  $nome = download_to_string($url_lockscreen)
  show_log "A setar '$nome'."
  if (-Not (Test-Path "$image_folder\$nome.png")) {
    show_warn "O WallPaper '$nome' não existe."
  }
  elseif (-Not ([string]::IsNullOrEmpty($nome) -Or ($nome -match '^\s*$'))) {
    try {
      setrgkey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImagePath' "$image_folder\$nome.png"
      rundll32.exe user32.dll, UpdatePerUserSystemParameters
      show_log "Definido."
    }
    catch {
      show_error "FALHA ao definir tela de bloqueio."
    }
  }
  ## DEFINIR WALLPAPPER APENAS SE ESTIVER EM USUÁRIO
  if (-not $in_system_context) {
    show_log_title "Definindo WallPaper"
    # now set the registry entry
    $nome = download_to_string($url_defWallPaper)
    show_log "A setar '$nome'."
    if (-Not (Test-Path "$image_folder\$nome.png")) {
      show_warn "O WallPaper '$nome' não existe."
    }
    elseif (-Not ([string]::IsNullOrEmpty($nome) -Or ($nome -match '^\s*$'))) {
      try {
        setrgkey 'HKCU:\Control Panel\Desktop' 'WallPaper' "$image_folder\$nome.png"
        setrgkey 'HKCU:\Control Panel\Desktop' 'WallPaperStyle' 10
        setrgkey 'HKCU:\Control Panel\Desktop' 'TileWallpaper' 0
        rundll32.exe user32.dll, UpdatePerUserSystemParameters
        show_log "Definido."
      }
      catch {
        show_error "FALHA ao definir WallPaper."
      }
    }
  }
}
#######################################################
#######################################################
#####
##### WINGET
#####
#######################################################
#######################################################
if (-not $in_system_context) {
  show_log_title "Fix winget, forçando disponibilização de winget no contexto do sistema"
  try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe | write-host
  }
  catch {
    show_error "Falha ao executar Add-AppxPackage "
  }
  show_log_title "Winget setup fix 1"
  try {
    $ResolveWingetPath = Resolve-Path "$env:SystemDrive\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
    if ($ResolveWingetPath) {
      $WingetPath = $ResolveWingetPath[-1].Path
    }
    Write-Host "-> winget: '$wingetpath'"
    Set-Location "$wingetpath"
  }
  catch {
    show_error "FALHA ao executar FIX 1"
  }
  write-host "Atual: $pwd"
  if (-not $script:is_test_mode) {
    isowin_winget_update
  }
  else {
    show_log "TEST MODE: winget upgrade ignorado"
  }
}
#######################################################
#######################################################
#####
##### INSTALAÇÕES
#####
#######################################################
#######################################################
if (-not $in_system_context) {
  show_log_title "Instalando APPs basiquissimos"
  isowin_install_app "Oracle.JavaRuntimeEnvironment"
  isowin_install_app "Microsoft.DirectX"
  isowin_install_app "7zip.7zip"
  isowin_install_app "Microsoft.VisualStudioCode" '/SILENT /mergetasks="!runcode,addcontextmenufiles,addcontextmenufolders,addtopath,associatewithfiles,quicklaunchicon"'
  if ("$Env:install_mode" -eq "dev") {
    wsl --install
    wsl --set-default-version 2
  }
  show_log_title "Instalando demais APPs"
  if ("$Env:install_mode" -ne "cru") {
    show_log "Continuar padrão ou seguir 'apps.lst' do online/pendrive?"
    $apps_lst = ""
    # verifica se tem lista de apps no pendrive
    if (Test-Path "$appsinstall_folder\apps.lst") {
      $apps_lst = "$appsinstall_folder\apps.lst"
    }
    elseif (Test-Path "$appsinstall_folder\apps\apps.lst") {
      $apps_lst = "$appsinstall_folder\apps\apps.lst"
    }
    if (-Not ([string]::IsNullOrEmpty($apps_lst))) {
      show_log "usando 'apps.lst do pendrive'..."
      foreach ($line in Get-Content "$apps_lst") {
        $line = $line.trim()
        if ([string]::IsNullOrEmpty($line) -Or ($line -match '^\s*$')) {
          continue
        }
        isowin_install_app $line.Trim()
      }
    }
    else {
      show_log "Obtendo lista online..."
      $apps_f = "$path_log\apps-download.lst"
      download_save "$url_apps_lst" "$apps_f"
      if (Test-Path "$apps_f") {
        show_log "Lista de apps online encontrato, usando..."
        foreach ($line in Get-Content "$apps_f") {
          $line = $line.trim()
          if ([string]::IsNullOrEmpty($line) -Or ($line -match '^\s*$')) {
            continue
          }
          isowin_install_app $line.trim()
        }
      }
      else {
        show_log "Lista de apps online inexistente, usando o padrao..."
        isowin_install_app "Microsoft.PowerToys"
        isowin_install_app "QL-Win.QuickLook"
        isowin_install_app "CodecGuide.K-LiteCodecPack.Mega"
        isowin_install_app "VideoLAN.VLC"
        isowin_install_app "Google.Chrome"
        isowin_install_app "Brave.Brave"
        isowin_install_app "SumatraPDF.SumatraPDF"
        isowin_install_app "PDFsam.PDFsam"
        isowin_install_app "Piriform.Defraggler"
        isowin_install_app "CrystalDewWorld.CrystalDiskInfo"
        isowin_install_app "qBittorrent.qBittorrent"
        isowin_install_app "TheDocumentFoundation.LibreOffice"
      }
    }
    show_log "Executar script offline do pendrive '$pendrive_script_name'?"
    # tenta executar o script localizado no pendrive
    if (Test-Path "$appsinstall_folder\$pendrive_script_name") {
      show_log "Sim, executando..."
      run_command "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$appsinstall_folder\$pendrive_script_name`""
    }
    else {
      show_log 'Não, não localizado.'
    }
  }
}
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