# carregar biblioteca
. "$PSScriptRoot\parser.ps1"

# manifesto de teste inline
$manifest = @"
apps:
  - id: brave
    path: ./brave.syncdownload

profiles:
  - name: default
    items:
      - ref: brave
      - id: customApp
        name: MyTool
        url: https://example.com/tool.exe
"@

# criar arquivo syncdownload simulado
@"
.exe,Standalone,Silent,!Arm64|https://github.com/brave/brave-browser
Brave
"@ | Set-Content -Encoding UTF8 "$PSScriptRoot\brave.syncdownload"

# execução
$m = load_manifest $manifest
$list = resolve_profile $m "default"

# saída
foreach ($app in $list) {
  Write-Host "ID: $($app.id)"
  Write-Host "Name: $(get_value $app.id 'canonico')"
  Write-Host "URL: $($app.url)"
  Write-Host "Ext: $(get_value $app.id 'extension')"
  Write-Host "File: $(get_value $app.id 'filename')"
  Write-Host "----"
}