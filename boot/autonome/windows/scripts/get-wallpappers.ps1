#requires -version 5.1
<#
.SYNOPSIS
    Personalização Visual: Gestor de Wallpapers e LockScreen.
    Provisionamento de ativos visuais e aplicação de identidade visual no Windows.

.DESCRIPTION
    Componente responsável pela coleta, sincronização e aplicação de fundos de tela 
    e imagens de bloqueio. O script implementa uma lógica de busca híbrida 
    (Offline-First) e aplica as configurações via Registro do Windows.

    ESPECIFICIDADES TÉCNICAS (WALLPAPERS):
    - Estratégia de Coleta: 
        1. Busca recursiva em mídia física (Offline) nas extensões .png e .jpg.
        2. Fallback Online via listas de download (.lst) caso a mídia esteja ausente 
           ou o modo de instalação não seja 'cru'.
    - Nomeação e Integridade: Utiliza hashing SHA256 para nomear arquivos baixados, 
      prevenindo duplicidade e garantindo unicidade no sistema de arquivos.
    - Local de Destino: Padronização em '%SystemDrive%\Users\Default\Pictures\WallPapers' 
      para garantir disponibilidade a novos perfis de usuário.

    OBJETIVOS DE PERSONALIZAÇÃO:
    - Tela de Bloqueio (LockScreen): Aplicação global via 'PersonalizationCSP' em HKLM.
    - Papel de Parede (Wallpaper): Aplicação em contexto de usuário (HKCU) com 
      estilo de preenchimento 'Fill' (Style 10).
    - Refresh de UI: Acionamento de 'UpdatePerUserSystemParameters' via rundll32 
      para forçar a atualização visual sem necessidade de logoff.

    RESTRIÇÕES ESPECÍFICAS:
    - Contexto de Usuário: A definição de Wallpaper (HKCU) é ignorada se o script 
      detectar execução em contexto estritamente SYSTEM ($in_system_context).
    - Dependências de Funções: Exige 'download_save', 'download_to_string', 'sha256' 
      e 'setrgkey' para operação plena.
    - Validação de Existência: O script valida a presença física do arquivo antes 
      de tentar a aplicação no Registro para evitar telas pretas ou erros de UI.

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
    Gestor de Ativos Visuais, Personalização de UI e Sincronizador de Mídia.
    Foco: Identidade Visual, Resiliência Offline e Automação de Registro.
#>


show_log_title "### WallPapers"
$WallPapers_path = ""
if (-Not ([string]::IsNullOrEmpty($appsinstall_folder))) {
  $WallPapers_path = (get-item $appsinstall_folder).Parent.FullName
  $WallPapers_path = "$WallPapers_path\WallPapers\images"
}
if ([string]::IsNullOrEmpty($image_folder)) { $image_folder = "$env:SystemDrive\Users\Default\Pictures" }
$image_folder = "$image_folder\WallPapers"
$img_count = 0
if ((-Not ([string]::IsNullOrEmpty($WallPapers_path))) -And (Test-Path -Path "$WallPapers_path")) {
  show_log "Obtendo WallPapers do pendrive, se exitir..."
  foreach ($ee in @('png', 'jpg')) {
    Get-ChildItem -Path "$WallPapers_path" -Filter "*.$ee" -Recurse -File | ForEach-Object {
      try {
        $nome = $_.BaseName
        Copy-Item $_ "$image_folder\$nome.$ee" -Force
        $img_count = $img_count + 1
      }
      catch {
        # ignore
      }
    }
  }
  show_log "'$img_count' WallPaper(s) obdito(s) offline."
}
if (("$Env:install_mode" -ne "cru") -And ($img_count -le 0)) {
  show_log "Obtendo WallPapers ONLINE..."
  if (-Not (Test-Path -Path "$image_folder")) {
    New-Item -Path "$image_folder" -Force -ItemType Directory
  }
  download_save "$url_WallPapers_lst" "$image_folder\download.lst"
  if (Test-Path "$image_folder\download.lst") {
    $i = 0
    $ext = "png"
    foreach ($line in Get-Content "$image_folder\download.lst") {
      $line = $line.trim()
      if (
        [string]::IsNullOrEmpty($line) -or
        ($line -match '^\s*$') -or
        ($line -match '^\s*#')
      ) {
        continue
      }
      #$destname = $i
      $destname = sha256($line)
      #$destname = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($line))
      download_save "$line" "$image_folder\$destname.$ext"
      #$shaname = (Get-FileHash "$image_folder\$i.$ext" -Algorithm SHA256).Hash
      #try {
      #  if (Test-Path "$image_folder\$shaname.$ext") {
      #    Remove-Item "$image_folder\$shaname.$ext" -Force
      #  }
      #  Move-Item -Path "$image_folder\$i.$ext" "$image_folder\$shaname.$ext"
      #}
      #catch {
      #}
      $i = $i + 1
    }
  }
  show_log_title "Definindo tela de bloqueio personalizada"
  # now set the registry entry
  $nome = download_to_string($url_lockscreen)
  show_log "A setar '$nome'."
  if (-Not (Test-Path "$image_folder\$nome.png")) {
    show_warn "O WallPaper '$nome' não existe."
  }
  elseif (-Not ([string]::IsNullOrEmpty($nome) -Or ($nome -match '^\s*$'))) {
    try {
      setrgkey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImagePath' "$image_folder\$nome.png"
      rundll32.exe user32.dll, UpdatePerUserSystemParameters
      show_log "Definido."
    }
    catch {
      show_error "FALHA ao definir tela de bloqueio."
    }
  }
  ## DEFINIR WALLPAPPER APENAS SE ESTIVER EM USUÁRIO
  if (-not $in_system_context) {
    show_log_title "Definindo WallPaper"
    # now set the registry entry
    $nome = download_to_string($url_defWallPaper)
    show_log "A setar '$nome'."
    if (-Not (Test-Path "$image_folder\$nome.png")) {
      show_warn "O WallPaper '$nome' não existe."
    }
    elseif (-Not ([string]::IsNullOrEmpty($nome) -Or ($nome -match '^\s*$'))) {
      try {
        setrgkey 'HKCU:\Control Panel\Desktop' 'WallPaper' "$image_folder\$nome.png"
        setrgkey 'HKCU:\Control Panel\Desktop' 'WallPaperStyle' 10
        setrgkey 'HKCU:\Control Panel\Desktop' 'TileWallpaper' 0
        rundll32.exe user32.dll, UpdatePerUserSystemParameters
        show_log "Definido."
      }
      catch {
        show_error "FALHA ao definir WallPaper."
      }
    }
  }
}