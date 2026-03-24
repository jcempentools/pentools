# =============================================================
# AUTOUNATTEND Bootstrap Loader
# -------------------------------------------------------------
# Objetivo:
#   Localizar e executar automaticamente o script principal
#   "autounattend.ps1" durante a instalação do Windows.
#
# Cenário:
#   - Execução em WinPE / Setup / SYSTEM / FirstLogon
#   - Ambiente possivelmente incompleto ou restrito
#   - Pendrive de instalação pode não ter letra atribuída
#
# Comportamento:
#   1. Detecta automaticamente SYSTEM vs FirstLogon
#   2. Prioriza execução offline via pendrive
#   3. Tenta montar volumes (mountvol) se necessário
#   4. Retry resiliente de localização e cópia
#   5. Fallback para download online
#   6. Execução silenciosa e tolerante a falhas
#
# Diretrizes:
#   - Não falhar de forma catastrófica
#   - Manter compatibilidade PowerShell 2 / 5 / 7
#   - Evitar dependências externas ou módulos
#   - Priorizar minimalismo e robustez
#   - Executar com privilégios SYSTEM quando possível
#
# Padrões:
#   - Offline-first
#   - Try/catch defensivo
#   - Sem logging obrigatório
#   - Sem interação com usuário
#   - Compatível com WinPE e OOBE
#
# Observação:
#   Este script é apenas um bootstrapper resiliente e deve
#   permanecer pequeno, simples e independente.
# =============================================================

$Env:install_cru = "cru"

# =========================================================
# Detecção automática de contexto (SYSTEM vs FirstLogon)
# =========================================================
try {
  $user = [Environment]::UserName
  $domain = [Environment]::UserDomainName

  if ($user -eq "SYSTEM" -or $domain -eq "NT AUTHORITY") {    
    $Env:LOCAL_EXEC = "SYSTEM"
  }
  else {    
    $Env:LOCAL_EXEC = "FirstLogon"
  }
}
catch {
  # fallback mais seguro durante instalação  
  $Env:LOCAL_EXEC = "SYSTEM"
}


# =========================================================
# Configuração
# =========================================================
$script = "C:\autounattend.ps1"
$relPath = "boot\autonome\windows\autounattend.ps1"

Remove-Item $script -Force -ErrorAction SilentlyContinue


# =========================================================
# Função: localizar script offline
# =========================================================
function Find-OfflineScript {
  $found = $null

  foreach ($letter in 65..90) {
    try {
      $drive = [char]$letter + ":\"
      $test = $drive + $relPath
      if (Test-Path $test) {
        $found = $test
        break
      }
    }
    catch {}
  }

  return $found
}


# =========================================================
# 1. Tentar localizar offline
# =========================================================
$found = Find-OfflineScript


# =========================================================
# 2. Tentar montar volumes se não encontrou
# =========================================================
if (-not $found) {
  try { mountvol /E > $null 2>&1 } catch {}
  Start-Sleep -Seconds 2
  $found = Find-OfflineScript
}


# =========================================================
# 3. Copiar se encontrado
# =========================================================
if ($found) {
  try {
    Copy-Item $found $script -Force -ErrorAction SilentlyContinue
  }
  catch {}
}


# =========================================================
# 4. Fallback internet
# =========================================================
if (!(Test-Path $script)) {
  try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile("https://abre.ai/o1q4", $script)
  }
  catch {}
}


# =========================================================
# 5. Executar com resiliência
# =========================================================
if (Test-Path $script) {
  try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
  }
  catch {}
}


# limpeza silenciosa
try {
  Remove-Item $script -Force -ErrorAction SilentlyContinue
}
catch {}