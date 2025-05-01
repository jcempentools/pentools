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

sys.stdout = codecs.getwriter('utf-8')(sys.stdout.detach())
sys.stderr = codecs.getwriter('utf-8')(sys.stderr.detach())

# Inicializa o console para mensagens estilizadas
console = Console()

# Dicionário para armazenar hashes temporários em RAM
hash_cache = {}

def show_message(txt, cor="white", bold=True, inline=False):
    """Exibe mensagem com cor e estilo, opcionalmente sobrescrevendo a linha atual."""
    style = f"{'bold ' if bold else ''}{cor}"
    if inline:
        terminal_width = os.get_terminal_size().columns
        console.print(' ' * terminal_width, end='\r')  # Limpa a linha
        console.print(f"[{style}]{txt}[/{style}]", end='\r')
    else:
        console.print(f"[{style}]{txt}[/{style}]")
  

def show_inline(txt, cor="white", bold=True):
    show_message(txt, cor, bold, True)

# Regex para ignorar arquivos e pastas específicas
# Regex para ignorar arquivos e pastas específicas, incluindo exFAT e Lixeira
# Função para obter arquivos e diretórios a serem ignorados via parâmetro no console
def get_ignored_files_and_dirs():
    """Captura arquivos e diretórios a serem ignorados passados por parâmetro no console."""
    ignore_param = None
    for arg in sys.argv:
        if arg.startswith("ignore="):
            ignore_param = arg.split('=')[1]
            break
    
    # Se parâmetros de ignorar forem passados, cria lista de arquivos e diretórios
    if ignore_param:
        ignored_files_and_dirs = ignore_param.split(',')
        return ignored_files_and_dirs
    return []

# Adiciona os arquivos e diretórios ignorados à regex
def build_ignore_regex():
    ignored_files_and_dirs = get_ignored_files_and_dirs()
    
    # Regex base para arquivos do sistema e exFAT
    base_ignore_regex = r"(\.(git(\\|/|$)|(log|tmp)$)|^(\\|/)?(minios|Disk ?Backup|DiskImage)(\\|/|$)|" \
                        r"(\.fseventsd$|\.Trashes$|\.Spotlight$|\.AppleDouble$|\.TemporaryItems$|" \
                        r"\$Recycle\.Bin$|Recycler$))"
    
    # Adiciona arquivos e diretórios customizados passados por parâmetro
    if ignored_files_and_dirs:
        custom_ignore_regex = '|'.join([re.escape(item) + r"$" for item in ignored_files_and_dirs])
        return base_ignore_regex + "|" + custom_ignore_regex
    return base_ignore_regex

# Regex para ignorar arquivos e pastas específicas, incluindo exFAT e Lixeira, com arquivos e diretórios passados por parâmetro
__ignored = build_ignore_regex()

# Arquivo de log
LOG_FILE = "backup_log.txt"
MAX_LOG_SIZE = 10 * 1024 * 1024  # 10 MB

# Listas de controle
verifieds = []       # Arquivos/pastas já verificados
failed_files = []    # Arquivos que falharam na cópia

# Verifica argumento do destino
if len(sys.argv) < 2:
    show_message("[ERROR] Caminho de destino não fornecido.", "red")
    sys.exit(1)

# Caminhos
destination_path = os.path.normpath(sys.argv[1]).rstrip(os.path.sep) + os.path.sep
origin_path = os.path.normpath(os.getcwd()).rstrip(os.path.sep) + os.path.sep

# Valida caminho destino
if not os.path.exists(destination_path):
    show_message("[ERROR] Caminho de destino não existe.", "red")
    sys.exit(1)
if not os.path.isdir(destination_path):
    show_message("[ERROR] Caminho de destino não é uma pasta.", "red")
    sys.exit(1)

# Função para calcular hash (xxHash ou SHA-256 para .iso/.img)
def hash_file(filename, label):
    filename = str(filename) if isinstance(filename, Path) else filename

    """Calcula hash de um arquivo. Usa xxHash para geral e SHA-256 para .iso/.img."""
    if os.path.isdir(filename):
        return 1        

    # Verifica se o hash já foi calculado e está no cache
    if filename in hash_cache:
        return hash_cache[filename]

    try:
        file_size = os.path.getsize(filename)
        with open(filename, 'rb') as file:
            if filename.endswith(('.iso', '.img')):
                hasher = hashlib.sha256()
            else:
                hasher = xxhash.xxh3_64()

            file_name = os.path.basename(filename)            
            with Progress(transient=True) as progress:
                task = progress.add_task(f"[magenta]Hash {label}: {file_name}[/magenta]", total=file_size, unit="B", unit_scale=True)
                progress.update(task, advance=0)
                while chunk := file.read(4096):
                    hasher.update(chunk)
                    progress.update(task, advance=len(chunk))

            # Salva o hash no cache
            hash_value = hasher.hexdigest()
            hash_cache[filename] = hash_value
            return hash_value
    except Exception as e:
        show_message(f"[ERROR] Erro ao calcular hash de '{filename}': {e}", "red")
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
            show_message(f"[I] Hash {filename}.{hash_type} criado com sucesso.", "green")
        else:
            show_message(f"[ERROR] Não foi possível calcular o hash para '{filename}'","red")

    except Exception as e:
        show_message(f"[ERROR] Erro ao criar hash de '{filename}': {e}", "red")

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

                if (hash_src == None):
                    if retry:
                        failed_files.append([src, 'cp'])
                        show_message(f"[I] Retentar Checagem: '{os.path.basename(src)}'.", "yellow")
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
                with Progress(transient=True) as progress:
                    task = progress.add_task(f"[cyan]Copiando {os.path.basename(src)}[/cyan]", total=file_size, unit="B", unit_scale=True)
                    for chunk in iter(lambda: f_in.read(4096), b""):
                        f_out.write(chunk)
                        progress.update(task, advance=len(chunk))

            show_message(f"[+] Arquivo Copiado: '{os.path.basename(src)}'.", "green")

        elif cp_meta:
            show_message(f"[🗸] Já sincronizado: '{os.path.basename(src)}'.", "light_green", False)
        
        else:
            show_message(f"[@] Retentar Cópia.: '{os.path.basename(src)}'.", "yellow")

        if copy or cp_meta:
            shutil.copystat(src, dst)

        return os.path.exists(dst)

    except Exception as e:
        show_message(f"[ERROR] Erro ao copiar '{src}': {e}", "red")
        if retry:
            failed_files.append([src, 'cp'])
            show_message(f"[@] Retentar Cópia.: '{os.path.basename(src)}'.", "yellow")

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
    if bool(re.search(__ignored, path)):
        return  # Arquivo ou pasta ignorada

    global destination_path, origin_path, verifieds

    #dest_path = path.replace(origin_path, destination_path)
    dest_path = trocar_prefixo(path, origin_path, destination_path)

    if dest_path not in verifieds:
        verifieds.append(dest_path)                
        
        show_inline(f"[I] Verificando '{path.replace(origin_path, '')}'...")

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
    global destination_path, origin_path

    src_path = trocar_prefixo(path, destination_path, origin_path)
    #path.replace(destination_path, origin_path)
    #print(origin_path)

    show_inline(f"Deletar? '{path}'","white")    

    if not os.path.exists(src_path):
        if dry_run:
            show_message(f"[DRY RUN] Deletaria '{path}'", "yellow")
            return

        try:
            if os.path.isdir(path):
                shutil.rmtree(path)
                show_message(f"[-] Pasta Removida..: '{path}'.", "bright_magenta")
            else:
                os.remove(path)
                show_message(f"[-] Arquivo Removido: '{path}'.", "bright_magenta")
        except Exception as e:
            show_message(f"[ERROR] Erro ao remover '{path}': {e}", "red")
            if retry:
                failed_files.append([path, 'rm'])
                show_message(f"[@] Retentar Remover: '{os.path.basename(path)}'.", "yellow")

            return False
        
    return True

# Função principal
def main():
    dry_run = '--dry-run' in sys.argv

    # Primeira etapa: sincronizar arquivos da origem
    recursive_directory_iteration(origin_path, origin_to_destination, True, dry_run=dry_run)

    show_message("\n[I] Limpando destino...", "green")

    # Segunda etapa: remover do destino o que não existe na origem
    recursive_directory_iteration(destination_path, remove_from_destination, True, dry_run=dry_run)

    show_message("[I] Sincronização concluída.", "green")

    # Tentativas de recópia de arquivos que falharam    
    loop_count = 1
    while len(failed_files)> 0 and loop_count < 11:
        show_message("\n[TENTATIVA] Retentando arquivos com falha...\n" "yellow")
        time.sleep(5)

        for file, tipo in failed_files[:]:                                
            show_message(f"[{loop_count}] Retentando ({tipo}) '{file}'", "cyan")
            if tipo == 'cp':                    
                if origin_to_destination(file, True, dry_run=dry_run):
                    failed_files.remove([file, tipo])
            elif tipo == 'rm':
                if remove_from_destination(file, True, dry_run=dry_run):
                    failed_files.remove([file, tipo])
                
        loop_count += 1
    show_message("[I] Todos os arquivos recopiados com sucesso.", "green")

# Executa o script
if __name__ == "__main__":
    main()
