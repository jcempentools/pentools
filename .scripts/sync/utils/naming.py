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
import re

from sync.commons import *

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES

def normalize_product_name(filename):
    """
    Descrição: Normaliza nome de produto removendo ruídos e versões:
    - alias
    - remoção de vendor
    - remoção de versão
    - cache    
    Parâmetros:
    - filename (str): Nome do arquivo.
    Retorno:
    - str|None: Nome normalizado.
    """

    if filename in _product_cache:
        return _product_cache[filename]

    name = os.path.basename(filename).lower()

    # remove extensão
    name = re.sub(r'\.[a-z0-9]{2,5}$', '', name)

    tokens = normalize_tokens(name)

    filtered = []

    for t in tokens:
        if t in NOISE_TOKENS:
            continue

        if t in KNOWN_VENDORS:
            continue

        if re.match(r'^\d+(\.\d+)*$', t):
            continue

        # aplica alias
        t = PRODUCT_ALIASES.get(t, t)

        filtered.append(t)

    if not filtered:
        result = None
    else:
        # Usa até 2 tokens para melhorar robustez sem quebrar compatibilidade
        result = ".".join(filtered[:2])

    _product_cache[filename] = result
    return result

def normalize_canonical_name(name):
    """
    Normaliza nome canônico:
    - remove {}
    - trim de bordas não alfanuméricas
    - mantém conteúdo interno intacto
    """
    if not name:
        return None

    name = name.replace("{}", "").strip()

    # trim apenas nas bordas (não destrói estrutura interna)
    name = re.sub(r'^[^a-zA-Z0-9]+', '', name)
    name = re.sub(r'[^a-zA-Z0-9]+$', '', name)

    return name or None

def normalize_tokens(s):
    """
    Descrição: Tokeniza string em partes normalizadas.
    Parâmetros:
    - s (str): String de entrada.
    Retorno:
    - list[str]: Lista de tokens.
    """
    return [t for t in re.split(r'[^a-z0-9]+', s.lower()) if t] 

def is_same_product(a, b):
    """
    Descrição: Verifica se dois nomes representam o mesmo produto.
    Parâmetros:
    - a (str): Nome A.
    - b (str): Nome B.
    Retorno:
    - bool: True se equivalentes.
    """    
    if not a or not b:
        return False

    # 🔒 Se ambos não possuem separador ".", tratar como canônico rígido
    if "." not in a and "." not in b:
        return a.lower() == b.lower()

    ta = set(a.split("."))
    tb = set(b.split("."))

    intersect = ta & tb

    return len(intersect) >= 1  