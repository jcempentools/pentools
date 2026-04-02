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
    $apps_lst = ""

    $baseListPath = Join-Path $appsinstall_folder $apps_list_dir

    $mainList = Join-Path $baseListPath "apps.lst"

    if (Test-Path $mainList) {
      $apps_lst = $mainList
    }
    if (-Not ([string]::IsNullOrEmpty($apps_lst))) {
      show_log "usando 'apps.lst do pendrive'..."
      Install-AppList $apps_lst
    }
    else {
      show_log "Obtendo lista online..."
      $apps_f = "$path_log\apps-download.lst"
      if ($url_apps_lst -notmatch '\.lst$') {
        show_error "URL de apps inválida (não é .lst): $url_apps_lst"
      }
      download_save "$url_apps_lst" "$apps_f"
      if (Test-Path "$apps_f") {
        show_log "Lista de apps online encontrada, usando..."
        Install-AppList $apps_f
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