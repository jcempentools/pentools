"""
BIBLIOTECA loggerAndProgress.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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
Centralizar toda saída visual, logging persistente e feedback de execução,
garantindo rastreabilidade, legibilidade e consistência de UX.

ESCOPO
======
- Logging em arquivo com rotação
- Output console formatado (rich)
- Progressbars unificadas
- Mensagens inline e estruturadas

PRINCÍPIOS
==========
- Logging humano + machine-readable
- Não poluir stdout com ruído desnecessário
- Feedback contínuo sem flooding
- Consistência visual entre operações

REGRAS CRÍTICAS
===============
- Toda saída DEVE passar por este módulo
- Não embutir lógica de negócio nas mensagens
- Não bloquear execução por falha de log
- Garantir compatibilidade com retry (prefixo contextual)

PROGRESSBAR
===========
- Atualização inline obrigatória
- Sem quebra de layout
- Indicadores claros de operação (hash, download, cópia)

DEPENDÊNCIAS
============
Depende de common.
Consumido por todos os módulos operacionais.

LIMITAÇÕES
==========
- Não executar operações de sync
- Não alterar fluxo lógico do pipeline

ESTILO
======
- Mensagens curtas, objetivas
- Uso consistente de cores e ícones
"""

# =========================
# IMPORTS
# =========================
import os
import re
from datetime import datetime
from rich.console import Console
from rich.progress import Progress, TextColumn, BarColumn, DownloadColumn, TransferSpeedColumn, TimeRemainingColumn

import common

# =========================
# VARIÁVEIS
# =========================
console = Console()

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

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


def get_op_icon(op_type, direction=None):
    if op_type == "hash":
        return "🔍⬅" if direction == "source" else "🔍➜"

    if op_type == "download":
        return "⬇⬇"

    if op_type == "copy":
        return "➜➜"

    return "  "  # fallback 2 chars

def create_progress(color="cyan"):
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
