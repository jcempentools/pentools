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

from sync.commons import *
from sync.utils.naming import normalize_product_name
from sync.utils.naming import is_same_product
from sync.utils.logging import show_message

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES


def is_cached_file_valid(path, expected_hash):
    if not os.path.exists(path):
        return False

    ext = os.path.splitext(path)[1].lower()
    sha_file = path + ".sha256"
    sync_file = path + ".syncado"

    # =========================================================
    # 1. HASH EXTERNO (linha 2) → prioridade máxima
    # =========================================================
    if expected_hash:
        current_hash = hash_file(path, "Cache")
        return current_hash == expected_hash.lower()

    # =========================================================
    # 2. ARQUIVOS DE IMAGEM → USAR SHA256 SE EXISTIR
    # =========================================================
    if ext in (".iso", ".img") and os.path.exists(sha_file):
        try:
            with open(sha_file, "r", encoding="utf-8") as f:
                saved_hash = f.readline().split()[0]

            current_hash = hash_file(path, "Cache")
            return current_hash == saved_hash.lower()
        except:
            return False

    # =========================================================
    # 3. .SYNCADO → VALIDAÇÃO DE EXISTÊNCIA / COERÊNCIA
    # =========================================================
    if os.path.exists(sync_file):
        try:
            with open(sync_file, "r", encoding="utf-8") as f:
                stored_name = f.read().strip()

            current_name = os.path.basename(path)

            stored_base = normalize_product_name(stored_name)
            current_base = normalize_product_name(current_name)

            # 🔒 comparação por produto (não nome bruto)
            if is_same_product(stored_base, current_base):
                return True

            return False
        except:
            return False

    # =========================================================
    # 4. FALLBACK FINAL
    # =========================================================
    return os.path.getsize(path) > 0