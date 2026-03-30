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
#   1. Prioriza execução offline via pendrive
#   2. Tenta montar volumes (mountvol) se necessário
#   3. Retry resiliente de localização e cópia
#   4. Fallback para download online
#   5. Execução silenciosa e tolerante a falhas
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

$Env:install_cru = "$$VNTY_PERFIL_CONFIG_install_cru$$";
$Env:install_cru = $Env:install_cru.Trim().ToLower();
$Env:LOCAL_EXEC = "#{{MODE}}#".Trim().ToUpper();

try {
  $user = [Environment]::UserName;
  $domain = [Environment]::UserDomainName;
}
catch {  
}


# =========================================================
# Configuração
# =========================================================
$script = "C:\autounattend.ps1";
$relPath = "boot\autonome\windows\autounattend.ps1";

Remove-Item $script -Force -ErrorAction SilentlyContinue;


# =========================================================
# Função: localizar script offline
# =========================================================
function Find-OfflineScript {
  $found = $null;

  foreach ($letter in 65..90) {
    try {
      $drive = [char]$letter + ":\";
      $test = $drive + $relPath;
      if (Test-Path $test) {
        $found = $test;
        break;
      }
    }
    catch {}
  }

  return $found;
}


# =========================================================
# 1. Tentar localizar offline
# =========================================================
$found = Find-OfflineScript;


# =========================================================
# 2. Tentar montar volumes se não encontrou
# =========================================================
if (-not $found) {
  try { mountvol /E > $null 2>&1; } catch {}
  Start-Sleep -Seconds 2;
  $found = Find-OfflineScript;
}


# =========================================================
# 3. Copiar se encontrado
# =========================================================
if ($found) {
  try {
    Copy-Item $found $script -Force -ErrorAction SilentlyContinue;
  }
  catch {}
}


# =========================================================
# 4. Fallback internet
# =========================================================
if (!(Test-Path $script)) {
  try {
    $wc = New-Object System.Net.WebClient;
    $wc.DownloadFile("https://raw.githubusercontent.com/jcempentools/pentools/refs/heads/master/boot/autonome/windows/autounattend.ps1", $script);
  }
  catch {}
}


# =========================================================
# 5. Executar com resiliência
# =========================================================
if (Test-Path $script) {
  try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script;
  }
  catch {}
}


# limpeza silenciosa
try {
  Remove-Item $script -Force -ErrorAction SilentlyContinue;
}
catch {}
