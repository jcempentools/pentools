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
