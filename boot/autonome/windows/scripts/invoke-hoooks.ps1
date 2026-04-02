
show_log_title "Executando gatilhos finais (scripts externos)"

try {
  if ([string]::IsNullOrEmpty($script:appsinstall_folder)) {
    show_log "Pasta base não definida."
    return
  }

  $scriptsPath = Join-Path $script:appsinstall_folder "scripts"

  if (-not (Test-Path $scriptsPath)) {
    show_log "Pasta de scripts não encontrada."
    return
  }

  $baseName = "in.$local_exec"

  $orderedExt = @("reg", "ps1", "cmd", "bat")

  foreach ($ext in $orderedExt) {

    $file = Join-Path $scriptsPath "$baseName.$ext"

    if (-not (Test-Path $file)) {
      continue
    }

    try {
      $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
      if ([string]::IsNullOrWhiteSpace($content)) {
        show_log "Ignorado (vazio): $file"
        continue
      }
    }
    catch {
      show_warn "Falha ao ler conteúdo de $file"
      continue
    }

    show_log "Executando gatilho: $file"

    switch ($ext) {

      "reg" {
        run_command "reg.exe import `"$file`""
      }

      "ps1" {
        run_command "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$file`""
      }

      "cmd" {
        run_command "cmd.exe /c `"$file`""
      }

      "bat" {
        run_command "cmd.exe /c `"$file`""
      }
    }
  }
}
catch {
  show_warn "Falha ao executar gatilhos finais"
}