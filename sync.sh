#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/sync.py"

# Detecta distro e gerenciador de pacotes
if command -v apt-get &>/dev/null; then
    PKG_MGR="sudo apt-get install -y"
elif command -v dnf &>/dev/null; then
    PKG_MGR="sudo dnf install -y"
elif command -v pacman &>/dev/null; then
    PKG_MGR="sudo pacman -Sy --noconfirm"
elif command -v brew &>/dev/null; then
    PKG_MGR="brew install"
else
    echo "Gerenciador de pacotes não suportado. Abortando."
    exit 1
fi

# Verifica se Python está instalado
if ! command -v python3 &>/dev/null; then
    if ! sudo -n true 2>/dev/null; then
        echo "Python não encontrado e sem privilégios sudo. Abortando."
        exit 1
    fi
    echo "Instalando Python..."
    $PKG_MGR python3
fi

# Verifica se pip está instalado
if ! command -v pip3 &>/dev/null; then
    if ! sudo -n true 2>/dev/null; then
        echo "pip não encontrado e sem privilégios sudo. Abortando."
        exit 1
    fi
    echo "Instalando pip..."
    curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    python3 /tmp/get-pip.py
fi

# Extrai e instala dependências
MISSING=()
for dep in $(grep -E '^import |^from ' "$PYTHON_SCRIPT" | awk '{print $2}' | cut -d. -f1 | sort -u); do
    python3 -c "import $dep" 2>/dev/null || MISSING+=("$dep")
done

if [ "${#MISSING[@]}" -gt 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "Dependências ausentes encontradas, mas sem privilégios sudo. Abortando."
        exit 1
    fi
    for dep in "${MISSING[@]}"; do
        echo "Instalando $dep..."
        pip3 install "$dep" >/dev/null
    done
fi

# Executa sync.py com os mesmos parâmetros
python3 "$PYTHON_SCRIPT" "$@"
