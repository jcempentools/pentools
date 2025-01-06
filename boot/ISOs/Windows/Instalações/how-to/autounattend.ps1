Param(
  [string]$is_test    
)

$path_log = "c:\appinstall.log"
$pwsh_msi_path = "c:\pwsh_install.msi"
$pendrive_autonome_path = "boot\Autonome-install\windows"
$image_folder = "C:\Users\Default\Pictures"
$pendrive_script_name = "run.ps1"
$url_wallpappers_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/wallpappers/wallpapper.lst"
$url_apps_lst = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/windows/apps.lst"
$url_lockscreen = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/wallpappers/lockscreen.lst"
$url_defwallpapper = "raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/wallpappers/default.lst"
$appsinstall_folder = "" # manter vazio

Write-Host " "

if (-Not ([string]::IsNullOrEmpty($is_test))) {  
  $Env:autonome_test = "1"
}

if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
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
  for (; Test-Path "$path_log\auto-install-$name_install_log.$i.log"; $i++) {}
  $name_install_log = "$name_install_log.$i"

  Start-Transcript -Append "$path_log\custom-install-$name_install_log.log"
}
catch {}

Write-Host "-------------------------------------------------" -BackgroundColor blue
Write-Host "             Não Feche esta janela              "-BackgroundColor blue
Write-Host "-------------------------------------------------" -BackgroundColor blue

Write-Host ""
Write-Host "Instação crua: '$Env:install_cru'"
Write-Host ""

write-host "..."

Start-Sleep -Seconds 3

if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
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
  $tmpFile = "c:\$tmp.tmp"
  Invoke-WebRequest $url -OutFile $tmpFile
  $myString = Get-Content $tmpFile
  Remove-Item $tmpFile
  return $myString.trim()
}

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function isowin_install_pwsh7 {
  show_log_title "Instalando powershell 7"

  $x = Get-Command "pwsh" -errorAction SilentlyContinue
  if (-Not ([string]::IsNullOrEmpty($x))) {
    return ""
  }

  try {
    download_save "github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi" "$pwsh_msi_path"    

    show_cmd "& msiexec.exe /package '$pwsh_msi_path' /quiet ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1 | write-host"
    & msiexec.exe /package "$pwsh_msi_path" /quiet ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1 | write-host  

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

  $winget = fixWingetLocation
  
  try {
    show_cmd "& '$winget' update --all | write-host"
    & "$winget" update --all | write-host

    show_log "winget atualizado!"
  }
  catch {
    # Catch any error
    show_error "winget: Falha ao atualizar winget, tentando com PWSH 7"
    runInPWSH7 "pwsh -NoProfile -Command 'winget update --all"
  }
}


#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
function runInPWSH7() {
  param(
    [string]$cmd_,
    [string]$path_log_full
  )

  switch ($PSVersionTable.PSVersion.Major) {
    ## 7 and (hopefully) later versions
    { $_ -ge 7 } {
      show_log "já estávamos no PSWH 7"
      return 0
    } # PowerShell 7

    ## 5, and only 5. We aren't interested in previous versions.
    5 {
      isowin_install_pwsh7

      try {          
        if (-Not ([string]::IsNullOrEmpty($nn))) {      
          show_cmd "& pwsh -NoProfile -Command '$cmd_'  | write-host"
          & pwsh -NoProfile -Command "$cmd_"  | write-host
        }
        else {
          show_cmd "& pwsh -NoProfile -Command '$cmd_'  | Out-File -FilePath '$path_log_full'"
          & pwsh -NoProfile -Command "$cmd_"  | Out-File -FilePath "$path_log_full"
        }

        show_nota "$name_id supostamente executado corretamente."

      }
      catch {
        show_error "FALHA final ao instalar '$name_id'"
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
function isowin_winget_install {
  param(
    [string]$name_id
  )

  show_log "Winget: Instalando $name_id"
  show_log "Configurando Winget..."

  $winget = fixWingetLocation
  
  $i = 0
  for (; Test-Path "$path_log\apps\$name_id.winget.$i.log"; $i++) {}
  $path_log_full = "$path_log\apps\$name_id.winget.$i.log"
  show_log "Log: '$path_log_full'"

  try {
    $timeout = [datetime]::Now.AddMinutes( 5 );    

    while ($true) {
      if ( $winget | Test-Path) {
        show_cmd "& '$winget' install --id '$name_id' --scope machine --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath '$path_log_full'"
        & "$winget" install --id "$name_id" --verbose --scope machine --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath "$path_log_full"    
        show_log "$name_id instalado."
        return
      }

      if ( [datetime]::Now -gt $timeout ) {
        'Winget: File {0} does not exist.' -f $winget | Write-Warning;
        return;
      }            

      Start-Sleep -Seconds 1;
    }
  }
  catch {
    # Catch any error
    show_error "Winget: Falha ao instalar '$name_id', tentando com PWSH 7"
    runInPWSH7 "$winget install --scope machine --id '$name_id' --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements" "$path_log_full"  
  }
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
    [string]$name_id
  )

  show_log_title "Instalando $name_id"
  
  $nn = findExeMsiOnFolders($name_id)
      
  if (-Not ([string]::IsNullOrEmpty($nn))) {      
    $extencao = $nn.split(".")[-1]
    show_log "Arquivo offline '.$extencao' encontrado"
    show_log "File: '$nn'"
    show_log "Executando..."

    try {
      if ("msi" -eq "$extencao") {        
        show_cmd "& msiexec.exe /i '$nn' /qn -Wait /L*V '$path_log\apps\$name_id.log'"
        & msiexec.exe /i "$nn" /qn -Wait /L*V "$path_log\apps\$name_id.log"
      }
      elseif ("exe" -eq "$extencao") {
        show_cmd "$ExecutionContext.InvokeCommand.ExpandString('$nn | Out-File -FilePath '$path_log_full')"
        $ExecutionContext.InvokeCommand.ExpandString("'$nn' | Out-File -FilePath '$path_log_full'")
      }        
    }
    catch {
      show_error "Falha ao executar aquivo de instalação offline, tentando via winget... "
      isowin_winget_install $name_id
    }

    return ""
  }  
  
  show_nota "Arquivo de instalação offline inexistente, tentando via winget..."

  isowin_winget_install $name_id
}

#######################################################
#######################################################
#####
##### INICIO
#####
#######################################################
#######################################################

write-host "Iniciando..."

Start-Sleep -Seconds 3
$appsinstall_folder = appinstall_find_path
Write-Host "Pendrive?: '$appsinstall_folder'"

#######################################################
#######################################################
#####
##### WINGET
#####
#######################################################
#######################################################

show_log_title "Fix winget, forçando disponibilização de winget no contexto do sistema"

try {
  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe | write-host
}
catch { 
  show_error "falha ao executar Add-AppxPackage "
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

#######################################################
#######################################################
#####
##### WALLPAPPERS
#####
#######################################################
#######################################################

show_log_title "### Wallpappers"

$wallpappers_path = ""

if (-Not ([string]::IsNullOrEmpty($appsinstall_folder))) {
  $wallpappers_path = (get-item $appsinstall_folder).Parent.FullName
  $wallpappers_path = "$wallpappers_path\wallpappers\images"
}

$image_folder = "$image_folder\wallpappers"
$img_count = 0

if ((-Not ([string]::IsNullOrEmpty($wallpappers_path))) -And (Test-Path -Path "$wallpappers_path")) {
  show_log "Obtendo wallpappers do pendrive, se exitir..."

  foreach ($ee in @('png', 'jpg')) {
    Get-ChildItem -Path "$wallpappers_path" -Filter "*.$ee" -Recurse -File | ForEach-Object {
      try {
        $nome = $_.BaseName
        Copy-Item $_ "$image_folder\$nome.$ee" -Force
        $img_count++
      }
      catch {
        # ignore
      }
    }
  }

  show_log "'$img_count' wallpapper(s) obdito(s) offline."
}

if (([string]::IsNullOrEmpty($Env:install_cru)) -And ($img_count -le 0)) {
  show_log "Obtendo wallpappers ONLINE..."    

  if (-Not (Test-Path -Path "$image_folder")) {  
    New-Item -Path "$image_folder" -Force -ItemType Directory
  }
  
  download_save "$url_wallpappers_lst" "$image_folder\download.lst"    

  if (Test-Path "$image_folder\download.lst") {
    $i = 0
    $ext = "png"
    foreach ($line in Get-Content "$image_folder\download.lst") {
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

      $i++
    }  
  }  

  show_log_title "Definindo tela de bloqueio personalizada"
  $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'  
  # create the key if it doesn't already exist
  if (!(Test-Path -Path $regKey)) {
    $null = New-Item -Path $regKey
  }

  # now set the registry entry
  try {    
    $nome = download_to_string($url_lockscreen)
    Set-ItemProperty -Path $Key -Name 'LockScreenImagePath' -value "$image_folder\$nome.jpg"
  }
  catch {
    show_error "FALHA ao definir tela de bloqueio."
  }

  if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
    show_log_title "Definindo wallpapper"
    # now set the registry entry
    try {    
      $nome = download_to_string($url_defwallpapper)
      Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallPaper" -Value "$image_folder\$nome.jpg"
    }
    catch {
      show_error "FALHA ao definir wallpapper."
    }  
  }
}

#######################################################
#######################################################
#####
##### INSTALAÇÕES
#####
#######################################################
#######################################################

show_log_title "Instalando APPs basiquissimos"

isowin_install_app "Oracle.JavaRuntimeEnvironment"
isowin_install_app "Microsoft.DirectX"
isowin_install_app "CodecGuide.K-LiteCodecPack.Mega"
isowin_install_app "7zip.7zip"
isowin_install_app "Microsoft.VisualStudioCode"

show_log_title "Instalando demais APPs"

if ([string]::IsNullOrEmpty($Env:install_cru)) {

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
      isowin_install_app $line
    }
  }
  else {
    show_log "Obtendo lista online..."  
    $apps_f = "$path_log\apps-download.lst"
    download_save "$url_apps_lst" "$apps_f"

    if (Test-Path "$apps_f") {
      show_log "Lista de apps online encontrato, usando..."

      foreach ($line in Get-Content "$apps_f") {
        isowin_install_app $line
      }    
    }
    else {
      show_log "Lista de apps online inexistente, usando o padrao..."  

      isowin_install_app "Microsoft.PowerToys"
      isowin_install_app "VideoLAN.VLC"  
      isowin_install_app "Google.Chrome"
      isowin_install_app "Brave.Brave"
      isowin_install_app "SumatraPDF.SumatraPDF"
      isowin_install_app "PDFsam.PDFsam"
      isowin_install_app "QL-Win.QuickLook"
      isowin_install_app "Piriform.Defraggler"
      isowin_install_app "CrystalDewWorld.CrystalDiskInfo"
      isowin_install_app "qBittorrent.qBittorrent"
      isowin_install_app "TheDocumentFoundation.LibreOffice"
    }
  }

  show_log "Executar script offline do pendrive '$pendrive_script_name'?"

  # tenta executar o scrip localizado no pendrive
  if (Test-Path "$appsinstall_folder\$pendrive_script_name") {
    show_log "Sim, executando..."
    show_cmd "& pwsh.exe -NoProfile -Command 'Get-Content -LiteralPath '$appsinstall_folder\$pendrive_script_name' -Raw | Invoke-Expression; ' | write-host"
    & pwsh.exe -NoProfile -Command "Get-Content -LiteralPath '$appsinstall_folder\$pendrive_script_name' -Raw | Invoke-Expression; " | write-host  
  }
  else {
    show_log 'Não, não localizado.'
  }
}

show_log_title "Desabilitando Hibernação."

try {
  powercfg.exe /hibernate off
}
catch {
  show_log "Falha ao desabilitar hibernação."
}

write-host ""
write-host "CONCLUIDO"
write-host ""
Write-Host "-------------------------------------------------" -BackgroundColor blue
Write-Host "                  REINICIANDO                   "-BackgroundColor blue
Write-Host "-------------------------------------------------" -BackgroundColor blue

try {
  Stop-Transcript
}
catch {}

#if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
#  if ([string]::IsNullOrEmpty($Env:autonome_test)) {  
#    Restart-Computer
#  }
#}