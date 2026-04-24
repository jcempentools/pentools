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

from sync_local.commons import *
from sync_local.core.syncdownload_parser import resolve_syncdownload_cached
from sync_local.utils.naming import normalize_product_name
from sync_local.utils.naming import is_same_product
from sync_local.utils.logging import show_message

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES

def destination_cleanup(root, dry_run=False):
    """
    Descrição: Remove itens no destino não presentes na origem.
    Parâmetros:
    - root (str): Diretório raiz.
    - dry_run (bool): Simulação sem remover.
    Retorno:
    - None
    """
    global _sync_global_map
    # --- CACHE LOCAL DE PROTEÇÃO POR DIRETÓRIO (.syncdownload) ---
    local_sync_files = []
    try:
        origin_dir_equiv = os.path.join(ORIGIN_PATH, os.path.relpath(root, destination_path))
        if os.path.exists(origin_dir_equiv):
            for f in os.listdir(origin_dir_equiv):
                if f.lower().endswith(".syncdownload"):
                    local_sync_files.append(os.path.join(origin_dir_equiv, f))
    except Exception:
        local_sync_files = []

    has_local_sync = len(local_sync_files) > 0

    for item in os.listdir(root):        
        dest_full_path = os.path.join(root, item)
        rel_path = os.path.relpath(dest_full_path, destination_path)
        origin_equivalent = os.path.join(ORIGIN_PATH, rel_path)        

        # --- IGNORA PASTAS RAIZ apps/ e Drivers/ NO DESTINO ---
        # Se estiver na raiz do destino e for uma dessas pastas, ignora completamente
        if root == destination_path and item in ("apps", "Drivers"):
            show_message(f"Remoção ignorada: {item}", "i")
            continue
        
        # protege arquivos auxiliares de sync vinculados a arquivo existente
        if dest_full_path.lower().endswith((".sha256", ".syncado")):
            origin_equivalent_sync = origin_equivalent + ".syncdownload"

            # 🔒 1. Se existir .syncdownload correspondente na origem → protege
            if os.path.exists(origin_equivalent_sync):
                try:
                    resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                    if resolved:
                        expected_name = resolved.get("filename")
                        base_dir = os.path.dirname(dest_full_path)
                        expected_full = os.path.join(base_dir, expected_name)

                        if os.path.exists(expected_full):
                            show_message(f"Remoção protegida (.syncdownload válido): {item}", "D")
                            continue
                except Exception:
                    pass

            # 🔒 2. Se o arquivo base existir localmente → SEMPRE protege
            base_file = re.sub(r'\.(sha256|syncado)$', '', dest_full_path, flags=re.IGNORECASE)

            if os.path.exists(base_file):
                show_message(f"Remoção protegida (arquivo base existente): {item}", "D")
                continue

            # 🔒 3. REMOÇÃO REAL DE METADATA ÓRFÃ (ANTES NÃO OCORRIA)
            show_message(f"Metadata órfã removida: {item}", "d")

            if not dry_run:
                try:
                    os.remove(dest_full_path)
                except Exception as e:
                    show_message(f"Falha ao remover metadata órfã: {e}", "e")

            continue        

        if re.search(IGNORED_PATHS, dest_full_path, re.IGNORECASE):
            show_message(f"Remoção ignorada [regex]: {dest_full_path}", "W")
            continue

        # --- TRATAMENTO PARA ARQUIVOS GERADOS POR .syncdownload ---
        origin_equivalent_sync = origin_equivalent + ".syncdownload"

        # --- PROTEÇÃO CONDICIONAL POR DIRETÓRIO ---
        # (já calculado no início da função)

        # =========================================================
        # 🔒 PROTEÇÃO CANÔNICA DE ARQUIVOS GERADOS POR .syncdownload
        # =========================================================

        try:
            origin_equivalent_sync = origin_equivalent + ".syncdownload"

            if os.path.exists(origin_equivalent_sync):
                resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                if resolved:
                    expected_name = resolved.get("filename")

                    if expected_name:
                        expected_full = os.path.join(root, expected_name)

                        # 🔒 proteção direta (nome resolvido)
                        if os.path.abspath(dest_full_path) == os.path.abspath(expected_full):
                            show_message(f"Protegido (.syncdownload resolvido): {item}", "D")
                            continue

                        # 🔒 proteção por presença do arquivo esperado
                        if os.path.exists(expected_full):
                            current_base = normalize_product_name(os.path.basename(dest_full_path))
                            expected_base = normalize_product_name(expected_name)

                            if is_same_product(current_base, expected_base):
                                show_message(f"Protegido (grupo do .syncdownload): {item}", "D")
                                continue

        except Exception:
            pass        

        if not os.path.exists(origin_equivalent):

            # =========================================================
            # 🔒 PROTEÇÃO GLOBAL: arquivo gerado por QUALQUER .syncdownload
            # =========================================================
            try:
                protected = False

                for root_dir, _, files in os.walk(ORIGIN_PATH):
                    for f in files:
                        if not f.lower().endswith(".syncdownload"):
                            continue

                        sync_file = os.path.join(root_dir, f)

                        try:
                            resolved = resolve_syncdownload_cached(sync_file)

                            if not resolved:
                                continue

                            expected_name = resolved.get("filename")

                            if not expected_name:
                                continue

                            expected_base = normalize_product_name(expected_name)
                            current_base = normalize_product_name(os.path.basename(dest_full_path))

                            if is_same_product(expected_base, current_base):
                                show_message(f"Protegido (global .syncdownload): {item}", "D")
                                protected = True
                                break

                        except Exception:
                            pass

                    if protected:
                        break

                if protected:
                    continue

            except Exception:
                pass

        # --- RECURSÃO CONTROLADA ---
        # Executa limpeza em subdiretórios existentes (após possíveis remoções)
        if os.path.isdir(dest_full_path):
            try:
                destination_cleanup(dest_full_path, dry_run)
            except Exception as e:
                show_message(f"Erro ao acessar subdiretório {dest_full_path}: {e}", "e")

