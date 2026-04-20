"""
SYNC ENGINE — MAIN ORCHESTRATOR — CONTRATO OPERACIONAL

OBJETIVO
========
Orquestrar o pipeline completo de sincronização garantindo ordem, coerência
e determinismo.

PIPELINE (ordem imutável)
=========================
1. Limpeza
2. Processamento .syncdownload (download/cache)
3. Cópia origem→destino
4. Retentativa (mesma ordem)
5. Pós-processamento

PRINCÍPIOS
==========
- Execução síncrona
- Ordem estrita
- Idempotência total
- Retry controlado

REGRAS CRÍTICAS
===============
- Não executar lógica interna complexa
- Delegar para módulos especializados
- Garantir consistência entre etapas

DEPENDÊNCIAS
============
Depende de todos os módulos.

LIMITAÇÕES
==========
- Não conter regras de negócio detalhadas
- Não duplicar lógica de outros módulos

ESTILO
======
- Orquestração pura
- Fluxo explícito e linear
"""

# =========================
# IMPORTS
# =========================
from common import *
from loggerAndProgress import *
from clear import *
from copy import *
from parserSyncDownload import *

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

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
