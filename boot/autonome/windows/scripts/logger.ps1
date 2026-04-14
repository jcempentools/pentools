#requires -version 5.1
<#
.SYNOPSIS
    AUTONOME LOG LIBRARY.
    Componente centralizador de saída de dados e formatação visual.

.DESCRIPTION
    Gerencia a lógica de apresentação e persistência de registros, garantindo a 
    manutenção da assinatura original do sistema. Atua como o ponto único de 
    saída para logs em console e arquivos.

    ESPECIFICIDADES TÉCNICAS E DE DESIGN:
    - Alta Legibilidade: Otimizado para análise visual de logs extensos em tela.
    - Notação de Tipos (Visual): Implementação de prefixos tipados para organização:
        • [t] Title: Cabeçalhos de etapa ou seções principais.
        • [s] Subtítulo: Destaques secundários (especificidade desta biblioteca).
        • [l] Log: Registro padrão de fluxo e operações.
        • [i] Info: Detalhes informativos ou diagnósticos.
        • [w] Warn: Alertas de falhas não críticas ou retentativas.
        • [e] Error: Falhas críticas que exigem atenção ou interrupção.

    DIRETRIZES ESPECÍFICAS:
    - Autonomia: Não depende de variáveis externas para inicialização.
    - Sem Efeitos Colaterais: A biblioteca processa a string sem alterar o estado 
      global de outras variáveis do sistema, salvo os buffers de saída.
    - Consistência: Mantém compatibilidade total com o comportamento e assinatura 
      original do AUTONOME INSTALL SCRIPT.

    RESTRIÇÕES DO COMPONENTE:
    - Independência: Sem dependência de módulos externos ou bibliotecas de terceiros.
    - Persistência: Capaz de espelhar simultaneamente para Console e Arquivo.

.NOTES
    ================================================================================
    REGRAS DE NEGÓCIO GLOBAIS DO PROJETO    
    POWERSHELL MISSION-CRITICAL FRAMEWORK - ESPECIFICAÇÃO DE EXECUÇÃO
    ================================================================================

    [CAPACIDADES GERAIS]
    Orquestração determinística, resiliente e idempotente para Windows.
    Compatibilidade Dual-Engine (5.1 + 7.4+) em contextos SYSTEM, WINPE e USER.

    [ESTILO, DESIGN & RASTREABILIDADE]
    - Design: Imutabilidade, Baixo Acoplamento e suporte a camelCase/snake_case.
    - Rastreabilidade Diff-Friendly: Alterações de código minimalistas otimizados
                                     para desempenho aliado a análise visual
                                     de mudanças.

    [CAPACIDADES TÉCNICAS (REAPROVEITÁVEIS)]
    - COMPATIBILIDADE: Identificação de versão/subversão para comandos adequados.
    - RESILIÊNCIA: Retry com backoff progressivo e múltiplas formas de tentativa.
    - OFFLINE-FIRST: Lógica global de priorização de recursos locais vs rede.
                    configurável para Online-FIRST.
    - DETERMINISMO: Validação de estado real pós-operação (não apenas ExitCode).

    [EVENTOS & TELEMETRIA (CALLBACK)]
    - DESACOPLAMENTO: Script não gerencia arquivos de log ou console diretamente,
                    salvo se explicitamente definido.
    - OBRIGATORIEDADE: Telemetria via ScriptBlock [callback($msg, $type)]
                    salvo se explicitamente definido.
    - TIPAGEM DE MENSAGEM (Parâmetro 2):
        - [t] Title: Título de etapa ou seções principais.
        - [l] Log: Registro padrão de fluxo e operações.
        - [i] Info: Detalhes informativos ou diagnósticos.
        - [w] Warn: Alertas de falhas não críticas ou retentativas.
        - [e] Error: Falhas críticas que exigem atenção ou interrupção.

    [REGRAS DE ARQUITETURA]
    - ISOLAMENTO: Mutex Global obrigatório para prevenir paralelismo.
    - MODULARIDADE: Baseado em micro-funções especialistas e reutilizáveis.
    - SINCRO: Execução 100% síncrona, bloqueante e sequencial.
    - ESTADO: Barreira de consistência (DISM/CBS) para operações de sistema.
    - NATIVO: Uso estrito de comandos nativos do OS, salvo exceção declarada.

    [DIRETRIZES DE IMPLEMENTAÇÃO]
    - IDEMPOTÊNCIA: Seguro para múltiplas execuções no mesmo ambiente.
    - HEADLESS: Operação plena sem interface gráfica ou interação de usuário.
    - TIMEOUT: Limites controlados adequados à capacidade do hardware.

    [RESTRIÇÕES / VEDAÇÕES]
    - Não prosseguir com sistema em estado inconsistente ou pendente.
    - Não assumir conectividade de rede (Offline-First por padrão)
    configurável para Online-FIRST.
    - Não depender de módulos externos ou bibliotecas não nativas.
    - Não executar etapas sem validação de sucesso posterior.

    [ESTRUTURA DE EXECUÇÃO]
    1. Inicialização segura (ExecutionPolicy, TLS, Context Check).
    2. Garantia de instância única (Global Mutex).
    3. Validação de pré-requisitos e pilha de manutenção do SO.
    4. Orquestração modular com validação individual de cada micro-função.
    5. Finalização auditável com log rastreável e saída determinística.

    [INVOCAÇãO]
    O script sempre auto identifica se foi importado ou executado:
    1. Se executado diretatamente executa função main repassando parametros 
       recebidos por linha de comando ou variáveis de ambiente.,
    2. Se importado expõe as funções públicas para serem chamadas por outros
       scripts sem executar nada.    

.COMPONENT
    Ponto único de saída de logs.
    Foco: Organização visual, legibilidade e compatibilidade de comportamento.
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
    [string]$type = "l",
    [scriptblock]$callback
  )

  $msg = $str_menssagem

  # ==============================
  # CALLBACK (telemetria obrigatória quando fornecida)
  # ==============================
  if ($callback) {
    & $callback $msg $type
    return
  }

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