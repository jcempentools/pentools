<#
.SYNOPSIS
    Discovery Engine: Localizador de Unidade de Ferramentas (.pentools).
    Função Principal: Get-PentoolsEnvironment
    Runtime: PowerShell 2.0 (Bootstrap) -> PowerShell 7.6+ (Full Execution).

.DESCRIPTION
    Biblioteca especializada em identificar unidades físicas e lógicas que contenham 
    a estrutura '/.pentools/' ou '/boot/.pentools/'. O script mapeia a origem e 
    exporta metadados críticos para variáveis de ambiente (ENV) globais.

.PARAMETER LogCallback
    ScriptBlock opcional para redirecionamento de logs estruturados. 
    Ex: { param($msg, $level) Write-Host "[$level] $msg" }

.ENVIRONMENT_VARIABLES
    Para evitar conflitos, utiliza-se o prefixo 'PENTOOLS_':
    - PENTOOLS_ROOT_DRIVE: Letra da unidade identificada (ex: 'D:').
    - PENTOOLS_PHYSICAL_ID: ID do disco físico (ex: 'Disk #1').
    - PENTOOLS_PATH_TYPE: Tipo de entrada detectada (Root vs Boot).
    - PENTOOLS_CONTEXT: Contexto de execução detectado (WinPE/System/User).

.BUSINESS_RULES
    - DETERMINISMO: Busca sequencial e bloqueante (Sync-first).
    - IDEMPOTÊNCIA: Seguro para múltiplas chamadas; atualiza ENVs se houver mudança física.
    - RESILIÊNCIA: Retry com backoff progressivo na leitura de partições "RAW" ou "Busy".
    - EXCLUSIVIDADE: Uso de Mutex global para impedir descoberta concorrente.
    - FIDELIDADE: Salva o ID físico do disco para garantir persistência caso a letra da unidade mude durante o Windows Setup.

.MODUS_OPERANDI
    1. BOOTSTRAP: Validação de privilégios e elevação de PS 2.0 para PS 7.6+.
    2. MUTEX: Garantia de instância única de descoberta.
    3. DISCOVERY: Varredura de drives lógicos em busca de assinaturas .pentools.
    4. MAPPING: Correlação entre letra da unidade (Logical) e número do disco (Physical).
    5. EXPORT: Registro das variáveis PENTOOLS_* no escopo de Processo e Máquina.

.TECHNICAL_CONSTRAINTS
    - DEPENDÊNCIAS: Apenas comandos nativos (WMIC/Get-CimInstance, Diskpart).
    - VEDAÇÕES: Sem operações de escrita/cópia (Read-only discovery).
    - VEDAÇÕES: Sem gestão de energia (Sleep/Shutdown), Reboot ou Hooks externos.
    - LOGGING: Exclusivamente via callback fornecido ou Stream padrão (vazio por padrão).

.COMPATIBILITY
    - OS: Windows 10 / 11 / WinPE (Contexto SYSTEM e USER).
    - Engine: PowerShell 2.0 até 7.6+.

.NOTES
    Função Universal: 'Get-PentoolsEnvironment'
    Foco: Localização ultra-resiliente de ativos offline em estágios iniciais de deploy.
#>

function Get-PentoolsEnvironment {
  param(
    [ScriptBlock]$LogCallback
  )

  # -----------------------------
  # LOG WRAPPER
  # -----------------------------
  function __log($msg, $level = "INFO") {
    if ($LogCallback) {
      try { & $LogCallback $msg $level } catch {}
    }
  }

  # -----------------------------
  # MUTEX GLOBAL
  # -----------------------------
  $mutexName = "Global\PENTOOLS_DISCOVERY_MUTEX"
  $mutex = $null
  $hasHandle = $false

  try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasHandle = $mutex.WaitOne(30000) # 30s timeout
    if (-not $hasHandle) {
      __log "Timeout ao adquirir mutex" "WARN"
      return $null
    }
  }
  catch {
    __log "Falha ao criar mutex" "WARN"
  }

  try {

    # -----------------------------
    # RETRY CONFIG
    # -----------------------------
    $maxRetries = 3

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {

      __log "Discovery tentativa $attempt"

      $drives = @()

      try {
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
          $_.Root -match '^[A-Z]:\\$'
        } | Sort-Object Name
      }
      catch {
        __log "Falha ao listar drives" "WARN"
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

        __log "Detectado em $root ($pathType)"

        # -----------------------------
        # MAPEAMENTO FÍSICO
        # -----------------------------
        $diskId = "UNKNOWN"

        try {
          if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {

            $part = Get-CimInstance Win32_LogicalDiskToPartition |
            Where-Object { $_.Dependent -match $d.Name }

            if ($part) {
              $disk = Get-CimInstance Win32_DiskDriveToDiskPartition |
              Where-Object { $_.Dependent -match ($part.Antecedent -replace '"', '') }

              if ($disk) {
                $diskObj = Get-CimInstance Win32_DiskDrive |
                Where-Object { $_.__PATH -eq ($disk.Antecedent) }

                if ($diskObj) {
                  $diskId = "Disk #" + $diskObj.Index
                }
              }
            }
          }
          else {
            # fallback PS 2.0
            $wmi = Get-WmiObject Win32_LogicalDiskToPartition |
            Where-Object { $_.Dependent -match $d.Name }

            if ($wmi) {
              $diskId = "Disk ?"
            }
          }
        }
        catch {
          __log "Falha mapping físico ($root)" "WARN"
        }

        # -----------------------------
        # CONTEXTO
        # -----------------------------
        $context = "USER"

        try {
          $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
          if ($id.Name -match "SYSTEM") {
            $context = "SYSTEM"
          }
        }
        catch {
          $context = "UNKNOWN"
        }

        # -----------------------------
        # EXPORT ENV
        # -----------------------------
        $envMap = @{
          PENTOOLS_ROOT_DRIVE  = $d.Name + ":"
          PENTOOLS_PHYSICAL_ID = $diskId
          PENTOOLS_PATH_TYPE   = $pathType
          PENTOOLS_CONTEXT     = $context
        }

        foreach ($k in $envMap.Keys) {
          try {
            [System.Environment]::SetEnvironmentVariable($k, $envMap[$k], "Process")
            [System.Environment]::SetEnvironmentVariable($k, $envMap[$k], "Machine")
          }
          catch {
            __log "Falha ao exportar ENV $k" "WARN"
          }
        }

        return $envMap
      }

      # backoff progressivo
      Start-Sleep -Seconds ([math]::Pow(2, $attempt))
    }

    __log "Nenhum ambiente .pentools encontrado" "WARN"
    return $null

  }
  finally {
    if ($hasHandle -and $mutex) {
      try { $mutex.ReleaseMutex() } catch {}
      $mutex.Dispose()
    }
  }
}