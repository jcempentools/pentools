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
from common import *
from loggerAndProgress import *
from hash import *

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

def http_open(url_or_req, timeout=15):
    """
    Wrapper centralizado para acesso HTTP.

    Garantias:
    - Timeout SEMPRE aplicado
    - Aceita str (URL) ou Request
    - Não implementa retry (delegado para retry_sync)
    - Compatível com HEAD/GET via Request

    Parâmetros:
    - url_or_req (str|Request): URL ou objeto Request.
    - timeout (int): Timeout em segundos.
    Retorno:
    - HTTPResponse: Objeto de resposta.
    """

    if isinstance(url_or_req, str):
        req = urllib.request.Request(url_or_req)
    else:
        req = url_or_req

    return urllib.request.urlopen(req, timeout=timeout)

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

def resolve_download_context(sync_path):
    """
    Descrição: Monta contexto completo de download.
    Parâmetros:
    - sync_path (str): Caminho do .syncdownload.
    Retorno:
    - dict|None: Contexto com URL final e headers.
    """    
    resolved = resolve_syncdownload_cached(sync_path)

    if not resolved:
        return None

    cached = sync_resolve_cache.get(sync_path)
    if cached and cached.get("final_url"):
        final_url = cached["final_url"]
        headers = cached.get("headers", {})
    else:
        final_url, headers = resolve_final_url(resolved["url"])
        resolved["final_url"] = final_url
        resolved["headers"] = headers

    return {
        **resolved,
        "final_url": final_url,
        "headers": headers,
    }    

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

def normalize_tokens(s):
    """
    Descrição: Tokeniza string em partes normalizadas.
    Parâmetros:
    - s (str): String de entrada.
    Retorno:
    - list[str]: Lista de tokens.
    """
    return [t for t in re.split(r'[^a-z0-9]+', s.lower()) if t] 

def resolve_final_filename(url, path, custom_name=None, forced_extension=None):
    """
    Mantém todas as regras originais, com melhorias:
    - Extração de versão simplificada e robusta
    - Fonte unificada (URL > HEADER > fallback)
    - Menos duplicação de lógica
    """

    # --- SEM linha 3 ---
    if not custom_name:
        return _resolve_filename_from_url(url, path)

    custom_name = custom_name.strip()

    # =========================================================
    # 🔒 RESOLVE NOME BASE (URL / HEADER)
    # =========================================================
    base_source = None

    try:
        remote_info = _resolve_effective_remote_name(url)

        if isinstance(remote_info, dict):
            remote_name = remote_info.get("name")
            remote_headers = remote_info.get("headers", {})
        else:
            remote_name = remote_info
            remote_headers = {}

        # 1. URL com versão
        if remote_name and re.search(r'\d+(?:[.\-]\d+)+', remote_name):
            base_source = remote_name

        # 2. HEADER
        if not base_source and remote_headers:
            cd = remote_headers.get("Content-Disposition", "")
            m = re.search(r'filename="?([^"]+)"?', cd)
            if m:
                base_source = m.group(1)

        # 3. fallback URL
        if not base_source:
            final_url, _ = resolve_final_url(url)
            effective = final_url or url
            base_source = os.path.basename(effective.split("?")[0])

    except Exception:
        pass

    def resolve_extension(url, custom_name, forced_extension=None, existing_ext=None, base_source=None, tried=None):
        """
        Resolve extensão de forma progressiva com fallback real.
        Nunca falha prematuramente — apenas quando TODAS as fontes falham.
        """

        if tried is None:
            tried = set()

        def is_valid(ext):
            return ext and ext.lower() in SyncDonwloadExtensions

        # -------------------------------------------------
        # Lista ordenada de tentativas (prioridade)
        # -------------------------------------------------
        candidates = []

        if forced_extension and "forced" not in tried:
            candidates.append(("forced", forced_extension))

        if existing_ext and "existing" not in tried:
            candidates.append(("existing", existing_ext))

        if base_source and "base_source" not in tried:
            m = re.search(r'\.([a-zA-Z]{2,5})$', base_source)
            if m:
                candidates.append(("base_source", m.group(1)))

        if "url" not in tried:
            try:
                final_url, _ = resolve_final_url(url)
                effective = final_url or url
                remote_name = os.path.basename(effective.split("?")[0])

                if remote_name:
                    m = re.search(r'\.([a-zA-Z]{2,5})$', remote_name)
                    if m:
                        candidates.append(("url", m.group(1)))
            except Exception:
                pass

        # -------------------------------------------------
        # Tentativa progressiva
        # -------------------------------------------------
        for source, ext in candidates:
            tried.add(source)

            if not ext:
                continue

            ext = ext.lower()

            # 🔒 valida antes de aceitar
            if is_valid(ext):
                return ext

            # 🔁 fallback recursivo
            result = resolve_extension(
                url,
                custom_name,
                forced_extension,
                existing_ext,
                base_source,
                tried
            )

            if result:
                return result

        # -------------------------------------------------
        # FALHA REAL (após esgotar tudo)
        # -------------------------------------------------
        raise Exception(f"Extensão não resolvida para: {custom_name or url}")    

    # =========================================================
    # 🔒 EXTRAÇÃO DE VERSÃO (SIMPLES E CONFIÁVEL)
    # =========================================================
    def extract_version(name):        
        if not name:
            raise Exception("Nome não fornecido para extração de versão")

        base = re.sub(r'\.[a-zA-Z0-9]{2,5}$', '', name)

        pattern = rf'({"|".join(map(re.escape, NOISE_TOKENS))})'
        base_clean = re.sub(pattern, '', base, flags=re.I)

        m = re.search(
            r'([a-z]?\d+(?:[.\-,]\d+)+[a-z]?)',
            base_clean,
            re.I
        )        

        # 🔒 CONTRATO: não pode falhar silenciosamente
        if not m:
            # 🔒 fallback 1: ano (YYYY)
            m_year = re.search(r'\b(20\d{2})\b', base_clean)
            if m_year:
                version = m_year.group(1)
                prefix = base_clean[:m_year.start()]
            else:
                # 🔒 fallback 2: número isolado
                m_num = re.search(r'\b\d+\b', base_clean)
                if m_num:
                    version = m_num.group(0)
                    prefix = base_clean[:m_num.start()]
                else:
                    raise Exception(f"Não foi possível extrair versão de: '{name}'")

            # reaproveita lógica existente
            tokens = re.split(r'[^a-zA-Z0-9]+', prefix)
            tokens = [t for t in tokens if t]

            extra = tokens[-1] if tokens else None

            return version, extra

        version = re.sub(
            r'\.{2,}', '.',
            re.sub(
                r'(?<!\d)[a-z]+|[a-z]+(?=\.)',
                '',
                re.sub(r'[^0-9a-zA-Z]+', '.', m.group(1))
            )
        ).strip('.')

        # 🔒 alinhado com base_clean (onde ocorreu o match)
        prefix = base_clean[:m.start()]

        tokens = re.split(r'[^a-zA-Z0-9]+', prefix)
        tokens = [t for t in tokens if t]

        extra = tokens[-1] if tokens else None        

        return version, extra

    # =========================================================
    # 🔒 SUBSTITUIÇÃO {}
    # =========================================================
    original_custom_name = normalize_canonical_name(custom_name)

    if "{}" in custom_name:
        
        if base_source:
            version, extra = extract_version(base_source)

            try:

                if version:
                    # --- TAGS DECLARADAS ---
                    declared_tags = []

                    try:
                        raw_url = None
                        try:
                            with open(path, "r", encoding="utf-8") as f:
                                raw_url = f.readline().strip()
                        except Exception:
                            raw_url = None

                        if raw_url and "|" in raw_url:
                            left, right = raw_url.split("|", 1)

                            if right.strip().startswith(("http://", "https://")):
                                parts = [p.strip().lower() for p in left.split(",") if p.strip()]

                                for p in parts:
                                    if not p.startswith("."):
                                        declared_tags.append(p)

                    except Exception:
                        declared_tags = []

                    # --- MONTA BLOCO ---
                    if declared_tags:
                        version_block = f"{declared_tags[0]}-{version}"
                    elif extra:
                        version_block = f"{extra}-{version}"
                    else:
                        version_block = version

                    custom_name = custom_name.replace("{}", version_block)

            except Exception as e:
                show_message(f"[DEBUG] erro na substituição {{}}: {e}", "e")

    # =========================================================
    # 🔒 EXTENSÃO
    # =========================================================
    match_ext = re.search(r'\.([a-z0-9]{2,5})$', custom_name, re.IGNORECASE)
    existing_ext = match_ext.group(1).lower() if match_ext else None

    ext = resolve_extension(
        url=url,
        custom_name=custom_name,
        forced_extension=forced_extension,
        existing_ext=existing_ext,
        base_source=locals().get("base_source")
    ).lower()

    if not ext:
        raise Exception(f"Extensão não resolvida para: {custom_name or url}")    

    if ext not in SyncDonwloadExtensions:
        raise Exception(f"Extensão não permitida pela regra de negócio: .{ext}")

    # =========================================================
    # 🔒 BASE NAME
    # =========================================================
    if not existing_ext:
        base_name = re.sub(r'\{\}', '', custom_name).strip()
        base_name = re.sub(r'\s+', '-', base_name)
    else:
        base_name = re.sub(r'\.[a-z0-9]{2,5}$', '', custom_name, flags=re.IGNORECASE)

        if not base_name:
            base_name = custom_name.strip()

        if not base_name:
            base_name = re.sub(r'\.[a-z0-9]{2,5}$', '', custom_name.lower())
            base_name = re.sub(r'[^a-z0-9]+', '.', base_name).strip('.')

    # =========================================================
    # 🔒 DEDUP (INALTERADO)
    # =========================================================
    try:
        version_patterns = re.findall(r'\d+(?:\.\d+)+', base_name)

        version_map = {}
        for i, v in enumerate(version_patterns):
            placeholder = f"__VER{i}__"
            version_map[placeholder] = v
            base_name = base_name.replace(v, placeholder)

        tokens = re.split(r'[^a-zA-Z0-9_]+', base_name)
        seen = set()
        cleaned_tokens = []

        for t in tokens:
            if not t:
                continue

            key = t.lower()

            if t in version_map:
                cleaned_tokens.append(t)
                continue

            if re.match(r'^\d+$', t):
                cleaned_tokens.append(t)
                continue

            if key in seen:
                continue

            seen.add(key)
            cleaned_tokens.append(t)

        if cleaned_tokens:
            separator = "." if "." in base_name else "-"
            base_name = separator.join(cleaned_tokens)

        for placeholder, value in version_map.items():
            base_name = base_name.replace(placeholder, value)

    except Exception:
        pass

    # =========================================================
    # 🔒 FINAL
    # =========================================================
    if ext:
        return f"{base_name}.{ext}"   

    return base_name