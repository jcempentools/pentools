<#
.SYNOPSIS
    Gatilhos Finais (External Hooks Executor).
    Motor de execução para scripts de pós-instalação e extensões externas.

.DESCRIPTION
    Componente especializado na orquestração de scripts externos (.ps1, .reg, .cmd, .bat). 
    O script localiza ativos baseados no contexto de execução atual e os processa seguindo 
    uma ordem de precedência técnica pré-definida.

    ESPECIFICIDADES DE EXECUÇÃO (HOOKS):
    - Nomeação Contextual: O script busca arquivos que correspondam ao padrão 'in.$local_exec', 
      permitindo isolamento por contexto (ex: in.system, in.useronce).
    - Ordem de Precedência (Prioridade de Extensão):
        1. .reg (Importações de Registro)
        2. .ps1 (Scripts PowerShell)
        3. .cmd (Scripts de Lote modernos)
        4. .bat (Scripts de Lote legados)
    - Validação de Conteúdo: Implementa barreira de segurança contra arquivos vazios ou 
      com espaços em branco, ignorando execuções nulas.

    MECANISMOS TÉCNICOS:
    - Delegação de Comando: Utiliza o 'run_command' do Core Exec para garantir que a 
      execução do hook herde as capacidades de fallback e logging do framework.
    - Isolamento de Erro: Falhas na leitura ou execução de um hook individual não 
      interrompem o processamento da fila de extensões.
    - Caminho Dinâmico: Resolução baseada na variável '$autonome_hooks' dentro da 
      estrutura de pastas do orquestrador.

    RESTRIÇÕES DO COMPONENTE:
    - Localização: Depende da definição prévia da pasta base ($script:appsinstall_folder).
    - Segurança: Execução via -NoProfile e -ExecutionPolicy Bypass para scripts PowerShell.
    - Estritamente Read-Only na origem: O motor apenas lê e executa, sem mutação dos hooks.

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
    Orquestrador de Extensões, Executor de Gatilhos e Integrador de Pós-Instalação.
    Foco: Extensibilidade, Precedência de Formatos e Execução Contextual.
#>


show_log_title "Executando gatilhos finais (scripts externos)"

try {
  if ([string]::IsNullOrEmpty($script:appsinstall_folder)) {
    show_log "Pasta base não definida."
    return
  }

  $scriptsPath = Join-Path $script:appsinstall_folder "$autonome_hooks"  

  if (-not (Test-Path $scriptsPath)) {
    show_log "Pasta de scripts não encontrada."
    return
  }

  $baseName = "in.$local_exec"  

  $orderedExt = @("reg", "ps1", "cmd", "bat")

  foreach ($ext in $orderedExt) {    
    $file = Join-Path $$scriptsPath "$baseName.$ext"

    if (-not (Test-Path $file)) {
      continue
    }

    try {
      $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
      if ([string]::IsNullOrWhiteSpace($content)) {
        show_log "Ignorado (vazio): $file"
        continue
      }
    }
    catch {
      show_warn "Falha ao ler conteúdo de $file"
      continue
    }

    show_log "Executando gatilho: $file"

    switch ($ext) {

      "reg" {
        run_command "reg.exe import `"$file`""
      }

      "ps1" {
        run_command "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$file`""
      }

      "cmd" {
        run_command "cmd.exe /c `"$file`""
      }

      "bat" {
        run_command "cmd.exe /c `"$file`""
      }
    }
  }
}
catch {
  show_warn "Falha ao executar gatilhos finais"
}