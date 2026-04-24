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
import shutil
import ctypes

import urllib

from sync_local.commons import *
from sync_local.utils.naming import normalize_product_name
from sync_local.utils.naming import normalize_canonical_name
from sync_local.utils.naming import is_same_product
from sync_local.utils.logging import get_op_icon, show_message
from sync_local.utils.dsl import has_parser_expression, resolve_parser_expression
from sync_local.core.cache_validation import is_cached_file_valid
from sync_local.core.download_manager import http_open, resolve_final_url                            
from sync_local.core.cache_validation import  hash_file
from sync_local.utils.progress import create_progress

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES

def origin_to_destination(path, retry, dry_run):
    """
    Descrição: Copia arquivos da origem para destino.
    Parâmetros:
    - path (str): Caminho origem.
    - retry (bool): Permite retentativa.
    - dry_run (bool): Simulação.
    Retorno:
    - None
    """
    global failed_files
    rel_path = os.path.relpath(path, ORIGIN_PATH)
    dest_path = os.path.join(destination_path, rel_path)
    need_download = True

    try:
        if os.path.isdir(path):
            if not dry_run:
                os.makedirs(dest_path, exist_ok=True)
            return

        if not dry_run:
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)

            # --- .syncdownload agora é tratado na Etapa 3 ---
            if path.lower().endswith(".syncdownload"):
                return

            # Lógica simples de cópia (exemplo: se não existe ou hash diferente)
            if not os.path.exists(dest_path) or hash_file(path, "Origem") != hash_file(dest_path, "Destino"):
                show_message(f"Copiando: {rel_path}", "+")
                copy_file_with_progress(path, dest_path)
    
    except OSError as e:
        show_message(f"Erro no sistema de arquivos em {rel_path}: {e}", "e")
        if retry and path not in failed_files:
            show_message(f"Adicionado para retentativa: {rel_path}", "w")
            failed_files.append(path)


def recursive_directory_iteration(root, action, retry, dry_run):
    """
    Descrição: Itera diretórios recursivamente aplicando ação.
    Parâmetros:
    - root (str): Diretório base.
    - action (callable): Função a aplicar.
    - retry (bool): Flag de retentativa.
    - dry_run (bool): Simulação.
    Retorno:
    - None
    """
    try:
        items = os.listdir(root)
    except OSError as e:
        show_message(f"Erro ao acessar {root}: {e}", "e")
        return

    for item in items:
        full_path = os.path.join(root, item)
        if re.search(IGNORED_PATHS, full_path, re.IGNORECASE):
            continue
        
        action(full_path, retry, dry_run)
        if os.path.isdir(full_path):
            recursive_directory_iteration(full_path, action, retry, dry_run)

def apply_root_hidden_attribute():
    """
    Descrição: Aplica atributo oculto no root do destino (Windows).
    Parâmetros:
    - None
    Retorno:
    - None
    """        
    try:
        origin_root_items = set(os.listdir(ORIGIN_PATH))
    except Exception as e:
        show_message(f"Erro ao listar origem (root): {e}", "e")
        return

    exceptions = {"NÃO FORMATAR", "Drivers", "apps"}

    for item in os.listdir(destination_path):
        dest_full_path = os.path.join(destination_path, item)

        # Apenas itens no root que também existem na origem
        if item not in origin_root_items:
            continue

        # Exceções explícitas
        if item in exceptions:
            continue

        try:
            # Apenas aplica no item (não recursivo)
            if os.name == "nt":                
                FILE_ATTRIBUTE_HIDDEN = 0x02

                attrs = ctypes.windll.kernel32.GetFileAttributesW(dest_full_path)
                if attrs != -1 and not (attrs & FILE_ATTRIBUTE_HIDDEN):
                    ctypes.windll.kernel32.SetFileAttributesW(dest_full_path, attrs | FILE_ATTRIBUTE_HIDDEN)
                    show_message(f"Ocultado: {item}", "d")

        except Exception as e:
            show_message(f"Falha ao ocultar {item}: {e}", "e")            
        

def copy_file_with_progress(src, dst):
    """
    Descrição: Cópia de arquivo com progressbar unificada.
    Parâmetros:
    - src (str): Caminho origem.
    - dst (str): Caminho destino.
    Retorno:
    - None
    """
    file_size = os.path.getsize(src)

    with open(src, 'rb') as src_f, open(dst, 'wb') as dst_f:
        with create_progress("green") as progress:
            task = progress.add_task(
                "",
                total=file_size,
                name=os.path.basename(src),
                op=get_op_icon("copy")
            )

            while chunk := src_f.read(65536):
                dst_f.write(chunk)
                progress.update(task, advance=len(chunk))

    # preserva metadata (equivalente ao copy2)
    try:
        shutil.copystat(src, dst)
    except Exception:
        pass

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


def _resolve_filename_from_url(url, fallback_path=None):
    """    
    Descrição: Resolve nome final normalizado com extensão válida, sem duplicação e com base no nome canônico do produto.
    Garante:
    - Nome estável (ex: powershell.msi)
    - Não duplicação de extensão
    - Compatibilidade com purge    
    - Nome fixado na terceira linha representa nome canônico do software
      para fins comparação (limpeza e purge), desconsiderando o conteúdo:
        1. terminações contidas em SyncDonwloadExtensions (incluindo o ponto)
        2. o `{}`, que representa versiojamenteo a ser incorporado no nome do
           arquivo final
        3. caracteres não alfanuméricos imediatamente ao entorno de `{}` que
           estarão presentes apenas no nome do arquivo final

    Regras:
    - Força extensão compatível (mime-type ou inferida)
    - Evita duplicação de extensão
    - Normaliza basename para manter apenas o nome do software
    - Garante compatibilidade com purge e dedup

    Exemplos de arquivo (todos representam apenas um software canonico = 7zip):
    - 7zip.7zip -> 7zip.7zip.msi
    - 7zip.7zip.msi -> 7zip.7zip.msi
    - 7zip -> 7zip.msi
    - 7zip.msi -> 7zip.msi
    - Microsoft.PowerShell-7.6.0-rc.1-win-x64.msi -> powershell.msi
    - 7zip{} -> 7zip-7.6.0.msi (substitui {} por versão unificada)
    - 7zip-{}.7zip.msi -> 7zip-7.6.0.7zip.msi (substitui {} por versão unificada, mantém extensão original)

    Parâmetros:
    - url (str): URL do recurso.
    - fallback_path (str|None): Caminho alternativo.
    Retorno:
    - str|None: Nome do arquivo resolvido.    

    Retorno:
    - str: Nome final do arquivo.   
    """
    filename = None

    # 1. URL
    url_name = os.path.basename(url.split("?")[0])
    if url_name:
        filename = url_name

    # 2. Header
    try:
        
        req = urllib.request.Request(url, method='HEAD')
        with http_open(req) as response:
            content_disposition = response.headers.get('Content-Disposition')
            if content_disposition:
                match = re.search(r'filename="?([^"]+)"?', content_disposition)
                if match:
                    filename = match.group(1)
    except Exception:
        pass

    # 3. Fallback
    if not filename and fallback_path:
        base = os.path.basename(fallback_path)
        if base.lower().endswith(".syncdownload"):
            filename = base[:-len(".syncdownload")]

    return filename  

def _resolve_effective_remote_name(url):
    """
    Resolve nome REAL do arquivo remoto com prioridade correta:
    1. Content-Disposition (mais confiável)
    2. URL final (se não for UUID/lixo)
    3. Fallback local
    """

    try:
        final_url, headers = resolve_final_url(url)
        effective_url = final_url or url

        req = urllib.request.Request(effective_url, method="HEAD")

        with http_open(req) as response:
            headers = dict(response.headers)

            # =====================================================
            # 1. HEADER (PRIORIDADE MÁXIMA)
            # =====================================================
            cd = headers.get("Content-Disposition", "")
            m = re.search(r'filename="?([^"]+)"?', cd)

            if m:
                name = m.group(1)
                if name:
                    return {
                        "name": name,
                        "source": "header",
                        "headers": headers
                    }

            # =====================================================
            # 2. URL FINAL
            # =====================================================
            final_url_resp = response.geturl()
            name = os.path.basename(final_url_resp.split("?")[0])

            # 🔒 descarta nomes inválidos (UUID / download / vazio)
            if name and name.lower() != "download":
                if not re.match(r'^[0-9a-f\-]{20,}$', name.lower()):
                    return {
                        "name": name,
                        "source": "url",
                        "headers": headers
                    }

    except Exception:
        pass

    # =========================================================
    # 3. FALLBACK PADRÃO (NORMALIZADO)
    # =========================================================
    fallback = _resolve_filename_from_url(url)

    if isinstance(fallback, str):
        return {
            "name": fallback,
            "source": "fallback",
            "headers": {}
        }

    return fallback

def similarity_score(a, b):
    """
    Descrição: Calcula similaridade simples entre dois nomes.
    Parâmetros:
    - a (str): Nome A.
    - b (str): Nome B.
    Retorno:
    - float: Score de similaridade (0 a 1).
    """
    if not a or not b:
        return 0

    return 1.0 if a == b else 0 

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
