#requires -version 5.1
<#
.SYNOPSIS
    Application Deployment Engine (App Orchestrator).
    Gerencia o ciclo de vida de instalação de softwares base e complementares.

.DESCRIPTION
    Componente responsável pela instalação de aplicações essenciais e softwares 
    adicionais via Winget ou pacotes locais. Implementa uma lógica de seleção 
    dinâmica baseada em perfis (dev, cru) e listas de provisionamento externas.

    ESPECIFICIDADES DE NEGÓCIO (APPLICATIONS):
    - Camada Core (Basiquíssimos): Instalação mandatória de runtimes e ferramentas 
      essenciais (Java, DirectX, 7zip, VSCode).
    - Perfil DEV: Acionamento automatizado do subsistema WSL (Windows Subsystem 
      for Linux) com imposição da Versão 2.
    - Estratégia de Lista (Precedência):
        1. Local: Prioriza 'apps.lst' localizado na mídia física (Pendrive).
        2. Remote: Fallback para download de lista online via URL configurada.
        3. Hardcoded: Fallback final para uma seleção nativa de utilitários (Chrome, VLC, LibreOffice, etc.).

    DIRETRIZES DE EXECUÇÃO:
    - Customização de Instalação: Suporte a flags específicas por app (ex: tasks 
      silenciosas e integração de contexto no VSCode).
    - Extensibilidade: Capacidade de acionar um script de pós-instalação customizado 
      diretamente da mídia física ($pendrive_script_name).
    - Validação de Lista: Verificação estrita de extensão (.lst) para listas online 
      visando prevenir processamento de payloads inválidos.

    RESTRIÇÕES ESPECÍFICAS:
    - Contexto: Operação permitida exclusivamente fora do contexto de sistema 
      ($in_system_context - Contexto de Usuário).
    - Modo 'Cru': Inibe a instalação da suíte secundária de aplicativos quando 
      o ambiente é definido como minimalista.

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
    Orquestrador de Software, Gestor de Listas (.lst) e Provisionador de Ambiente.
    Foco: Padronização de Workspace, Flexibilidade de Origem e Automação de Runtimes.
#>


if (-not $in_system_context) {
  show_log_title "Instalando APPs basiquissimos"
  isowin_install_app "Oracle.JavaRuntimeEnvironment"
  isowin_install_app "Microsoft.DirectX"
  isowin_install_app "7zip.7zip"
  isowin_install_app "Microsoft.VisualStudioCode" '/SILENT /mergetasks="!runcode,addcontextmenufiles,addcontextmenufolders,addtopath,associatewithfiles,quicklaunchicon"'
  if ("$Env:install_mode" -eq "dev") {
    wsl --install
    wsl --set-default-version 2
  }
  show_log_title "Instalando demais APPs"
  if ("$Env:install_mode" -ne "cru") {
    show_log "Continuar padrão ou seguir 'apps.lst' do online/pendrive?"
    $apps_lst = ""
    # verifica se tem lista de apps no pendrive
    $apps_lst = ""

    $baseListPath = Join-Path $appsinstall_folder $apps_list_dir

    $mainList = Join-Path $baseListPath "apps.lst"

    if (Test-Path $mainList) {
      $apps_lst = $mainList
    }
    if (-Not ([string]::IsNullOrEmpty($apps_lst))) {
      show_log "usando 'apps.lst do pendrive'..."
      Install-AppList $apps_lst
    }
    else {
      show_log "Obtendo lista online..."
      $apps_f = "$path_log\apps-download.lst"
      if ($url_apps_lst -notmatch '\.lst$') {
        show_error "URL de apps inválida (não é .lst): $url_apps_lst"
      }
      download_save "$url_apps_lst" "$apps_f"
      if (Test-Path "$apps_f") {
        show_log "Lista de apps online encontrada, usando..."
        Install-AppList $apps_f
      }
      else {
        show_log "Lista de apps online inexistente, usando o padrao..."
        isowin_install_app "Microsoft.PowerToys"
        isowin_install_app "QL-Win.QuickLook"
        isowin_install_app "CodecGuide.K-LiteCodecPack.Mega"
        isowin_install_app "VideoLAN.VLC"
        isowin_install_app "Google.Chrome"
        isowin_install_app "Brave.Brave"
        isowin_install_app "SumatraPDF.SumatraPDF"
        isowin_install_app "PDFsam.PDFsam"
        isowin_install_app "Piriform.Defraggler"
        isowin_install_app "CrystalDewWorld.CrystalDiskInfo"
        isowin_install_app "qBittorrent.qBittorrent"
        isowin_install_app "TheDocumentFoundation.LibreOffice"
      }
    }
    show_log "Executar script offline do pendrive '$pendrive_script_name'?"
    # tenta executar o script localizado no pendrive
    if (Test-Path "$appsinstall_folder\$pendrive_script_name") {
      show_log "Sim, executando..."
      run_command "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$appsinstall_folder\$pendrive_script_name`""
    }
    else {
      show_log 'Não, não localizado.'
    }
  }
}