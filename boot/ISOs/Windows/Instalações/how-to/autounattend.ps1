Param(
  [string]$is_test    
)

$path_log = "c:\appinstall.log"
$pwsh_msi_path = "c:\pwsh_install.msi"
$pendrive_autonome_path = "boot\Autonome-install\windows"
$image_folder = "C:\Users\Default\Pictures"
$pendrive_script_name = "run.ps1"
$url_wallpappers_lst = "https://raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/wallpappers/wallpapper.lst"
$url_apps_lst = "https://raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/Autonome-install/windows/apps.lst"
$appsinstall_folder = "" # manter vazio

Write-Host ""
Write-Host ""
Write-Host "instação crua: '$Env:install_cru'"
Write-Host ""
Write-Host ""

if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
  $image_folder = "C:\Users\${env:USERNAME}\Pictures"
}

try {
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
}
catch { 
  write-host "????? falha ao setar política de execuçao."
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
Write-Host "              Não Feche esta janela              " -BackgroundColor blue
Write-Host "-------------------------------------------------" -BackgroundColor blue

write-host "..."

Start-Sleep -Seconds 3

if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
  if (-Not ($is_test)) {
    try {
      taskkill /F /IM explorer.exe
      taskkill /F /IM msedge.exe
    }
    catch { 
      write-host "."
      write-host "-> falha ao encerar explorer.exe / msedge.exe"
    }
  }
}

Start-Sleep -Seconds 3

####
####
####
function show_log_title {
  param(
    [string]$str_menssagem
  )    

  write-host "."    
  write-host "."
  write-host "$str_menssagem"
}

####
####
####
function sha256 {
  Param (
    [Parameter(Mandatory = $true)]
    [string] $ClearString
  )

  $hasher = [System.Security.Cryptography.HashAlgorithm]::Create('sha256')
  $hash = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ClearString))

  $hashString = [System.BitConverter]::ToString($hash)
  $hashString.Replace('-', '')  
  write-host $hashString
}

####
####
####
function download_save() {
  param(
    [string]$url,
    [string]$dest
  )  
  
  if ([string]::IsNullOrEmpty($url)) {      
    Write-Host "---> URL vazia '$url'."
    return ""
  }

  if (-Not (Test-Path "$dest")) {
    write-host "--->Baixando URL..."
    write-host "Invoke-WebRequest '$url' -OutFile '$dest'"

    try {
      Invoke-WebRequest "$url" -OutFile "$dest"
      write-host "---> Pronto."

      if (Test-path "$dest") {
        write-host "---> Baixado e salvo."
      }
      else {
        write-host ":::: Baixado, mas NÃO foi salvo no destino."
      }
    }
    catch {
      write-host "Falha ao baixar arquivo"
    }
  }
  else {
    write-host "Arquivo já existente."
  }
}

####
####
####
function isowin_install_pwsh7 {
  show_log_title "### Instalando powershell 7"

  $x = Get-Command "pwsh" -errorAction SilentlyContinue
  if (-Not ([string]::IsNullOrEmpty($x))) {
    return ""
  }

  try {
    download_save "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi" "$pwsh_msi_path"    

    write-host "& msiexec.exe /package '$pwsh_msi_path' /quiet ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1 | write-host"
    & msiexec.exe /package "$pwsh_msi_path" /quiet ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1 | write-host  

    Start-Sleep -Seconds 1

    $x1 = Get-Command "pwsh" -errorAction SilentlyContinue
    if (-Not ([string]::IsNullOrEmpty($x1))) {
      Remove-Item "$pwsh_msi_path" -Force
    }
  }
  catch {
    write-show_log_title "????? FALHA AO INSTALAR POWESHELL 7"
  }
}

####
####
####
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
      $winget = "winget"
    }

    #if ($null -ne $winget) { "winget content: $winget" }
    # Logs $(env:LOCALAPPDATA)\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir    
  }
  catch {
    write-host "winget"
    write-host "::: FALHA ao setar winget"
  }

  return $winget
}

####
####
####
function isowin_winget_update {
  show_log_title ">>> Atualizando winget..."

  $winget = fixWingetLocation
  
  try {
    write-host "& '$winget' update --all | write-host"
    & "$winget" update --all | write-host

    write-host "------> winget atualizado!"
  }
  catch {
    # Catch any error
    show_log_title "winget: Falha ao atualizar winget, tentando com PWSH 7"

    switch ($PSVersionTable.PSVersion.Major) {

      ## 7 and (hopefully) later versions
      { $_ -ge 7 } {
        Write-Host "---> já estávamos no PSWH 7"
      } # PowerShell 7

      ## 5, and only 5. We aren't interested in previous versions.
      5 {
        isowin_install_pwsh7

        try {
          write-host "& pwsh -NoProfile -Command 'winget update --all' | write-host"
          & pwsh -NoProfile -Command "winget update --all" | write-host

        }
        catch {
          show_log_title "????? FALHA ao atualizar winget '$name_id'"
        }
      } # PowerShell 5

      default {
        ## If it's not 7 or later, and it's not 5, then we aren't doing it.
        write-host "??? Unsupported PowerShell version [1]."

      } # default

    } # switch    
  }
}

####
####
####
function isowin_winget_install {
  param(
    [string]$name_id
  )

  show_log_title ">>> Winget: Instalando $name_id"
  write-host "- Configurando Winget"

  $winget = fixWingetLocation
  
  $i = 0
  for (; Test-Path "$path_log\apps\$name_id.winget.$i.log"; $i++) {}
  $path_log_full = "$path_log\apps\$name_id.winget.$i.log"
  "Log: $path_log_full"

  try {
    write-host "& '$winget' install --id '$name_id' --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath '$path_log_full'"
    & "$winget" install --id "$name_id" --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements | Out-File -FilePath "$path_log_full"    

    write-host "------> $name_id instalado."
  }
  catch {
    # Catch any error
    write-host "Winget: Falha ao instalar '$name_id', tentando com PWSH 7"

    switch ($PSVersionTable.PSVersion.Major) {
      ## 7 and (hopefully) later versions
      { $_ -ge 7 } {
        Write-Host "---> já estávamos no PSWH 7"
        return 0
      } # PowerShell 7

      ## 5, and only 5. We aren't interested in previous versions.
      5 {
        isowin_install_pwsh7

        try {          
          write-host "& pwsh -NoProfile -Command '$winget install --id '$name_id' --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements'  | Out-File -FilePath '$path_log_full'"
          & pwsh -NoProfile -Command "$winget install --id "$name_id" --verbose --exact --silent --disable-interactivity --accept-package-agreements --accept-source-agreements"  | Out-File -FilePath "$path_log_full"
          write-host "------> $name_id supostamente instalado."

        }
        catch {
          write-host "????? FALHA final ao instalar '$name_id'"
        }

      } # PowerShell 5

      default {
        ## If it's not 7 or later, and it's not 5, then we aren't doing it.
        Write-Host "??? Unsupported PowerShell version [2]."

      } # default
    } # switch    
  }
}

####
####
####
function appinstall_find_path() {    
  if (([string]::IsNullOrEmpty($appsinstall_folder)) -Or (-Not (Test-path $appsinstall_folder))) {    
    try {
      $Drives = Get-PSDrive -PSProvider 'FileSystem'

      foreach ($Drive in $drives) {
        if (Test-Path -Path "${Drive}:\$pendrive_autonome_path") {
          $appsinstall_folder = "${Drive}:\$pendrive_autonome_path"
          break
        }
      }    
    }  
    catch {    
      return ""
      write-host '---> Falha ao localizar pasta de instalação offline'
    }
  }

  return $appsinstall_folder
}

####
####
####
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


####
####
####
function isowin_install_app {
  param(
    [string]$name_id
  )

  show_log_title "Instalando $name_id"
  
  $nn = findExeMsiOnFolders($name_id)
      
  if (-Not ([string]::IsNullOrEmpty($nn))) {      
    $extencao = $nn.split(".")[-1]
    Write-Host "- Arquivo offline '.$extencao' encontrado"
    Write-Host "= '$nn'"
    Write-Host "- Executando..."

    try {
      if ("msi" -eq "$extencao") {        
        write-host "& msiexec.exe /i '$nn' /qn -Wait /L*V '$path_log\apps\$name_id.log'"
        & msiexec.exe /i "$nn" /qn -Wait /L*V "$path_log\apps\$name_id.log"
      }
      elseif ("exe" -eq "$extencao") {
        write-host "$ExecutionContext.InvokeCommand.ExpandString('$nn | Out-File -FilePath '$path_log_full')"
        $ExecutionContext.InvokeCommand.ExpandString("'$nn' | Out-File -FilePath '$path_log_full'")
      }        
    }
    catch {
      write-host "??? Falha ao executar aquivo de instalação offline, tentando via winget... "
      isowin_winget_install $name_id
    }

    return ""
  }  
  
  write-host "- Arquivo de instalação offline inexistente, tentando via winget..."

  isowin_winget_install $name_id
}

write-host "Iniciando..."

Start-Sleep -Seconds 3
$appsinstall_folder = appinstall_find_path

#show_log_title "### Fix winget, forçando disponibilização de winget no contexto do sistema"

#try {
#  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe | write-host
#}
#catch { 
#  write-host "????? falha ao executar Add-AppxPackage "
#}

show_log_title "### Winget setup fix 1"

try {
  $ResolveWingetPath = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
  if ($ResolveWingetPath) {
    $WingetPath = $ResolveWingetPath[-1].Path
  }

  $config

  Write-Host "-> $wingetpath"
  Set-Location "$wingetpath"
}
catch {
  write-show_log_title "????? FALHA ao executar FIX 1"
}

write-host "Atual: $pwd"

if ([string]::IsNullOrEmpty($Env:install_cru)) {
  show_log_title "### Baixando imagens"

  $image_folder = "$image_folder\wallpappers"

  if (-Not (Test-Path -Path "$image_folder")) {  
    New-Item -Path "$image_folder" -Force -ItemType Directory
  }

  write-host "download_save '$url_wallpappers_lst' '$image_folder\download.lst'"
  download_save "$url_wallpappers_lst" "$image_folder\download.lst"    

  if (Test-Path "$image_folder\download.lst") {
    $i = 0
    foreach ($line in Get-Content "$image_folder\download.lst") {
      #$shaname = sha256 $line    
      download_save "$line" "$image_folder\$i.jpg"
      $shaname = (Get-FileHash "$image_folder\$i.jpg" -Algorithm SHA256).Hash    
      Move-Item -Path "$image_folder\$i.jpg" "$image_folder\$shaname.jpg"
      $i++
    }  
  }

  show_log_title "### Definindo tela de bloqueio personalizada"

  $regKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
  # create the key if it doesn't already exist
  if (!(Test-Path -Path $regKey)) {
    $null = New-Item -Path $regKey
  }

  # now set the registry entry
  try {
    Set-ItemProperty -Path $regKey -Name 'LockScreenImage' -value "$image_folder\5F3C1A878379373A9853DC58CC78D414212DFD6063F9E8F48832ED940502902B.jpg"
  }
  catch {
    write-host "????? FALHA ao definir tela de bloqueio"
  }
}

###
isowin_winget_update

show_log_title "### Instalando APPs basiquissimos..."

isowin_install_app "Oracle.JavaRuntimeEnvironment"
isowin_install_app "Microsoft.DirectX"
isowin_install_app "CodecGuide.K-LiteCodecPack.Mega"
isowin_install_app "7zip.7zip"
isowin_install_app "Microsoft.VisualStudioCode"

if ([string]::IsNullOrEmpty($Env:install_cru)) {

  show_log_title "Continuar padrão ou seguir 'apps.lst' do online/pendrive?"

  $apps_lst = ""

  # verifica se tem lista de apps no pendrive
  if (Test-Path "$appsinstall_folder\apps.lst") {
    $apps_lst = "$appsinstall_folder\apps.lst"
  }
  elseif (Test-Path "$appsinstall_folder\apps\apps.lst") {
    $apps_lst = "$appsinstall_folder\apps\apps.lst"
  }

  if (-Not ([string]::IsNullOrEmpty($apps_lst))) {
    Write-Host "---> usando 'apps.lst do pendrive'..."

    foreach ($line in Get-Content "$appsinstall_folder\apps.lst") {
      isowin_install_app $line
    }
  }
  else {
    Write-Host "---> Obtendo lista online..."  
    $apps_f = "$path_log\apps-download.lst"
    download_save "$url_apps_lst" "$apps_f"

    if (Test-Path "$apps_f") {
      Write-Host "---> Lista de apps online encontrato, usando..."

      foreach ($line in Get-Content "$apps_f") {
        isowin_install_app $line
      }    
    }
    else {
      Write-Host "---> Lista de apps online inexistente, usando o padrao..."  

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

  show_log_title "Executar script offline do pendrive '$pendrive_script_name'?"

  # tenta executar o scrip localizado no pendrive
  if (Test-Path "$appsinstall_folder\$pendrive_script_name") {
    Write-Host "---> Sim, executando..."
    & pwsh.exe -NoProfile -Command "Get-Content -LiteralPath '$appsinstall_folder\$pendrive_script_name' -Raw | Invoke-Expression; " | write-host  
  }
  else {
    write-host '---> Não, não localizado.'
  }
}

show_log_title "### Desabilitando Hibernação."

try {
  powercfg.exe /hibernate off
}
catch {
  write-host "---> Falha ao desabilitar hibernação."
}

write-host "CONCLUIDO"

Write-Host "-------------------------------------------------" -BackgroundColor blue
Write-Host "                   REINICIANDO                   " -BackgroundColor blue
Write-Host "-------------------------------------------------" -BackgroundColor blue

try {
  Stop-Transcript
}
catch {}

if (-Not ($env:USERNAME -eq "$env:COMPUTERNAME")) {
  if (-Not ($is_test)) {
    Restart-Computer
  }
}