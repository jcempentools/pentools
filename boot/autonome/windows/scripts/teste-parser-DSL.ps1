# =========================
# TESTE DSL PARSER (STRICT MODE)
# USO EXCLUSIVO: resolve_parser_expression
# =========================

# --- IMPORT DA BIBLIOTECA ---
$libPath = Join-Path $PSScriptRoot "parser-DSL.ps1"

if (-not (Test-Path $libPath)) {
  throw "Biblioteca não encontrada em: $libPath"
}

# isolamento: remove possíveis versões já carregadas
if (Get-Command resolve_parser_expression -ErrorAction SilentlyContinue) {
  Remove-Item function:resolve_parser_expression -ErrorAction SilentlyContinue
}

. $libPath

# assertiva: garantir que a função veio da lib
$cmd = Get-Command resolve_parser_expression -ErrorAction SilentlyContinue
if (-not $cmd) {
  throw "resolve_parser_expression não foi carregada"
}

# =========================
# CALLBACK (neutro)
# =========================
$callback = {
  param($msg, $type)
}

# =========================
# VALIDAÇÃO (SEM PARSER)
# =========================
function Test-IsValidUrl {
  param([string]$value)

  if (-not $value) { return $false }

  # regra crítica: nenhuma DSL residual
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
# MASSA DE TESTE (100% DSL)
# =========================
$tests = @(
  '${"https://api.github.com"}.current_user_url',

  '${"https://api.github.com/repos/PowerShell/PowerShell"}.html_url',
  '${"https://api.github.com/repos/PowerShell/PowerShell"}.owner.avatar_url',

  '${"https://api.github.com/repos/microsoft/vscode"}.owner.html_url',

  '${"https://api.github.com/repos/nodejs/node"}.owner.avatar_url',

  '${"https://api.github.com/repos/PowerShell/PowerShell/releases"}[0].html_url',
  '${"https://api.github.com/repos/microsoft/vscode/commits"}[0].html_url'
)

# =========================
# EXECUÇÃO (APENAS LIB)
# =========================
$results = @()

foreach ($input in $tests) {

  # garante que TODO input exige parser
  if (-not (has_parser_expression $input)) {
    throw "Entrada inválida (sem DSL): $input"
  }

  $output = $null

  try {
    # 🔒 ÚNICO ponto de resolução permitido
    $output = resolve_parser_expression -source $input -callback $callback
  }
  catch {
    $output = $null
  }

  $isValid = Test-IsValidUrl $output

  $results += [PSCustomObject]@{
    Input  = $input
    Output = $output
    Valid  = $isValid
    Status = if ($isValid) { "PASS" } else { "FAIL" }
  }
}

# =========================
# RELATÓRIO
# =========================
$pass = ($results | Where-Object Status -eq "PASS").Count
$fail = ($results | Where-Object Status -eq "FAIL").Count

Write-Host "`n=== DSL PARSER TEST (STRICT LIB MODE) ==="
Write-Host "TOTAL: $($results.Count)"
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail`n"

$results | Format-Table -AutoSize

# =========================
# ASSERTIVA FINAL (FAIL HARD)
# =========================
if ($fail -gt 0) {
  throw "Teste falhou: $fail casos inválidos"
}