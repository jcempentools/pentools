"""
BIBLIOTECA download.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

CONTEXTO GLOBAL DO PROJETO
==========================

  Estrutura geral dos componentes da bilbioteca:
    - common.py: Funções e variáveis globais compartilhadas por múltiplos scripts.
    - copy.py: Funções relacionadas a operações de cópia.
    - download.py: Funções relacionadas a downloads.
    - parserSyncDownload.py: Processamento técnico dos arquivos de extensão ".syncdownload".
    - parserDSL.py: Lógica e processamento de parser DSL.
    - loggerAndProgress.py: Gestão de logs e barras de progresso.
    - clear.py: Rotinas de limpeza.
    - hash.py: Lógica e processamento de hashs
    - main.py: Script orquestrador que gerencia o fluxo entre os módulos acima.

  Abstrações de Origens:  
    Interface lógica equivalente p/ todos providers (GitHub, GitLab, SF, etc.).
    Extensível. Mesma lógica de decisão, validação, metadata. Preferir APIs
    oficiais. Evitar parsing HTML/XML heurístico.

  Diretrizes Técnicas:  
    - HEAD (metadata) e GET (download) separados
    - Hash rápido (xxhash) + SHA256 (integridade)
    - Cache: memória + persistente na origem
    - Metadata não bloqueia atualização de versão
    - Timeout de rede obrigatório por inatividade; logging rotativo

  GUI/UX:  
    Preservar progressbar inline (rich.progress). Atualização em linha sem
    flooding. Feedback visual p/ hash, download, retry, cópia.

  Estilo de Implementação:  
    Funções pequenas, especialistas, reutilizáveis. NÃO duplicar lógica.
    Centralização obrigatória de: normalização, decisão de versão, nome final,
    validação, download. Nomeação consistente. Evitar side-effects e hardcode.
    Baixo acoplamento.

  Restrições/vedações:
    - Não duplicar lógica
    - Não usar parsing HTML se houver API
    - Não remover arquivos sem validação
    - Não fazer purge agressivo só por nome
    - Não quebrar coerência origem↔destino
    - Não alterar UX da progressbar sem decisão explícita
    - Não quebrar compatibilidade de metadata
    - Linha4 de .syncdownload inválida ou hash não extraível → abortar
    - Divergência de hash remoto → retry obrigatório
    - Execução de script não pode interferir na integridade do sync
    - Sempre importar e utilizar as implementações das bibliotecas participantes
      do projeto, sem  se intrometer em atribuições de outros scripts da
      do projeto incuindo, imlementar o que é atribuição de outros scripts

DEFINIÇÕES DESTA BIBLIOTECA
===========================

OBJETIVO
========
Gerenciar operações de download, resolução de URL final e obtenção de hash
remoto, garantindo integridade e controle de rede.

ESCOPO
======
- Download com progressbar
- Timeout por inatividade
- Resolução de URL final (redirects, providers)
- Obtenção de hash remoto (linha 4)

PRINCÍPIOS
==========
- Download SEMPRE para cache na origem
- Nunca escrever diretamente no destino
- Separação clara entre HEAD (metadata) e GET (conteúdo)
- Reuso de downloads via cache

REGRAS CRÍTICAS
===============
- Timeout obrigatório por inatividade
- Falha de download → elegível para retry
- Não validar versão (apenas transporte)
- Não decidir sobre integridade final

HASH REMOTO
===========
- Extração resiliente (ignora filename)
- Suporte a formatos:
  - bruto
  - .sha256 / .md5
  - endpoints DSL

DEPENDÊNCIAS
============
Depende de common e logger.
Consumido por parserSyncDownload e main.

LIMITAÇÕES
==========
- Não decidir se download é necessário
- Não manipular metadata persistente

ESTILO
======
- Operações lineares e previsíveis
- Sem efeitos colaterais fora do cache
"""

# =========================
# IMPORTS
# =========================
import os
import time
import urllib.request

import common
import loggerAndProgress

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

def download_file_with_progress(url, dst):
    """
    Descrição: Download de arquivo com progressbar unificada.
    Parâmetros:
    - url (str): URL do arquivo.
    - dst (str): Caminho destino.
    Retorno:
    - None
    """

    req = urllib.request.Request(url)

    with http_open(req) as response:
        total_size = response.headers.get("Content-Length")
        total_size = int(total_size) if total_size else None

        with open(dst, 'wb') as out_file:
            with create_progress("cyan") as progress:
                task = progress.add_task(
                    "",
                    total=total_size,
                    name=os.path.basename(dst)
                )

                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break

                    out_file.write(chunk)

                    if total_size:
                        progress.update(task, advance=len(chunk))   

def resolve_final_url(url, timeout=10):
    """
    Descrição: Resolve URL final após redirect via HEAD.
    Parâmetros:
    - url (str): URL original.
    - timeout (int): Timeout.
    Retorno:
    - tuple: (url_final, headers)
    """    
    try:
        req = urllib.request.Request(url, method="HEAD")
        with http_open(req, timeout=timeout) as response:
            return response.geturl(), response.headers
    except Exception:
        return None, {}
    
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
    resolved = resolve_download_context(path)
    if not resolved:
        return

    final_url = resolved["final_url"]
    expected_hash = resolved["expected_hash"]
    filename = resolved["filename"]

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
            if is_cached_file_valid(origin_cached_path, expected_hash):
                show_message(f"Cache válido na origem: {filename}", "k")

                # =========================================================
                # 🔒 STATUS DO DESTINO
                # =========================================================
                dest_exists = os.path.exists(final_dest_path)
                dest_valid = dest_exists and is_cached_file_valid(final_dest_path, expected_hash)

                if dest_valid:
                    show_message(f"Cache válido no destino: {filename}", "k")
                    show_message(f"Sincronizado (sem ação): {filename}", "d")
                    show_message(f"Sync completo: {filename}", "s")
                    return

                if dest_exists and not dest_valid:
                    show_message(f"Destino inválido → cópia necessária: {filename}", "w")
                elif not dest_exists:
                    show_message(f"Destino inexistente → cópia necessária: {filename}", "i")

                # =========================================================
                # 🔒 DECISÕES
                # =========================================================
                show_message(f"Download não necessário: {filename}", "d")

                if not dry_run:
                    copy_file_with_progress(origin_cached_path, final_dest_path)

                    # 🔒 propaga metadata também
                    for ext_meta in (".sha256", ".syncado"):
                        src_meta = origin_cached_path + ext_meta
                        dst_meta = final_dest_path + ext_meta

                        if os.path.exists(src_meta):
                            try:
                                copy_file_with_progress(src_meta, dst_meta)
                            except Exception:
                                pass

                    show_message(f"Arquivo sincronizado via cache: {filename}", "s")
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

    # === VALIDAÇÃO ===
    if not is_cached_file_valid(final_dest_path, expected_hash):
        show_message(f"Download inválido (hash/tamanho): {filename}", "w")
        try:
            os.remove(final_dest_path)
        except:
            pass
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

        show_message(f"Sync completo: {filename}", "s")

    except Exception as e:
        show_message(f"Inconsistência: falha ao propagar cache→destino: {e}", "e")

def resolve_syncdownload_cached(sync_path):
    """
    Resolve completamente um .syncdownload e cacheia resultado.

    Garante:
    - URL final resolvida (GitHub/SourceForge)
    - Nome final determinístico
    - Reutilização em cleanup + download

    NÃO realiza download
    Parâmetros:
    - sync_path (str): Caminho do arquivo.
    Retorno:
    - dict|None: Dados resolvidos.    
    """

    cache_entry = sync_resolve_cache.get(sync_path)

    if cache_entry:
        cached_mtime = cache_entry.get("_mtime")
        current_mtime = os.path.getmtime(sync_path)

        if cached_mtime == current_mtime:
            return cache_entry

    url, expected_hash, custom_filename = parse_syncdownload(sync_path)

    if not url:
        return None

    spec = None

    # --- split spec | url ---
    if "|" in url:
        try:
            left, right = url.split("|", 1)
            right = right.strip()

            if right.startswith("http://") or right.startswith("https://"):
                spec = left.strip()
                url = right
        except Exception:
            spec = None

    # --- GitHub ---
    forced_extension = None

    if spec and "github.com" in url.lower() and not __IGNORAR_GITHUB:
        try:
            
            import json

            parts = [p.strip().lower() for p in spec.split(",") if p.strip()]

            ext = None
            arch = None
            include_filters = []
            exclude_filters = []

            for p in parts:
                if p.startswith("."):
                    ext = p[1:]
                    forced_extension = ext
                elif p in ("x86", "x64", "arm64", "amd64"):
                    arch = p
                elif p.startswith("!"):
                    exclude_filters.append(p[1:])
                else:
                    include_filters.append(p)

            if ext:
                api_url = url.rstrip('/').replace(
                    "github.com",
                    "api.github.com/repos"
                ) + "/releases/latest"

                with http_open(api_url) as response:
                    data = json.loads(response.read().decode())

                assets = data.get("assets", [])

                candidates = []

                for asset in assets:
                    name = asset.get("name", "")
                    tokens = normalize_tokens(name)
                    clean = name.lower()

                    if not clean.endswith(f".{ext}"):
                        continue

                    ok = True

                    if arch and not any(arch in t for t in tokens):
                        ok = False

                    for f_in in include_filters:
                        if not any(f_in in t for t in tokens):
                            ok = False
                            break

                    if ok:
                        for f_ex in exclude_filters:
                            if any(f_ex in t for t in tokens):
                                ok = False
                                break

                    if ok:
                        candidates.append(asset)

                if candidates:
                    selected = max(candidates, key=lambda a: a.get("size", 0))
                    url = selected.get("browser_download_url")

        except Exception:
            pass

    # 🔒 resolve URL final antes de qualquer decisão de nome/extensão
    final_url, _ = resolve_final_url(url)
    effective_url = final_url or url

    filename = resolve_final_filename(
        url=effective_url,
        path=sync_path,
        custom_name=custom_filename,
        forced_extension=forced_extension
    )

    result = {
        "url": url,
        "filename": filename,
        "expected_hash": expected_hash,
        "forced_extension": forced_extension,
        "custom_filename": custom_filename
    }

    result["_mtime"] = os.path.getmtime(sync_path)
    sync_resolve_cache[sync_path] = result
    return result    
