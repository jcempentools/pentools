"""
SYNC ENGINE
PARSER SYNCDOWNLOAD | BIBLIOTECA

SUMÁRIO E ESCOPO
================
[1] CONTEXTO GLOBAL DO PROJETO (normativo e vinculante)
[2] DIRETRIZES E PRINCÍPIOS COMPARTILHADOS
[3] REGRAS E RESTRIÇÕES DO ECOSSISTEMA
[4] DEFINIÇÕES DESTA BIBLIOTECA (específico deste script)

Nota: Este cabeçalho documenta EXCLUSIVAMENTE o contexto e as regras do projeto.
As regras específicas desta biblioteca serão definidas na seção [4].

---------------------------------------------------------------------

[1] CONTEXTO GLOBAL DO PROJETO
==============================

Arquitetura SYNC:
sync/
│
├── main.py                        # Orquestração do pipeline (cleanup → download → cópia → retry → pós)
├── commons.py                     # globais: funções, paths, regex, flags, estruturas compartilhas 
│                                    entre dois ou mais scripts
├── core/
│   ├── syncdownload.parser.py     # Parsing .syncdownload, resolução de URL e nome determinístico
│   ├── syncdownload.processor.py  # Pipeline por item: decisão, cache, download, sync
│   ├── download_manager.py        # Execução de downloads: progresso, timeout, cache
│   ├── cache_validation.py        # Integridade: hash + metadata (.sha256/.syncado)
│   ├── cleanup.py                 # Remoção segura de órfãos com base em regras globais
│   ├── file_operations.py         # Operações de filesystem seguras e determinísticas
│   ├── metadata.py                # Geração e vínculo de metadata persistente
│   └── retry.py                   # Política de retentativa e reprocessamento
│
└── utils/
    ├── progress.py                # Progressbar padronizada (rich)
    ├── naming.py                  # Normalização/canonicalização/dedup
    ├── dsl.py                     # Parser de expressões dinâmicas (${...})
    └── logging.py                 # Logging estruturado e padronizado

Abstração de Origens:
- Interface unificada para providers (GitHub, GitLab, etc.)
- Preferência por APIs oficiais; vedado parsing heurístico (HTML/XML)

---------------------------------------------------------------------

[2] DIRETRIZES E PRINCÍPIOS
===========================

Técnicos:
- Separação obrigatória: HEAD (metadata) × GET (download)
- Integridade via SHA256
- Cache híbrido: memória + persistente
- Metadata não bloqueia atualização
- Timeout por inatividade + logging rotativo

Execução:
- Idempotente, determinística, síncrona e ordenada
- Decisão incremental (cache + validação)
- Retry automático (falhas transitórias); abort seguro (inconsistência)

UX:
- Progressbar inline, sem flooding
- Feedback contínuo: hash, download, retry, cópia

Implementação:
- Funções pequenas, especializadas, reutilizáveis
- Baixo acoplamento, imutabilidade, sem duplicação
- Centralização: naming, versão, validação, download
- Sem side-effects e sem hardcode
- Diff-friendly (mudanças mínimas e rastreáveis)

---------------------------------------------------------------------

[3] REGRAS E RESTRIÇÕES
=======================

Regras:
- Dedup por nome canônico (primário) e hash (fallback)
- Preservar versão válida mais recente
- Nome lógico estável; filename pode variar
- Coerência obrigatória origem ↔ destino
- Remoção apenas com validação lógica

Restrições:
- Proibido duplicar lógica ou invadir responsabilidade de outros módulos
- Proibido parsing HTML se houver API
- Proibido purge agressivo por nome
- Proibido quebrar metadata ou UX definida
- Divergência de hash remoto exige retry
- Preservar arquivos sem equivalente na origem/.syncdownload

---------------------------------------------------------------------

[4] DEFINIÇÕES DESTA BIBLIOTECA (específico deste script)
=========================================================


"""

# IMPORTS
import os
import re
import json
import sys
import time
import shutil
import gzip
import hashlib
import ctypes
import urllib.request

# VARIÁVEIS GLOBAIS
ORIGIN_PATH = ...
destination_path = None

IGNORED_PATHS = ...
__IGNORAR_GITHUB = False

sync_resolve_cache = {}
download_registry = {}
failed_files = []

retent_loop_count = 0

PROVIDERS = {}

# --- [Parser DSL Resolver] ---

__PARSER_CACHE = {}
PARSER_CACHE_TTL = 60  # segundos

# Registro seguro de providers (evita NameError)
try:
    PROVIDERS["github.com"] = resolve_github
except NameError:
    pass  # provider não disponível

__IGNORAR_GITHUB = False

# Variável global para o ID da execução
ID_EXECUCAO = ''.join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(3))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(SCRIPT_DIR, "sync.log")
MAX_LOG_SIZE = 5 * 1024 * 1024  # 5 MB

# evita falso positivo em arquivos pequenos (boot, configs embutidos, etc.)
MIN_SIZE_BYTES = 2 * 1024 * 1024  # 2MB

SyncDonwloadExtensions = ["exe", "msi", "iso", "img", "img.gz", "iso.gz"]

_log_iniciado = False
retent_loop_count = 0

# Listas de controle
verifieds = []       # Arquivos/pastas já verificados
failed_files = []    # Arquivos que falharam na cópia

sys.stdout = codecs.getwriter('utf-8')(sys.stdout.detach())
sys.stderr = codecs.getwriter('utf-8')(sys.stderr.detach())

# Inicializa o console para mensagens estilizadas
console = Console()

# Cache de proteção global .syncdownload
_sync_global_map = None

# Dicionário para armazenar hashes temporários em RAM
hash_cache = {}

# Cache de resolução de .syncdownload (pré-processamento)
sync_resolve_cache = {}

# Cache global de downloads já realizados (url -> path destino)
download_registry = {}

# Caminhos
destination_path = "?"
ORIGIN_PATH = os.path.normpath(SCRIPT_DIR).rstrip(os.path.sep) + os.path.sep

# Padrões fixos que a ignorar
DEFAULT_IGNORED = (
    r"(\.(git|vscode|trunk|github)(\\|/|$))|"          # Pastas de dev
    r"(\.(log|tmp|eslintrc\.json|gitattributes|gitignore|prettierrc|prettierignore)$)|" # Extensões/Arquivos
    r"(API_JSON)$|" # Pastas diversas
    r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|" # Pastas de sistema    
    r"\.TemporaryItems$|\$Recycle\.Bin$|Recycler$)"    
)

# Verifica se há argumentos via CLI
if any(arg.startswith("ignore=") for arg in sys.argv):
    cli_ignored = '|'.join(
        re.escape(item) + r"$"
        for arg in sys.argv
        if arg.startswith("ignore=")
        for item in arg.split('=', 1)[1].split(',')
    )
    IGNORED_PATHS = f"({DEFAULT_IGNORED}|{cli_ignored})"
else:
    IGNORED_PATHS = DEFAULT_IGNORED

# Cache global de normalização
_product_cache = {}

# Alias canônicos
PRODUCT_ALIASES = {
    "7zip": "7z",
    "7z": "7z",
    "pwsh": "powershell",
    "powershell": "powershell",
}

# Vendors conhecidos (ignorados)
KNOWN_VENDORS = {
    "microsoft", "oracle", "google", "adobe", "mozilla",
    "github", "gitlab"
}

# Ruídos
NOISE_TOKENS = {
    "x86", "x64", "arm32", "amd32", "arm64", "amd64",    
    "arm", "win", "windows", "linux", "mac",
    "setup", "installer", "install",
    "release", "portable",
    "rc", "beta", "alpha",
    "msi", "exe", "zip", "live"
}

# MAPEAMENTO DE FUNÇÕES

def hash_file(filename, label):
    """
    Descrição: Calcula hash (xxhash ou SHA256) de arquivo com cache.
    Parâmetros:
    - filename (str|Path): Caminho do arquivo.
    - label (str): Rótulo para exibição.
    Retorno:
    - str|None: Hash calculado ou None em erro.
    """    
    filename = str(filename) if isinstance(filename, Path) else filename
    if os.path.isdir(filename):
        return 1        
    cached_hash = hash_cache.get(filename)
    if cached_hash:
        return cached_hash
    try:
        file_size = os.path.getsize(filename)
        with open(filename, 'rb') as file:
            # Detecta se deve usar SHA256 (quando houver metadata ou validação crítica)
            use_sha256 = filename.lower().endswith((".iso", ".img")) or os.path.exists(filename + ".sha256")

            hasher = hashlib.sha256() if use_sha256 else xxhash.xxh3_64()
            file_name = os.path.basename(filename)  
            with create_progress("bold yellow") as progress:
                task = progress.add_task("", total=file_size, label=label, name=file_name)
                while chunk := file.read(65536):
                    hasher.update(chunk)
                    progress.update(task, advance=len(chunk))
        res = hasher.hexdigest()
        hash_cache[filename] = res
        return res.lower()
    except Exception as e:
        show_message(f"Erro ao calcular hash de {filename}: {e}", "e")
        return None
