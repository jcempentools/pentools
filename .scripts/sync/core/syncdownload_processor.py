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
import gzip
import shutil
import hashlib

from sync.commons import *

from sync.core.syncdownload_parser import resolve_download_context
from sync.core.cache_validation import is_cached_file_valid
from sync.core.download_manager import download_file_with_progress
from sync.core.metadata import generate_sync_metadata
from sync.core.metadata import manage_sync_metadata
from sync.core.metadata import execute_sync_script
from sync.core.file_operations import copy_file_with_progress, parse_syncdownload_scripts
from sync.core.file_operations import purge_similar_installers_safe

from sync.utils.naming import normalize_product_name
from sync.utils.naming import normalize_canonical_name
from sync.utils.naming import is_same_product
from sync.utils.dsl import resolve_if_dsl
from sync.utils.logging import show_message

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES
def process_single_syncdownload(path, dry_run):
    """
    Descrição: Processa um único arquivo .syncdownload.
    Parâmetros:
    - path (str): Caminho do arquivo.
    - dry_run (bool): Simulação.
    Retorno:
    - None
    """    
    # =========================================================
    # 🔒 CARREGA SCRIPTS EMBUTIDOS (ANTES DE TUDO)
    # =========================================================
    script_blocks = parse_syncdownload_scripts(path)

    def run_phase(phase, downloaded_file=None):
        for b in script_blocks:
            if b["phase"] == phase:
                execute_sync_script(b, path, downloaded_file)

    # 🔒 fase preresolve
    run_phase("preresolve")

    resolved = resolve_download_context(path)
    if not resolved:
        return

    final_url = resolved["final_url"]
    expected_hash = resolved["expected_hash"]
    remote_hash_url = resolved.get("remote_hash_url")
    filename = resolved["filename"]

    # 🔒 fase start (default)
    run_phase("start")

    dest_dir = os.path.join(
        destination_path,
        os.path.relpath(os.path.dirname(path), ORIGIN_PATH)
    )

    final_dest_path = os.path.join(dest_dir, filename)

    # === CACHE NA ORIGEM ===
    origin_cached_path = os.path.join(os.path.dirname(path), filename)

    valid_metadata = False    

    if os.path.exists(origin_cached_path):

        # 🔒 valida presença de metadata CORRETA por tipo
        ext = os.path.splitext(origin_cached_path)[1].lower()

        has_sha = os.path.exists(origin_cached_path + ".sha256")
        has_syncado = os.path.exists(origin_cached_path + ".syncado")

        # =========================================================
        # 🔒 NOVA REGRA: HASH DIRETO (linha 2 OU linha 4) SUBSTITUI METADATA
        # =========================================================
        hash_override_valid = False

        try:
            if expected_hash:
                current_hash = hash_file(origin_cached_path, "Cache")
                if current_hash and current_hash == expected_hash.lower():
                    hash_override_valid = True

            elif remote_hash_url:
                remote_hash = fetch_remote_hash(remote_hash_url)
                current_hash = hash_file(origin_cached_path, "Cache")

                if current_hash and current_hash == remote_hash:
                    hash_override_valid = True

        except Exception:
            hash_override_valid = False

        if hash_override_valid:
            show_message(f"Cache válido via hash direto (sem metadata): {filename}", "k")
            valid_metadata = True

        else:
            if ext in (".iso", ".img"):
                if has_sha:
                    valid_metadata = True
                else:
                    show_message(f"Cache sem .sha256 → inválido (tratado como inexistente): {filename}", "w")
            else:
                if has_syncado:
                    valid_metadata = True
                else:
                    show_message(f"Cache sem .syncado → inválido (tratado como inexistente): {filename}", "w")

        # =========================================================
        # 🔒 FORÇA REPROCESSAMENTO COMO SE NÃO EXISTISSE
        # =========================================================
        if not valid_metadata:
            try:
                os.remove(origin_cached_path)
                show_message(f"Cache inválido removido: {filename}", "w")
            except Exception:
                pass

            # 🔒 remove qualquer metadata residual
            for ext_meta in (".sha256", ".syncado"):
                try:
                    meta_path = origin_cached_path + ext_meta
                    if os.path.exists(meta_path):
                        os.remove(meta_path)
                except Exception:
                    pass

            # =========================================================
            # 🔒 FORÇA DOWNLOAD SEM USAR CACHE (SEM QUEBRAR FLUXO)
            # =========================================================
            show_message(f"Forçando reprocessamento imediato: {filename}", "i")

            need_download = True      

            # 🔒 segue fluxo normal (download obrigatório)
        else:
            if is_cached_file_valid(origin_cached_path, expected_hash) or hash_override_valid:
                show_message(f"Cache válido na origem: {filename}", "k")

                # =========================================================
                # 🔒 STATUS DO DESTINO (COM SUPORTE A HASH DIRETO)
                # =========================================================
                dest_exists = os.path.exists(final_dest_path)

                dest_valid = False

                if dest_exists:
                    try:
                        if expected_hash:
                            dest_valid = hash_file(final_dest_path, "Destino") == expected_hash.lower()
                        elif remote_hash_url:
                            remote_hash = fetch_remote_hash(remote_hash_url)
                            dest_valid = hash_file(final_dest_path, "Destino") == remote_hash
                        else:
                            dest_valid = is_cached_file_valid(final_dest_path, expected_hash)
                    except Exception:
                        dest_valid = False

                # =========================================================
                # 🔒 REGRA CRÍTICA: BASTA UM DOS DOIS ESTAR VÁLIDO
                # =========================================================
                if dest_valid:
                    show_message(f"Cache válido no destino: {filename}", "k")
                    show_message(f"Sincronizado (sem ação): {filename}", "d")
                    show_message(f"Sync completo: {filename}", "s")
                    return

                if dest_exists and not dest_valid:
                    show_message(f"Destino inválido → será sobrescrito via espelhamento: {filename}", "w")
                elif not dest_exists:
                    show_message(f"Destino inexistente → cópia necessária: {filename}", "i")

                # =========================================================
                # 🔒 ESPALHAMENTO (SEM DOWNLOAD)
                # =========================================================
                show_message(f"Download não necessário (hash já válido): {filename}", "d")

                if not dry_run:
                    copy_file_with_progress(origin_cached_path, final_dest_path)

                    # 🔒 gera metadata se inexistente
                    generate_sync_metadata(origin_cached_path, resolved["url"])

                    for ext_meta in (".sha256", ".syncado"):
                        src_meta = origin_cached_path + ext_meta
                        dst_meta = final_dest_path + ext_meta

                        if os.path.exists(src_meta):
                            try:
                                copy_file_with_progress(src_meta, dst_meta)
                            except Exception:
                                pass

                    show_message(f"Arquivo sincronizado via espelhamento: {filename}", "s")
                    show_message(f"Sync completo: {filename}", "s")

                    if os.path.exists(final_dest_path):
                        purge_similar_installers_safe(
                            dest_dir,
                            filename,
                            canonical_name=resolved.get("custom_filename")
                        )
                else:
                    show_message(f"[DRY-RUN] Copiaria do cache: {filename}", "d")

                return
            else:
                show_message(f"Cache corrompido na origem → removendo: {filename}", "w")

                try:
                    os.remove(origin_cached_path)
                    show_message(f"Cache removido: {filename}", "w")
                except Exception:
                    pass

                # 🔒 remove metadata associada
                try:
                    if os.path.exists(origin_cached_path + ".sha256"):
                        os.remove(origin_cached_path + ".sha256")
                        show_message(f"Metadado .sha256 do cache removido: {filename}", "w")
                except Exception:
                    pass

                try:
                    if os.path.exists(origin_cached_path + ".syncado"):
                        os.remove(origin_cached_path + ".syncado")
                        show_message(f"Metadado .syncado do cache removido: {filename}", "w")

                except Exception:
                    pass

    # === DECISÃO ===
    if not valid_metadata:
        need_download = True
    else:
        need_download = manage_sync_metadata(
            final_dest_path=final_dest_path,
            url=final_url or resolved["url"],
            expected_hash=expected_hash
        )

    if not need_download:
        return

    # === DRY-RUN: NÃO EXECUTA DOWNLOAD ===
    if dry_run:
        show_message(f"[DRY-RUN] Baixaria: {filename} ({final_url})", "d")
        return

    # =========================================================
    # 🔒 REUSO DE DOWNLOAD EM MEMÓRIA (evita redownload)
    # =========================================================
    if final_url in download_registry:
        cached_path = download_registry[final_url]

        if os.path.exists(cached_path):
            show_message(f"Reuso de download (duplicado): {filename}", "w")

            try:
                os.makedirs(dest_dir, exist_ok=True)

                if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
                    copy_file_with_progress(cached_path, final_dest_path)

                if os.path.exists(final_dest_path):
                    purge_similar_installers_safe(
                        dest_dir,
                        filename,
                        canonical_name=resolved.get("custom_filename")
                    )

                return

            except Exception as e:
                show_message(f"Falha no reuso de download: {e}", "e")

    # === DOWNLOAD (SEMPRE PRIMEIRO PARA CACHE NA ORIGEM) ===
    try:
        os.makedirs(os.path.dirname(origin_cached_path), exist_ok=True)
        os.makedirs(dest_dir, exist_ok=True)

        # 🔒 download vai SEMPRE para o cache (origem)
        download_file_with_progress(final_url, origin_cached_path)

        show_message(f"Download concluído (cache): {filename}", "+")

        # 🔒 registra download para reutilização futura (aponta para cache)
        download_registry[final_url] = origin_cached_path

        # 🔒 copia do cache → destino (NUNCA download direto no destino)
        if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
            copy_file_with_progress(origin_cached_path, final_dest_path)

    except Exception as e:
        show_message(f"Erro no download: {filename} -> {e}", "e")

        if path not in failed_files:
            failed_files.append(path)

        return

    # =========================================================
    # 🔒 PIPELINE .gz (validação + possível descompressão)
    # =========================================================
    is_gz = final_dest_path.lower().endswith(".gz")

    validated = False

    # 🔒 1. tenta validar o .gz diretamente
    if is_gz:
        if is_cached_file_valid(final_dest_path, expected_hash):
             # 🔒 .gz é o artefato final válido → NÃO remover
            validated = True
        else:
            show_message(f".gz não confere hash → tentando conteúdo: {filename}", "w")

            try:
                decompressed_path = final_dest_path[:-3]  # remove .gz

                with gzip.open(final_dest_path, 'rb') as f_in, open(decompressed_path, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)

                # 🔒 valida conteúdo descompactado
                if is_cached_file_valid(decompressed_path, expected_hash):
                    show_message(f"Hash válido após descompressão: {filename}", "k")
                    
                    try:
                        # 🔒 remove .gz somente após validação do conteúdo
                        os.remove(final_dest_path)
                    except:
                        pass

                    final_dest_path = decompressed_path
                    filename = os.path.basename(decompressed_path)

                    validated = True

                    # =========================================================
                    # 🔒 METADATA ESPECIAL (.gz → conteúdo)
                    # =========================================================
                    try:                        
                        def _hash_file(p):
                            h = hashlib.sha256()
                            with open(p, "rb") as f:
                                for chunk in iter(lambda: f.read(65536), b""):
                                    h.update(chunk)
                            return h.hexdigest()

                        # 🔒 se houver múltiplos arquivos, escolher o maior
                        base_dir = os.path.dirname(final_dest_path)

                        candidates = []
                        for f in os.listdir(base_dir):
                            full = os.path.join(base_dir, f)

                            if not os.path.isfile(full):
                                continue

                            if f.lower().endswith((".sha256", ".syncado", ".gz")):
                                continue

                            candidates.append(full)

                        if candidates:
                            target_file = max(candidates, key=lambda p: os.path.getsize(p))
                        else:
                            target_file = final_dest_path

                        final_dest_path = target_file
                        filename = os.path.basename(target_file)

                        # 🔒 calcula hashes
                        extracted_hash = _hash_file(target_file)

                        gz_hash = None
                        if expected_hash:
                            gz_hash = expected_hash.lower()

                        sha_path = target_file + ".sha256"

                        with open(sha_path, "w", encoding="utf-8") as f:
                            # linha 1 → conteúdo real
                            f.write(f"{extracted_hash}\n")

                            # linha 2 → vínculo com .gz (hash original + URL)
                            if gz_hash:
                                f.write(f"{gz_hash}  {resolved['url']}\n")

                    except Exception as e:
                        show_message(f"Falha ao gerar .sha256 especial: {e}", "e")                    
                else:
                    show_message(f"Conteúdo descompactado inválido: {filename}", "w")

                    try:
                        os.remove(decompressed_path)
                    except:
                        pass

            except Exception as e:
                show_message(f"Falha ao descompactar .gz: {e}", "e")

    # 🔒 fallback padrão (não gz ou gz válido direto)
    if not validated:
        if not is_cached_file_valid(final_dest_path, expected_hash):
            show_message(f"Download inválido (hash/tamanho): {filename}", "w")
            try:
                os.remove(final_dest_path)
            except:
                pass
            return
    
    # =========================================================
    # 🔒 PADRONIZAÇÃO DE BASENAME (linha 3)
    # =========================================================
    canonical = resolved.get("custom_filename")

    # 🔒 BLOQUEIO DE PLACEHOLDER NÃO RESOLVIDO
    if isinstance(canonical, str) and ("{}" in canonical or "{" in canonical):
        show_message(f"Canonical inválido (placeholder não resolvido): {canonical}", "w")
        canonical = None

    if canonical:
        base = os.path.splitext(canonical)[0]
        ext = os.path.splitext(final_dest_path)[1]

        new_name = base + ext
        new_path = os.path.join(dest_dir, new_name)

        if new_path != final_dest_path:
            try:
                os.rename(final_dest_path, new_path)
                final_dest_path = new_path
                filename = new_name
            except Exception as e:
                show_message(f"Falha ao padronizar nome: {e}", "e")   

    # =========================================================
    # 🔒 MULTI-ARQUIVOS (mesmo basename)
    # =========================================================
    if canonical:
        base = os.path.splitext(canonical)[0]

        for f in os.listdir(dest_dir):
            full = os.path.join(dest_dir, f)

            if not os.path.isfile(full):
                continue

            if f == filename:
                continue

            ext = os.path.splitext(f)[1]

            candidate = base + ext
            candidate_path = os.path.join(dest_dir, candidate)

            try:
                if normalize_product_name(f) == normalize_product_name(filename):
                    if full != candidate_path:
                        os.rename(full, candidate_path)
            except:
                pass                 

    # =========================================================
    # 🔒 VALIDAÇÃO OBRIGATÓRIA — HASH REMOTO (linha 4)
    # =========================================================
    if remote_hash_url:
        try:
            # 🔒 fase preremotehash
            run_phase("preremotehash")
        
            resolved_hash_input = resolve_if_dsl(
                remote_hash_url,
                context="remote_hash_url"
            )

            # 🔒 se DSL retornar hash direto → usa direto
            if isinstance(resolved_hash_input, str) and re.fullmatch(r'[a-fA-F0-9]{64}', resolved_hash_input.strip()):
                remote_hash = resolved_hash_input.strip().lower()
            else:
                remote_hash = fetch_remote_hash(resolved_hash_input)

            # 🔒 fase posremotehash
            run_phase("posremotehash")

            local_hash = hash_file(final_dest_path, "Destino")

            if local_hash != remote_hash:
                show_message(f"Hash remoto divergente → invalidando: {filename}", "w")

                # 🔒 remove destino
                try:
                    os.remove(final_dest_path)
                except:
                    pass

                # 🔒 remove cache origem
                try:
                    if os.path.exists(origin_cached_path):
                        os.remove(origin_cached_path)
                except:
                    pass

                # 🔒 remove metadata
                for ext_meta in (".sha256", ".syncado"):
                    try:
                        if os.path.exists(origin_cached_path + ext_meta):
                            os.remove(origin_cached_path + ext_meta)
                    except:
                        pass

                # 🔒 força retry
                if path not in failed_files:
                    failed_files.append(path)

                return

            show_message(f"Hash remoto válido: {filename}", "k")            

        except Exception as e:
            show_message(f"Falha na validação de hash remoto: {e}", "e")

            # 🔒 abort conforme contrato
            if path not in failed_files:
                failed_files.append(path)

            return    

    # === PURGE CONTROLADO ===
    purge_similar_installers_safe(
        dest_dir,
        filename,
        canonical_name=resolved.get("custom_filename")
    )

    # =========================================================
    # 🔒 METADATA PRIMEIRO NO CACHE (ORIGEM)
    # =========================================================
    generate_sync_metadata(
        final_dest_path=origin_cached_path,
        url=resolved["url"]
    )

    # =========================================================
    # 🔒 COPIA PARA DESTINO (ARQUIVO + METADATA)
    # =========================================================
    # === CACHE NA ORIGEM ===
    try:
        # arquivo
        if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
            copy_file_with_progress(origin_cached_path, final_dest_path)

        # metadata associada (se existir)
        for ext_meta in (".sha256", ".syncado"):
            src_meta = origin_cached_path + ext_meta
            dst_meta = final_dest_path + ext_meta

            if os.path.exists(src_meta):
                try:
                    copy_file_with_progress(src_meta, dst_meta)
                except Exception:
                    pass

        # 🔒 fase end (arquivo já disponível)
        run_phase("end", final_dest_path)

        show_message(f"Sync completo: {filename}", "s")

    except Exception as e:
        show_message(f"Inconsistência: falha ao propagar cache→destino: {e}", "e")

def process_syncdownloads(root, dry_run):
    """
    Descrição: Processa todos .syncdownload recursivamente.
    Parâmetros:
    - root (str): Diretório base.
    - dry_run (bool): Simulação.
    Retorno:
    - None
    """    
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.lower().endswith(".syncdownload"):
                continue

            sync_path = os.path.join(dirpath, f)

            try:
                process_single_syncdownload(sync_path, dry_run)
            except Exception as e:
                show_message(f"Erro no .syncdownload {sync_path}: {e}", "e")

def process_single_syncdownload(path, dry_run):
    """
    Descrição: Processa um único arquivo .syncdownload.
    Parâmetros:
    - path (str): Caminho do arquivo.
    - dry_run (bool): Simulação.
    Retorno:
    - None
    """    
    # =========================================================
    # 🔒 CARREGA SCRIPTS EMBUTIDOS (ANTES DE TUDO)
    # =========================================================
    script_blocks = parse_syncdownload_scripts(path)

    def run_phase(phase, downloaded_file=None):
        for b in script_blocks:
            if b["phase"] == phase:
                execute_sync_script(b, path, downloaded_file)

    # 🔒 fase preresolve
    run_phase("preresolve")

    resolved = resolve_download_context(path)
    if not resolved:
        return

    final_url = resolved["final_url"]
    expected_hash = resolved["expected_hash"]
    remote_hash_url = resolved.get("remote_hash_url")
    filename = resolved["filename"]

    # 🔒 fase start (default)
    run_phase("start")

    dest_dir = os.path.join(
        destination_path,
        os.path.relpath(os.path.dirname(path), ORIGIN_PATH)
    )

    final_dest_path = os.path.join(dest_dir, filename)

    # === CACHE NA ORIGEM ===
    origin_cached_path = os.path.join(os.path.dirname(path), filename)

    valid_metadata = False    

    if os.path.exists(origin_cached_path):

        # 🔒 valida presença de metadata CORRETA por tipo
        ext = os.path.splitext(origin_cached_path)[1].lower()

        has_sha = os.path.exists(origin_cached_path + ".sha256")
        has_syncado = os.path.exists(origin_cached_path + ".syncado")

        # =========================================================
        # 🔒 NOVA REGRA: HASH DIRETO (linha 2 OU linha 4) SUBSTITUI METADATA
        # =========================================================
        hash_override_valid = False

        try:
            if expected_hash:
                current_hash = hash_file(origin_cached_path, "Cache")
                if current_hash and current_hash == expected_hash.lower():
                    hash_override_valid = True

            elif remote_hash_url:
                remote_hash = fetch_remote_hash(remote_hash_url)
                current_hash = hash_file(origin_cached_path, "Cache")

                if current_hash and current_hash == remote_hash:
                    hash_override_valid = True

        except Exception:
            hash_override_valid = False

        if hash_override_valid:
            show_message(f"Cache válido via hash direto (sem metadata): {filename}", "k")
            valid_metadata = True

        else:
            if ext in (".iso", ".img"):
                if has_sha:
                    valid_metadata = True
                else:
                    show_message(f"Cache sem .sha256 → inválido (tratado como inexistente): {filename}", "w")
            else:
                if has_syncado:
                    valid_metadata = True
                else:
                    show_message(f"Cache sem .syncado → inválido (tratado como inexistente): {filename}", "w")

        # =========================================================
        # 🔒 FORÇA REPROCESSAMENTO COMO SE NÃO EXISTISSE
        # =========================================================
        if not valid_metadata:
            try:
                os.remove(origin_cached_path)
                show_message(f"Cache inválido removido: {filename}", "w")
            except Exception:
                pass

            # 🔒 remove qualquer metadata residual
            for ext_meta in (".sha256", ".syncado"):
                try:
                    meta_path = origin_cached_path + ext_meta
                    if os.path.exists(meta_path):
                        os.remove(meta_path)
                except Exception:
                    pass

            # =========================================================
            # 🔒 FORÇA DOWNLOAD SEM USAR CACHE (SEM QUEBRAR FLUXO)
            # =========================================================
            show_message(f"Forçando reprocessamento imediato: {filename}", "i")

            need_download = True      

            # 🔒 segue fluxo normal (download obrigatório)
        else:
            if is_cached_file_valid(origin_cached_path, expected_hash) or hash_override_valid:
                show_message(f"Cache válido na origem: {filename}", "k")

                # =========================================================
                # 🔒 STATUS DO DESTINO (COM SUPORTE A HASH DIRETO)
                # =========================================================
                dest_exists = os.path.exists(final_dest_path)

                dest_valid = False

                if dest_exists:
                    try:
                        if expected_hash:
                            dest_valid = hash_file(final_dest_path, "Destino") == expected_hash.lower()
                        elif remote_hash_url:
                            remote_hash = fetch_remote_hash(remote_hash_url)
                            dest_valid = hash_file(final_dest_path, "Destino") == remote_hash
                        else:
                            dest_valid = is_cached_file_valid(final_dest_path, expected_hash)
                    except Exception:
                        dest_valid = False

                # =========================================================
                # 🔒 REGRA CRÍTICA: BASTA UM DOS DOIS ESTAR VÁLIDO
                # =========================================================
                if dest_valid:
                    show_message(f"Cache válido no destino: {filename}", "k")
                    show_message(f"Sincronizado (sem ação): {filename}", "d")
                    show_message(f"Sync completo: {filename}", "s")
                    return

                if dest_exists and not dest_valid:
                    show_message(f"Destino inválido → será sobrescrito via espelhamento: {filename}", "w")
                elif not dest_exists:
                    show_message(f"Destino inexistente → cópia necessária: {filename}", "i")

                # =========================================================
                # 🔒 ESPALHAMENTO (SEM DOWNLOAD)
                # =========================================================
                show_message(f"Download não necessário (hash já válido): {filename}", "d")

                if not dry_run:
                    copy_file_with_progress(origin_cached_path, final_dest_path)

                    # 🔒 gera metadata se inexistente
                    generate_sync_metadata(origin_cached_path, resolved["url"])

                    for ext_meta in (".sha256", ".syncado"):
                        src_meta = origin_cached_path + ext_meta
                        dst_meta = final_dest_path + ext_meta

                        if os.path.exists(src_meta):
                            try:
                                copy_file_with_progress(src_meta, dst_meta)
                            except Exception:
                                pass

                    show_message(f"Arquivo sincronizado via espelhamento: {filename}", "s")
                    show_message(f"Sync completo: {filename}", "s")

                    if os.path.exists(final_dest_path):
                        purge_similar_installers_safe(
                            dest_dir,
                            filename,
                            canonical_name=resolved.get("custom_filename")
                        )
                else:
                    show_message(f"[DRY-RUN] Copiaria do cache: {filename}", "d")

                return
            else:
                show_message(f"Cache corrompido na origem → removendo: {filename}", "w")

                try:
                    os.remove(origin_cached_path)
                    show_message(f"Cache removido: {filename}", "w")
                except Exception:
                    pass

                # 🔒 remove metadata associada
                try:
                    if os.path.exists(origin_cached_path + ".sha256"):
                        os.remove(origin_cached_path + ".sha256")
                        show_message(f"Metadado .sha256 do cache removido: {filename}", "w")
                except Exception:
                    pass

                try:
                    if os.path.exists(origin_cached_path + ".syncado"):
                        os.remove(origin_cached_path + ".syncado")
                        show_message(f"Metadado .syncado do cache removido: {filename}", "w")

                except Exception:
                    pass

    # === DECISÃO ===
    if not valid_metadata:
        need_download = True
    else:
        need_download = manage_sync_metadata(
            final_dest_path=final_dest_path,
            url=final_url or resolved["url"],
            expected_hash=expected_hash
        )

    if not need_download:
        return

    # === DRY-RUN: NÃO EXECUTA DOWNLOAD ===
    if dry_run:
        show_message(f"[DRY-RUN] Baixaria: {filename} ({final_url})", "d")
        return

    # =========================================================
    # 🔒 REUSO DE DOWNLOAD EM MEMÓRIA (evita redownload)
    # =========================================================
    if final_url in download_registry:
        cached_path = download_registry[final_url]

        if os.path.exists(cached_path):
            show_message(f"Reuso de download (duplicado): {filename}", "w")

            try:
                os.makedirs(dest_dir, exist_ok=True)

                if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
                    copy_file_with_progress(cached_path, final_dest_path)

                if os.path.exists(final_dest_path):
                    purge_similar_installers_safe(
                        dest_dir,
                        filename,
                        canonical_name=resolved.get("custom_filename")
                    )

                return

            except Exception as e:
                show_message(f"Falha no reuso de download: {e}", "e")

    # === DOWNLOAD (SEMPRE PRIMEIRO PARA CACHE NA ORIGEM) ===
    try:
        os.makedirs(os.path.dirname(origin_cached_path), exist_ok=True)
        os.makedirs(dest_dir, exist_ok=True)

        # 🔒 download vai SEMPRE para o cache (origem)
        download_file_with_progress(final_url, origin_cached_path)

        show_message(f"Download concluído (cache): {filename}", "+")

        # 🔒 registra download para reutilização futura (aponta para cache)
        download_registry[final_url] = origin_cached_path

        # 🔒 copia do cache → destino (NUNCA download direto no destino)
        if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
            copy_file_with_progress(origin_cached_path, final_dest_path)

    except Exception as e:
        show_message(f"Erro no download: {filename} -> {e}", "e")

        if path not in failed_files:
            failed_files.append(path)

        return

    # =========================================================
    # 🔒 PIPELINE .gz (validação + possível descompressão)
    # =========================================================
    is_gz = final_dest_path.lower().endswith(".gz")

    validated = False

    # 🔒 1. tenta validar o .gz diretamente
    if is_gz:
        if is_cached_file_valid(final_dest_path, expected_hash):
             # 🔒 .gz é o artefato final válido → NÃO remover
            validated = True
        else:
            show_message(f".gz não confere hash → tentando conteúdo: {filename}", "w")

            try:
                decompressed_path = final_dest_path[:-3]  # remove .gz

                with gzip.open(final_dest_path, 'rb') as f_in, open(decompressed_path, 'wb') as f_out:
                    shutil.copyfileobj(f_in, f_out)

                # 🔒 valida conteúdo descompactado
                if is_cached_file_valid(decompressed_path, expected_hash):
                    show_message(f"Hash válido após descompressão: {filename}", "k")
                    
                    try:
                        # 🔒 remove .gz somente após validação do conteúdo
                        os.remove(final_dest_path)
                    except:
                        pass

                    final_dest_path = decompressed_path
                    filename = os.path.basename(decompressed_path)

                    validated = True

                    # =========================================================
                    # 🔒 METADATA ESPECIAL (.gz → conteúdo)
                    # =========================================================
                    try:                        
                        def _hash_file(p):
                            h = hashlib.sha256()
                            with open(p, "rb") as f:
                                for chunk in iter(lambda: f.read(65536), b""):
                                    h.update(chunk)
                            return h.hexdigest()

                        # 🔒 se houver múltiplos arquivos, escolher o maior
                        base_dir = os.path.dirname(final_dest_path)

                        candidates = []
                        for f in os.listdir(base_dir):
                            full = os.path.join(base_dir, f)

                            if not os.path.isfile(full):
                                continue

                            if f.lower().endswith((".sha256", ".syncado", ".gz")):
                                continue

                            candidates.append(full)

                        if candidates:
                            target_file = max(candidates, key=lambda p: os.path.getsize(p))
                        else:
                            target_file = final_dest_path

                        final_dest_path = target_file
                        filename = os.path.basename(target_file)

                        # 🔒 calcula hashes
                        extracted_hash = _hash_file(target_file)

                        gz_hash = None
                        if expected_hash:
                            gz_hash = expected_hash.lower()

                        sha_path = target_file + ".sha256"

                        with open(sha_path, "w", encoding="utf-8") as f:
                            # linha 1 → conteúdo real
                            f.write(f"{extracted_hash}\n")

                            # linha 2 → vínculo com .gz (hash original + URL)
                            if gz_hash:
                                f.write(f"{gz_hash}  {resolved['url']}\n")

                    except Exception as e:
                        show_message(f"Falha ao gerar .sha256 especial: {e}", "e")                    
                else:
                    show_message(f"Conteúdo descompactado inválido: {filename}", "w")

                    try:
                        os.remove(decompressed_path)
                    except:
                        pass

            except Exception as e:
                show_message(f"Falha ao descompactar .gz: {e}", "e")

    # 🔒 fallback padrão (não gz ou gz válido direto)
    if not validated:
        if not is_cached_file_valid(final_dest_path, expected_hash):
            show_message(f"Download inválido (hash/tamanho): {filename}", "w")
            try:
                os.remove(final_dest_path)
            except:
                pass
            return
    
    # =========================================================
    # 🔒 PADRONIZAÇÃO DE BASENAME (linha 3)
    # =========================================================
    canonical = resolved.get("custom_filename")

    # 🔒 BLOQUEIO DE PLACEHOLDER NÃO RESOLVIDO
    if isinstance(canonical, str) and ("{}" in canonical or "{" in canonical):
        show_message(f"Canonical inválido (placeholder não resolvido): {canonical}", "w")
        canonical = None

    if canonical:
        base = os.path.splitext(canonical)[0]
        ext = os.path.splitext(final_dest_path)[1]

        new_name = base + ext
        new_path = os.path.join(dest_dir, new_name)

        if new_path != final_dest_path:
            try:
                os.rename(final_dest_path, new_path)
                final_dest_path = new_path
                filename = new_name
            except Exception as e:
                show_message(f"Falha ao padronizar nome: {e}", "e")   

    # =========================================================
    # 🔒 MULTI-ARQUIVOS (mesmo basename)
    # =========================================================
    if canonical:
        base = os.path.splitext(canonical)[0]

        for f in os.listdir(dest_dir):
            full = os.path.join(dest_dir, f)

            if not os.path.isfile(full):
                continue

            if f == filename:
                continue

            ext = os.path.splitext(f)[1]

            candidate = base + ext
            candidate_path = os.path.join(dest_dir, candidate)

            try:
                if normalize_product_name(f) == normalize_product_name(filename):
                    if full != candidate_path:
                        os.rename(full, candidate_path)
            except:
                pass                 

    # =========================================================
    # 🔒 VALIDAÇÃO OBRIGATÓRIA — HASH REMOTO (linha 4)
    # =========================================================
    if remote_hash_url:
        try:
            # 🔒 fase preremotehash
            run_phase("preremotehash")
        
            resolved_hash_input = resolve_if_dsl(
                remote_hash_url,
                context="remote_hash_url"
            )

            # 🔒 se DSL retornar hash direto → usa direto
            if isinstance(resolved_hash_input, str) and re.fullmatch(r'[a-fA-F0-9]{64}', resolved_hash_input.strip()):
                remote_hash = resolved_hash_input.strip().lower()
            else:
                remote_hash = fetch_remote_hash(resolved_hash_input)

            # 🔒 fase posremotehash
            run_phase("posremotehash")

            local_hash = hash_file(final_dest_path, "Destino")

            if local_hash != remote_hash:
                show_message(f"Hash remoto divergente → invalidando: {filename}", "w")

                # 🔒 remove destino
                try:
                    os.remove(final_dest_path)
                except:
                    pass

                # 🔒 remove cache origem
                try:
                    if os.path.exists(origin_cached_path):
                        os.remove(origin_cached_path)
                except:
                    pass

                # 🔒 remove metadata
                for ext_meta in (".sha256", ".syncado"):
                    try:
                        if os.path.exists(origin_cached_path + ext_meta):
                            os.remove(origin_cached_path + ext_meta)
                    except:
                        pass

                # 🔒 força retry
                if path not in failed_files:
                    failed_files.append(path)

                return

            show_message(f"Hash remoto válido: {filename}", "k")            

        except Exception as e:
            show_message(f"Falha na validação de hash remoto: {e}", "e")

            # 🔒 abort conforme contrato
            if path not in failed_files:
                failed_files.append(path)

            return    

    # === PURGE CONTROLADO ===
    purge_similar_installers_safe(
        dest_dir,
        filename,
        canonical_name=resolved.get("custom_filename")
    )

    # =========================================================
    # 🔒 METADATA PRIMEIRO NO CACHE (ORIGEM)
    # =========================================================
    generate_sync_metadata(
        final_dest_path=origin_cached_path,
        url=resolved["url"]
    )

    # =========================================================
    # 🔒 COPIA PARA DESTINO (ARQUIVO + METADATA)
    # =========================================================
    # === CACHE NA ORIGEM ===
    try:
        # arquivo
        if not os.path.exists(final_dest_path) or not is_cached_file_valid(final_dest_path, expected_hash):
            copy_file_with_progress(origin_cached_path, final_dest_path)

        # metadata associada (se existir)
        for ext_meta in (".sha256", ".syncado"):
            src_meta = origin_cached_path + ext_meta
            dst_meta = final_dest_path + ext_meta

            if os.path.exists(src_meta):
                try:
                    copy_file_with_progress(src_meta, dst_meta)
                except Exception:
                    pass

        # 🔒 fase end (arquivo já disponível)
        run_phase("end", final_dest_path)

        show_message(f"Sync completo: {filename}", "s")

    except Exception as e:
        show_message(f"Inconsistência: falha ao propagar cache→destino: {e}", "e")
