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
- Ponto único de saída de logs
- Compatível com console e arquivos
- Alta legibilidade e rastreabilidade para logs extensos
  em tela e em arquivo
- Notação de tipos de mensagem para melhor organização visual:
    - [t] Title: Cabeçalhos de etapa ou seções principais.
    - [s] Subtítulo: Destaques secundários.
    - [l] Log: Registro padrão de fluxo e operações.
    - [i] Info: Detalhes informativos ou diagnósticos.
    - [w] Warn: Alertas de falhas não críticas ou retentativas.
    - [e] Error: Falhas críticas que exigem atenção ou aborto.

-------------------------------------------------------------------------------
[FAIL-SAFE]
- Não depende de variáveis externas
- Pode ser carregado múltiplas vezes (idempotente)

===============================================================================
#>
# ==============================
# VALIDATION GUARD (idempotência)
# ==============================
if (Get-Command _logger -ErrorAction SilentlyContinue) {
  return
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

<#
.SYNOPSIS
Sistema central de logging.

.DESCRIPTION
[SISTEMA DE EVENTOS / CALLBACK] (OBRIGATÓRIO)
- Ponto único de saída de logs
- Compatível com console e arquivos
- Alta legibilidade para logs extensos em tela e em arquivo
    - [t] Title: Cabeçalhos de etapa ou seções principais.
    - [s] Subtítulo: Destaques secundários.
    - [l] Log: Registro padrão de fluxo e operações.
    - [i] Info: Detalhes informativos ou diagnósticos.
    - [w] Warn: Alertas de falhas não críticas ou retentativas.
    - [e] Error: Falhas críticas que exigem atenção ou aborto.

.PARAMETER str_menssagem
Mensagem a ser exibida.

.PARAMETER type
Tipo da mensagem.
#>
function _logger {
  param(
    [string]$str_menssagem,
    [string]$type = "l"
  )

  $msg = $str_menssagem

  switch ($type) {

    # ==============================
    # TITLE (alto destaque)
    # ==============================
    "t" {
      Write-Host ""
      Write-Host ""
      Write-Host "############################################################" -BackgroundColor DarkCyan
      Write-Host ("#### {0}" -f $msg) -BackgroundColor DarkCyan
      Write-Host "############################################################" -BackgroundColor DarkCyan
      Write-Host ""
      Write-Host ""
      return
    }

    # ==============================
    # SUBTITLE
    # ==============================
    "s" {
      Write-Host ""
      Write-Host "-------------------- $msg --------------------" -ForegroundColor Cyan
      return
    }

    # ==============================
    # COMMAND BLOCK (heurística)
    # ==============================
    "c" {
      Write-Host ""
      Write-Host "---------------------------------------------"
      Write-Host $msg -BackgroundColor Cyan -ForegroundColor Black
      Write-Host "---------------------------------------------"
      return
    }

    # ==============================
    # ERROR
    # ==============================
    "e" {
      Write-Host "[ERROR]" -BackgroundColor Red
      Write-Host ("[ERROR]: {0}" -f $msg) -BackgroundColor Red
      return
    }

    # ==============================
    # WARN
    # ==============================
    "w" {
      Write-Host "[WARN]" -BackgroundColor Yellow -ForegroundColor Black
      Write-Host ("[WARN]: {0}" -f $msg) -BackgroundColor Yellow -ForegroundColor Black
      return
    }

    # ==============================
    # INFO
    # ==============================
    "i" {
      Write-Host ("[INFO]: {0}" -f $msg) -BackgroundColor Gray -ForegroundColor Black
      return
    }

    # ==============================
    # DEFAULT LOG
    # ==============================
    default {
      Write-Host ("---> {0}" -f $msg) -BackgroundColor DarkGray
      return
    }
  }
}