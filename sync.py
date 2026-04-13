"""
SYNC ENGINE — Contrato Operacional

OBJETIVO
========
Sincronizar origem→destino (cópia local + downloads .syncdownload). Detectar
releases remotos e atualizar auto. Garantir integridade, determinismo,
idempotência. Origem = cache persistente (não fonte de versão, exceto hash
fixo).

PIPELINE (ordem imutável)
=========================
1. Limpeza controlada do destino
2. Cópia origem→destino
3. Processamento .syncdownload (download + cache na origem)
4. Retentativa (mesma ordem, síncrono)
5. Pós-processamento (atributos)

PRINCÍPIOS GLOBAIS
==================
- Idempotente, determinístico, síncrono, ordenado
- Nunca remover sem validação lógica
- Retry auto p/ falhas transitórias; abort seguro p/ inconsistências
- Logs humano + machine-readable
- Metadata persistente (.sha256 / .syncado)
- Decisão incremental: cache + validação
- Ignorar paths por regex configurável

REGRAS COMPARTILHADAS
=====================
- Normalização de nomes p/ dedup (tolerante a variações reais)
- Nome do software estável; filename pode variar
- Preservar apenas versão válida + recente
- Dedup: nome canônico (primário) | hash (fallback)
- Sem purge agressivo só por nome
- Coerência obrigatória origem↔destino

ETAPA 1 — LIMPEZA (destino + cache)
===================================
Remover só itens inexistentes na origem. Respeitar .syncdownload. Proteger
arquivos válidos por: existência, metadata válida, similaridade. Purge atua
no destino E cache, preserva versão final, usa heurística segura (nome +
fallback hash). Nunca remover metadata de arquivo existente.

ETAPA 2 — CÓPIA (origem→destino)
================================
Copiar quando: não existe OU hash diverge. Sem sobrescrita desnecessária.
Determinística. Respeitar dedup. Não afetar arquivos de .syncdownload.

ETAPA 3 — .SYNCDOWNLOAD
=======================
Formato: linha1 = URL/DSL | linha2 = SHA256 fixo (opc) | linha3 = nome custom (opc)
                  DSL deve resolver também indices semânticos, ex.: [@attr="img"] e [@attr='img']

Regra de versão:
- COM hash na linha2 → versão FIXA (não consultar latest)
- SEM hash → resolver latest online

Fluxo: resolver URL → nome final → verificar cache → decidir via metadata
→ download se necessário → validar (hash/tamanho) → purge → gerar metadata
→ persistir cache.

Cache: reutilizar downloads válidos, evitar re-download, manter só versões
válidas (sem histórico desnecessário).

Metadata:
- .syncado → controle de versão (nome remoto real ou referência)
- .sha256 → integridade, formato "<hash>  <filename>" (2 espaços),
  compatível c/ sha256sum. Uso EXCLUSIVO: validação local.
  NÃO participa da decisão de versão.

Hash: NÃO define atualização de versão (exceto se fixo no .syncdownload).
Usado p/ validação pós-download, validação de cache, dedup fallback.

ETAPA 4 — RETENTATIVA
=====================
Retry controlado, síncrono, determinístico. Mesma ordem. Sem paralelismo.
Só itens falhos. Limite explícito.

ETAPA 5 — PÓS-PROCESSAMENTO
===========================
Aplicar atributos (ex: ocultação). Sem alterar lógica de sync ou
integridade/metadata (fóco exFat/pendrive).

ABSTRAÇÃO DE ORIGENS
====================
Interface lógica equivalente p/ todos providers (GitHub, GitLab, SF, etc.).
Extensível. Mesma lógica de decisão, validação, metadata. Preferir APIs
oficiais. Evitar parsing HTML/XML heurístico.

DIRETRIZES TÉCNICAS
===================
- HEAD (metadata) e GET (download) separados
- Hash rápido (xxhash) + SHA256 (integridade)
- Cache: memória + persistente na origem
- Metadata não bloqueia atualização de versão
- Timeout de rede obrigatório; logging rotativo

GUI/UX
======
Preservar progressbar inline (rich.progress). Atualização em linha sem
flooding. Feedback visual p/ hash, download, retry, cópia.

ESTILO DE IMPLEMENTAÇÃO
=======================
Funções pequenas, especialistas, reutilizáveis. NÃO duplicar lógica.
Centralização obrigatória de: normalização, decisão de versão, nome final,
validação, download. Nomeação consistente. Evitar side-effects e hardcode.
Baixo acoplamento.

RESTRIÇÕES
==========
- Não duplicar lógica
- Não usar parsing HTML se houver API
- Não remover arquivos sem validação
- Não fazer purge agressivo só por nome
- Não quebrar coerência origem↔destino
- Não alterar UX da progressbar sem decisão explícita
- Não quebrar compatibilidade de metadata
"""
import os
import sys
import codecs
import shutil
import re
import urllib.request
import xxhash
import hashlib
from rich.console import Console
from rich.progress import Progress
from pathlib import Path
import time
from datetime import datetime
import random

from rich.style import Style
from rich.progress import (
    Progress,
    TextColumn,
    BarColumn,
    TimeRemainingColumn,
    DownloadColumn,
    TransferSpeedColumn,
    TaskProgressColumn
)

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

SyncDonwloadExtensions = ["exe", "msi", "iso", "img"]

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

def resolve_provider(url):
    """resolve_provider(url)
    Descrição: Resolve a URL usando um provider registrado, se aplicável.
    Parâmetros:
    - url (str): URL a ser resolvida.
    Retorno:
    - str: URL resolvida ou original.
    """    
    for domain, handler in PROVIDERS.items():
        if domain in url:
            return handler(url)
    return url

def retry_sync(fn, attempts=3, delay=1):
    """retry_sync(fn, attempts=3, delay=1)
    Descrição: Executa função com retentativa em falhas transitórias.
    Parâmetros:
    - fn (callable): Função a executar.
    - attempts (int): Número máximo de tentativas.
    - delay (int): Delay entre tentativas (segundos).
    Retorno:
    - any: Resultado da função executada.
    """    
    for i in range(attempts):
        try:
            return fn()
        except (TimeoutError, ConnectionError) as e:
            if i == attempts - 1:
                raise
            time.sleep(delay)
        except Exception:
            raise

def show_message(txt, tipo=None, cor="white", bold=True, inline=False):
    """show_message(txt, tipo=None, cor="white", bold=True, inline=False)
    Descrição: Exibe mensagem formatada e registra log.
    Parâmetros:
    - txt (str): Texto da mensagem.
    - tipo (str|None): Tipo/nível da mensagem.
    - cor (str): Cor do texto.
    - bold (bool): Aplica negrito.
    - inline (bool): Atualização inline no terminal.
    Retorno:
    - None
    """
    global _log_iniciado, retent_loop_count

    def limpar_formatacao_rich(mensagem):
        mensagem = re.sub(r'\[(\w[^\]]*)\](.*?)\[/\1\]', r'\2', mensagem)
        mensagem = re.sub(r'\[(\w[^\]]*)\](.*?)\[/\]', r'\2', mensagem)
        return mensagem.strip()

    def truncar_log_se_necessario():
        if not os.path.isfile(LOG_FILE):
            return
        tamanho = os.path.getsize(LOG_FILE)
        if tamanho <= MAX_LOG_SIZE:
            return
        with open(LOG_FILE, 'rb') as f:
            f.seek(-MAX_LOG_SIZE, os.SEEK_END)
            conteudo = f.read()
            primeiro_nl = conteudo.find(b'\n')
            conteudo = conteudo[primeiro_nl + 1:] if primeiro_nl != -1 else conteudo
        with open(LOG_FILE, 'wb') as f:
            f.write(conteudo)

    tipos_demo = {
        "i": ("I", "cyan"), "e": ("E", "bright_magenta"), "w": ("W", "yellow"),
        "d": ("D", "bright_black"), "s": ("✓", "green"), "k": ("✓", "dodger_blue2"),
        "+": ("+", "bright_green"), "-": ("-", "bright_red"),
    }

    aliases = {
        "info": "i", "error": "e", "warn": "w", "warning": "w",
        "debug": "d", "success": "s", "sucesso": "s",
        "ok": "k", "added": "+", "add": "+",
        "removed": "-", "remove": "-", "del": "-"
    }

    if tipo is not None:
        tipo_str = aliases.get(str(tipo).lower(), str(tipo).lower())
        marcador, cor_definida = tipos_demo.get(tipo_str, ("?", "white"))
        cor = cor_definida
        txt = f"[{marcador}] {txt}"

    if retent_loop_count > 0:
        txt = f"(Retry: {retent_loop_count}) {txt}"

    style_extra, base_color = _normalize_color(cor)

    # 🔒 evita duplicação de bold
    final_style = []

    if bold and "bold" not in style_extra:
        final_style.append("bold")

    if style_extra:
        final_style.append(style_extra)

    final_style.append(base_color)

    style = " ".join(final_style).strip()

    if inline:
        terminal_width = os.get_terminal_size().columns
        console.print(' ' * terminal_width, end='\r')
    
    console.print(f"[{style}]{txt}[/{style}]", end=f"{'\r' if inline else '\n'}")

    mensagem_limpa = limpar_formatacao_rich(txt)
    timestamp = datetime.now().strftime("[%H:%M:%S] ")
    truncar_log_se_necessario()
    
    with open(LOG_FILE, 'a', encoding='utf-8') as f_log:
        if not _log_iniciado:
            f_log.write("\n")
            f_log.write(f"[   ] {timestamp} " + "-" * 40 + "\n")
            f_log.write(f"[   ] {timestamp} Início execução ID '{ID_EXECUCAO}', {datetime.now().strftime('%Y-%m-%d')}\n")
            _log_iniciado = True
        f_log.write(f"[{ID_EXECUCAO}] {timestamp} {mensagem_limpa}\n")

def show_inline(txt, tipo, cor="white", bold=True):
    """show_inline(txt, tipo, cor="white", bold=True)
    Descrição: Exibe mensagem inline no console.
    Parâmetros:
    - txt (str): Texto da mensagem.
    - tipo (str): Tipo da mensagem.
    - cor (str): Cor do texto.
    - bold (bool): Aplica negrito.
    Retorno:
    - None
    """    
    show_message(txt, tipo, cor, bold, True)

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
            with create_progress("# Hash", "bold yellow") as progress:
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
        with create_progress("# Cópia", "green") as progress:
            task = progress.add_task(
                "",
                total=file_size,
                name=os.path.basename(src)
            )

            while chunk := src_f.read(65536):
                dst_f.write(chunk)
                progress.update(task, advance=len(chunk))

    # preserva metadata (equivalente ao copy2)
    try:
        shutil.copystat(src, dst)
    except Exception:
        pass

def _resolve_filename_from_url(url, fallback_path=None):
    """
    INTERNAL: uso exclusivo por resolve_final_filename
    Descrição: Resolve nome de arquivo a partir de URL ou fallback.
    Parâmetros:
    - url (str): URL do recurso.
    - fallback_path (str|None): Caminho alternativo.
    Retorno:
    - str|None: Nome do arquivo resolvido.
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

def purge_similar_installers(dest_dir, target_name):
    """
    Remove versões antigas de um mesmo produto, preservando:
    - o arquivo alvo (recém baixado ou selecionado)
    - exatamente 1 versão final válida

    Estratégia:
    - agrupa por nome canônico
    - filtra apenas instaladores válidos
    - preserva o target
    - remove apenas excedentes
    
    Parâmetros:
    - dest_dir (str): Diretório destino.
    - target_name (str): Arquivo alvo.
    Retorno:
    - None    
    """

    target_base = normalize_product_name(target_name)

    if not target_base:
        return

    candidates = []

    for f in sorted(os.listdir(dest_dir)):
        full = os.path.join(dest_dir, f)

        if not os.path.isfile(full):
            continue
        
        # 🔒 Nunca tocar em metadata ou arquivos de controle
        if f.lower().endswith((".sha256", ".syncado", ".syncdownload")):
            continue

        base = normalize_product_name(f)

        same_product = is_same_product(base, target_base)

        # --- fallback controlado por hash ---
        if not same_product:
            try:
                ext = os.path.splitext(full)[1].lower()

                # apenas tipos relevantes (instaladores / imagens grandes)
                ALLOWED_HASH_DEDUP_EXT = {
                    ".exe", ".msi", ".zip", ".7z", ".rar",
                    ".iso", ".img"
                }

                if ext in ALLOWED_HASH_DEDUP_EXT:
                    size = os.path.getsize(full)                    

                    if size >= MIN_SIZE_BYTES:
                        target_full = os.path.join(dest_dir, target_name)

                        if os.path.exists(target_full):
                            if hash_file(full, "Destino") == hash_file(target_full, "Destino"):
                                same_product = True

            except Exception:
                pass

        if not same_product:
            continue

        candidates.append(f)

    # 🔒 Segurança: precisa ter mais de 1 candidato
    if len(candidates) <= 1:
        return

    target_full = os.path.join(dest_dir, target_name)

    # 🔒 Só permite purge se o alvo (latest) EXISTE fisicamente
    if not os.path.exists(target_full):
        show_message(f"Purga abortada: alvo ainda não existe fisicamente ({target_name})", "d")
        return

    # 🔒 Garante que o target está presente no grupo
    if target_name not in candidates:
        show_message(f"Purga abortada: alvo não encontrado entre candidatos ({target_name})", "w")
        return
    
    # 🔒 mantém target + 1 fallback válido
    keep = [target_name]

    for f in candidates:
        if f == target_name:
            continue

        full = os.path.join(dest_dir, f)

        if is_cached_file_valid(full, None):
            keep.append(f)
            break

    for f in candidates:
        if f not in keep:
            try:
                os.remove(os.path.join(dest_dir, f))
                show_message(f"Removido excedente: {f}", "-", cor="yellow")
            except Exception as e:
                show_message(f"Erro ao remover {f}: {e}", "e")

def resolve_final_filename(url, path, custom_name=None, forced_extension=None):
    import os
    import re

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
            raise Exception(f"Não foi possível extrair versão de: '{name}'")

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

def parse_syncdownload(file_path):
    """
    Descrição: Lê e interpreta arquivo .syncdownload.
    Parâmetros:
    - file_path (str): Caminho do arquivo.
    Retorno:
    - tuple: (url, expected_hash, custom_name)
    """    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            raw_lines = [l.rstrip('\n') for l in f.readlines()]

        if not raw_lines:
            return None, None, None

        # Preserva posição das linhas (não remove vazias)
        url = raw_lines[0].strip() if len(raw_lines) > 0 else None

        # --- Parser DSL resolution ---
        try:
            if has_parser_expression(url):
                resolved = resolve_parser_expression(
                    url,
                    context_name=os.path.basename(file_path)
                )

                if not isinstance(resolved, str):
                    raise Exception("Parser DSL não retornou URL válida")

                url = resolved

        except Exception as e:
            show_message(f"Erro ao resolver parser DSL: {e}", "e")
            return None, None, None

        # 🔒 GARANTIA: URL final válida
        if not url or not isinstance(url, str):
            show_message(f"URL inválida no .syncdownload: {file_path}", "e")
            return None, None, None

        if "${" in url:
            show_message(f"URL inválida após parser: {url}", "e")
            return None, None, None

    except Exception as e:
        show_message(f"Erro ao ler .syncdownload {file_path}: {e}", "e")
        return None, None, None

    expected_hash = raw_lines[1].strip() if len(raw_lines) > 1 and raw_lines[1].strip() else None
    custom_name = raw_lines[2].strip() if len(raw_lines) > 2 and raw_lines[2].strip() else None

    return url, expected_hash, custom_name        

def manage_sync_metadata(final_dest_path, url, expected_hash):
    """
    Decisão unificada de download (independente da origem)

    Ordem:
    1. Arquivo existe?
    2. .syncado existe?
    3. Nome confere?
    4. Hash confere?

    Parâmetros:
    - final_dest_path (str): Caminho destino.
    - url (str): URL do recurso.
    - expected_hash (str|None): Hash esperado.
    Retorno:
    - bool: True se precisa baixar.    
    """

    sha_file = final_dest_path + ".sha256"
    sync_file = final_dest_path + ".syncado"

    # =========================================================
    # 1. ARQUIVO NÃO EXISTE → DOWNLOAD
    # =========================================================
    if not os.path.exists(final_dest_path):
        show_message("Arquivo não existe → download necessário", "d")
        return True

    # =========================================================
    # 2. SEM .syncado → NÃO SABE QUAL VERSÃO → DOWNLOAD
    # =========================================================
    if not os.path.exists(sync_file):
        show_message("Sem .syncado → download necessário", "d")
        return True

    try:
        # =====================================================
        # 3. COMPARAÇÃO DE NOME (VERSÃO)
        # =====================================================
        with open(sync_file, "r", encoding="utf-8") as f:
            stored_name = f.read().strip()

        current_name = _resolve_effective_remote_name(url)

        if not current_name:
            show_message("Não foi possível resolver nome atual → download", "w")
            return True

        if stored_name.lower() != current_name.lower():
            show_message(
                f"Novo release detectado: {stored_name} -> {current_name}",
                "i"
            )
            return True

        show_message(f"Mesmo release detectado: {current_name}", "d")

        # =====================================================
        # 4. VALIDAÇÃO DE HASH EXTERNO (linha 2 do .syncdownload)
        # =====================================================
        if expected_hash:
            current_hash = hash_file(final_dest_path, "Destino")

            if current_hash == expected_hash.lower():
                show_message(
                    f"Hash externo válido (sem download): {os.path.basename(final_dest_path)}",
                    "k"
                )
                return False

            show_message(
                f"Hash externo divergente → download necessário",
                "w"
            )
            return True        

        # =====================================================
        # 5. VALIDAÇÃO DE HASH LOCAL (.sha256)
        # =====================================================
        if not os.path.exists(sha_file):
            show_message("Sem .sha256 → fallback leve", "d")

            try:
                show_message("Sem .sha256 → confiando apenas em .syncado", "d")
                return False
            except:
                return True

        with open(sha_file, "r", encoding="utf-8") as f:
            line = f.readline().strip()
            saved_hash = line.split()[0] if line else None

        if not saved_hash:
            show_message("Hash inválido no .sha256 → download", "w")
            return True

        current_hash = hash_file(final_dest_path, "Destino")

        if current_hash == saved_hash:
            show_message(
                f"Arquivo íntegro (sem download): {os.path.basename(final_dest_path)}",
                "k"
            )
            return False

        show_message(f"Hash atual {current_hash} != {saved_hash}", "w")
        return True

    except Exception as e:
        show_message(f"Erro na validação: {e}", "w")
        return True
    
def generate_sync_metadata(final_dest_path, url):
    try:
        show_message(f"Gerando arquivos auxiliares: {os.path.basename(final_dest_path)}", "d")

        ext = os.path.splitext(final_dest_path)[1].lower()

        # =========================================================
        # 1. SHA256 → SOMENTE PARA IMAGENS
        # =========================================================
        if ext in (".iso", ".img"):
            sha256_hash = hashlib.sha256()

            total_size = os.path.getsize(final_dest_path)

            with open(final_dest_path, "rb") as f:
                with create_progress("# Hash", "bold yellow") as progress:

                    task = progress.add_task(
                        "",
                        total=total_size,
                        name=os.path.basename(final_dest_path)
                    )

                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break

                        sha256_hash.update(chunk)
                        progress.update(task, advance=len(chunk))

            filename_only = os.path.basename(final_dest_path)
            sha_line = f"{sha256_hash.hexdigest()}  {filename_only}"

            with open(final_dest_path + ".sha256", "w", encoding="utf-8") as f:
                f.write(sha_line + "\n")

        # =========================================================
        # 2. .syncado → SEMPRE
        # =========================================================
        original_info = _resolve_effective_remote_name(url)

        original_name = None

        if isinstance(original_info, dict):
            original_name = original_info.get("name")
        elif isinstance(original_info, str):
            original_name = original_info

        if original_name:
            with open(final_dest_path + ".syncado", "w", encoding="utf-8") as f:
                f.write(str(original_name))

    except Exception as e:
        show_message(f"Erro ao gerar arquivos auxiliares: {e}", "w")

def normalize_tokens(s):
    """
    Descrição: Tokeniza string em partes normalizadas.
    Parâmetros:
    - s (str): String de entrada.
    Retorno:
    - list[str]: Lista de tokens.
    """
    return [t for t in re.split(r'[^a-z0-9]+', s.lower()) if t] 

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

def has_parser_expression(value):
    """has_parser_expression(value)
    Descrição: Detecta expressão DSL ${"..."}.
    Parâmetros:
    - value (str): Valor a verificar.
    Retorno:
    - bool: True se contém expressão.
    """    
    if not value:
        return False
    return bool(re.search(r'\$\{\s*["\']https?://[^"\']+["\']\s*\}', value))

def extract_parser_url(value):
    """
    Descrição: Extrai URL de expressão DSL.
    Parâmetros:
    - value (str): Expressão.
    Retorno:
    - str|None: URL extraída.
    """
    if not value:
        return None
    m = re.search(r'\$\{\s*["\'](https?://[^"\']+)["\']\s*\}', value)
    return m.group(1) if m else None


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

def is_binary_content(headers):
    """
    Descrição: Verifica se conteúdo é binário.
    Parâmetros:
    - headers (dict): Headers HTTP.
    Retorno:
    - bool: True se binário.
    """    
    ct = headers.get("Content-Type", "").lower()
    return "text/html" not in ct 

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

def has_resolvable_url(value):    
    """
    Descrição: Detecta URL direta OU indireta (parser DSL)
    Parâmetros:
    - value (str): Valor contendo URL.
    Retorno:
    - tuple: (tipo, url)
    """    
    if not value:
        return False

    if has_parser_expression(value):
        return True

    return bool(re.search(r'https?://', value)) 

def resolve_url_source(value):
    """    
    Descrição: Identifica tipo e origem da URL, direta ou via parser DSL.
    Parâmetros:
    - value (str): Valor contendo URL.
    Retorno:
    - tuple: (tipo, url)
    """

    if not value:
        return None, None

    if has_parser_expression(value):
        return "parser", extract_parser_url(value)

    m = re.search(r'(https?://[^\s]+)', value)
    if m:
        return "direct", m.group(1)

    return None, None   

def _parser_cache_get(url):
    """_parser_cache_get(url)
    Descrição: Recupera cache de parser com TTL.
    Parâmetros:
    - url (str): URL base.
    Retorno:
    - any: Dados em cache ou None.
    """    
    entry = __PARSER_CACHE.get(url)
    if not entry:
        return None

    ts, data = entry
    if time.time() - ts > PARSER_CACHE_TTL:
        return None

    return data

def _parser_cache_set(url, data):
    """_parser_cache_set(url, data)
    Descrição: Armazena dados no cache de parser.
    Parâmetros:
    - url (str): URL base.
    - data (any): Dados a armazenar.
    Retorno:
    - None
    """
    __PARSER_CACHE[url] = (time.time(), data)


def fetch_and_parse(url):
    """
    Descrição: Fetch + parse automático (JSON/YAML fallback JSON only)
    Parâmetros:
    - url (str): URL de origem.
    Retorno:
    - dict: Dados parseados    
    """

    cached = _parser_cache_get(url)
    if cached is not None:
        return cached

    
    import json

    req = urllib.request.Request(url, headers={"User-Agent": "sync-engine"})

    with http_open(req) as response:
        raw = response.read()

        content_type = response.headers.get("Content-Type", "").lower()

        if "json" in content_type:
            data = json.loads(raw.decode())
        else:
            # fallback seguro → tenta JSON
            try:
                data = json.loads(raw.decode())
            except Exception:
                raise Exception("Parser DSL: formato não suportado")

    _parser_cache_set(url, data)
    return data


def resolve_data_path(obj, path, context_name=None):
    """
    Resolve caminho aninhado com suporte a:
    - índice: [0]
    - filtro: [@campo="valor"]
    """

    current = obj

    tokens = re.split(r'\.(?![^\[]*\])', path)

    for token in tokens:
        # match: campo[index] OU campo[@attr="value"]
        m = re.match(r'([a-zA-Z0-9_\-]+)(\[(.*?)\])?', token)

        if not m:
            raise Exception(f"Parser DSL inválido: {token}")

        key = m.group(1)
        selector = m.group(3)  # conteúdo dentro []

        # --- acesso base (dict OU lista) ---
        if isinstance(current, dict):
            current = current.get(key)

        elif isinstance(current, list):
            # 🔒 tenta resolver key dentro de lista (estrutura comum em APIs)
            next_list = []

            for item in current:
                if isinstance(item, dict) and key in item:
                    next_list.append(item.get(key))

            if not next_list:
                raise Exception(
                    f"Parser DSL: chave '{key}' não encontrada em lista | origem: {context_name}"
                )

            # 🔒 flatten simples se possível
            if len(next_list) == 1:
                current = next_list[0]
            else:
                current = next_list

        else:
            raise Exception(
                f"Parser DSL: estrutura inválida (esperado dict/list) | origem: {context_name}"
            )

        # --- sem seletor ---
        if selector is None:
            continue

        # --- índice numérico ---
        if re.match(r'^\d+$', selector):
            if not isinstance(current, list):
                raise Exception("Parser DSL: índice aplicado em estrutura não-lista")

            current = current[int(selector)]
            continue

        # --- filtro estilo [@campo="valor"] ---
        m_filter = re.match(r'@([a-zA-Z0-9_\-]+)\s*=\s*["\']([^"\']+)["\']', selector)

        if m_filter:
            attr = m_filter.group(1)
            value = m_filter.group(2)

            # 🔒 garante lista (mesmo se veio item único)
            if isinstance(current, dict):
                current = [current]

            if not isinstance(current, list):
                raise Exception("Parser DSL: filtro aplicado em estrutura não-lista")

            match_item = None

            for item in current:
                if isinstance(item, dict):
                    v = item.get(attr)

                    # 🔒 comparação tolerante (string)
                    if v is not None and str(v).strip() == value:
                        match_item = item
                        break

            if match_item is None:
                raise Exception(f"Parser DSL: nenhum match para {attr}={value}")

            current = match_item
            continue

        raise Exception(f"Parser DSL: seletor inválido [{selector}]")

    return current

def resolve_parser_expression(expr, context_name=None):
    """
    Resolve expressão completa:
    ${"url"}.path.to.value
    Parâmetros:
    - expr (str): Expressão DSL.
    Retorno:
    - any: Resultado resolvido.    
    """

    url = extract_parser_url(expr)

    if not url:
        raise Exception("Parser DSL: URL inválida")

    # extrai path após }
    path_match = re.search(r'\}\.(.+)$', expr)

    if not path_match:
        return fetch_and_parse(url)

    path = path_match.group(1)

    data = fetch_and_parse(url)

    return resolve_data_path(data, path, context_name=context_name)

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

            # 🔒 3. Só permite remoção se NÃO houver .syncdownload E NÃO houver base
            show_message(f"Metadata órfã removida: {item}", "d")              

        if re.search(IGNORED_PATHS, dest_full_path, re.IGNORECASE):
            show_message(f"Remoção ignorada [regex]: {dest_full_path}", "W")
            continue

        # --- TRATAMENTO PARA ARQUIVOS GERADOS POR .syncdownload ---
        origin_equivalent_sync = origin_equivalent + ".syncdownload"

        # --- PROTEÇÃO CONDICIONAL POR DIRETÓRIO ---
        has_local_sync = len(local_sync_files) > 0

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
            # --- PROTEÇÃO INTELIGENTE DE DOWNLOADS ---
            if has_local_sync:
                ext = os.path.splitext(dest_full_path)[1].lower().lstrip(".")
                if ext in SyncDonwloadExtensions:
                    show_message(f"Protegido (extensão gerenciada por .syncdownload): {item}", "D")
                    continue

            # Verifica se existe um .syncdownload correspondente na origem
            if os.path.exists(origin_equivalent_sync):
                try:
                    resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                    if not resolved:
                        continue

                    expected_name = resolved.get("filename")

                    # Se o nome bate com o arquivo atual, NÃO remove
                    expected_base = normalize_product_name(expected_name)
                    current_base = normalize_product_name(os.path.basename(dest_full_path))

                    if is_same_product(expected_base, current_base):
                        show_message(f"Protegido por similaridade: {item}", "D")
                        continue
                except Exception:
                    pass

            show_message(f"Removendo do destino (não existe na origem): {rel_path}", "remove")
            if not dry_run:
                try:
                    if os.path.isdir(dest_full_path):
                        shutil.rmtree(dest_full_path)
                    else:
                        os.remove(dest_full_path)
                except OSError as e:
                    show_message(f"Falha ao remover {dest_full_path}: {e}", "e")

        # --- RECURSÃO CONTROLADA ---
        # Executa limpeza em subdiretórios existentes (após possíveis remoções)
        if os.path.isdir(dest_full_path):
            try:
                destination_cleanup(dest_full_path, dry_run)
            except Exception as e:
                show_message(f"Erro ao acessar subdiretório {dest_full_path}: {e}", "e")

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

def _normalize_color(color: str):
    """
    Separa estilo e cor base.
    Ex:
    - 'yellow' → ('', 'yellow')
    - 'bold yellow' → ('bold', 'yellow')
    - 'bright_red' → ('', 'red')
    """
    if not color:
        return "", "cyan"

    parts = color.strip().lower().split()

    # pega última parte como cor
    base_color = parts[-1]

    # remove prefixo bright_ se vier
    base_color = base_color.replace("bright_", "")

    # resto vira estilo
    style = " ".join(parts[:-1])

    return style, base_color

from rich.progress import Progress, TextColumn, BarColumn, DownloadColumn, TransferSpeedColumn, TimeRemainingColumn

def create_progress(task_label, color="cyan"):
    style, base_color = _normalize_color(color)

    # 🔒 monta estilo completo com reset explícito
    label_style = f"{style} {base_color}".strip()

    return Progress(
        TextColumn(f"[{label_style}]{{task.description}}: {{task.fields[name]}}[/]"),
        
        BarColumn(
            complete_style=base_color,
            finished_style=f"bright_{base_color}"
        ),

        TextColumn("[white]{task.percentage:>3.0f}%[/]"),
        DownloadColumn(),
        TransferSpeedColumn(),
        TimeRemainingColumn(),
        transient=True
    )

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
            with create_progress("# Hash", "cyan") as progress:
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
                import ctypes
                FILE_ATTRIBUTE_HIDDEN = 0x02

                attrs = ctypes.windll.kernel32.GetFileAttributesW(dest_full_path)
                if attrs != -1 and not (attrs & FILE_ATTRIBUTE_HIDDEN):
                    ctypes.windll.kernel32.SetFileAttributesW(dest_full_path, attrs | FILE_ATTRIBUTE_HIDDEN)
                    show_message(f"Ocultado: {item}", "d")

        except Exception as e:
            show_message(f"Falha ao ocultar {item}: {e}", "e")            


def purge_similar_installers_safe(dest_dir, target_name, canonical_name=None):
    """
    Descrição: Remove versões antigas de forma segura.
    Parâmetros:
    - dest_dir (str): Diretório destino.
    - target_name (str): Arquivo alvo.
    Retorno:
    - None
    """    
    target_full = os.path.join(dest_dir, target_name)

    if not os.path.exists(target_full):
        return

    # 🔒 prioridade: nome canônico da linha 3
    if canonical_name:
        target_base = normalize_canonical_name(canonical_name)
    else:
        target_base = normalize_product_name(target_name)

    if not target_base:
        return

    # =========================================================
    # 🔒 MODO ESTRITO (quando há subtipo explícito no canônico)
    # =========================================================
    strict_mode = False

    if canonical_name:
        canonical_clean = normalize_canonical_name(canonical_name)
        if canonical_clean and "-" in canonical_clean:
            strict_mode = True        

    candidates = []

    for f in sorted(os.listdir(dest_dir)):
        full = os.path.join(dest_dir, f)

        if not os.path.isfile(full):
            continue

        if f.lower().endswith((".sha256", ".syncado", ".syncdownload")):
            continue

        base = normalize_product_name(f)

        # =========================================================
        # 🔒 PRIORIDADE: comparação canônica (linha 3)
        # =========================================================
        candidate_canonical = normalize_canonical_name(f)

        if candidate_canonical and target_base:
            if candidate_canonical == target_base:
                candidates.append(f)
                continue

            # 🔒 modo estrito → não permite fallback
            if strict_mode:
                continue

        # =========================================================
        # fallback (compatibilidade antiga)
        # =========================================================
        base = normalize_product_name(f)

        if is_same_product(base, target_base):
            candidates.append(f)
            
    if len(candidates) <= 1:
        return

    # 🔒 mantém target + 1 fallback válido
    keep = [target_name]

    for f in candidates:
        if f == target_name:
            continue

        full = os.path.join(dest_dir, f)

        if is_cached_file_valid(full, None):
            keep.append(f)
            break

    for f in candidates:
        if f not in keep:
            try:
                os.remove(os.path.join(dest_dir, f))
                show_message(f"Removido excedente: {f}", "-", cor="yellow")
            except Exception as e:
                show_message(f"Erro ao remover {f}: {e}", "e")                

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

    if os.path.exists(origin_cached_path):

        # 🔒 valida presença de metadata CORRETA por tipo
        ext = os.path.splitext(origin_cached_path)[1].lower()

        has_sha = os.path.exists(origin_cached_path + ".sha256")
        has_syncado = os.path.exists(origin_cached_path + ".syncado")

        valid_metadata = False

        if ext in (".iso", ".img"):
            if has_sha:
                valid_metadata = True
            else:
                show_message(f"Cache sem .sha256 → inválido: {filename}", "w")
        else:
            if has_syncado:
                valid_metadata = True
            else:
                show_message(f"Cache sem .syncado → inválido: {filename}", "w")

        if valid_metadata:
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

def main():
    """
    Descrição: Orquestra execução do pipeline de sincronização.
    """
    global destination_path, failed_files, retent_loop_count

    if len(sys.argv) < 2:
        show_message("Uso: python sync.py <caminho_destino> [dry-run]", "e")
        return

    destination_path = os.path.abspath(sys.argv[1])
    dry_run = "dry-run" in sys.argv

    # 1. LIMPEZA
    show_message("Etapa 1: Iniciando limpeza do destino...", "info")
    if os.path.exists(destination_path):
        destination_cleanup(destination_path, dry_run)

    # 2. DOWNLOAD PRIMEIRO (corrige dupla escrita)
    show_message("Etapa 2: Processando .syncdownload...", "info")
    process_syncdownloads(ORIGIN_PATH, dry_run)

    # 3. CÓPIA DEPOIS
    show_message("Etapa 3: Iniciando cópia da origem...", "info")
    recursive_directory_iteration(ORIGIN_PATH, origin_to_destination, True, dry_run)

    # 4. RETENTATIVA
    MAX_RETRIES = 2
    retry_round = 1

    while failed_files and retry_round <= MAX_RETRIES:
        show_message(
            f"Etapa 4: Retentativa {retry_round}/{MAX_RETRIES} ({len(failed_files)} arquivos)...",
            "warn"
        )
        retent_loop_count = retry_round

        to_retry = failed_files[:]
        failed_files = []

        time.sleep(1)

        for path in to_retry:
            retry_sync(lambda: origin_to_destination(path, False, dry_run))

        # 🔁 mantém consistência: download também pode falhar
        process_syncdownloads(ORIGIN_PATH, dry_run)

        retry_round += 1

    if failed_files:
        show_message(
            f"Falha definitiva após {MAX_RETRIES} tentativas: {len(failed_files)} arquivos",
            "e"
        )

    # 5. PÓS-PROCESSAMENTO
    show_message("Etapa 5: Aplicando ocultação no root...", "info")
    apply_root_hidden_attribute()

    show_message("Processo concluído.", "s")

if __name__ == "__main__":
    main()
