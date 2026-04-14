# carregar biblioteca
. "$PSScriptRoot\apps.yml.ps1"

# resolver caminho absoluto do manifesto (BLINDADO)
$manifestPath = Join-Path $PSScriptRoot "..\apps-list.json"
$manifestPath = [System.IO.Path]::GetFullPath($manifestPath)

if (-not (Test-Path $manifestPath)) {
  throw "manifesto não encontrado: $manifestPath"
}

# execução
$m = load_manifest $manifestPath
$list = resolve_profile $m "default"

# saída
foreach ($app in $list) {
  Write-Host "ID: $($app.id)"
  Write-Host "Canonico: $(get_value $app.id 'canonico')"
  Write-Host "URL: $($app.url)"
  Write-Host "Ext: $(get_value $app.id 'extension')"
  Write-Host "File: $(get_value $app.id 'filename')"
  Write-Host "----"
}