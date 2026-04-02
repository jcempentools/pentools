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
      if (
        [string]::IsNullOrEmpty($line) -or
        ($line -match '^\s*$') -or
        ($line -match '^\s*#')
      ) {
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