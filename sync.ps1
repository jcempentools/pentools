$ErrorActionPreference = 'Stop'

# Caminho fixo
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$pythonScript = Join-Path $scriptPath 'sync.py'

# Verifica se Python está instalado
function Test-Python {
  try {
    python --version | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

# Verifica se pip está instalado
function Test-Pip {
  try {
    pip --version | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

# Verifica se script está com privilégios elevados
function Test-Elevated {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal $currentIdentity
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Instala Python (winget)
function Install-Python {
  Write-Host 'Instalando Python via winget...'
  winget install -e --id Python.Python.3.12 -h --accept-source-agreements --accept-package-agreements
}

# Instala pip
function Install-Pip {
  Write-Host 'Instalando pip...'
  Invoke-WebRequest https://bootstrap.pypa.io/get-pip.py -OutFile "$env:TEMP\get-pip.py"
  python "$env:TEMP\get-pip.py"
}

# Extrai dependências do sync.py
function Get-Dependencies {
    (Get-Content $pythonScript) -match '^import |^from ' |
  ForEach-Object {
    if ($_ -match '^import\s+(\S+)' -or $_ -match '^from\s+(\S+)') {
                ($matches[1].Split('.')[0])
    }
  } | Sort-Object -Unique
}

# Instala dependências ausentes
function Ensure-Dependencies {
  $missing = @()
  foreach ($dep in Get-Dependencies) {
    try {
      python -c "import $dep" 2>$null
    }
    catch {
      $missing += $dep
    }
  }
  if ($missing.Count -gt 0) {
    if (-not (Test-Elevated)) {
      Write-Host 'Dependências ausentes encontradas, mas privilégios de administrador são necessários para instalar. Abortando.' -ForegroundColor Red
      exit 1
    }
    foreach ($dep in $missing) {
      Write-Host "Instalando $dep..."
      pip install $dep -q
    }
  }
}

# Lógica principal
if (-not (Test-Python)) {
  if (-not (Test-Elevated)) {
    Write-Host 'Python não encontrado e privilégios de administrador ausentes. Abortando.' -ForegroundColor Red
    exit 1
  }
  Install-Python
}

if (-not (Test-Pip)) {
  if (-not (Test-Elevated)) {
    Write-Host 'pip não encontrado e privilégios de administrador ausentes. Abortando.' -ForegroundColor Red
    exit 1
  }
  Install-Pip
}

Ensure-Dependencies

# Executa sync.py com os mesmos parâmetros
python $pythonScript @args