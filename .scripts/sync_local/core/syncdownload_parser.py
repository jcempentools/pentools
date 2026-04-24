"""
SYNC ENGINE
PARSER SYNCDOWNLOAD | BIBLIOTECA

SUMÁRIO E ESCOPO
================
[1] CONTEXTO GLOBAL DO PROJETO (normativo e vinculante)
[2] DIRETRIZES E PRINCÍPIOS COMPARTILHADOS
[3] REGRAS E RESTRIÇÕES DO ECOSSISTEMA
[4] ESPECIFICAÇãO DO FORMATO .syncdownload (atribuição deste script)
[5] DEFINIÇÕES DESTA BIBLIOTECA (específico deste script)

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

[4] ESPECIFICAÇãO DO FORMATO .syncdownload (atribuição deste script)
====================================================================

---------------------------------------------------------------------
4.1 DEFINIÇÃO FORMAL (SINTAXE)
---------------------------------------------------------------------

syncdownload := line1 [line2] [line3] [line4] [line5] {script_block}

line1 := <url_or_dsl> | <spec> "|" <url_or_dsl>
line2 := <hash_literal>
line3 := <custom_filename>
line4 := <remote_hash_source>
line5 := <files_in_container>
script_block := ">>>" <ext> ["," <phase>] <newline> {content}

4.1.A Onde:
 <spec> = <ext>[,<tag>...]
 <tag>  = x64, x86, arm32, arm64, amd32, arm, live...
 <ext>  = extensão precedida por ponto (.iso, .exe, .msi...)

Restrições:

- Ordem é obrigatória e semântica
- Linhas opcionais só podem existir se as anteriores existirem
- Linhas vazias intermediárias são proibidas
- Encoding obrigatório: UTF-8

---------------------------------------------------------------------
4.2 SEMÂNTICA DAS LINHAS
---------------------------------------------------------------------

LINHA 1 — ORIGEM

- URL direta ou DSL
- Pode conter prefixo spec

Resolução:
- Deve ser determinística
- Deve utilizar utils.dsl:
    resolve_if_dslany, context=str|None = None) -> string
    has_parser_expressionstr|None) -> bool

Falha:
→ erro estrutural → rebaixamento

---------------------------------------------------------------------

LINHA 2 — HASH FIXO

Formato:
- 32 chars hex → MD5
- 64 chars hex → SHA256

Semântica:
- Define versão FIXA

---------------------------------------------------------------------

LINHA 3 — NOME FINAL

Semântica:
- Define basename final
- Define nome canônico
- Se ausente:
    → derivar via:
        - URL
        - HEAD (sem download)

---------------------------------------------------------------------

LINHA 4 — HASH REMOTO

Conteúdo:
- URL / DSL / literal
- Desativa fixação de versão da linha 2
- Quando presente, a definição de versão passa a ser implícita
  ao hash remoto, tornando a versão dinâmica porém verificável

Formatos suportados:
- Hash puro
- Arquivo .sha256/.md5
- Conteúdo bruto
- Endpoint estruturado

Regras:

- Ignorar filename remoto
- Extrair apenas hash
- Inferência:
    32 → MD5
    64 → SHA256

Semântica:

- Validação obrigatória
- Precedência máxima

Falhas:

- Hash não extraível → rebaixamento
- Divergência → rebaixamento + retry

Persistência:
- NÃO persistir como metadata primária

---------------------------------------------------------------------

LINHA 5 — TRATAMENTO de ARQUIVOS INSERIDOS EM CONTAINERS

- A linha cinco define um vetor com notação estilo json, que
  define um ou mais aquivos que serão extraídos do container

    >> VIDE item 3 de "4.5 PIPELINE DE DOWNLOAD".

---------------------------------------------------------------------
4.3 SUBSCRIPTS EMBUTIDOS
---------------------------------------------------------------------

Definição:

A partir da linha 6, o arquivo pode conter zero, um ou múltiplos blocos de script.

Formato:

>>>ext[,fase]
conteúdo (0 ou mais linhas)

Delimitação:

- Um bloco inicia EXCLUSIVAMENTE em uma linha que começa com:
    >>>ext[,fase]

- O bloco se estende até:
    a) a próxima linha que inicie com ">>>"
    OU
    b) o fim do arquivo (EOF)

- Não existe marcador explícito de fim de bloco

Casos válidos:

1) Único bloco até EOF:

    >>>py
    print("A")

2) Múltiplos blocos sequenciais:

    >>>py
    print("A")
    >>>sh
    echo "B"

3) Bloco vazio:

    >>>py

    >>>sh

Fases:

- start (default)
- end
- preresolve / posresolve
- preremotehash / posremotehash

Execução:

Para cada bloco:

1. Criar arquivo temporário no diretório do `.syncdownload`
2. Nome aleatório + extensão definida (ext)
3. Escrever o conteúdo do bloco (excluindo a linha ">>>")
4. Executar com:

    argv[1] = path completo do .syncdownload
    argv[2] = nome final (se conhecido)
    argv[3] = path do artefato (se já existente)

5. Aguardar conclusão do processo (execução síncrona)
6. Remover o arquivo temporário

Regras:

- A ordem dos blocos DEVE ser respeitada
- Execução é estritamente sequencial
- Cada bloco é isolado (sem compartilhamento implícito de estado)

Restrições:

- Scripts NÃO participam da decisão de:
    - versão
    - integridade
    - cache

- Scripts NÃO podem interferir na coerência origem ↔ destino
- Falhas em scripts NÃO interrompem o engine global
    → devem ser tratadas como falha local (ver seção 4.8)

Definição formal das fases:

Cada fase define um ponto exato de execução dentro do pipeline lógico
do processamento do `.syncdownload`.

As fases NÃO são abstratas — elas correspondem a estados concretos do fluxo.

---------------------------------------------------------------------

start (default)
---------------
Momento:
- Imediatamente após parsing estrutural do `.syncdownload`
- Antes de qualquer resolução de URL, nome ou hash

Estado disponível:
- path do .syncdownload

Estado NÃO disponível:
- URL resolvida
- nome final
- artefato local
- hash remoto

Uso típico:
- preparação de ambiente
- validações externas iniciais

---------------------------------------------------------------------

preresolve
-----------
Momento:
- Antes de resolver linha1 (URL/DSL)

Estado disponível:
- conteúdo bruto da linha1

Estado NÃO disponível:
- URL final resolvida
- nome final

Uso típico:
- manipulação dinâmica de DSL
- pré-processamento de entrada

---------------------------------------------------------------------

posresolve
-----------
Momento:
- Após resolver linha1
- Após determinar nome final (linha3 ou derivado)

Estado disponível:
- URL final resolvida
- nome final

Estado NÃO disponível:
- artefato baixado
- hash remoto

Uso típico:
- ajuste de naming
- inspeção de origem resolvida

---------------------------------------------------------------------

preremotehash
--------------
Momento:
- Antes de obter/resolver linha4

Estado disponível:
- URL final
- nome final

Estado NÃO disponível:
- hash remoto resolvido

Uso típico:
- alterar endpoint de hash
- preparar autenticação externa

---------------------------------------------------------------------

posremotehash
--------------
Momento:
- Após resolução/extração do hash remoto (linha4)

Estado disponível:
- hash remoto (se aplicável)

Estado NÃO disponível:
- artefato validado

Uso típico:
- logging
- auditoria de integridade externa

---------------------------------------------------------------------

end
----
Momento:
- Após conclusão completa do pipeline:
    - reconciliação
    - download (se ocorreu)
    - validação
    - metadata

Estado disponível:
- artefato final (se obtido)
- metadata consistente

Uso típico:
- pós-processamento
- ajustes finais no artefato

---------------------------------------------------------------------

INVARIANTES DE FASE
--------------------

- Fases são executadas em ordem lógica do pipeline
- Cada fase ocorre no máximo uma vez por item
- Scripts de fases diferentes NÃO se sobrepõem
- Estado disponível é estritamente definido por fase
- Scripts não podem assumir estados futuros

---------------------------------------------------------------------

REGRA CRÍTICA
--------------

Se um script tentar operar sobre um estado ainda não disponível
(ex: acessar arquivo antes do download):

→ comportamento é indefinido e deve ser tratado como erro do script
(não do engine)    

---------------------------------------------------------------------
4.4 RESOLUÇÃO E DECISÃO DE VERSÃO
---------------------------------------------------------------------

Fluxo:

resolver linha1
→ determinar nome
→ RECONCILIAR (ver 4.6)
→ decidir versão:

    if linha2:
        versão fixa
    else:
        resolver latest remoto

→ validar linha4 (se existir)

Invariantes:

- Metadata NÃO define versão
- Cache NÃO define versão

---------------------------------------------------------------------
4.5 PIPELINE DE DOWNLOAD
---------------------------------------------------------------------

Ordem imutável:

0. Reconciliação (4.6)

1. Download (somente se necessário)

2. Validação de hash:

    prioridade:
        linha4
        linha2
        fallback

3. Tratamento de compactação:

Arquivos suportados:
- .gz
- .zip
- .tar
- combinações (ex: .tar.gz)

Definição:

- <ext> = extensão do container (.gz, .zip, .tar)
- <sub-ext> = extensão do artefato desejado (.iso, .img, .exe, etc.)

Regra fundamental:

- O objetivo do sistema é obter o artefato final (<sub-ext>),
  NUNCA o container (<ext>)

Fluxo obrigatório:

1. Validar hash no container (se aplicável)

2. Descompactação obrigatória:
    → extrair conteúdo completo

3. Seleção do artefato:

    3.1. Se existir linha 5 válida:
        - a linha cinco define um vetor com notação estilo json, que
          define um ou mais aquivos que serão extraídos do container
            [ 
                [
                    "<vetor>" # conforme regras 4.1.A,
                    "<canonico>" # conforme regras da LINHA 3
                ]
                ,...
            ]        
    
    3.2. Se não existir linha 5 válida:
        - Identificar arquivos com extensão <sub-ext>
        - Se múltiplos candidatos:
            → aplicar heurística determinística:
                - match com nome canônico (linha3)
                - fallback: maior consistência semântica (não tamanho arbitrário)

4. Validação de hash:

    - Se linha4 presente:
        → validar contra:
            a) container OU
            b) artefato extraído

    - Ordem:
        1. tentar container
        2. fallback para <sub-ext>

    - Persistindo falha:
        → descartar download (rebaixamento)

5. Pós-processamento:

    - Remover container (<ext>)
    - Manter apenas artefato final (<sub-ext>)

6. Nomeação:

    - Aplicar nome canônico (linha3)
    - Preservar extensão real (<sub-ext>)

Invariantes:

- Container nunca é considerado artefato final
- <sub-ext> é sempre o alvo do sistema
- Hash pode referenciar container OU conteúdo
- Sistema deve suportar ambos sem ambiguidade

---------------------------------------------------------------------

METADATA PARA ARQUIVOS COMPACTADOS:

Arquivo .sha256/.md5 deve conter:

Linha 1:
    hash do artefato final (<sub-ext>)

Linha 2:
    hash do container (<ext>) + URL (quando aplicável)

Regra:

- A referência primária de integridade é SEMPRE o artefato final (<sub-ext>)
- Hash do container é auxiliar e pode não existir na origem remota
    
Validação:

- primeiro container
- fallback conteúdo extraído

---------------------------------------------------------------------

4.6 RECONCILIAÇÃO CACHE ↔ DESTINO
---------------------------------------------------------------------

Objetivo:
- Evitar download desnecessário
- Garantir integridade

Estados:

A) Ambos válidos → nenhuma ação

B) Apenas cache válido:
    → copiar cache → destino

C) Apenas destino válido:
    → copiar destino → cache

D) Ambos inválidos:
    → REBAIXAMENTO

E) Divergentes:
    → aplicar precedência
    → reconciliar

F) Estado inconsistente:
    → REBAIXAMENTO

Invariantes:

- Download é último recurso
- Estado final deve ser idêntico

---------------------------------------------------------------------
4.7 METADATA
---------------------------------------------------------------------

Tipos:

- .syncado
- .sha256 / .md5

Formato:

"<hash>␠␠<filename>"

Regras:

- NÃO define versão
- NÃO substitui linha4

---------------------------------------------------------------------
4.8 FALHAS E REBAIXAMENTO
---------------------------------------------------------------------

Definição:

Rebaixamento =

- remover:
    cache
    destino
    metadata
- estado = inexistente

Fluxo:

falha → rebaixar → reiniciar

Progresso material:

- arquivo válido obtido
- hash confirmado
- metadata consistente

Se não houver progresso:

→ marcar falha
→ parar item
→ continuar próximos

Invariantes:

- nunca loop infinito
- nunca travar execução

---------------------------------------------------------------------
4.9 PRECEDÊNCIA
---------------------------------------------------------------------

1. Linha 4
2. Linha 2
3. Remoto (latest)
4. Metadata

---------------------------------------------------------------------
4.10 INTEGRAÇÃO COM DOWNLOAD_MANAGER (HTTP / DOWNLOAD)
---------------------------------------------------------------------

Responsabilidade:

- Este módulo NÃO implementa lógica de rede
- Toda operação HTTP e download é delegada ao módulo:

    ./core/download_manager.py

- Este módulo atua APENAS como consumidor dessas funções

---------------------------------------------------------------------

FUNÇÕES PÚBLICAS DISPONÍVEIS
-----------------------------

1) download_file_with_progress
--------------------------------

Assinatura:

    download_file_with_progress(url: str, dst: str) -> None

Descrição:

- Realiza download completo de um recurso HTTP
- Exibe progressbar unificada (via utils.progress)
- Escreve diretamente no destino informado

Parâmetros:

- url (str)
    → URL absoluta do recurso
    → Deve estar previamente resolvida (sem DSL)

- dst (str)
    → Caminho absoluto ou relativo do arquivo de destino
    → Deve apontar para o arquivo final (não diretório)

Retorno:

- None

Garantias:

- Download completo ou falha explícita
- Escrita atômica sob responsabilidade do módulo
- Não realiza retry automático (delegado a retry.py)

Restrições:

- Não deve ser usado para requisições parciais
- Não deve ser usado para HEAD
- Não expõe controle de headers ou método HTTP

---------------------------------------------------------------------

2) http_open
-------------

Assinatura:

    http_open(url_or_req: str | Request, timeout: int = 15) -> HTTPResponse

Descrição:

- Wrapper centralizado para operações HTTP
- Permite execução de requisições customizadas (GET/HEAD)

Parâmetros:

- url_or_req (str | Request)
    → str:
        - Interpretado como URL
        - Método implícito: GET

    → Request:
        - Objeto compatível com urllib.request.Request
        - Permite definição explícita de:
            - método (GET, HEAD)
            - headers
            - payload (quando aplicável)

- timeout (int)
    → Tempo máximo em segundos
    → Aplicado obrigatoriamente a todas as requisições

Retorno:

- HTTPResponse
    → Objeto de resposta compatível com urllib
    → Deve suportar:
        - .read()
        - .status (ou equivalente)
        - headers

Garantias:

- Timeout SEMPRE aplicado
- Compatibilidade com HEAD e GET via Request
- Não realiza retry automático

Restrições:

- Não realiza parsing de conteúdo
- Não interpreta resposta (responsabilidade do chamador)
- Não deve ser usado para download de arquivos grandes
    → usar download_file_with_progress

---------------------------------------------------------------------

REGRAS DE USO
--------------

- HEAD requests:
    → devem ser feitos via http_open(Request(method="HEAD"))

- GET simples (conteúdo leve):
    → http_open(url)

- Download de arquivos:
    → download_file_with_progress(url, dst)

---------------------------------------------------------------------

INVARIANTES
------------

- Este módulo NÃO decide:
    - método HTTP
    - política de retry
    - headers

- Este módulo NÃO manipula:
    - sessões
    - cookies
    - autenticação persistente

- Toda lógica HTTP deve permanecer isolada em download_manager.py

---------------------------------------------------------------------

ERROS E FALHAS
---------------

- Falhas de rede são propagadas ao chamador
- Este módulo deve tratar falhas conforme seção 4.8 (REBAIXAMENTO)
- Nenhuma falha HTTP deve interromper o engine global

=====================================================================
FIM DO CONTRATO
=====================================================================
"""

# IMPORTS
import re
import json

from sync_local.commons import *
from sync_local.utils.dsl import extract_parser_url, has_parser_expression, resolve_parser_expression
from sync_local.utils.naming import normalize_tokens    
from sync_local.commons import __IGNORAR_GITHUB
from sync_local.core.file_operations import resolve_final_filename
from sync_local.core.download_manager import http_open
from sync_local.core.file_operations import resolve_final_url
from sync_local.core.file_operations import parse_syncdownload

# VARIÁVEIS GLOBAIS
# (usa commons)

# MAPEAMENTO DE FUNÇÕES
def resolve_syncdownload_cached(sync_path):
    """
    Resolve completamente um .syncdownload e cacheia resultado.

    Garante:
    - URL final resolvida (GitHub/SourceForge)
    - Nome final determinístico
    - Reutilização em cleanup + download

    NÃO realiza download
    Parâmetros:
    - sync_path (str): Caminho do arquivo.
    Retorno:
    - dict|None: Dados resolvidos.    
    """

    cache_entry = sync_resolve_cache.get(sync_path)

    if cache_entry:
        cached_mtime = cache_entry.get("_mtime")
        current_mtime = os.path.getmtime(sync_path)

        if cached_mtime == current_mtime:
            return cache_entry

    url, expected_hash, custom_filename, remote_hash_url = parse_syncdownload(sync_path)

    if not url:
        return None

    spec = None

    # --- split spec | url ---
    if "|" in url:
        try:
            left, right = url.split("|", 1)
            right = right.strip()

            if right.startswith("http://") or right.startswith("https://"):
                spec = left.strip()
                url = right
        except Exception:
            spec = None

    # --- GitHub ---
    forced_extension = None

    if spec and "github.com" in url.lower() and not __IGNORAR_GITHUB:
        try:                    
            parts = [p.strip().lower() for p in spec.split(",") if p.strip()]

            ext = None
            arch = None
            include_filters = []
            exclude_filters = []

            for p in parts:
                if p.startswith("."):
                    ext = p[1:]
                    forced_extension = ext
                elif p in ("x86", "x64", "arm64", "amd64"):
                    arch = p
                elif p.startswith("!"):
                    exclude_filters.append(p[1:])
                else:
                    include_filters.append(p)

            if ext:
                api_url = url.rstrip('/').replace(
                    "github.com",
                    "api.github.com/repos"
                ) + "/releases/latest"

                with http_open(api_url) as response:
                    data = json.loads(response.read().decode())

                assets = data.get("assets", [])

                candidates = []

                for asset in assets:
                    name = asset.get("name", "")
                    tokens = normalize_tokens(name)
                    clean = name.lower()

                    if not clean.endswith(f".{ext}"):
                        continue

                    ok = True

                    if arch and not any(arch in t for t in tokens):
                        ok = False

                    for f_in in include_filters:
                        if not any(f_in in t for t in tokens):
                            ok = False
                            break

                    if ok:
                        for f_ex in exclude_filters:
                            if any(f_ex in t for t in tokens):
                                ok = False
                                break

                    if ok:
                        candidates.append(asset)

                if candidates:
                    selected = max(candidates, key=lambda a: a.get("size", 0))
                    url = selected.get("browser_download_url")

        except Exception:
            pass

    # 🔒 resolve URL final antes de qualquer decisão de nome/extensão
    final_url, _ = resolve_final_url(url)
    effective_url = final_url or url

    filename = resolve_final_filename(
        url=effective_url,
        path=sync_path,
        custom_name=custom_filename,
        forced_extension=forced_extension
    )

    result = {
        "url": url,
        "filename": filename,
        "expected_hash": expected_hash,
        "remote_hash_url": remote_hash_url,
        "forced_extension": forced_extension,
        "custom_filename": custom_filename
    }

    result["_mtime"] = os.path.getmtime(sync_path)
    sync_resolve_cache[sync_path] = result
    return result    

def resolve_download_context(sync_path):
    """
    Descrição: Monta contexto completo de download.
    Parâmetros:
    - sync_path (str): Caminho do .syncdownload.
    Retorno:
    - dict|None: Contexto com URL final e headers.
    """    
    resolved = resolve_syncdownload_cached(sync_path)

    if not resolved:
        return None

    cached = sync_resolve_cache.get(sync_path)
    if cached and cached.get("final_url"):
        final_url = cached["final_url"]
        headers = cached.get("headers", {})
    else:
        final_url, headers = resolve_final_url(resolved["url"])
        resolved["final_url"] = final_url
        resolved["headers"] = headers

    return {
        **resolved,
        "final_url": final_url,
        "headers": headers,
    }    

def has_resolvable_url(value):    
    """
    Descrição: Detecta URL direta OU indireta (parser DSL)
    Parâmetros:
    - value (str): Valor contendo URL.
    Retorno:
    - tuple: (tipo, url)
    """    
    if not value:
        return False

    if has_parser_expression(value):
        return True

    return bool(re.search(r'https?://', value)) 

def resolve_url_source(value):
    """    
    Descrição: Identifica tipo e origem da URL, direta ou via parser DSL.
    Parâmetros:
    - value (str): Valor contendo URL.
    Retorno:
    - tuple: (tipo, url)
    """

    if not value:
        return None, None

    if has_parser_expression(value):
        return "parser", extract_parser_url(value)

    m = re.search(r'(https?://[^\s]+)', value)
    if m:
        return "direct", m.group(1)

    return None, None   

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