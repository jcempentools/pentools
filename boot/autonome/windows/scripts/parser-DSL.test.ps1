#requires -version 5.1

# No topo do script
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8 

# =========================
# TESTE DSL PARSER (REAL-TIME LOG)
# =========================

# --- IMPORT DA BIBLIOTECA ---
$libPath = Join-Path $PSScriptRoot "parser-DSL.ps1"

if (-not (Test-Path $libPath)) {
  throw "Biblioteca não encontrada em: $libPath"
}

if (Get-Command resolve_parser_expression -ErrorAction SilentlyContinue) {
  Remove-Item function:resolve_parser_expression -ErrorAction SilentlyContinue
}

. $libPath

if (-not (Get-Command resolve_parser_expression -ErrorAction SilentlyContinue)) {
  throw "resolve_parser_expression não carregada"
}

# =========================
# CALLBACK (LOG STREAM)
# =========================
# força encoding UTF-8 no console (compatível PS 5.1 / 7+)
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  chcp 65001 > $null 2>&1
}
catch {}

$callback = {
  param($msg, $type)

  $prefix = switch ($type) {
    "e" { "[ERROR]" }
    "w" { "[WARN ]" }
    "i" { "[INFO ]" }
    "l" { "[LOG  ]" }
    "t" { "[STEP ]" }
    default { "[.... ]" }
  }

  $color = switch ($type) {
    "e" { "Red" }
    "w" { "Yellow" }
    "i" { "Cyan" }
    "t" { "Magenta" }
    default { "Gray" }
  }

  try {
    # normalização determinística (ANSI -> UTF-8)
    $safeMsg = $msg
    try {
      $safeMsg = [System.Text.Encoding]::UTF8.GetString(
        [System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage).GetBytes([string]$msg)
      )
    }
    catch {}

    [Console]::WriteLine("{0} {1}", $prefix, $safeMsg)
  }
  catch {
    Write-Host "$prefix $msg" -ForegroundColor $color
  }
}

# =========================
# VALIDAÇÃO
# =========================
function Test-IsValidUrl {
  param([string]$value)

  if (-not $value) { return $false }
  if ($value -match '\$\{') { return $false }

  try {
    $uri = [System.Uri]$value
    return $uri.Scheme -in @("http", "https")
  }
  catch {
    return $false
  }
}

# =========================
# MASSA DE TESTE
# =========================
$tests = @(
  '${"https://api.github.com"}.current_user_url',
  '${"https://api.github.com/repos/PowerShell/PowerShell"}.html_url',
  '${"https://api.github.com/repos/PowerShell/PowerShell"}.owner.avatar_url',
  '${"https://api.github.com/repos/microsoft/vscode"}.owner.html_url',
  '${"https://api.github.com/repos/nodejs/node"}.owner.avatar_url',
  '${"https://api.github.com/repos/PowerShell/PowerShell/releases"}[@draft="false"].url',
  '${"https://api.github.com/repos/microsoft/vscode/commits"}[1].url'
)

# =========================
# EXECUÇÃO COM LOG EM TEMPO REAL
# =========================
$results = @()
$index = 0

Write-Host "`n=== INÍCIO TESTE DSL (REAL-TIME) ===`n" -ForegroundColor Green

foreach ($input in $tests) {

  $index++

  Write-Host "-------------------------------------" -ForegroundColor DarkGray
  Write-Host "[TEST $index/$($tests.Count)]" -ForegroundColor White
  Write-Host "INPUT : $input" -ForegroundColor Gray

  if (-not (has_parser_expression $input)) {
    Write-Host "[ERROR] Entrada não contém DSL válida"    Write-Host "[ERROR] Entrada não contém DSL válida" -ForegroundColor Red
    continue
  }

  $output = $null

  try {
    Write-Host "[STEP ] Resolvendo..." -ForegroundColor Magenta
    $output = resolve_parser_expression -source $input -callback $callback
  }
  catch {
    Write-Host "[ERROR] Exceção: $($_.Exception.Message)" -ForegroundColor Red
    $output = $null
  }

  Write-Host "[INFO ] OUTPUT: $output" -ForegroundColor Cyan

  $isValid = Test-IsValidUrl $output

  if ($isValid) {
    Write-Host "[PASS ] URL válida" -ForegroundColor Green
  }
  else {
    Write-Host "[FAIL ] URL inválida ou resolução falhou" -ForegroundColor Red
  }

  $results += [PSCustomObject]@{
    Input  = $input
    Output = $output
    Valid  = $isValid
    Status = if ($isValid) { "PASS" } else { "FAIL" }
  }
}

# =========================
# RESUMO FINAL
# =========================
$pass = ($results | Where-Object Status -eq "PASS").Count
$fail = ($results | Where-Object Status -eq "FAIL").Count

Write-Host "`n=====================================" -ForegroundColor DarkGray
Write-Host "RESUMO FINAL" -ForegroundColor White
Write-Host "=====================================" -ForegroundColor DarkGray
Write-Host "TOTAL: $($results.Count)" -ForegroundColor Gray
Write-Host "PASS : $pass" -ForegroundColor Green
Write-Host "FAIL : $fail" -ForegroundColor Red
Write-Host "=====================================" -ForegroundColor DarkGray

