# --- CONFIGURAÇÃO ---
$___RulePrefix = "Bloqueia ADOBE " # Prefixo que aparecerá no INÍCIO de todas as regras
$___ProgramFiles = @(
  "$env:ProgramFiles\Adobe",
  "${env:ProgramFiles(x86)}\Adobe"
)

# Vetor de padrões (Regex)
$___regexPatterns = @(
  ".*\.pentools[\w\d]+"  
)

# Otimização: Une os padrões em uma única expressão Regex
$___combinedRegex = $___regexPatterns -join "|"

function Get-ExecutableByContent {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string[]]$Paths,
    [Parameter(Mandatory = $true)][string]$CombinedPattern
  )

  $extensions = @("*.exe", "*.ps1", "*.bat", "*.cmd")

  foreach ($rootPath in $Paths) {
    if (-not (Test-Path -LiteralPath $rootPath -ErrorAction SilentlyContinue)) { continue }

    try {
      $files = Get-ChildItem -LiteralPath $rootPath -Include $extensions -Recurse -ErrorAction SilentlyContinue -Force

      foreach ($file in $files) {
        if ($null -ne $file -and -not $file.PSIsContainer) {
          if ($file.Name -imatch $CombinedPattern) {
            $file.FullName
          }
        }
      }
    }
    catch { 
      Write-Warning "Erro ao acessar subpastas em: $rootPath"
    }
  }
}

function Ensure-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

  if (-not $isAdmin) {
    if (-not $PSCommandPath) {
      Write-Host "[X] Execute a partir de um arquivo .ps1 salvo." -ForegroundColor Red
      exit 1
    }
    Write-Host "[!] Elevando privilegios para Administrador..." -ForegroundColor Cyan
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
  }
}

function Test-FirewallRuleExists {
  param ([string]$RuleName, [string]$ProgramPath)
    
  $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | 
  Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | 
  Where-Object { $_.Program -eq $ProgramPath }

  return $null -ne $rule
}

function New-BlockRule {
  param ([string]$Name, [string]$Direction, [string]$ProgramPath)
  New-NetFirewallRule -DisplayName $Name -Direction $Direction -Program $ProgramPath `
    -Action Block -Profile Any -Description "Bloqueio automatico via script" `
    -ErrorAction Stop | Out-Null
}

# --- EXECUÇÃO PRINCIPAL ---
Ensure-Admin

Write-Host "`n=== Iniciando Bloqueio de Rede (Modo Otimizado) ===" -ForegroundColor Magenta

$caminhosEncontrados = Get-ExecutableByContent -Paths $___ProgramFiles -CombinedPattern $___combinedRegex

foreach ($caminho in $caminhosEncontrados) {
  if (-not (Test-Path -LiteralPath $caminho)) { continue }

  $nomeArquivo = Split-Path -Leaf $caminho
  
  # Aplicação do prefixo no nome das regras
  $regraEntrada = "$___RulePrefix`Entrada $nomeArquivo"
  $regraSaida = "$___RulePrefix`Saida $nomeArquivo"

  try {
    $entradaExiste = Test-FirewallRuleExists -RuleName $regraEntrada -ProgramPath $caminho
    $saidaExiste = Test-FirewallRuleExists -RuleName $regraSaida   -ProgramPath $caminho

    if ($entradaExiste -and $saidaExiste) {
      Write-Host "[=] '$nomeArquivo' ja esta protegido." -ForegroundColor Gray
      continue
    }

    if (-not $entradaExiste) { New-BlockRule -Name $regraEntrada -Direction Inbound -ProgramPath $caminho }
    if (-not $saidaExiste) { New-BlockRule -Name $regraSaida   -Direction Outbound -ProgramPath $caminho }

    Write-Host "[+] '$nomeArquivo' bloqueado com sucesso." -ForegroundColor Green
  }
  catch {
    Write-Host "[X] Falha ao processar '$nomeArquivo': $($_.Exception.Message)" -ForegroundColor Red
  }
}

Write-Host "`n=== Processo Concluido ===" -ForegroundColor Magenta
Read-Host "Pressione ENTER para fechar"
