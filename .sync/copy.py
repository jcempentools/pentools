"""
BIBLIOTECA copy.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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
Executar limpeza controlada do destino e cache, preservando integridade e
coerência com a origem.

ESCOPO
======
- Remoção de itens inexistentes na origem
- Proteção baseada em:
  - metadata válida
  - similaridade de produto
  - presença de .syncdownload
- Purge seguro de versões antigas

PRINCÍPIOS
==========
- Nunca remover sem validação lógica
- Preservar sempre versão válida
- Heurística segura (nome + hash fallback)

REGRAS CRÍTICAS
===============
- Não remover metadata de arquivo existente
- Respeitar proteção global e local de .syncdownload
- Não executar purge agressivo

DEPENDÊNCIAS
============
Depende de common, parserSyncDownload e logger.
Consumido por main.

LIMITAÇÕES
==========
- Não executar download
- Não gerar metadata

ESTILO
======
- Defensivo
- Baseado em evidência (não heurística frágil)
"""

# =========================
# IMPORTS
# =========================
import os
import shutil

import common
import loggerAndProgress

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

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