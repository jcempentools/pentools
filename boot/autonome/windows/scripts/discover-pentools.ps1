#requires -version 5.1
<#
.SYNOPSIS
    Discovery Engine: Localizador de Unidade de Ferramentas (.pentools).
    Função Principal: Get-PentoolsEnvironment
    Runtime: PowerShell 2.0 (Bootstrap) -> PowerShell 7.6+ (Full Execution).

.DESCRIPTION
    Biblioteca especializada em identificar unidades físicas e lógicas que contenham 
    a estrutura '/.pentools/' ou '/boot/.pentools/'. O script mapeia a origem e 
    exporta metadados críticos para variáveis de ambiente (ENV) globais.

    [BUSINESS_RULES]
    - DETERMINISMO: Busca sequencial e bloqueante (Sync-first).
    - IDEMPOTÊNCIA: Seguro para múltiplas chamadas; atualiza ENVs se houver mudança física.
    - RESILIÊNCIA: Retry com backoff progressivo na leitura de partições "RAW" ou "Busy".
    - EXCLUSIVIDADE: Uso de Mutex global para impedir descoberta concorrente.
    - FIDELIDADE: Salva o ID físico do disco para garantir persistência caso a letra 
      da unidade mude durante o Windows Setup.
    - RASTREABILIDADE GIT: Priorizar estruturas "Diff-Friendly". Alterações devem ser 
      atômicas e rastreáveis linha a linha.

    [ENVIRONMENT_VARIABLES (Prefixo 'PENTOOLS_')]
    - PENTOOLS_ROOT_DRIVE: Letra da unidade identificada (ex: 'D:').
    - PENTOOLS_PHYSICAL_ID: ID do disco físico (ex: 'Disk #1').
    - PENTOOLS_PATH_TYPE: Tipo de entrada detectada (Root vs Boot).
    - PENTOOLS_CONTEXT: Contexto de execução detectado (WinPE/System/User).

    [MODUS_OPERANDI]
    1. BOOTSTRAP: Validação de privilégios e elevação de PS 2.0 para PS 7.6+.
    2. MUTEX: Garantia de instância única de descoberta.
    3. DISCOVERY: Varredura de drives lógicos em busca de assinaturas .pentools.
    4. MAPPING: Correlação entre letra da unidade (Logical) e número do disco (Physical).
    5. EXPORT: Registro das variáveis PENTOOLS_* no escopo de Processo e Máquina.

    [TECHNICAL_CONSTRAINTS]
    - DEPENDÊNCIAS: Apenas comandos nativos (WMIC/Get-CimInstance, Diskpart).
    - VEDAÇÕES: Sem operações de escrita/cópia (Read-only discovery).
    - VEDAÇÕES: Sem gestão de energia (Sleep/Shutdown), Reboot ou Hooks externos.
    - LOGGING: Exclusivamente via callback fornecido ou Stream padrão.

.PARAMETER LogCallback
    ScriptBlock opcional para redirecionamento de logs estruturados. 
    Ex: { param($msg, $type) Write-Host "[$type] $msg" }

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
    Função Universal: 'Get-PentoolsEnvironment'
    Foco: Localização ultra-resiliente de ativos offline em estágios iniciais de deploy.
#>

function Get-PentoolsEnvironment {
  param(
    [ScriptBlock]$LogCallback
  )

  # =============================
  # LOG WRAPPER (CONTRATO)
  # =============================
  function __log($msg, $type = "l") {
    if ($LogCallback) {
      try { & $LogCallback $msg $type } catch {}
    }
  }

  # =============================
  # MUTEX GLOBAL
  # =============================
  $mutexName = "Global\PENTOOLS_DISCOVERY_MUTEX"
  $mutex = $null
  $hasHandle = $false

  try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasHandle = $mutex.WaitOne(30000)

    if (-not $hasHandle) {
      __log "Timeout ao adquirir mutex global" "w"
      return $null
    }
  }
  catch {
    __log "Falha ao criar mutex global" "w"
  }

  try {

    # =============================
    # RETRY (RESILIÊNCIA)
    # =============================
    $maxRetries = 3

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {

      __log "Discovery tentativa $attempt" "t"

      $drives = @()

      try {
        $drives = Get-PSDrive -PSProvider FileSystem |
        Where-Object { $_.Root -match '^[A-Z]:\\$' } |
        Sort-Object Name
      }
      catch {
        __log "Falha ao listar drives" "w"
      }

      foreach ($d in $drives) {

        $root = $d.Root
        $rootPentools = Join-Path $root ".pentools"
        $bootPentools = Join-Path $root "boot\.pentools"

        $pathType = $null

        if (Test-Path $rootPentools) {
          $pathType = "ROOT"
        }
        elseif (Test-Path $bootPentools) {
          $pathType = "BOOT"
        }
        else {
          continue
        }

        __log "Detectado em $root ($pathType)" "i"

        # =============================
        # MAPEAMENTO FÍSICO (ROBUSTO)
        # =============================
        $diskId = "UNKNOWN"

        try {

          if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {

            $part = Get-CimInstance Win32_LogicalDiskToPartition |
            Where-Object {
              $_.Dependent -match "DeviceID=`"$($d.Name)`""
            }

            if ($part) {
              $diskRel = Get-CimInstance Win32_DiskDriveToDiskPartition |
              Where-Object {
                $_.Dependent -match ($part.Antecedent -replace '"', '')
              }

              if ($diskRel) {
                $diskObj = Get-CimInstance Win32_DiskDrive |
                Where-Object {
                  $_.__PATH -eq $diskRel.Antecedent
                }

                if ($diskObj) {
                  $diskId = "Disk #" + $diskObj.Index

                  if ($diskObj.SerialNumber) {
                    $diskId += " [" + $diskObj.SerialNumber.Trim() + "]"
                  }
                }
              }
            }

          }
          else {
            # fallback PS 2.0
            $wmi = Get-WmiObject Win32_LogicalDiskToPartition |
            Where-Object {
              $_.Dependent -match "DeviceID=`"$($d.Name)`""
            }

            if ($wmi) {
              $diskId = "Disk ?"
            }
          }

        }
        catch {
          __log "Falha mapping físico ($root)" "w"
        }

        # =============================
        # CONTEXTO (WINPE / SYSTEM / USER)
        # =============================
        $context = "USER"

        try {
          $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()

          if ($id.Name -match "SYSTEM") {
            $context = "SYSTEM"
          }

          if (Test-Path "X:\Windows\System32") {
            $context = "WINPE"
          }
        }
        catch {
          $context = "UNKNOWN"
        }

        # =============================
        # EXPORT ENV (IDEMPOTENTE)
        # =============================
        $envMap = @{
          PENTOOLS_ROOT_DRIVE  = $d.Name + ":"
          PENTOOLS_PHYSICAL_ID = $diskId
          PENTOOLS_PATH_TYPE   = $pathType
          PENTOOLS_CONTEXT     = $context
        }

        foreach ($k in $envMap.Keys) {

          try {
            $current = [System.Environment]::GetEnvironmentVariable($k, "Machine")

            if ($current -ne $envMap[$k]) {

              [System.Environment]::SetEnvironmentVariable($k, $envMap[$k], "Process")
              [System.Environment]::SetEnvironmentVariable($k, $envMap[$k], "Machine")

              __log "ENV atualizado: $k=$($envMap[$k])" "i"
            }

          }
          catch {
            __log "Falha ao exportar ENV $k" "w"
          }
        }

        return $envMap
      }

      # =============================
      # BACKOFF (TÉCNICO)
      # =============================
      Start-Sleep -Seconds ([math]::Pow(2, $attempt))
    }

    __log "Nenhum ambiente .pentools encontrado" "w"
    return $null

  }
  finally {
    if ($hasHandle -and $mutex) {
      try { $mutex.ReleaseMutex() } catch {}
      $mutex.Dispose()
    }
  }
}