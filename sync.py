# ==============================================================================
# SYNC ENGINE — CONTRATO OPERACIONAL E DIRETRIZES
# ==============================================================================
#
# OBJETIVO
# - Sincronizar origem → destino com suporte a cópia local e downloads declarativos
# - Detectar releases remotos, atualizar automaticamente e garantir integridade
# - Manter destino limpo, determinístico, idempotente e resiliente
#
# FAIL-SAFE / RESILIÊNCIA / AUTO-RECUPERAÇÃO
# - Execução idempotente e determinística
# - Nunca remover dados sem validação lógica
# - Download apenas quando necessário
# - Validação pós-download (hash/tamanho)
# - Retry automático para falhas transitórias
# - Metadata persistente (.sha256 / .syncado) para recuperação de estado
# - Abort seguro em inconsistências
# - Execução ordenada e validada por etapas
#
# PIPELINE OBRIGATÓRIO
# 1. Limpeza controlada do destino
# 2. Sincronização origem → destino
# 3. Processamento .syncdownload (downloads)
# 4. Retentativa de falhas
# 5. Pós-processamento (atributos)
#
# REGRAS DE NEGÓCIO
# - .syncdownload define downloads declarativos
# - Normalização de nomes para deduplicação
# - Preservar apenas versão válida mais recente
# - Remover instaladores redundantes do mesmo produto
# - Ignorar paths conforme regex configurável
#
# ABSTRAÇÃO DE ORIGENS (OBRIGATÓRIO)
# - Diferentes provedores devem expor interface lógica equivalente
# - Mesma lógica de decisão, validação e metadata
# - Preferir APIs oficiais sempre
# - Evitar parsing HTML/XML heurístico
#
# GUI / UX (REQUISITO)
# - Preservar progressbar inline (rich.progress)
# - Atualização em linha (sem flooding)
# - Feedback visual para hash, download, retry e cópia
#
# ESTILO DE IMPLEMENTAÇÃO (OBRIGATÓRIO)
# - Funções pequenas, específicas e reutilizáveis (microfunções com bom senso)
# - NÃO duplicar lógica em nenhuma parte do código
# - Qualquer regra reutilizável deve existir em uma única função central
# - Exemplos obrigatórios de centralização:
#   • normalização de nomes de aplicativos
#   • decisão de versão mais recente
#   • resolução de nome final de arquivo
#   • validação de integridade
#   • lógica de download
# - Nomeação consistente e descritiva
# - Evitar side-effects implícitos
# - Evitar hardcode desnecessário
# - Centralizar lógica crítica (download, execução, validação, decisão)
# - Logs humanos + machine-readable
# - Código autoexplicativo e baixo acoplamento
#
# DIRETRIZES TÉCNICAS
# - Hash rápido para comparação + SHA256 para integridade
# - Cache em memória para performance
# - Metadata persistente para decisão incremental
# - Logging rotativo
# - Retry controlado e execução incremental
#
# RESTRIÇÕES
# - Não duplicar lógica (qualquer domínio)
# - Não usar parsing HTML se API existir
# - Não remover arquivos sem validação
# - Não alterar UX da progressbar sem decisão explícita
# - Não quebrar compatibilidade de metadata
# ==============================================================================
import os
import sys
import codecs
import shutil
import re
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

__IGNORAR_GITHUB = False

# Variável global para o ID da execução
ID_EXECUCAO = ''.join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(3))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(SCRIPT_DIR, "sync.log")
MAX_LOG_SIZE = 2 * 1024 * 1024  # 5 MB

_log_iniciado = False
retent_loop_count = 0

# Listas de controle
verifieds = []       # Arquivos/pastas já verificados
failed_files = []    # Arquivos que falharam na cópia

sys.stdout = codecs.getwriter('utf-8')(sys.stdout.detach())
sys.stderr = codecs.getwriter('utf-8')(sys.stderr.detach())

# Inicializa o console para mensagens estilizadas
console = Console()

# Dicionário para armazenar hashes temporários em RAM
hash_cache = {}

# Cache de resolução de .syncdownload (pré-processamento)
sync_resolve_cache = {}

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
    "x86", "x64", "arm", "arm64",
    "win", "windows", "linux", "mac",
    "setup", "installer", "install",
    "release", "portable",
    "rc", "beta", "alpha",
    "msi", "exe", "zip"
}

def show_message(txt, tipo=None, cor="white", bold=True, inline=False):
    """Exibe mensagem formatada no console e salva uma versão limpa no log"""
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

    style = f"{'bold ' if bold else ''}{cor}"

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
    show_message(txt, tipo, cor, bold, True)

def hash_file(filename, label):
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
            with Progress(
                TextColumn("[bold lightmagenta]→ Hash {task.fields[label]}: {task.fields[name]}"),
                BarColumn(complete_style="orange3", finished_style="gold1", pulse_style="lightgoldenrod1"),
                TextColumn("[white]{task.percentage:>3.0f}%[/] "),
                transient=True
            ) as progress:
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

def resolve_filename_from_url(url, fallback_path=None):
    """Resolve nome de arquivo a partir de URL, header ou fallback (.syncdownload)"""
    filename = None

    # 1. URL
    url_name = os.path.basename(url.split("?")[0])
    if url_name:
        filename = url_name

    # 2. Header
    try:
        import urllib.request
        req = urllib.request.Request(url, method='HEAD')
        with urllib.request.urlopen(req) as response:
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

def resolve_effective_remote_name(url):
    """
    Resolve nome REAL do arquivo após redirects (SourceForge, etc).
    Prioriza:
    1. URL final após redirect
    2. Content-Disposition
    3. Fallback padrão
    """
    try:
        import urllib.request

        req = urllib.request.Request(url, method="HEAD")

        with urllib.request.urlopen(req) as response:
            # 1. URL final (após redirect)
            final_url = response.geturl()
            name = os.path.basename(final_url.split("?")[0])

            if name and name.lower() != "download":
                return name

            # 2. Header
            cd = response.headers.get("Content-Disposition")
            if cd:
                match = re.search(r'filename="?([^"]+)"?', cd)
                if match:
                    return match.group(1)

    except Exception:
        pass

    # 3. fallback existente
    return resolve_filename_from_url(url)

def resolve_effective_download_url(url):
    """
    Resolve URL final real do arquivo (especialmente SourceForge).
    Segue redirects até obter o binário.
    """
    try:
        import urllib.request

        req = urllib.request.Request(url, method="GET")

        with urllib.request.urlopen(req) as response:
            final_url = response.geturl()
            content_type = response.headers.get("Content-Type", "").lower()

            # Se ainda for HTML, tenta fallback (SourceForge edge case)
            if "text/html" in content_type:
                return None, content_type

            return final_url, content_type

    except Exception:
        return None, None    

def normalize_product_name(filename):
    """
    Normalização avançada com:
    - alias
    - remoção de vendor
    - remoção de versão
    - cache
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
    Score simples baseado em tokens (0 a 1)
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
    """

    target_base = normalize_product_name(target_name)

    if not target_base:
        return

    candidates = []

    for f in os.listdir(dest_dir):
        full = os.path.join(dest_dir, f)

        if not os.path.isfile(full):
            continue

        # 🔒 Nunca tocar em metadata
        if f.lower().endswith((".sha256", ".syncado")):
            continue

        base = normalize_product_name(f)

        same_product = (base == target_base)

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

                    # evita falso positivo em arquivos pequenos (boot, configs embutidos, etc.)
                    MIN_SIZE_BYTES = 10 * 1024 * 1  # 10MB

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

    # 🔒 Garante que o target está presente
    if target_name not in candidates:
        show_message(f"Purga abortada: alvo não encontrado entre candidatos ({target_name})", "w")
        return

    # 🔒 Mantém o target SEMPRE
    to_remove = [f for f in candidates if f != target_name]

    for f in to_remove:
        full = os.path.join(dest_dir, f)

        try:
            os.remove(full)
            show_message(f"Removido instalador antigo: {f}", "-", cor="yellow")
        except Exception as e:
            show_message(f"Erro ao remover {f}: {e}", "e")

# Força extenção compatível com mime-type, sem duplicação e,
# trata bansename para manter apenas o nome do software com
# a extensão real do mime type.
#
# Exemplo para mime type .msi:
# 7zip.7zip =  7zip.7zip.msi
# 7zip.7zip.msi =  7zip.7zip.msi
# 7zip =  7zip.msi
# 7zip.msi =  7zip.msi
# Exemplo complexo:
# Microsoft.PowerShell-7.6.0-rc.1-win-x64.msi = Powershell.msi
def resolve_final_filename(url, path, custom_name=None, github_ext=None):
    """
    Resolve nome final com normalização de produto.
    Garante:
    - Nome estável (ex: powershell.msi)
    - Não duplicação de extensão
    - Compatibilidade com purge
    """

    # --- SEM linha 3 → comportamento original ---
    if not custom_name:
        return resolve_filename_from_url(url, path)

    custom_name = custom_name.strip()

    # --- Extrai extensão existente ---
    match_ext = re.search(r'\.([a-z0-9]{2,5})$', custom_name, re.IGNORECASE)
    existing_ext = match_ext.group(1).lower() if match_ext else None

    # --- Determina extensão final ---
    ext = None

    if github_ext:
        ext = github_ext.lower()
    elif existing_ext:
        ext = existing_ext
    else:
        # fallback URL
        remote_name = resolve_effective_remote_name(url)
        if remote_name and "." in remote_name:
            ext = remote_name.split(".")[-1].lower()

    # --- NORMALIZA NOME DO PRODUTO ---
    base_name = normalize_product_name(custom_name)

    if not base_name:
        # fallback robusto: usa nome limpo preservando identidade
        base_name = re.sub(r'\.[a-z0-9]{2,5}$', '', custom_name.lower())

        # remove espaços e caracteres inválidos básicos
        base_name = re.sub(r'[^a-z0-9]+', '.', base_name).strip('.')    

    # --- MONTA NOME FINAL ---
    if ext:
        return f"{base_name}.{ext}"

    return base_name    

def parse_syncdownload(file_path):
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
                resolved = resolve_parser_expression(url)

                if not isinstance(resolved, str):
                    raise Exception("Parser DSL não retornou URL válida")

                url = resolved
        except Exception as e:
            show_message(f"Erro ao resolver parser DSL: {e}", "e")
            return None, None, None
        
        expected_hash = raw_lines[1].strip() if len(raw_lines) > 1 and raw_lines[1].strip() else None
        custom_filename = raw_lines[2].strip() if len(raw_lines) > 2 and raw_lines[2].strip() else None

        return url, expected_hash, custom_filename

    except Exception as e:
        show_message(f"Erro ao ler .syncdownload {file_path}: {e}", "e")
        return None, None, None

def manage_sync_metadata(final_dest_path, url, expected_hash, github_ext):    
    """
    Decisão unificada de download (independente da origem)

    Ordem:
    1. Arquivo existe?
    2. .syncado existe?
    3. Nome confere?
    4. Hash confere?
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

        current_name = resolve_effective_remote_name(url)

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
            show_message("Sem .sha256 → download necessário", "d")
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
    
def generate_sync_metadata(final_dest_path, url, custom_filename, github_ext):
    """
    Gera arquivos auxiliares (.sha256 / .syncado)
    Universal (independente da origem)
    """    

    try:
        # Sempre gera metadata (regra unificada)

        show_message(f"Gerando arquivos auxiliares: {os.path.basename(final_dest_path)}", "d")

        # SHA256
        sha256_hash = hashlib.sha256()
        with open(final_dest_path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                sha256_hash.update(chunk)

        filename_only = os.path.basename(final_dest_path)
        sha_line = f"{sha256_hash.hexdigest()}  {filename_only}"

        with open(final_dest_path + ".sha256", "w", encoding="utf-8") as f:
            f.write(sha_line + "\n")

        # .syncado sempre registra nome remoto real (controle de versão)
        original_name = resolve_effective_remote_name(url)

        if original_name:
            with open(final_dest_path + ".syncado", "w", encoding="utf-8") as f:
                f.write(original_name)

    except Exception as e:
        show_message(f"Erro ao gerar arquivos auxiliares: {e}", "w") 

def normalize_tokens(s):
    """Quebra string em tokens normalizados"""
    return [t for t in re.split(r'[^a-z0-9]+', s.lower()) if t] 

# --- [Parser DSL Detection / URL Abstraction] ---

def has_parser_expression(value):
    """Detecta presença de expressão parser ${"..."}"""
    if not value:
        return False
    return bool(re.search(r'\$\{\s*["\']https?://[^"\']+["\']\s*\}', value))


def extract_parser_url(value):
    """Extrai URL base de expressão parser"""
    if not value:
        return None
    m = re.search(r'\$\{\s*["\'](https?://[^"\']+)["\']\s*\}', value)
    return m.group(1) if m else None


def has_resolvable_url(value):
    """Detecta URL direta OU indireta (parser DSL)"""
    if not value:
        return False

    if has_parser_expression(value):
        return True

    return bool(re.search(r'https?://', value)) 

def resolve_url_source(value):
    """
    Resolve origem da URL:
    - direta
    - parser DSL
    """

    if not value:
        return None, None

    if has_parser_expression(value):
        return "parser", extract_parser_url(value)

    m = re.search(r'(https?://[^\s]+)', value)
    if m:
        return "direct", m.group(1)

    return None, None   

# --- [Parser DSL Resolver] ---

__PARSER_CACHE = {}
PARSER_CACHE_TTL = 60  # segundos


def _parser_cache_get(url):
    entry = __PARSER_CACHE.get(url)
    if not entry:
        return None

    ts, data = entry
    if time.time() - ts > PARSER_CACHE_TTL:
        return None

    return data


def _parser_cache_set(url, data):
    __PARSER_CACHE[url] = (time.time(), data)


def fetch_and_parse(url):
    """
    Fetch + parse automático (JSON/YAML fallback JSON only)
    """

    cached = _parser_cache_get(url)
    if cached is not None:
        return cached

    import urllib.request
    import json

    req = urllib.request.Request(url, headers={"User-Agent": "sync-engine"})

    with urllib.request.urlopen(req) as response:
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


def resolve_data_path(obj, path):
    """
    Resolve caminho tipo:
    users[0].name
    """

    current = obj

    tokens = re.split(r'\.(?![^\[]*\])', path)

    for token in tokens:
        m = re.match(r'([a-zA-Z0-9_\-]+)(\[(\d+)\])?', token)

        if not m:
            raise Exception(f"Parser DSL inválido: {token}")

        key = m.group(1)
        index = m.group(3)

        if isinstance(current, dict):
            current = current.get(key)
        else:
            raise Exception("Parser DSL: estrutura inválida")

        if index is not None:
            current = current[int(index)]

    return current


def resolve_parser_expression(expr):
    """
    Resolve expressão completa:
    ${"url"}.path.to.value
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

    return resolve_data_path(data, path)       

def resolve_syncdownload_cached(sync_path):
    """
    Resolve completamente um .syncdownload e cacheia resultado.

    Garante:
    - URL final resolvida (GitHub/SourceForge)
    - Nome final determinístico
    - Reutilização em cleanup + download

    NÃO realiza download
    """

    if sync_path in sync_resolve_cache:
        return sync_resolve_cache[sync_path]

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
    github_ext = None

    if spec and "github.com" in url.lower() and not __IGNORAR_GITHUB:
        try:
            import urllib.request
            import json

            parts = [p.strip().lower() for p in spec.split(",") if p.strip()]

            ext = None
            arch = None
            include_filters = []
            exclude_filters = []

            for p in parts:
                if p.startswith("."):
                    ext = p[1:]
                    github_ext = ext
                elif p in ("x86", "x64", "arm64"):
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

                with urllib.request.urlopen(api_url) as response:
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

    # --- nome final ---
    filename = resolve_final_filename(
        url=url,
        path=sync_path,
        custom_name=custom_filename,
        github_ext=github_ext
    )

    result = {
        "url": url,
        "filename": filename,
        "expected_hash": expected_hash,
        "github_ext": github_ext
    }

    sync_resolve_cache[sync_path] = result
    return result    

def destination_cleanup(root, dry_run=False):
    """Remove arquivos/pastas no destino que não existem na origem"""
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
            show_message(f"Remoção protegida: {item}", "D")
            base_file = re.sub(r'\.(sha256|syncado)$', '', dest_full_path, flags=re.IGNORECASE)

            # mantém se o arquivo principal existir
            if os.path.exists(base_file):
                continue

            # fallback: tenta validar via .syncdownload correspondente
            origin_equivalent_sync = origin_equivalent + ".syncdownload"
            if os.path.exists(origin_equivalent_sync):
                continue

            # caso contrário, pode remover (metadata órfã)                   

        if re.search(IGNORED_PATHS, dest_full_path, re.IGNORECASE):
            show_message(f"Remoção ignorada [regex]: {dest_full_path}", "W")
            continue

        # --- TRATAMENTO PARA ARQUIVOS GERADOS POR .syncdownload ---
        origin_equivalent_sync = origin_equivalent + ".syncdownload"

        if not os.path.exists(origin_equivalent):
            # Verifica se existe um .syncdownload correspondente na origem
            if os.path.exists(origin_equivalent_sync):
                try:
                    resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                    if not resolved:
                        continue

                    expected_name = resolved.get("filename")

                    # Se o nome bate com o arquivo atual, NÃO remove
                    if expected_name and os.path.basename(dest_full_path) == expected_name:
                        show_message(f"Remoção protegida .syncdownload: {item}", "D") 
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

def origin_to_destination(path, retry, dry_run):
    """Sincroniza da origem para o destino com tratamento de erro WinError 1392"""
    global failed_files
    rel_path = os.path.relpath(path, ORIGIN_PATH)
    dest_path = os.path.join(destination_path, rel_path)

    try:
        if os.path.isdir(path):
            if not dry_run:
                os.makedirs(dest_path, exist_ok=True)
            return

        if not dry_run:
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)

            # --- TRATAMENTO PARA .syncdownload ---
            if path.lower().endswith(".syncdownload"):
                show_message(f"Sincronização online: {os.path.splitext(os.path.basename(path))[0]}")

                try:
                    resolved = resolve_syncdownload_cached(path)

                    if not resolved:
                        return

                    url = resolved["url"]
                    expected_hash = resolved["expected_hash"]
                    custom_filename = None  # já incorporado no filename final
                    github_ext = resolved["github_ext"]

                    # --- NORMALIZAÇÃO UNIVERSAL spec | url ---
                    spec = None

                    if url and "|" in url:
                        try:
                            left, right = url.split("|", 1)

                            right = right.strip()

                            # só aceita se lado direito for URL válida
                            if right.startswith("http://") or right.startswith("https://"):
                                spec = left.strip()
                                url = right
                            else:
                                spec = None

                        except Exception:
                            spec = None                    

                    if not url:
                        return                  
                                                            
                    github_ext = None                    

                    github_match = None

                    if spec and "github.com" in url.lower():
                        github_match = True

                    if github_match and not __IGNORAR_GITHUB:
                        try:
                            raw_spec = spec
                            repo_url = url.rstrip('/')

                            github_ext = None 

                            # --- PARSE DOS PARÂMETROS ---
                            parts = [p.strip().lower() for p in raw_spec.split(",") if p.strip()]

                            ext = None
                            arch = None
                            include_filters = []
                            exclude_filters = []

                            for p in parts:
                                if p.startswith("."):
                                    ext = p[1:]
                                    github_ext = ext
                                elif p in ("x86", "x64", "arm64"):
                                    arch = p
                                elif p.startswith("!"):
                                    exclude_filters.append(p[1:])
                                else:
                                    include_filters.append(p)

                            if not ext:
                                show_message("Extensão não informada no padrão GitHub (.ext obrigatório)", "e")
                                return

                            # Monta endpoint da API
                            api_url = repo_url.replace("github.com", "api.github.com/repos") + "/releases/latest"

                            import urllib.request
                            import json

                            show_message(f"Detectado padrão GitHub: .{ext}" + (f", {arch}" if arch else ""), "d")                            

                            with urllib.request.urlopen(api_url) as response:
                                data = json.loads(response.read().decode())

                            assets = data.get("assets", [])

                            if not assets:
                                show_message("Release não possui assets", "e")
                                return                            

                            # --- MATCH ESTRITO: TODOS OS CRITÉRIOS DEVEM CASAR ---
                            selected_candidates = []

                            for asset in assets:
                                name = asset.get("name", "")
                                tokens = normalize_tokens(name)

                                # 1. Extensão (obrigatória)
                                clean_name = name.lower().split('?')[0].split('#')[0]
                                if not clean_name.endswith(f".{ext}"):
                                    continue
                                
                                match_ok = True

                                # 2. Arquitetura (se informada → obrigatória)
                                if arch:
                                    if not any(arch in t for t in tokens):
                                        match_ok = False

                                # 3. Filtros positivos (TODOS obrigatórios)
                                for f in include_filters:
                                    if not any(f in t for t in tokens):
                                        match_ok = False
                                        break

                                # 4. Filtros negativos (NENHUM pode existir)
                                if match_ok:
                                    for f in exclude_filters:
                                        if any(f in t for t in tokens):
                                            match_ok = False
                                            break

                                if match_ok:
                                    selected_candidates.append(asset)

                            # Seleção final
                            if len(selected_candidates) == 1:
                                selected_asset = selected_candidates[0]

                            elif len(selected_candidates) > 1:
                                # Critério simples e determinístico: maior arquivo
                                selected_asset = max(selected_candidates, key=lambda a: a.get("size", 0))
                                show_message(f"Múltiplos matches encontrados, selecionado maior arquivo", "w")

                            else:
                                selected_asset = None
                            # --- FIM DO MATCH ---

                            if selected_asset:
                                url = selected_asset.get("browser_download_url")

                                show_message(f"Asset encontrado: {selected_asset.get('name')}", "s")

                                # Mantém hash se fornecido externamente (mais confiável que heurística de asset)
                                # expected_hash NÃO deve ser sobrescrito aqui
                            else:
                                show_message(f"Nenhum asset compatível encontrado (.{ext}" + (f", {arch}" if arch else "") + ")", "e")
                                return

                        except Exception as e:
                            show_message(f"Erro ao resolver GitHub release: {e}", "e")
                            return
                    # --- FIM DO BLOCO ---                    

                    # Nome do arquivo (mesma lógica do cleanup)                    
                    # PRESERVA nome vindo do GitHub (se existir)                    
                    filename = resolved["filename"]

                    dest_dir = os.path.dirname(dest_path)

                    final_dest_path = os.path.join(dest_dir, filename)                    
                    
                    # Verifica necessidade de download (centralizado)
                    need_download = manage_sync_metadata(
                        final_dest_path=final_dest_path,
                        url=url,
                        expected_hash=expected_hash,                        
                        github_ext=github_ext
                    )

                    # log explícito de decisão ---
                    if github_ext and need_download:
                        show_message(f"GitHub: download necessário (arquivo ausente/desatualizado): {filename}", "i")                                

                    if need_download:
                        import urllib.request

                        show_message(f"Baixando: {rel_path} -> {filename}", "+")

                        with urllib.request.urlopen(url) as response:
                            final_url, content_type = resolve_effective_download_url(url)

                            if not final_url:
                                show_message(f"Falha ao resolver download real (HTML detectado): {url}", "e")
                                return

                            # --- EXTENSÃO VIA CONTENT-TYPE (fallback seguro) ---
                            def guess_ext_from_content_type(ct):
                                if "application/x-msdownload" in ct or "application/octet-stream" in ct:
                                    return None  # não força
                                if "application/x-msi" in ct:
                                    return "msi"
                                if "application/zip" in ct:
                                    return "zip"
                                return None

                            ext_from_ct = guess_ext_from_content_type(content_type or "")

                            if "." not in filename and ext_from_ct:
                                filename = f"{filename}.{ext_from_ct}"
                                final_dest_path = os.path.join(dest_dir, filename)

                            # --- DOWNLOAD REAL ---
                            with urllib.request.urlopen(final_url) as response:
                                total_size = int(response.headers.get('Content-Length', 0))
                                chunk_size = 65536

                                with Progress(
                                    TextColumn("[bold lightmagenta]→ Download: {task.fields[name]}"),
                                    BarColumn(),
                                    TaskProgressColumn(),
                                    DownloadColumn(),
                                    TransferSpeedColumn(),
                                    TimeRemainingColumn(),
                                    transient=True
                                ) as progress:
                                    task = progress.add_task("", total=total_size, name=filename)

                                    with open(final_dest_path, 'wb') as out_file:
                                        while True:
                                            chunk = response.read(chunk_size)
                                            if not chunk:
                                                break
                                            out_file.write(chunk)
                                            progress.update(task, advance=len(chunk))                                                                    

                                # --- VALIDAÇÃO LEVE (sem hash) ---
                                if not expected_hash:
                                    try:
                                        file_size = os.path.getsize(final_dest_path)

                                        # 1. Arquivo vazio
                                        if file_size == 0:
                                            raise Exception("arquivo vazio")

                                        # 2. Validação por Content-Length (se disponível)
                                        if total_size > 0 and file_size != total_size:
                                            raise Exception(f"tamanho divergente ({file_size} != {total_size})")

                                    except Exception as e:
                                        show_message(f"Falha no download: {filename} ({e})", "e")

                                        # 🧹 Remove arquivo corrompido antes do retry
                                        try:
                                            if os.path.exists(final_dest_path):
                                                os.remove(final_dest_path)
                                        except Exception:
                                            pass

                                        # 🔁 Integra com sistema de retry existente
                                        if retry and path not in failed_files:
                                            show_message(f"Adicionado para retentativa: {rel_path}", "w")
                                            failed_files.append(path)

                                        return                                                               

                        # Validação
                        # --- VALIDAÇÃO POR HASH EXTERNO (linha 2) ---
                        valid_download = True

                        if expected_hash:
                            downloaded_hash = hash_file(final_dest_path, "Download")

                            if downloaded_hash != expected_hash.lower():
                                show_message(f"Hash inválido: {filename}", "e")
                                valid_download = False
                            else:
                                show_message(f"Download validado: {filename}", "s")

                        # --- VALIDAÇÃO LEVE (quando não há hash) ---
                        if not expected_hash:
                            try:
                                file_size = os.path.getsize(final_dest_path)

                                if file_size == 0:
                                    raise Exception("arquivo vazio")

                                if total_size > 0 and file_size != total_size:
                                    raise Exception(f"tamanho divergente ({file_size} != {total_size})")

                            except Exception as e:
                                show_message(f"Falha no download: {filename} ({e})", "e")
                                valid_download = False

                        # --- PIPELINE FINAL ---
                        if valid_download:
                            if not dry_run:
                                pass  # hook intencional (pipeline extensível)

                            purge_similar_installers(dest_dir, filename)

                            # Metadata SEMPRE após sucesso
                            generate_sync_metadata(
                                final_dest_path=final_dest_path,
                                url=url,
                                custom_filename=custom_filename,
                                github_ext=github_ext
                            )
                        else:
                            # Remove arquivo inválido (fail-safe)
                            try:
                                if os.path.exists(final_dest_path):
                                    os.remove(final_dest_path)
                            except Exception:
                                pass                                                

                except Exception as e:
                    show_message(f"Erro no .syncdownload {rel_path}: {e}", "e")

                return
            # --- FIM DO TRATAMENTO ---

            # Lógica simples de cópia (exemplo: se não existe ou hash diferente)
            if not os.path.exists(dest_path) or hash_file(path, "Origem") != hash_file(dest_path, "Destino"):
                show_message(f"Copiando: {rel_path}", "+")
                shutil.copy2(path, dest_path)
    
    except OSError as e:
        show_message(f"Erro no sistema de arquivos em {rel_path}: {e}", "e")
        if retry and path not in failed_files:
            show_message(f"Adicionado para retentativa: {rel_path}", "w")
            failed_files.append(path)

def recursive_directory_iteration(root, action, retry, dry_run):
    """Percorre os diretórios recursivamente aplicando a ação"""
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
    """Oculta arquivos/pastas no root do destino que existem na origem (exceto exceções)"""
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
            else:
                # Fallback Unix (renomeia com ponto)
                if not os.path.basename(dest_full_path).startswith("."):
                    hidden_path = os.path.join(destination_path, "." + item)
                    os.rename(dest_full_path, hidden_path)
                    show_message(f"Ocultado (unix): {item}", "d")

        except Exception as e:
            show_message(f"Falha ao ocultar {item}: {e}", "e")            

def main():
    global destination_path, failed_files, retent_loop_count
    
    if len(sys.argv) < 2:
        show_message("Uso: python sync.py <caminho_destino> [dry-run]", "e")
        return

    destination_path = os.path.abspath(sys.argv[1])
    dry_run = "dry-run" in sys.argv

    # 1. LIMPEZA PRIMEIRO
    show_message("Etapa 1: Iniciando limpeza do destino...", "info")
    if os.path.exists(destination_path):
        destination_cleanup(destination_path, dry_run)

    # 2. CÓPIA DEPOIS
    show_message("Etapa 2: Iniciando cópia da origem...", "info")
    recursive_directory_iteration(ORIGIN_PATH, origin_to_destination, True, dry_run)

    # 3. RETENTATIVA POR ÚLTIMO
    if failed_files:
        show_message(f"Etapa 3: Retentando {len(failed_files)} arquivos que falharam...", "warn")
        retent_loop_count = 1
        to_retry = failed_files[:]
        failed_files = [] # Limpa para o relatório final
        time.sleep(1)
        for path in to_retry:
            origin_to_destination(path, False, dry_run)

    # 4. OCULTAR ITENS DO ROOT (PÓS-PROCESSAMENTO)
    show_message("Etapa 4: Aplicando ocultação no root...", "info")
    apply_root_hidden_attribute()

    show_message("Processo concluído.", "s")

if __name__ == "__main__":
    main()
