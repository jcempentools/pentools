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

# Caminhos
destination_path = "?"
ORIGIN_PATH = os.path.normpath(SCRIPT_DIR).rstrip(os.path.sep) + os.path.sep

# Atribui uma regex à variável IGNORED_PATHS
IGNORED_PATHS = (
    r"(\.(git(\\|/|$)|vscode|trunk|github|(log|tmp)$)|"    
    r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|"
    r"\.TemporaryItems$|\$Recycle\.Bin$|Recycler$))"
    + "|" +
    '|'.join(
        re.escape(item) + r"$"
        for arg in sys.argv
        if arg.startswith("ignore=")
        for item in arg.split('=', 1)[1].split(',')
    )
    if any(arg.startswith("ignore=") for arg in sys.argv)
    else
    r"(\.(git(\\|/|$)|(log|tmp)$)|"    
    r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|"
    r"\.TemporaryItems$|\$Recycle\.Bin$|Recycler$))"
)

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
            ext = Path(filename).suffix.lower()
            hasher = hashlib.sha256() if ext in ('.iso', '.img') else xxhash.xxh3_64()
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
        return res
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

def normalize_tokens(s):
    """Quebra string em tokens normalizados"""
    return [t for t in re.split(r'[^a-z0-9]+', s.lower()) if t] 

def destination_cleanup(root, dry_run=False):
    """Remove arquivos/pastas no destino que não existem na origem"""
    for item in os.listdir(root):
        dest_full_path = os.path.join(root, item)
        rel_path = os.path.relpath(dest_full_path, destination_path)
        origin_equivalent = os.path.join(ORIGIN_PATH, rel_path)

        # --- IGNORA PASTAS RAIZ apps/ e Drivers/ NO DESTINO ---
        # Se estiver na raiz do destino e for uma dessas pastas, ignora completamente
        if root == destination_path and item in ("apps", "Drivers"):
            show_message(f"Remoção ignorada: {item}", "w")
            continue

        if re.search(IGNORED_PATHS, dest_full_path, re.IGNORECASE):
            show_message(f"Remoção ignorada [regex]: {dest_full_path}", "w")
            continue

        # --- TRATAMENTO PARA ARQUIVOS GERADOS POR .syncdownload ---
        origin_equivalent_sync = origin_equivalent + ".syncdownload"

        if not os.path.exists(origin_equivalent):
            # Verifica se existe um .syncdownload correspondente na origem
            if os.path.exists(origin_equivalent_sync):
                try:
                    with open(origin_equivalent_sync, 'r', encoding='utf-8') as f:
                        first_line = f.readline().strip()

                    expected_name = None

                    expected_name = resolve_filename_from_url(first_line, origin_equivalent_sync)

                    # Se o nome bate com o arquivo atual, NÃO remove
                    if expected_name and os.path.basename(dest_full_path) == expected_name:
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
                try:
                    with open(path, 'r', encoding='utf-8') as f:
                        lines = [l.strip() for l in f.readlines() if l.strip()]

                    if not lines:
                        return

                    url = lines[0]
                    expected_hash = lines[1] if len(lines) > 1 else None

                    # --- NOVO: SUPORTE A GITHUB RELEASE (ext | url) ---
                    # Detecta padrão "extensão | url"
                    # --- NOVO: SUPORTE A GITHUB RELEASE (ext[, arch] | url) ---
                    github_match = re.match(r'^\s*([^|]+)\|\s*(https?://github\.com/[^/]+/[^/]+)\s*$', url, re.IGNORECASE)

                    if github_match:
                        try:
                            raw_spec = github_match.group(1)
                            repo_url = github_match.group(2).rstrip('/')

                            # --- PARSE DOS PARÂMETROS ---
                            parts = [p.strip().lower() for p in raw_spec.split(",") if p.strip()]

                            ext = None
                            arch = None
                            extra_filters = []  # NOVO: filtros adicionais livres

                            for p in parts:
                                if p.startswith("."):
                                    ext = p[1:]
                                elif p in ("x86", "x64", "arm64"):
                                    arch = p
                                else:
                                    extra_filters.append(p)  # qualquer outro termo vira filtro

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
                                    if arch not in tokens:
                                        match_ok = False

                                # 3. Filtros adicionais (TODOS obrigatórios)
                                for f in extra_filters:
                                    if not any(f in t for t in tokens):
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
                                filename = selected_asset.get("name")

                                show_message(f"Asset encontrado: {filename}", "s")

                                # IMPORTANTE: desabilita hash nesse modo
                                expected_hash = None
                            else:
                                show_message(f"Nenhum asset compatível encontrado (.{ext}" + (f", {arch}" if arch else "") + ")", "e")
                                return

                        except Exception as e:
                            show_message(f"Erro ao resolver GitHub release: {e}", "e")
                            return
                    # --- FIM DO BLOCO ---                    

                    # Nome do arquivo (mesma lógica do cleanup)                    
                    # PRESERVA nome vindo do GitHub (se existir)                    
                    filename = None
                    if not filename:
                        filename = resolve_filename_from_url(url, path)

                    final_dest_path = os.path.join(os.path.dirname(dest_path), filename)

                    # Verifica necessidade de download
                    need_download = True

                    if os.path.exists(final_dest_path):
                        if expected_hash:
                            current_hash = hash_file(final_dest_path, "Destino")
                            if current_hash == expected_hash:
                                need_download = False
                        else:
                            need_download = True

                    if need_download:
                        import urllib.request

                        show_message(f"Baixando: {rel_path} -> {filename}", "+")

                        with urllib.request.urlopen(url) as response:
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

                        # Validação
                        if expected_hash:
                            downloaded_hash = hash_file(final_dest_path, "Download")
                            if downloaded_hash != expected_hash:
                                show_message(f"Hash inválido: {filename}", "e")
                            else:
                                show_message(f"Download validado: {filename}", "s")

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
