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

# Atribui uma regex à variável IGNORED_PATHS, incluindo:
# - Padrões fixos para arquivos do sistema/exFAT
# - Padrões adicionais passados via linha de comando como: ignore=foo,bar
IGNORED_PATHS = (
    # Regex base para ignorar padrões comuns de arquivos e pastas do sistema
    r"(\.(git(\\|/|$)|(log|tmp)$)|"                  # .git, .log, .tmp
    r"^(\\|/)?(minios|Disk ?Backup|DiskImage)(\\|/|$)|"  # minios, Disk Backup, DiskImage
    r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|"
    r"\.TemporaryItems$|\$Recycle\.Bin$|Recycler$))"

    # Se existir algum argumento 'ignore=', adiciona os padrões personalizados
    + "|" +
    '|'.join(
        re.escape(item) + r"$"                       # Escapa e finaliza com $, para casar nomes exatos
        for arg in sys.argv                          # Itera sobre os argumentos da linha de comando
        if arg.startswith("ignore=")                 # Filtra os argumentos que começam com 'ignore='
        for item in arg.split('=', 1)[1].split(',')  # Divide o valor de 'ignore=' em itens separados
    )

    # Caso não haja nenhum argumento 'ignore=', apenas usa a regex base
    if any(arg.startswith("ignore=") for arg in sys.argv)
    else
    r"(\.(git(\\|/|$)|(log|tmp)$)|"                  # (repetição da base)
    r"^(\\|/)?(minios|Disk ?Backup|DiskImage)(\\|/|$)|"
    r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|"
    r"\.TemporaryItems$|\$Recycle\.Bin$|Recycler$))"
)

def show_message(txt, tipo=None, cor="white", bold=True, inline=False):
    """Exibe mensagem formatada no console e salva uma versão limpa no log, com ID de execução"""
    global _log_iniciado, retent_loop_count

    # Função para limpar a formatação Rich
    def limpar_formatacao_rich(mensagem):
        """
        Remove formatação Rich (como [bold red]...[/bold red] ou [green]...[/])
        mas preserva colchetes literais como [INFO], [ERROR], etc.
        """
        # Remove blocos completos [style]...[/style]
        mensagem = re.sub(r'\[(\w[^\]]*)\](.*?)\[/\1\]', r'\2', mensagem)
        # Remove blocos auto-encerrados tipo [style]...[/]
        mensagem = re.sub(r'\[(\w[^\]]*)\](.*?)\[/\]', r'\2', mensagem)
        return mensagem.strip()

    # Função para truncar o log, caso o tamanho exceda o limite
    def truncar_log_se_necessario():
        """Trunca o arquivo de log para manter o tamanho máximo definido."""
        if not os.path.isfile(LOG_FILE):
            return

        tamanho = os.path.getsize(LOG_FILE)
        if tamanho <= MAX_LOG_SIZE:
            return

        # Mantém apenas os últimos bytes dentro do limite
        with open(LOG_FILE, 'rb') as f:
            f.seek(-MAX_LOG_SIZE, os.SEEK_END)
            conteudo = f.read()

            # Garante que a primeira linha após truncamento esteja completa
            primeiro_nl = conteudo.find(b'\n')
            conteudo = conteudo[primeiro_nl + 1:] if primeiro_nl != -1 else conteudo

        with open(LOG_FILE, 'wb') as f:
            f.write(conteudo)

    # Funções para exibir a mensagem
    tipos_demo = {
        "i": ("I", "cyan"),      
        "e": ("E", "bright_magenta"),
        "w": ("W", "yellow"),    
        "d": ("D", "bright_black"),
        "s": ("✓", "green"),    
        "k": ("✓", "dodger_blue2"),
        "+": ("+", "bright_green"), 
        "-": ("-", "bright_red"),   
    }

    aliases = {
        "info": "i", "error": "e", "warn": "w", "warning": "w",
        "debug": "d", "success": "s", "sucesso": "s",
        "ok": "k", "added": "+", "add": "+",
        "removed": "-", "remove": "-", "del": "-"
    }

    # Se o tipo for passado, verificamos se é válido
    if tipo is not None:
        tipo_str = aliases.get(str(tipo).lower(), str(tipo).lower())
        if tipo_str not in tipos_demo:
            raise ValueError(f"Tipo de mensagem desconhecido: {tipo}")
        
        marcador, cor_definida = tipos_demo[tipo_str]
        cor = cor_definida
        # Usar a versão reduzida para a exibição e log
        txt = f"[{marcador}] {txt}"

    if retent_loop_count > 0:
        txt = f"(Retry: {retent_loop_count}) {txt}"

    style = f"{'bold ' if bold else ''}{cor}"

    # Exibição no console
    if inline:
        terminal_width = os.get_terminal_size().columns
        console.print(' ' * terminal_width, end='\r')        
    
    console.print(f"[{style}]{txt}[/{style}]", end=f"{'\r' if inline else '\n'}")

    # Escrita no log com ID de execução
    mensagem_limpa = limpar_formatacao_rich(txt)
    timestamp = datetime.now().strftime("[%H:%M:%S] ")
    truncar_log_se_necessario()
    
    # Gravando o log com o ID da execução
    with open(LOG_FILE, 'a', encoding='utf-8') as f_log:
        if not _log_iniciado:
            f_log.write("\n")
            f_log.write(f"[   ] {timestamp} " + "-" * 40 + "\n")
            f_log.write(f"[   ] {timestamp} Início execução ID '{ID_EXECUCAO}', {datetime.now().strftime('%Y-%m-%d')}\n")
            _log_iniciado = True

        f_log.write(f"[{ID_EXECUCAO}] {timestamp} {mensagem_limpa}\n")

# EXIBE NA MESMA LINHA
def show_inline(txt, tipo, cor="white", bold=True):
    show_message(txt, tipo, cor, bold, True)

# Função para calcular hash (xxHash ou SHA-256 para .iso/.img)
def hash_file(filename, label):
    filename = str(filename) if isinstance(filename, Path) else filename

    """Calcula hash de um arquivo. Usa xxHash para geral e SHA-256 para .iso/.img."""
    if os.path.isdir(filename):
        return 1        

    # Verifica se o hash já foi calculado e está no cache
    cached_hash = hash_cache.get(filename)
    if cached_hash:
        return cached_hash

    try:
        file_size = os.path.getsize(filename)
        with open(filename, 'rb') as file:
            ext = Path(filename).suffix.lower()
            if ext in ('.iso', '.img'):
                hasher = hashlib.sha256()
            else:
                hasher = xxhash.xxh3_64()

            file_name = os.path.basename(filename)  
            
            bar_complete_style = "orange3"
            bar_finished_style = "gold1"
            bar_pulse_style = "lightgoldenrod1"

            with Progress(
                TextColumn("[bold lightmagenta]→ Hash {task.fields[label]}: {task.fields[name]}"),
                BarColumn(
                    bar_width=None,
                    complete_style=bar_complete_style,
                    finished_style=bar_finished_style,
                    pulse_style=bar_pulse_style
                ),
                TextColumn(
                    "[white]{task.percentage:>3.0f}%[/] "
                ),
                transient=True
            ) as progress:
                task = progress.add_task(
                    "", total=file_size,
                    label=label, name=file_name
                )
                progress.update(task, advance=0)
                while chunk := file.read(4096):
                    hasher.update(chunk)
                    progress.update(task, advance=len(chunk))

            # Salva o hash no cache
            hash_value = hasher.hexdigest()
            hash_cache[filename] = hash_value
            return hash_value
    except Exception as e:
        show_message(f"Erro ao calcular hash de '{filename}': {e}", "e")
        return None

    return 2

# Função para criar arquivo .sha256
def create_hash_file(filename, hash_type='sha256'):
    """Cria arquivo de hash para .iso/.img, usando o hash calculado ou cache de RAM."""
    try:
        if os.path.exists(f"{filename}.{hash_type}"):
            return

        # Usa o hash calculado anteriormente ou do cache
        hash_value = hash_file(filename, "origem")

        if hash_value:
            with open(f"{filename}.{hash_type}", 'w') as f_hash:
                f_hash.write(f"{hash_value}  {os.path.basename(filename)}\n")
            show_message(f"Hash {filename}.{hash_type} criado com sucesso.", "i")
        else:
            show_message(f"Não foi possível calcular o hash para '{filename}'","e")

    except Exception as e:
        show_message(f"Erro ao criar hash de '{filename}': {e}", "e")

# Função para log de mensagens
def log_message(message):
    """Escreve mensagem no log, mantendo tamanho máximo."""
    if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > MAX_LOG_SIZE:
        with open(LOG_FILE, 'w') as f_log:
            f_log.write(f"Log reiniciado: {message}\n")
    else:
        with open(LOG_FILE, 'a') as f_log:
            f_log.write(f"{message}\n")

# Função para copiar arquivos com barra de progresso
def copy_file_sync(src, dst, retry=True, dry_run=False):
    """Copia arquivos com barra de progresso, sem verificação de hash pós-cópia."""
    copy = False
    cp_meta = False

    try:
        if not os.path.exists(dst):
            copy = True
        else:
            if os.path.getsize(src) != os.path.getsize(dst):
                copy = True
            elif os.path.getmtime(src) > os.path.getmtime(dst):
                copy = True
            elif os.path.getmtime(src) < os.path.getmtime(dst) and "-f" in sys.argv:
                copy = True
            else:
                hash_src = hash_file(src, "origem")
                hash_dst = hash_file(dst, "destino")

                if hash_src is None:
                    if retry:
                        failed_files.append([src, 'cp'])
                        show_message(f"Retentar Checagem: '{os.path.basename(src)}'.", "w")
                        return False

                if hash_src != hash_dst:
                    copy = True
                else:
                    cp_meta = True

        if copy and not dry_run:
            file_size = os.path.getsize(src)

            if os.path.exists(dst):
                os.remove(dst)

            with open(src, 'rb') as f_in, open(dst, 'wb') as f_out:
                bar_complete_style = "orange3"
                bar_finished_style = "gold1"
                bar_pulse_style = "lightgoldenrod1"

                with Progress(
                    TextColumn("[bold lightmagenta]→ Copiando {task.fields[name]}"),
                    BarColumn(
                        bar_width=None,
                        complete_style=bar_complete_style,
                        finished_style=bar_finished_style,
                        pulse_style=bar_pulse_style
                    ),
                    TextColumn(
                        "[white]{task.percentage:>3.0f}%[/] "
                    ),
                    transient=True
                ) as progress:
                    task = progress.add_task(
                        "", total=file_size,
                        name=os.path.basename(src)
                    )
                    while chunk := f_in.read(4096):
                        f_out.write(chunk)
                        progress.update(task, advance=len(chunk))

            show_message(f"Arquivo Copiado: '{os.path.basename(src)}'.", "+")

        elif cp_meta:
            show_message(f"Já sincronizado: '{os.path.basename(src)}'.", "k")
        
        else:
            show_message(f"Retentar Cópia.: '{os.path.basename(src)}'.", "w")

        if copy or cp_meta:
            shutil.copystat(src, dst)

        return os.path.exists(dst)

    except Exception as e:
        show_message(f"Erro ao copiar '{src}': {e}", "e")
        if retry:
            failed_files.append([src, 'cp'])
            show_message(f"Retentar Cópia.: '{os.path.basename(src)}'.", "w")

    return False    

# Função para iterar recursivamente pela origem
def recursive_directory_iteration(directory, action, retry=True, dry_run=False):
    """Itera recursivamente pelos arquivos e pastas da origem."""
    for root, subdirs, files in os.walk(directory):
        for file in files:
            action(os.path.join(root, file), retry, dry_run)
        for subdir in subdirs:
            action(os.path.join(root, subdir), retry, dry_run)
            recursive_directory_iteration(os.path.join(root, subdir), action, retry, dry_run)

def trocar_prefixo(caminho_alvo, prefixo_antigo, prefixo_novo):
    """
    Substitui o prefixo de um caminho pelo novo prefixo, mantendo o separador correto.
    """
    caminho_alvo = Path(caminho_alvo).resolve(strict=False)
    prefixo_antigo = Path(prefixo_antigo).resolve(strict=False)
    prefixo_novo = Path(prefixo_novo).resolve(strict=False)

    try:
        sufixo = caminho_alvo.relative_to(prefixo_antigo)
    except ValueError:
        raise ValueError(f"O caminho '{caminho_alvo}' não começa com '{prefixo_antigo}'")

    # Retornar o novo caminho com o novo prefixo
    novo_caminho = prefixo_novo / sufixo

    # Ajuste para Windows, se necessário
    return novo_caminho.as_posix() if Path().drive else novo_caminho

# Função que verifica e sincroniza cada item da origem
def origin_to_destination(path, retry=True, dry_run=False):
    """Sincroniza arquivo/pasta da origem para o destino."""
    if bool(re.search(IGNORED_PATHS, path)):
        return  # Arquivo ou pasta ignorada

    global destination_path, ORIGIN_PATH, verifieds
    
    dest_path = trocar_prefixo(path, ORIGIN_PATH, destination_path)

    if dest_path not in verifieds:
        verifieds.append(dest_path)                
        
        show_inline(f"Verificando '{path.replace(ORIGIN_PATH, '')}'...", "i")

        if os.path.exists(dest_path):
            if not os.path.isdir(dest_path):
                return copy_file_sync(path, dest_path, retry, dry_run)
        else:
            if os.path.isdir(path):
                os.makedirs(dest_path, exist_ok=True)
            else:
                if path.endswith(('.iso', '.img')):
                    create_hash_file(path)
                if not dry_run:
                    return copy_file_sync(path, dest_path, retry, dry_run)

    return False

# Função que remove arquivos/pastas no destino que não existem mais na origem
def remove_from_destination(path, retry=True, dry_run=False):
    """Remove arquivos ou pastas do destino que não existem na origem."""
    global destination_path, ORIGIN_PATH

    src_path = trocar_prefixo(path, destination_path, ORIGIN_PATH)    

    show_inline(f"Deletar? '{path}'", "i")

    if not os.path.exists(path):
        show_message(f"Já inexiste.....: '{path.replace(destination_path,'')}'.", "k")
    elif not os.path.exists(src_path):
        if dry_run:
            show_message(f"[DRY RUN] Deletaria '{path.replace(destination_path,'')}'", "-")
            return True

        try:
            if os.path.isdir(path):
                shutil.rmtree(path)                
                show_message(f"Pasta Removida..: '{path.replace(destination_path,'')}'.", "-")
            else:
                os.remove(path)
                show_message(f"Arquivo Removido: '{path.replace(destination_path,'')}'.", "-")
        except Exception as e:
            show_message(f"Erro ao remover '{path.replace(destination_path,'')}': {e}", "e")
            if retry:
                failed_files.append([path, 'rm'])
                show_message(f"Retentar Remover: '{os.path.basename(path)}'.", "w")

            return False
        
    return True

# Função principal
def main():
    global retent_loop_count, destination_path

    # Verifica argumento do destino
    if len(sys.argv) < 2:
        show_message("Caminho de destino não fornecido.", "e")
        sys.exit(1)

    # obten caminho destino
    destination_path = os.path.normpath(sys.argv[1]).rstrip(os.path.sep) + os.path.sep

    # Valida caminho destino
    if not os.path.exists(destination_path):
        show_message("Caminho de destino não existe.", "e")
        sys.exit(2)
    if not os.path.isdir(destination_path):
        show_message("Caminho de destino não é uma pasta.", "e")
        sys.exit(3)    

    dry_run = '--dry-run' in sys.argv

    show_message(f"\n\n::: Inicializando sincronização, ID = '{ID_EXECUCAO}'.", None, "gold3")
    show_message("\n::: Estapa 1/3: Transferir conteúdo.", None, "gold3")

    # Primeira etapa: sincronizar arquivos da origem
    recursive_directory_iteration(ORIGIN_PATH, origin_to_destination, True, dry_run=dry_run)

    show_message("Concluido 1/3 - Transferências.", "i")
    show_message("\n\n::: Estapa 2/3: Limpar Destino.", None, "gold3")

    # Segunda etapa: remover do destino o que não existe na origem
    recursive_directory_iteration(destination_path, remove_from_destination, True, dry_run=dry_run)

    show_message("Concluido 2/3 - Limpeza.", "i")
    show_message("\n\n::: Estapa 3/3: Retentar arquivos falhados.", None, "gold3")

    # Tentativas de recópia de arquivos que falharam    
    if len(failed_files)> 0:
        show_message(f"Há {len(failed_files)} arquivos a serem retentados.", "i")
         
        retent_loop_count = 1
        while len(failed_files)> 0 and retent_loop_count < 11:
            show_message(f"\nRetentando arquivos com falha...\n", None, "yellow")
            time.sleep(5)

            for file, tipo in failed_files[:]:                                
                show_message(f"Retentando ({tipo}) '{file}'", "i")
                if tipo == 'cp':                    
                    if origin_to_destination(file, True, dry_run=dry_run):
                        failed_files.remove([file, tipo])
                elif tipo == 'rm':
                    if remove_from_destination(file, True, dry_run=dry_run):
                        failed_files.remove([file, tipo])
                    
            retent_loop_count += 1

        retent_loop_count = 0

        if  len(failed_files) > 0:
            show_message("Terminado: Alguns arquivos falharam: {failed_files}.", "i")
        else:
            show_message("Terminado: Todos retentados com sucesso.", "i")
    else:
        show_message("Não há arquivos a serem retentados.", "i")

    show_message("Concluido 3/3 - Retentagem.", "i")
    show_message("FIM - tudo sincronizado.", "i")

# Executa o script
if __name__ == "__main__":
    main()
