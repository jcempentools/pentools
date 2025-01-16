Param(
  [string]$is_test
)
$path_log = "c:\appinstall.log"
$pwsh_msi_path = "c:\pwsh_install.msi"
$pendrive_autonome_path = "boot\Autonome-install\windows"
$image_folder = "C:\Users\Default\Pictures"
$pendrive_script_name = "run.ps1"
$url_pwsh = "github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi"
$url_WallPapers_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/WallPapers/WallPaper.lst"
$url_apps_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/windows"
$url_lockscreen = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/WallPapers/lockscreen.lst"
$url_defWallPaper = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/WallPapers/default.lst"
$appsinstall_folder = "" # manter vazio
$winget_timeout = "" # manter vazio
Write-Host " "
# modo full
if ("$Env:install_cru" -eq "dev") {
  $url_apps_lst = "$url_apps_lst/apps.dev.lst"
}
elseif ("$Env:install_cru" -eq "full") {
  $url_apps_lst = "$url_apps_lst/apps.full.lst"
}
elseif ("$Env:install_cru" -eq "basic") {
  $url_apps_lst = "$url_apps_lst/apps.lst"
  # modo dev
}
$in_system_context = (("$env:USERNAME" -eq "$env:COMPUTERNAME") -Or ("$env:USERNAME" -eq "SYSTEM") -Or (("$env:COMPUTERNAME" -match '(?-i)^SYSTEM.*')))
if (-Not ([string]::IsNullOrEmpty($is_test))) {
  $Env:autonome_test = "1"
}
if ("$in_system_context" -eq "$False") {
  $image_folder = "C:\Users\${env:USERNAME}\Pictures"
}
try {
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
}
catch {
  write-host "[ERROR]: falha ao setar política de execuçao."
}
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
Write-Host "Instação crua.........: '$Env:install_cru'"
write-host "Em modo teste.........: '$Env:autonome_test'"
write-host "Em contexto de sistema: '$in_system_context'"
write-host "Usuário atual.........: '$name_install_log'"
Write-Host ""
write-host "..."
Start-Sleep -Seconds 1
if ("$in_system_context" -eq "$False") {
  if ([string]::IsNullOrEmpty($Env:autonome_test)) {
    try {
      taskkill /F /IM explorer.exe
      taskkill /F /IM msedge.exe
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_error {
  param(
    [string]$str_menssagem
  )
  Write-Host "[ERROR]:" -BackgroundColor Red
  Write-Host "[ERROR]: $str_menssagem" -BackgroundColor Red
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_log {
  param(
    [string]$str_menssagem
  )
  Write-Host "---> $str_menssagem" -BackgroundColor DarkGray
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_warn {
  param(
    [string]$str_menssagem
  )
  Write-Host "[WARN] " -BackgroundColor Yellow -ForegroundColor Black
  Write-Host "[WARN]: $str_menssagem" -BackgroundColor Yellow -ForegroundColor Black
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function show_nota {
  param(
    [string]$str_menssagem
  )
  Write-Host "[NOTA]: $str_menssagem" -BackgroundColor Gray -ForegroundColor Black
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function download_to_string() {
  param(
    [string]$url
  )
  $tmp = -join ((65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
  $tmpFile = "$env:TEMP\$tmp.tmp"
  Invoke-WebRequest $url -OutFile $tmpFile
  $myString = Get-Content $tmpFile
  Remove-Item $tmpFile
  return $myString.trim()
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function fixWingetLocation {
  $winget = $null
  try {
    $DesktopAppInstaller = "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
    $SystemContext = Resolve-Path "$DesktopAppInstaller"
    if ($SystemContext) {
      $SystemContext = $SystemContext[-1].Path
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function isowin_winget_update {
  show_log_title "Atualizando winget..."
  $i = 0
  for (; Test-Path "$path_log\apps\winget.update.$i.log"; $i = $i + 1) {}
  $path_log_full = "$path_log\apps\winget.update.$i.log"
  winget_run_command "upgrade --all --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath '$path_log_full'"
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function runInPWSH7() {
  param(
    [string]$cmd_
  )
  switch ($PSVersionTable.PSVersion.Major) {
    ## 7 and (hopefully) later versions
    { $_ -ge 7 } {
      show_log "já estávamos no PSWH 7"
      return ""
    } # PowerShell 7
    ## 5, and only 5. We aren't interested in previous versions.
    5 {
      $tmp = -join ((65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
      $tmp = "c:\run_$tmp.ps1"
      write-host "$cmd_" | Out-File -FilePath "$tmp"
      $command_ = "pwsh.exe -NoProfile -Command 'Get-Content -LiteralPath $tmp -Raw | Invoke-Expression;'"
      try {
        show_cmd "$command_"
        $command_ | Invoke-Expression
        show_nota "winget supostamente executado corretamente."
      }
      catch {
        show_error "FALHA final ao instalar '$name_id'"
      }
      finally {
        Remove-Item $tmp -Force
      }
    } # PowerShell 5
    default {
      ## If it's not 7 or later, and it's not 5, then we aren't doing it.
      show_error "Unsupported PowerShell version [2]."
    } # default
  } # switch
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function run_command {
  param(
    [string]$command_
  )
  $id_ = -join ((65..90) + (97..122) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
  try {
    show_cmd "[$id_] $command_"
    "& $command_" | Invoke-Expression
    show_log "[$id_] Executado."
  }
  catch {
    show_error "[$id_] Falha ao executar comando. Tentando com PWSH 7..."
    runInPWSH7 "$command_"
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function winget_run_command {
  param(
    [string]$command_
  )
  show_log "Configurando Winget..."
  $winget = fixWingetLocation
  if ([string]::IsNullOrEmpty($winget_timeout)) {
    $winget_timeout = [datetime]::Now.AddMinutes(5)
  }
  while ($true) {
    if ( $winget | Test-Path) {
      run_command "$winget $command_"
      return ;
    }
    if ( [datetime]::Now -gt $winget_timeout ) {
      'Winget: File {0} indisponível ainda.' -f $winget | Write-Warning;
      return ;
    }
    Start-Sleep -Seconds 1;
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function appinstall_find_path() {
  if (([string]::IsNullOrEmpty($appsinstall_folder)) -Or (-Not (Test-path $appsinstall_folder))) {
    try {
      foreach ($Drive in (Get-PSDrive -PSProvider 'FileSystem')) {
        #foreach ($Drive in [System.IO.DriveInfo]::GetDrives())) {
        if (Test-Path -Path "${Drive}:\$pendrive_autonome_path") {
          $appsinstall_folder = "${Drive}:\$pendrive_autonome_path"
          break
        }
      }
    }
    catch {
      write-host ""
      show_nota 'Falha ao localizar pasta de instalação offline'
      return ""
    }
  }
  return $appsinstall_folder
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function findExeMsiOnFolders() {
  param(
    [string]$name_id
  )
  $path = appinstall_find_path
  if ((-Not ([string]::IsNullOrEmpty($path))) -And (Test-path $path)) {
    $name_id = $name_id.trim()
    $exts = @('exe', 'msi')
    $names = @($name_id, $name_id.split(".")[-1])
    $folders = @('', 'apps\')
    foreach ( $f in $folders) {
      foreach ( $n in $names) {
        foreach ( $e in $exts) {
          if (Test-Path -Path "${path}\${f}${n}.$e") {
            return "${path}\${f}${n}.$e"
          }
        }
      }
    }
  }
  return ""
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function isowin_install_app {
  param(
    [string]$name_id,
    [string]$override
  )
  show_log_title "Instalando '$name_id'"
  $name_id = $name_id.trim()
  $is_url = ""
  if ("$name_id" -match "^[\w]+|s*(http|ftp)s?[^|]+") {
    $is_url = $name_id.split("|")[-1]
    $name_id = $name_id.split("|")[0]
  }
  $nn = findExeMsiOnFolders($name_id)
  if (-Not ([string]::IsNullOrEmpty($nn))) {
    $extencao = $nn.split(".")[-1]
    show_log "Arquivo offline '.$extencao' encontrado"
    show_log "File: '$nn'"
    show_log "Executando..."
    if ("msi" -eq "$extencao") {
      if ([string]::IsNullOrEmpty($override)) {
        $override = ""
      }
      run_command "& msiexec.exe /i '$nn' /qn -Wait /L*V '$path_log\apps\$name_id.log' $override"
    }
    elseif ("exe" -eq "$extencao") {
      run_command "'$nn' | Out-File -FilePath '$path_log_full'"
    }
    return ""
  }
  show_nota "Arquivo de instalação offline inexistente, tentando via winget..."
  $installed = "1"
  if (-Not ([string]::IsNullOrEmpty($is_url))) {
    $installed = download_msi_install "$is_url"
  }
  if (([string]::IsNullOrEmpty($is_url)) -Or ([string]::IsNullOrEmpty($installed))) {
    isowin_winget_install $name_id $override
  }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
    $tmp = -join ((65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ })
    $to = "$env:TEMP\$tmp.tmp"
  }
  try {
    download_save "$url" "$to"
    show_cmd "& msiexec.exe /package '$to' /quiet $op | write-host"
    run_command "msiexec.exe /package '$to' /quiet $op | write-host"
    write-host "Supostamente instalado."
    return ""
  }
  catch {
    show_error "Falha ao instalar da URL: '$url'"
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
if (("$Env:install_cru" -ne "cru") -And ($img_count -le 0)) {
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
    $ResolveWingetPath = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
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
  if ("$Env:install_cru" -eq "dev") {
    wsl --install
    wsl --set-default-version 2
  }
  show_log_title "Instalando demais APPs"
  if ("$Env:install_cru" -ne "cru") {
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
      foreach ($line in Get-Content "$appsinstall_folder\apps.lst") {
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
      run_command "& powershell.exe -NoProfile -Command 'Get-Content -LiteralPath '$appsinstall_folder\$pendrive_script_name' -Raw | Invoke-Expression; ' | write-host"
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
    Restart-Computer
  }
}
