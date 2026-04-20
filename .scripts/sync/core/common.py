"""
BIBLIOTECA commom.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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
Centralizar estado global, cache, utilidades e configurações compartilhadas
entre todos os módulos. Atua como base estrutural do engine, garantindo
consistência, determinismo e reuso sem duplicação de lógica.

ESCOPO
======
- Variáveis globais de execução
- Cache em memória e persistente
- Funções utilitárias transversais (hash, retry, DSL bridge)
- Configuração de providers
- Normalização e regras auxiliares compartilhadas

PRINCÍPIOS
==========
- Fonte única de verdade para estado global
- Não conter lógica de negócio de sync
- Não conter lógica de I/O específica (download/cópia)
- Garantir consistência entre módulos
- Evitar dependências circulares

REGRAS CRÍTICAS
===============
- Toda variável global usada por múltiplos módulos DEVE residir aqui
- Cache deve ser determinístico e invalidável
- Funções devem ser puras sempre que possível
- Nenhuma função deve executar efeitos colaterais complexos

DEPENDÊNCIAS
============
Consumido por todos os módulos.

LIMITAÇÕES
==========
- Não executar download
- Não executar parsing de .syncdownload
- Não executar operações de filesystem complexas

ESTILO
======
- Funções pequenas e reutilizáveis
- Sem duplicação de lógica
- Nomes consistentes com o contrato global
"""

# =========================
# IMPORTS
# =========================
import os
import sys
import re
import time
import random
import hashlib
import xxhash
from pathlib import Path

# =========================
# VARIÁVEIS GLOBAIS
# =========================
PROVIDERS = {}

__PARSER_CACHE = {}
PARSER_CACHE_TTL = 60

ID_EXECUCAO = ''.join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(3))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = os.path.join(SCRIPT_DIR, "sync.log")

MAX_LOG_SIZE = 5 * 1024 * 1024
MIN_SIZE_BYTES = 2 * 1024 * 1024

SyncDonwloadExtensions = []

_log_iniciado = False
retent_loop_count = 0

verifieds = []
failed_files = []

hash_cache = {}
sync_resolve_cache = {}
download_registry = {}

destination_path = "?"
ORIGIN_PATH = None

IGNORED_PATHS = None

_product_cache = {}
PRODUCT_ALIASES = {}
KNOWN_VENDORS = set()
NOISE_TOKENS = set()

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

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
            with create_progress("bold yellow") as progress:
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