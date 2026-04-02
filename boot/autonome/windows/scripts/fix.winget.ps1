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