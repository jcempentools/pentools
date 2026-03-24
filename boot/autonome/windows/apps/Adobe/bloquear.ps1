# --- LISTA DE PROGRAMAS ---
$caminhosExe = @(
  "$env:ProgramFiles\Adobe\Adobe Creative Cloud Experience\CCXProcess.exe",
  "$env:ProgramFiles\Adobe\Adobe Premiere Pro 2024\Adobe Premiere Pro.exe"
  "$env:ProgramFiles\Adobe\Adobe Photoshop 2024\Photoshop.exe",
  "$env:ProgramFiles\Adobe\Adobe After Effects 2024\Support Files\AfterFX.exe"
)

# ================================
# BLOQUEADOR DE PROGRAMAS NO FIREWALL (REFATORADO)
# ================================

# --- GARANTIR EXECUÇÃO COMO ADMIN ---
function Ensure-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

  if (-not $isAdmin) {
    if (-not $PSCommandPath) {
      Write-Host "[X] Este script precisa ser executado a partir de um arquivo .ps1" -ForegroundColor Red
      exit 1
    }

    Write-Host "[!] Elevando privilégios para administrador..." -ForegroundColor Cyan

    Start-Process powershell.exe `
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
      -Verb RunAs

    exit
  }
}

# --- VALIDAR EXECUTÁVEL ---
function Test-Executable {
  param ($Path)

  if (-not (Test-Path -Path $Path)) {    
    return $false
  }

  if ($Path -notmatch "\.exe$") {
    Write-Host "[-] Arquivo não é um executável válido (.exe): $Path" -ForegroundColor Yellow
    return $false
  }

  return $true
}

# --- VERIFICAR SE REGRA JÁ EXISTE (ROBUSTO) ---
function Test-FirewallRuleExists {
  param (
    [string]$RuleName,
    [string]$ProgramPath
  )

  $rules = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

  if (-not $rules) {
    return $false
  }

  foreach ($rule in $rules) {
    $filter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule -ErrorAction SilentlyContinue
    if ($filter.Program -eq $ProgramPath) {
      return $true
    }
  }

  return $false
}

# --- CRIAR REGRA ---
function New-BlockRule {
  param (
    [string]$Name,
    [string]$Direction,
    [string]$ProgramPath
  )

  New-NetFirewallRule `
    -DisplayName $Name `
    -Direction $Direction `
    -Program $ProgramPath `
    -Action Block `
    -Profile Any `
    -Description "Bloqueio automático via script" `
    -ErrorAction Stop | Out-Null
}

# --- EXECUÇÃO PRINCIPAL ---
Ensure-Admin

Write-Host "`n=== Iniciando bloqueio de programas ===`n" -ForegroundColor Magenta

foreach ($caminho in $caminhosExe) {

  if (-not (Test-Executable $caminho)) {
    continue
  }

  $nomeArquivo = Split-Path -Leaf $caminho

  $regraEntrada = "Bloqueia Entrada $nomeArquivo"
  $regraSaida = "Bloqueia Saida $nomeArquivo"

  $entradaExiste = Test-FirewallRuleExists -RuleName $regraEntrada -ProgramPath $caminho
  $saidaExiste = Test-FirewallRuleExists -RuleName $regraSaida   -ProgramPath $caminho

  if ($entradaExiste -and $saidaExiste) {
    Write-Host "[=] '$nomeArquivo' já está totalmente bloqueado." -ForegroundColor Gray
    continue
  }

  try {
    if (-not $entradaExiste) {
      New-BlockRule -Name $regraEntrada -Direction Inbound -ProgramPath $caminho
    }

    if (-not $saidaExiste) {
      New-BlockRule -Name $regraSaida -Direction Outbound -ProgramPath $caminho
    }

    Write-Host "[+] '$nomeArquivo' bloqueado com sucesso." -ForegroundColor Green
  }
  catch {
    Write-Host "[X] Erro ao bloquear '$nomeArquivo': $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host "`n=== Processo finalizado ===" -ForegroundColor Magenta