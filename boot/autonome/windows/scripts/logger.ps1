<#
===============================================================================
AUTONOME LOG LIBRARY
===============================================================================

[OBJETIVO]
Centralizar toda a lógica de logging do AUTONOME INSTALL SCRIPT,
mantendo compatibilidade total com o comportamento original.

-------------------------------------------------------------------------------
[CARACTERÍSTICAS]
- Compatível com PowerShell 2.0+
- Não depende de módulos externos
- Mantém comportamento e assinatura original
- PowerShellDoc preservado
- Sem efeitos colaterais

-------------------------------------------------------------------------------
[FAIL-SAFE]
- Não depende de variáveis externas
- Pode ser carregado múltiplas vezes (idempotente)

===============================================================================
#>

# ==============================
# VALIDATION GUARD (idempotência)
# ==============================
if (Get-Command show_log -ErrorAction SilentlyContinue) {
  return
}

<#
.SYNOPSIS
Exibe um título destacado no console.

.DESCRIPTION
Imprime uma mensagem formatada com fundo colorido e separadores
para indicar início de seção no log visual.

.PARAMETER str_menssagem
Texto a ser exibido como título.
#>
function show_log_title {
  param(
    [string]$str_menssagem
  )
  write-host ""
  write-host ""
  write-host "################################################" -BackgroundColor DarkCyan
  write-host "#### $str_menssagem" -BackgroundColor DarkCyan
  write-host "################################################" -BackgroundColor DarkCyan
  write-host ""
  write-host ""
}
<#
.SYNOPSIS
Exibe mensagem de erro.

.DESCRIPTION
Imprime mensagem formatada com destaque em vermelho
indicando erro no fluxo de execução.

.PARAMETER str_menssagem
Mensagem de erro a ser exibida.
#>
function show_error {
  param(
    [string]$str_menssagem
  )
  Write-Host "[ERROR]:" -BackgroundColor Red
  Write-Host "[ERROR]: $str_menssagem" -BackgroundColor Red
}
<#
.SYNOPSIS
Exibe mensagem de log padrão.

.DESCRIPTION
Imprime mensagem informativa com formatação neutra
para acompanhamento do fluxo de execução.

.PARAMETER str_menssagem
Mensagem a ser exibida.
#>
function show_log {
  param(
    [string]$str_menssagem
  )
  Write-Host "---> $str_menssagem" -BackgroundColor DarkGray
}
<#
.SYNOPSIS
Exibe comando a ser executado.

.DESCRIPTION
Imprime o comando com separadores visuais
para facilitar rastreamento de execução.

.PARAMETER str_menssagem
Comando ou texto a ser exibido.
#>
function show_cmd {
  param(
    [string]$str_menssagem
  )
  Write-Host ""
  Write-Host "---------------------------------------------"
  Write-Host "$str_menssagem" -BackgroundColor Cyan -ForegroundColor Black
  Write-Host "---------------------------------------------"
}
<#
.SYNOPSIS
Exibe mensagem de aviso.

.DESCRIPTION
Imprime mensagem formatada com destaque amarelo
indicando condição não crítica.

.PARAMETER str_menssagem
Mensagem de aviso.
#>
function show_warn {
  param(
    [string]$str_menssagem
  )
  Write-Host "[WARN] " -BackgroundColor Yellow -ForegroundColor Black
  Write-Host "[WARN]: $str_menssagem" -BackgroundColor Yellow -ForegroundColor Black
}
<#
.SYNOPSIS
Exibe mensagem informativa.

.DESCRIPTION
Imprime mensagem com destaque leve
para observações não críticas.

.PARAMETER str_menssagem
Texto a ser exibido.
#>
function show_nota {
  param(
    [string]$str_menssagem
  )
  Write-Host "[NOTA]: $str_menssagem" -BackgroundColor Gray -ForegroundColor Black
}
<#
.SYNOPSIS
Gera string aleatória.

.DESCRIPTION
Retorna string com caracteres alfabéticos aleatórios
com tamanho configurável.

.PARAMETER num
Tamanho da string gerada. Default: 18.

.OUTPUTS
String aleatória.
#>
function rand_name {
  param(
    [AllowNull()][int]$num
  )  
  if (-not $num -or $num -le 0) {
    $num = 18
  }
  return -join ((65..90) + (97..122) | Get-Random -Count $num | ForEach-Object { [char]$_ })
}

function show_nota {
  param([string]$str_menssagem)

  Write-Host "[NOTA]: $str_menssagem" -BackgroundColor Gray -ForegroundColor Black
}

function rand_name {
  param(
    [AllowNull()][int]$num
  )

  if (-not $num -or $num -le 0) {
    $num = 18
  }

  return -join ((65..90) + (97..122) | Get-Random -Count $num | ForEach-Object { [char]$_ })
}