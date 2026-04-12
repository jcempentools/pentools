#requires -version 5.1
<#
.SYNOPSIS
    Winget Setup Fix & Context Enforcer.
    Repara e disponibiliza o Gerenciador de Pacotes do Windows (Winget).

.DESCRIPTION
    Componente especializado em corrigir a disponibilidade do 'AppInstaller' (Winget) 
    em contextos onde o binário não está registrado ou acessível. O script força 
    o registro do pacote AppX e tenta localizar o executável diretamente no 
    repositório de aplicações do Windows.

    ESPECIFICIDADES TÉCNICAS (REPARO):
    - Registro de Família: Utiliza 'Add-AppxPackage' via 'RegisterByFamilyName' 
      para reinstanciar o 'Microsoft.DesktopAppInstaller' no contexto atual.
    - Localização Forçada: Varre o diretório 'WindowsApps' em busca da versão x64 
      mais recente do binário caso o alias padrão do sistema falhe.
    - Pivot de Contexto: Altera a localização da sessão (Set-Location) para o 
      caminho físico do pacote para garantir a execução de comandos subsequentes.

    MECANISMOS DE CONTROLE:
    - Trava de Contexto: Execução limitada estritamente ao contexto de Usuário; 
      ignorado se detectado contexto de sistema ($in_system_context).
    - Test Mode Guard: Impede a atualização real de pacotes (winget upgrade) se a 
      variável '$script:is_test_mode' estiver ativa, permitindo auditoria seca.
    - Resiliência: Implementa blocos try/catch individuais por etapa para evitar 
      que falhas no registro de AppX impeçam a tentativa de localização física.

    RESTRIÇÕES DO COMPONENTE:
    - Arquitetura: Focado em binários x64 (__8wekyb3d8bbwe).
    - Dependências: Requer privilégios para leitura em 'Program Files\WindowsApps' 
      e execução da função interna 'isowin_winget_update'.

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

    [INVOCAÇãO]
    O script sempre auto identifica se foi importado ou executado:
    1. Se executado diretatamente executa função main repassando parametros 
       recebidos por linha de comando ou variáveis de ambiente.,
    2. Se importado expõe as funções públicas para serem chamadas por outros
       scripts sem executar nada.    

.COMPONENT
    Reparador de Pacotes AppX, Gestor de Winget e Fix de Contexto.
    Foco: Confiabilidade de Provisionamento e Disponibilidade de Ferramentas.
#>

function main {
  param(
    [scriptblock]$callback
  )

  if (-not $in_system_context) {

    if ($callback) { & $callback "Fix winget, forçando disponibilização de winget no contexto do sistema" "t" } else { show_log_title "Fix winget, forçando disponibilização de winget no contexto do sistema" }

    try {
      Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe | write-host
    }
    catch {
      if ($callback) { & $callback "Falha ao executar Add-AppxPackage " "e" } else { show_error "Falha ao executar Add-AppxPackage " }
    }

    if ($callback) { & $callback "Winget setup fix 1" "t" } else { show_log_title "Winget setup fix 1" }

    try {
      $ResolveWingetPath = Resolve-Path "$env:SystemDrive\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe"
      if ($ResolveWingetPath) {
        $WingetPath = $ResolveWingetPath[-1].Path
      }

      if ($callback) { & $callback "-> winget: '$wingetpath'" "i" } else { Write-Host "-> winget: '$wingetpath'" }

      Set-Location "$wingetpath"
    }
    catch {
      if ($callback) { & $callback "FALHA ao executar FIX 1" "e" } else { show_error "FALHA ao executar FIX 1" }
    }

    if ($callback) { & $callback "Atual: $pwd" "i" } else { write-host "Atual: $pwd" }

    if (-not $script:is_test_mode) {
      isowin_winget_update
    }
    else {
      if ($callback) { & $callback "TEST MODE: winget upgrade ignorado" "w" } else { show_log "TEST MODE: winget upgrade ignorado" }
    }
  }
}

# ==============================
# INVOCACAO (auto-detect import vs execução)
# ==============================
if ($MyInvocation.InvocationName -ne '.') {
  if (Get-Command main -ErrorAction SilentlyContinue) {
    main @args
  }
}