"""
BIBLIOTECA hash.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

CONTEXTO GLOBAL DO PROJETO
==========================

Estrutura geral dos componentes do projeto SYNC:
sync/
│
├── main.py                        # Orquestrador principal: controla fluxo completo (cleanup → downloads → cópia → retry → pós-processamento)
├── constants.py                   # Variáveis globais e constantes: paths, regex, flags e estruturas compartilhadas do sistema│
│
├── core/
│   ├── syncdownload_resolver.py   # Resolve arquivos .syncdownload: parsing, seleção de URL final, nome determinístico e cache de resolução
│   ├── syncdownload_processor.py  # Executa pipeline de cada .syncdownload: valida cache, decide download, aplica scripts e sincroniza destino
│   ├── download_manager.py        # Gerencia downloads: execução com progresso, timeout, reutilização em memória e gravação no cache
│   ├── cache_validation.py        # Validação de integridade: hash, metadata (.sha256/.syncado) e regras de consistência de arquivos
│   ├── cleanup.py                 # Limpeza do destino: remove órfãos e protege arquivos válidos com base em .syncdownload e regras globais
│   ├── file_operations.py         # Operações de arquivo: cópia, criação de diretórios, espelhamento e manipulação segura no filesystem
│   ├── metadata.py                # Geração e gerenciamento de metadata: arquivos .sha256, .syncado e vínculos com origem/download
│   └── retry.py                   # Lógica de retentativa: controle de falhas, reprocessamento e política de repetição do pipeline
│
└── utils/
    ├── progress.py                # Barra de progresso e métricas de transferência (download/cópia) com controle visual padronizado
    ├── naming.py                  # Normalização e comparação de nomes: identificação de produto, canonicalização e deduplicação
    ├── dsl.py                     # Parser DSL: resolução de expressões dinâmicas (${...}) em parâmetros de .syncdownload
    └── logging.py                 # Sistema de logging: mensagens estruturadas, níveis (info/warn/error/debug) e formatação visual
  
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
"""

from common import *

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
    
def fetch_remote_hash(remote_hash_url):
    """
    Extrai hash remoto conforme contrato:
    - aceita conteúdo bruto
    - aceita formato "<hash>  filename"
    - infere tipo por tamanho
    """

    try:
        req = urllib.request.Request(remote_hash_url)
        with http_open(req) as response:
            content = response.read().decode(errors="ignore")

        # 🔒 extrai primeiro hash válido
        match = re.search(r'\b([a-fA-F0-9]{32}|[a-fA-F0-9]{64})\b', content)

        if not match:
            raise Exception("Hash remoto não extraível")

        return match.group(1).lower()

    except Exception as e:
        raise Exception(f"Falha ao obter hash remoto: {e}")

def is_cached_file_valid(path, expected_hash):
    if not os.path.exists(path):
        return False

    ext = os.path.splitext(path)[1].lower()
    sha_file = path + ".sha256"
    sync_file = path + ".syncado"

    # =========================================================
    # 1. HASH EXTERNO (linha 2) → prioridade máxima
    # =========================================================
    if expected_hash:
        current_hash = hash_file(path, "Cache")
        return current_hash == expected_hash.lower()

    # =========================================================
    # 2. ARQUIVOS DE IMAGEM → USAR SHA256 SE EXISTIR
    # =========================================================
    if ext in (".iso", ".img") and os.path.exists(sha_file):
        try:
            with open(sha_file, "r", encoding="utf-8") as f:
                saved_hash = f.readline().split()[0]

            current_hash = hash_file(path, "Cache")
            return current_hash == saved_hash.lower()
        except:
            return False

    # =========================================================
    # 3. .SYNCADO → VALIDAÇÃO DE EXISTÊNCIA / COERÊNCIA
    # =========================================================
    if os.path.exists(sync_file):
        try:
            with open(sync_file, "r", encoding="utf-8") as f:
                stored_name = f.read().strip()

            current_name = os.path.basename(path)

            stored_base = normalize_product_name(stored_name)
            current_base = normalize_product_name(current_name)

            # 🔒 comparação por produto (não nome bruto)
            if is_same_product(stored_base, current_base):
                return True

            return False
        except:
            return False

    # =========================================================
    # 4. FALLBACK FINAL
    # =========================================================
    return os.path.getsize(path) > 0        