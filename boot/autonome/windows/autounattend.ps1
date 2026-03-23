Param(
  [string]$is_test
)
$script:__ps7_fallback_used = $false
$path_log = "%SystemDrive%\appinstall.log"
$pwsh_msi_path = "%SystemDrive%\pwsh_install.msi"
# exigido exiência de unidade:/.pentools/.pentools
$pendrive_autonome_checker = ".pentools"
$pendrive_autonome_root = "boot\autonome"
# instalações dentro da pasta /apps em windows:
$pendrive_autonome_path = "$pendrive_autonome_root\windows"
$image_folder = "%SystemDrive%\Users\Default\Pictures"
$pendrive_script_name = "run.ps1"
$url_pwsh = "github.com/PowerShell/PowerShell/releases/download/v7.6.0/PowerShell-7.6.0-win-x64.msi"
$url_WallPapers_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/WallPaper.lst"
$url_apps_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/windows"
$url_lockscreen = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/lockscreen.lst"
$url_defWallPaper = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/$pendrive_autonome_root/WallPapers/default.lst"
$appsinstall_folder = "" # manter vazio
$script:winget_timeout = "" # manter vazio
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
$in_system_context = (("$env:USERNAME" -eq "$env:COMPUTERNAME") -Or ("$env:USERNAME" -eq "SYSTEM") -Or (("$env:COMPUTERNAME" -match '(?-i)^SYSTEM.*')))
if (-Not ([string]::IsNullOrEmpty($is_test))) {
  $Env:autonome_test = "1"
}
if ("$in_system_context" -eq "$False") {
  $image_folder = "%SystemDrive%\Users\${env:USERNAME}\Pictures"
}
try {
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Force  
}
catch {
  write-host "[ERROR]: falha ao setar política de execuçao."
}

try {
  [Net.ServicePointManager]::SecurityProtocol =
  [Net.SecurityProtocolType]::Tls12 `
    -bor [Net.SecurityProtocolType]::Tls11 `
    -bor [Net.SecurityProtocolType]::Tls
}
catch {}

if (-Not (Test-Path -Path "$path_log\")) {
  New-Item -Path "$path_log" -Force -ItemType Directory
}
if (-Not (Test-Path -Path "$path_log\apps")) {
  New-Item -Path "$path_log\apps\" -Force -ItemType Directory
}
try {
  $name_install_log = $env:USERNAME
  if ([string]::IsNullOrEmpty($name_install_log)) {
    $name_install_log = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Replace("\", "-")
  }
  $i = 0
  $path_log_file = "$path_log\auto-install-$name_install_log"
  while (Test-Path "$path_log_file.$i.log") {
    $i = $i + 1
  }
  Start-Transcript -Append "$path_log_file.$i.log"
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
if ("$in_system_context" -eq "$False") {
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
  if (($args.Count -le 0) -Or ([string]::IsNullOrEmpty($num))) {
    $num = 18
  }
  return -join ((65..90) + (97..122) | Get-Random -Count $num | ForEach-Object { [char]$_ })
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
  Set-ItemProperty -Path $regKey -Name $keyName -value $value
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
      Invoke-WebRequest "$url" -OutFile "$dest"
      show_log "Pronto."
      if (Test-path "$dest") {
        show_log "Baixado e salvo."
      }
      else {
        show_warn "Baixado, mas NÃO foi salvo no destino."
      }
    }
    catch {
      show_error "Falha ao baixar arquivo"
    }
  }
  else {
    show_log "Arquivo já existente '$dest'"
  }
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

    $tmp = rand_name
    $tmpFile = "$env:TEMP\$tmp.tmp"

    Invoke-WebRequest $url -OutFile $tmpFile -ErrorAction Stop

    if (-Not (Test-Path $tmpFile)) {
      show_warn "Arquivo temporário não foi criado."
      return ""
    }

    $myString = Get-Content $tmpFile -ErrorAction SilentlyContinue

    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

    if ($null -eq $myString) {
      return ""
    }

    return $myString.ToString().Trim()
  }
  catch {
    show_error "Falha ao baixar conteúdo de '$url'"
    return ""
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function fixWingetLocation {
  $winget = $null
  try {
    $DesktopAppInstaller = "%SystemDrive%\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
    $paths = Get-ChildItem "%SystemDrive%\Program Files\WindowsApps" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe" } | Sort-Object Name -Descending
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
  for (; Test-Path "$path_log\apps\winget.update.$i.log"; $i = $i + 1) {}
  $path_log_full = "$path_log\apps\winget.update.$i.log"
  winget_run_command "upgrade --all --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath '$path_log_full'"
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function runInPWSH7() {
  param(
    [string]$cmd_
  )

  $pwshPath = "%SystemDrive%\Program Files\PowerShell\7\pwsh.exe"

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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function run_command {
  param(
    [string]$command_
  )
  $id_ = rand_name(7)
  try {
    show_cmd "[$id_] $command_"
    $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $command_" -Wait -PassThru -WindowStyle Hidden
    show_log "[$id_] Executado."
  }
  catch {    
    if (-not $script:__ps7_fallback_used) {
      $script:__ps7_fallback_used = $true
      show_error "[$id_] Falha ao executar comando. Tentando com PWSH 7..."
      runInPWSH7 "$command_"
    }
    else {
      show_error "[$id_] Falha definitiva (já tentou PS7)."
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
  while ($true) {
    if ( $winget | Test-Path) {
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
  for (; Test-Path "$path_log\apps\$name_id.winget.$i.log"; $i = $i + 1) {}
  $path_log_full = "$path_log\apps\$name_id.winget.$i.log"
  show_log "Log: '$path_log_full'"
  if (-Not ([string]::IsNullOrEmpty($override))) {
    $override = "--override `"$override`""
  }
  $defaut_parameters = "--verbose --scope machine --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements $override"
  winget_run_command "install --id '$name_id' $defaut_parameters | Out-File -FilePath '$path_log_full'"
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
      foreach ($Drive in (Get-PSDrive -PSProvider 'FileSystem')) {
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
        
    $files += Get-ChildItem -Path $root -Recurse -Include *.exe, *.msi -File -ErrorAction SilentlyContinue
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
    $tokens += ($name_id -split '[\.\-\_\s]')
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
function isowin_install_app {
  param(
    [string]$name_id,
    [string]$override
  )
  show_log_title "Instalando '$name_id'"
  $name_id = $name_id.trim()
    
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
    $current_log = Join-Path $path_log "apps\$id_only.log"

    if ("msi" -eq $extencao) {
      $msi_args = "/i ""$nn"" /qn -Wait /L*V ""$current_log"" $override"
      run_command "msiexec.exe $msi_args"
    }
    elseif ("exe" -eq $extencao) {
      # CORREÇÃO: Agora o log do EXE funciona corretamente
      try {
        show_cmd "& ""$nn"" /silent /install $override"

        $proc = Start-Process -FilePath $nn `
          -ArgumentList "/silent /install $override" `
          -RedirectStandardOutput "$current_log" `
          -RedirectStandardError "$current_log" `
          -NoNewWindow `
          -PassThru

        while (-not $proc.HasExited) {
          Start-Sleep -Seconds 1
        }

        show_log "Instalação concluída (EXE)."
      }
      catch {
        show_error "Falha ao executar '$nn'"
      }
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
    [string]$to
  )
  $url = $url.trim()
  if (-Not ("$url" -match "^http.*")) {
    return ""
  }
  if ([string]::IsNullOrEmpty($to)) {
    $tmp = rand_name
    $to = "$env:TEMP\$tmp.tmp"
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
    $drivers_path = "$drive_root" + "Drivers"

    if (-Not (Test-Path $drivers_path)) {
      show_log "Nenhuma pasta 'Drivers' encontrada."
      return
    }

    show_log "Disparando instalação assíncrona de drivers em '$drivers_path'"

    $cmd = "pnputil.exe /add-driver `"$drivers_path\*.inf`" /subdirs /install & pnputil.exe /scan-devices"

    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden

    show_log "Instalação de drivers iniciada em background."

  }
  catch {
    show_error "Falha ao iniciar instalação assíncrona de drivers."
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function Ensure-PS7 {
  $pwshPath = "%SystemDrive%\Program Files\PowerShell\7\pwsh.exe"

  # Já estamos no PS7? então NÃO faz nada
  if ($PSVersionTable.PSVersion.Major -ge 7) {
    show_log "Já em PowerShell 7 — não é necessário relançar."
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

#######################################################
#######################################################
#####
##### INICIO
#####
#######################################################
#######################################################
write-host "Iniciando..."
Ensure-PS7
Start-Sleep -Seconds 1
$appsinstall_folder = appinstall_find_path
Write-Host "Pendrive?: '$appsinstall_folder'"
show_log_title "Desabilitando Hibernação."
try {
  powercfg.exe /hibernate off
}
catch {
  show_log "Falha ao desabilitar hibernação."
}
#######################################################
#######################################################
#####
##### PiwerShell 7
#####
#######################################################
#######################################################
$x = Get-Command "pwsh" -errorAction SilentlyContinue
if ([string]::IsNullOrEmpty($x)) {
  show_log_title "Instalando powershell 7"
  try {
    download_msi_install $url_pwsh "ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1"
    Start-Sleep -Seconds 1
    $x1 = Get-Command "pwsh" -errorAction SilentlyContinue
    if (-Not ([string]::IsNullOrEmpty($x1))) {
      Remove-Item "$pwsh_msi_path" -Force
    }
  }
  catch {
    show_error "FALHA AO INSTALAR POWESHELL 7"
  }
}
$appsinstall_folder = appinstall_find_path
Write-Host "Pendrive?: '$appsinstall_folder'"
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
  if ("$in_system_context" -eq "$False") {
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
if ("$in_system_context" -eq "$False") {
  show_log_title "Fix winget, forçando disponibilização de winget no contexto do sistema"
  try {
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe | write-host
  }
  catch {
    show_error "Falha ao executar Add-AppxPackage "
  }
  show_log_title "Winget setup fix 1"
  try {
    $ResolveWingetPath = Resolve-Path "%SystemDrive%\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
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
  isowin_winget_update
}
#######################################################
#######################################################
#####
##### INSTALAÇÕES
#####
#######################################################
#######################################################
if ("$in_system_context" -eq "$False") {
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
if ("$in_system_context" -eq "$False") {
  if ([string]::IsNullOrEmpty($Env:autonome_test)) {
    Start-Sleep -Seconds 1
    Start-Sleep -Seconds 2
    Restart-Computer
  }
}