#requires -version 5.1
<#
.SYNOPSIS
    AUTONOME CORE EXEC LIBRARY.
    Motor de execução resiliente com abstração de interpretador e fallback dinâmico.

.DESCRIPTION
    Biblioteca centralizadora para execução de comandos externos e internos. 
    Diferencia-se pela capacidade de alternar inteligentemente entre interpretadores 
    (Native, PowerShell, CMD) para maximizar a taxa de sucesso da operação.

    [ESPECIFICIDADES DE EXECUÇÃO]
    - Abstração de Interpretador: Detecta automaticamente comandos que exigem 
      PowerShell (via Regex de Pipes e Redirecionamentos) vs. comandos simples via CMD.
    - Encoded Execution: Utiliza Base64 (EncodedCommand) para comandos PowerShell, 
      prevenindo quebras por caracteres especiais ou aspas complexas.
    - Captura Híbrida: Implementa redirecionamento de Standard Output e Standard 
      Error para arquivos temporários durante execução via CMD.
    - Gestão de Visibilidade: Execução forçada em 'WindowStyle Hidden' para 
      operação totalmente Headless.

    [ESTRATÉGIA DE FALLBACK EM CAMADAS]
    1. Camada Primária: Tentativa via interpretador detectado (PS ou CMD).
    2. Camada Secundária (CMD): Caso a execução via PS falhe ou retorne ExitCode != 0.
    3. Camada Terceária (PS7): Acionamento do runtime moderno (pwsh.exe) em 
       instância única para comandos que falharam nos runtimes legados.

    [MECANISMOS DE CONTROLE]
    - Tokenização: Geração de ID aleatório (rand_name) por comando para 
      rastreabilidade individual nos logs de saída.
    - Controle de Recorrência: Implementa trava de estado ($script:__ps7_fallback_used) 
      para evitar loops infinitos de elevação de runtime.
    - Validação de Dependência: Barreira de carregamento (Guard) que exige a 
      presença da 'autonome-log.ps1' (show_log/show_error).

    [RESTRIÇÕES DO COMPONENTE]
    - Dependências: Exclusivamente nativas e autonome-log.ps1.
    - Bloqueio: Operação estritamente Wait-centric (PassThru monitorado).
    - Memória: O leitor deve garantir a limpeza ou rotação dos logs de stdout/stderr 
      gerados no diretório temporário.

.NOTES
    ================================================================================
    REGRAS DE NEGÓCIO GLOBAIS DO PROJETO
    POWERSHELL MISSION-CRITICAL FRAMEWORK - ESPECIFICAÇÃO DE EXECUÇÃO
    ================================================================================

    [CAPACIDADES GERAIS]
    Orquestração determinística, resiliente e idempotente para Windows.
    Compatibilidade Dual-Engine (5.1 + 7.4+) em contextos SYSTEM e USER.

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

.COMPONENT
    Execução Determinística, Fallback de Runtime e Gestão de Saída.
#>


# ==============================
# VALIDATION GUARD
# ==============================
if (Get-Command run_command -ErrorAction SilentlyContinue) {
  return
}

# ==============================
# DEPENDÊNCIA: LOG LIB
# ==============================
if (-not (Get-Command show_log -ErrorAction SilentlyContinue)) {
  Write-Host "[FATAL] autonome-log.ps1 não carregado." -BackgroundColor Red
  exit 1
}

# ==============================
# ESTADO INTERNO
# ==============================
if (-not $script:__ps7_fallback_used) {
  $script:__ps7_fallback_used = $false
}

<#
.SYNOPSIS
Executa comando no PowerShell 7.
#>
function runInPWSH7 {
  param([string]$cmd_)

  $pwshPath = "$env:SystemDrive\Program Files\PowerShell\7\pwsh.exe"

  if ($PSVersionTable.PSVersion.Major -ge 7) {
    show_log "Já estamos no PowerShell 7"
    try {
      Invoke-Expression $cmd_
    }
    catch {
      show_error "Falha ao executar comando no PS7"
    }
    return
  }

  if (-not (Test-Path $pwshPath)) {
    show_error "PowerShell 7 não encontrado para fallback."
    return
  }

  try {
    show_cmd "$pwshPath -Command $cmd_"

    $proc = Start-Process -FilePath $pwshPath `
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd_`"" `
      -PassThru

    while (-not $proc.HasExited) {
      Start-Sleep -Seconds 1
    }

    show_nota "Comando executado via PS7."
  }
  catch {
    show_error "Falha ao executar comando via PS7"
  }
}

<#
.SYNOPSIS
Executa comando com fallback.
#>
function run_command {
  param([string]$command_)

  $id_ = rand_name(7)
  show_cmd "[$id_] $command_"

  $success = $false
  $exitCode = -1

  $needsPS = ($command_ -match '\||Out-File|2>&1|>')

  # 1. Execução principal
  try {
    if ($needsPS) {
      $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command_))

      $p = Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" `
        -Wait -PassThru -WindowStyle Hidden
    }
    else {
      $tmpOut = Join-Path $script:run_log_dir "$id_.stdout.log"
      $tmpErr = Join-Path $script:run_log_dir "$id_.stderr.log"

      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr
    }

    $exitCode = $p.ExitCode

    if ($exitCode -eq 0) {
      show_log "[$id_] OK (exit=0)"
      $success = $true
    }
    else {
      show_warn "[$id_] ExitCode: $exitCode"
    }
  }
  catch {
    show_warn "[$id_] Falha na execução direta"
  }

  # 2. fallback CMD
  if (-not $success -and $needsPS) {
    try {
      $tmpOut = Join-Path $script:run_log_dir "$id_.stdout.log"
      $tmpErr = Join-Path $script:run_log_dir "$id_.stderr.log"

      $p = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c $command_" `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr

      $exitCode = $p.ExitCode

      if ($exitCode -eq 0) {
        show_log "[$id_] OK via CMD fallback"
        $success = $true
      }
      else {
        show_warn "[$id_] CMD ExitCode: $exitCode"
      }
    }
    catch {
      show_warn "[$id_] Falha CMD fallback"
    }
  }

  # 3. fallback PS7 (único)
  if (-not $success) {
    if (-not $script:__ps7_fallback_used) {
      $script:__ps7_fallback_used = $true
      show_error "[$id_] Falha geral → fallback PS7"
      runInPWSH7 "$command_"
      return
    }
    else {
      show_error "[$id_] Falha definitiva"
    }
  }
}