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

  Write-Host "$prefix $msg"
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

Write-Host "`n=== INÍCIO TESTE DSL (REAL-TIME) ===`n"

foreach ($input in $tests) {

  $index++

  Write-Host "-------------------------------------"
  Write-Host "[TEST $index/$($tests.Count)]"
  Write-Host "INPUT : $input"

  if (-not (has_parser_expression $input)) {
    Write-Host "[ERROR] Entrada não contém DSL válida"
    continue
  }

  $output = $null

  try {
    Write-Host "[STEP ] Resolvendo..."
    $output = resolve_parser_expression -source $input -callback $callback
  }
  catch {
    Write-Host "[ERROR] Exceção: $($_.Exception.Message)"
    $output = $null
  }

  Write-Host "[INFO ] OUTPUT: $output"

  $isValid = Test-IsValidUrl $output

  if ($isValid) {
    Write-Host "[PASS ] URL válida"
  }
  else {
    Write-Host "[FAIL ] URL inválida ou resolução falhou"
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

Write-Host "`n====================================="
Write-Host "RESUMO FINAL"
Write-Host "====================================="
Write-Host "TOTAL: $($results.Count)"
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"
Write-Host "====================================="

if ($fail -gt 0) {
  throw "Teste falhou: $fail casos inválidos"
}