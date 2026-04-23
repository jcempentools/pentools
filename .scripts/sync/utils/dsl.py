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

# IMPORTS
import re

from sync.commons import *

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES

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

def resolve_if_dsl(value, context=None):
    """
    Resolve valor caso seja expressão DSL (${...})
    Mantém compatibilidade total com strings normais
    """
    if isinstance(value, str) and "${" in value:
        return resolve_parser_expression(value, context_name=context)
    return value

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

