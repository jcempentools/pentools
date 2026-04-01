#requires -version 2.0
# =====================================================================
# Windows 11 Language Enforcer (PT-BR)
# Compatível: PowerShell 2, 5, 7+
# Execução: SYSTEM / Setup / OOBE / Audit / WinPE
# Resiliente, Idempotente, Fail-Safe
# =====================================================================

# ------------------------------
# CONFIG
# ------------------------------
$Script:TargetLang = "pt-BR"
$Script:TargetKeyboard = "00010416" # ABNT2
$Script:TargetGeoId = 32          # Brazil
$Script:TargetTimeZone = "E. South America Standard Time"
$Script:MaxRetries = 5
$Script:RetryDelay = 5
$Script:LogFile = "$env:SystemRoot\Temp\ptbr-language.log"

# ------------------------------
# LOGGING
# ------------------------------
function Write-Log {
  param([string]$Message)

  $time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "$time - $Message"

  try { Add-Content -Path $Script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
}

# ------------------------------
# RETRY WRAPPER
# ------------------------------
function Invoke-Retry {
  param(
    [scriptblock]$ScriptBlock,
    [string]$ActionName
  )

  for ($i = 1; $i -le $Script:MaxRetries; $i++) {
    try {
      Write-Log "Tentativa $i : $ActionName"
      & $ScriptBlock
      Write-Log "Sucesso : $ActionName"
      return $true
    }
    catch {
      Write-Log "Erro tentativa $i : $ActionName : $_"
      Start-Sleep -Seconds ($Script:RetryDelay * $i)
    }
  }

  Write-Log "Falha definitiva : $ActionName"
  return $false
}

# ------------------------------
# TESTA IDIOMA ATUAL
# ------------------------------
function Get-CurrentUILanguage {

  try {
    $lang = (Get-ItemProperty `
        "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages" `
        -ErrorAction Stop).PSChildName

    return $lang[0]
  }
  catch {
    return $null
  }
}

# ------------------------------
# TESTA SE JÁ É PTBR
# ------------------------------
function Test-IsPtBr {

  $current = Get-CurrentUILanguage
  Write-Log "Idioma atual: $current"

  if ($current -eq $Script:TargetLang) {
    Write-Log "Sistema já está em PT-BR"
    return $true
  }

  return $false
}

# ------------------------------
# GARANTE REDE
# ------------------------------
function Ensure-Network {

  Invoke-Retry {
    Write-Log "Testando conectividade..."

    $ping = ping -n 1 8.8.8.8 | Out-Null
  } "Inicializar Rede"
}

# ------------------------------
# BAIXA LANGUAGE PACK
# ------------------------------
function Download-LanguagePack {

  $url = "https://software-download.microsoft.com/download/pr/LanguageExperiencePack.pt-BR.Neutral.appx"
  $dest = "$env:TEMP\lp-ptbr.appx"

  Invoke-Retry {

    Write-Log "Baixando Language Pack"

    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $dest)

  } "Download Language Pack"

  return $dest
}

# ------------------------------
# INSTALA LANGUAGE PACK
# ------------------------------
function Install-LanguagePack {

  param([string]$Path)

  Invoke-Retry {

    Write-Log "Instalando Language Pack via DISM"

    dism /Online /Add-ProvisionedAppxPackage `
      /PackagePath:$Path `
      /SkipLicense

  } "Instalar Language Pack"
}

# ------------------------------
# DEFINE IDIOMA DO SISTEMA
# ------------------------------
function Set-SystemLanguage {

  Invoke-Retry {

    Write-Log "Definindo idioma do sistema"

    Set-WinSystemLocale $Script:TargetLang -ErrorAction SilentlyContinue
    Set-Culture $Script:TargetLang -ErrorAction SilentlyContinue

  } "Definir idioma sistema"
}

# ------------------------------
# DEFINE TECLADO ABNT2
# ------------------------------
function Set-Keyboard {

  Invoke-Retry {

    Write-Log "Configurando teclado ABNT2"

    reg add "HKU\.DEFAULT\Keyboard Layout\Preload" `
      /v 1 /t REG_SZ /d $Script:TargetKeyboard /f

    reg add "HKCU\Keyboard Layout\Preload" `
      /v 1 /t REG_SZ /d $Script:TargetKeyboard /f

  } "Configurar teclado"
}

# ------------------------------
# DEFINE REGIÃO
# ------------------------------
function Set-Region {

  Invoke-Retry {

    Write-Log "Configurando região Brasil"

    Set-WinHomeLocation -GeoId $Script:TargetGeoId -ErrorAction SilentlyContinue

  } "Configurar região"
}

# ------------------------------
# DEFINE TIMEZONE
# ------------------------------
function Set-TimeZoneSafe {

  Invoke-Retry {

    Write-Log "Configurando timezone"

    tzutil /s "$Script:TargetTimeZone"

  } "Configurar timezone"
}

# ------------------------------
# REMOVE OUTROS IDIOMAS
# ------------------------------
function Remove-OtherLanguages {

  Invoke-Retry {

    Write-Log "Removendo idiomas não PT-BR"

    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages"
    Get-ChildItem $key | ForEach-Object {

      if ($_.PSChildName -ne $Script:TargetLang) {

        Write-Log "Removendo idioma $($_.PSChildName)"
        Remove-Item $_.PsPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

  } "Remover idiomas extras"
}

# ------------------------------
# VALIDAÇÃO FINAL
# ------------------------------
function Validate-Configuration {

  Write-Log "Validando configuração final"

  if (-not (Test-IsPtBr)) {
    throw "Idioma não aplicado corretamente"
  }
}

# ------------------------------
# MAIN
# ------------------------------
function Main {

  Write-Log "===== INICIO SCRIPT PTBR ====="

  if (Test-IsPtBr) {
    Write-Log "Nada a fazer"
    return
  }

  Ensure-Network

  $lp = Download-LanguagePack
  Install-LanguagePack $lp

  Set-SystemLanguage
  Set-Keyboard
  Set-Region
  Set-TimeZoneSafe
  Remove-OtherLanguages

  Validate-Configuration

  Write-Log "===== FIM SCRIPT PTBR ====="
}

# EXEC
Main