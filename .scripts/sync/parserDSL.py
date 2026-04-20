"""
BIBLIOTECA parserSyncparserDSL.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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

Abstração universal de origens via resolução declarativa de URLs dinâmicas.

Este componente é especializado em resolver endpoints dinâmicos a partir de APIs remotas 
(JSON, YAML, XML) sem a necessidade de parsing heurístico ou scraping. Permite que 
manifestos definam URLs que se auto-atualizam via navegação de objetos.

SINTAXE DSL (ESTRUTURA NAVEGACIONAL):
    - Padrão Base: ${"URL_API"}.path.subcampo[index].valor
    - Delimitadores: URL de origem obrigatoriamente entre ${"..."} ou ${'...'}.
    - Deep Nesting: Suporta acesso a membros (.campo) e índices de listas ([0]).
    - Hibridismo: Compatível com strings de metadados (ex: ".exe,x64 | ${DSL}").
    - Índices Semânticos: Suporta [@attr="valor"], onde "attr" indica o nome de 
      qualquer atributo (src, name, href...) para busca da primeira ocorrência.

PIPELINE DE RESOLUÇÃO:
    1. DETECÇÃO: Identificação de expressões DSL via 'has_parser_expression'.
    2. FETCH: Requisição remota com identificação automática de tipo (JSON/YAML/XML).
    3. NAVEGAÇÃO: Resolução determinística do path sobre o objeto retornado.
    4. CONVERSÃO: Retorno obrigatório do valor final como [str] de URL.
    5. LIMITES: Suporte a até 7 níveis de aninhamento (MAX_PROFUNDIDADE) e 
       3 encadeamentos (MAX_ENCADEAMENTOS). 
    6. TIMEOUTS: 30s por demanda inicial (MAX_BUSCA_TIMEOUT) e 90s global (MAX_TIMEOUT_GLOBAL).

GESTÃO DE CACHE & PERFORMANCE:
    - Escopo: Cache em memória persistente na sessão (__PARSER_CACHE).
    - TTL (Time-To-Live): 60 segundos por entrada (URL + Path).
    - Objetivo: Minimização de tráfego e latência em execuções repetitivas.

RESTRIÇÕES ESPECÍFICAS (HARD RULES):
    - ❌ VEDAÇÃO: Proibido parsing de HTML ou técnicas de Scraping.
    - ❌ VEDAÇÃO: Proibida execução de código arbitrário (Bloqueio de eval/exec).
    - ❌ VEDAÇÃO: Proibido encadeamento de múltiplas expressões (limite depth 10).
    - ❌ VEDAÇÃO: Operação estritamente de leitura (Idempotência HTTP GET).

FAIL-SAFE & TRATAMENTO DE ERROS:
    - Falhas (404, Timeout, Path Inválido) retornam obrigatoriamente None.
    - Isolamento: Erros de parsing não interrompem o fluxo do Orquestrador.
    - Log: Erros registrados via 'show_message' ou callback de telemetria.

OBSERVAÇÕES:
    Compatível com ambientes que exigem resolução dinâmica de artefatos sem 
    acoplamento rígido ao versionamento das APIs.
"""

# =========================
# IMPORTS
# =========================
from common import *

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

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