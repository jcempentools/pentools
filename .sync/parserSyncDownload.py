"""
BIBLIOTECA parserSyncDownload.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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

Objetivo:
  Interpretar arquivos .syncdownload, resolver contexto completo de download
  e coordenar execução de scripts embutidos.

Formato:
  - linha1 = URL/DSL (opcionalmente com spec: "spec | url")
  - linha2 = SHA256 fixador de versão (opc)
  - linha3 = nome custom (opc)
  - linha4 = URL/DSL de hash remoto (opc) - comparádo com o arquivo e/ou com 2a linha do .sha256/.md5
  - linha5+ = blocos de script (opc)

DSL deve resolver também índices semânticos, ex.: [@attr="img"] e [@attr='img'] - bibliotecar extena

Regra de versão:
  - COM hash na linha2 → versão FIXA (não consultar latest)
  - SEM hash → resolver latest online

FLUXO:
  Resolver URL → nome final → verificar cache → decidir via metadata
  → download (sempre p/ cache na origem) → validação forte (se aplicável)
  → purge → gerar metadata → persistir cache → copiar p/ destino

HASH REMOTO (linha 4):
  - Define validação obrigatória adicional baseada em origem externa
  - Pode apontar para:
    - conteúdo bruto contendo hash
    - arquivos .sha256 / .md5 (formato "<hash>  <filename>")
    - endpoints estruturados (via DSL)

Regras:
  - Hash extraído ignorando nome do arquivo remoto
  - Tipo inferido automaticamente:
    - 32 chars → MD5
    - 64 chars → SHA256
  - Hash mantido apenas em memória (não persiste como metadata primária)

Validação:
  - Presença da linha4 torna a validação por hash REMOTO obrigatória
  - Fluxo:
    → calcular hash local (função existente)
    → comparar com hash remoto
    → divergência:
      - remover arquivo local (cache + destino)
      - invalidar metadata associada
      - reiniciar download

Regra crítica:
  - Download só é considerado válido se o hash remoto conferir

Cache:
  - Reutilizar downloads válidos, evitar re-download
  - Cache inválido (sem metadata coerente ou hash divergente) → removido
  - Download ocorre exclusivamente no cache (origem), nunca direto no destino

Metadata:
  - .syncado → controle de versão (nome remoto real ou referência)
  - .sha256/.md5 → integridade local (formato "<hash>  <filename>", 2 espaços)
  - Metadata NÃO participa da decisão de versão
  - Metadata NÃO substitui validação da linha4
  - linha4 prevalece sobre linha2

Hash:
  - NÃO define atualização de versão (exceto linha2)
  - Usado para:
    - validação pós-download
    - validação de cache
    - dedup fallback

SUBSCRIPT EMBUTIDO (linha ≥5):
  - Blocos definidos por marcador de início de linha:

>>>ext[,fase]

Onde: 
 - Início: `>>>ext[,fase]`
 - Fim:   Próximo `>>>ext` ou fim do arquivo

FASES (Opcional - define o momento da execução do script):
 - start (default) / end: Antes/depois do processamento das 4 linhas do .syncdownload.
 - preresolve / posresolve: Apensar se for o caso, antes/depois de tentar resolver resolver a primeira linha.
 - preremotehash / posremotehash: Apensar se for o caso, antes/depois de tentar resolver/obter o hash remoto.

Execução:
- Para cada bloco:
  - criar arquivo temporário no diretório do .syncdownload
  - nome aleatório + extensão definida
  - escrever conteúdo integral do bloco sem o `>>>ext`
  - executar passando:
    1º parâmetro → fullpath do .syncdownload    
    2º parâmetro → nomeação do arquivo local (basename.ext) - (SE já descoberto pelo script gestor
    3º parâmetro → fullpath do arquivo baixado (SE já baixado)
- Subcripts não participam da decisão de integridade
- Aguarda a conclusão da execução do script e encerrameto
  do processo equivalente para continuar
- Exclui o script temporário
"""

# =========================
# IMPORTS
# =========================
import os

import common
import parserDSL
import loggerAndProgress
import download

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

def parse_syncdownload(file_path):
    """
    Descrição: Lê e interpreta arquivo .syncdownload.
    Parâmetros:
    - file_path (str): Caminho do arquivo.
    Retorno:
    - tuple: (url, expected_hash, custom_name)
    """    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            raw_lines = [l.rstrip('\n') for l in f.readlines()]

        if not raw_lines:
            return None, None, None

        # Preserva posição das linhas (não remove vazias)
        url = raw_lines[0].strip() if len(raw_lines) > 0 else None

        # --- Parser DSL resolution ---
        try:
            if has_parser_expression(url):
                resolved = resolve_parser_expression(
                    url,
                    context_name=os.path.basename(file_path)
                )

                if not isinstance(resolved, str):
                    raise Exception("Parser DSL não retornou URL válida")

                url = resolved

        except Exception as e:
            show_message(f"Erro ao resolver parser DSL: {e}", "e")
            return None, None, None

        # 🔒 GARANTIA: URL final válida
        if not url or not isinstance(url, str):
            show_message(f"URL inválida no .syncdownload: {file_path}", "e")
            return None, None, None

        if "${" in url:
            show_message(f"URL inválida após parser: {url}", "e")
            return None, None, None

    except Exception as e:
        show_message(f"Erro ao ler .syncdownload {file_path}: {e}", "e")
        return None, None, None

    expected_hash = raw_lines[1].strip() if len(raw_lines) > 1 and raw_lines[1].strip() else None
    custom_name = raw_lines[2].strip() if len(raw_lines) > 2 and raw_lines[2].strip() else None

    # 🔒 linha 4 — hash remoto (NÃO persiste, uso obrigatório em memória)
    remote_hash_url = raw_lines[3].strip() if len(raw_lines) > 3 and raw_lines[3].strip() else None

    return url, expected_hash, custom_name, remote_hash_url    

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

def parse_syncdownload_scripts(file_path):
    """
    Extrai blocos >>>ext[,fase] do .syncdownload
    Retorno: list[{ext, phase, content}]
    """

    blocks = []

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        current = None

        for line in lines[4:]:  # 🔒 começa após linha 4
            line = line.rstrip("\n")

            m = re.match(r'^>>>\s*([a-zA-Z0-9]+)(?:\s*,\s*([a-zA-Z0-9]+))?', line)

            if m:
                if current:
                    blocks.append(current)

                ext = m.group(1)
                phase = (m.group(2) or "start").lower()

                current = {
                    "ext": ext,
                    "phase": phase,
                    "content": []
                }
                continue

            if current:
                current["content"].append(line)

        if current:
            blocks.append(current)

    except Exception:
        return []

    return blocks

def execute_sync_script(block, sync_path, downloaded_file=None):
    """
    Executa script embutido garantindo contrato de parâmetros.
    """        
    if not sync_path or not os.path.exists(sync_path):
        raise RuntimeError("Contrato inválido: sync_path inexistente")

    try:
        code = block.get("content")
        interpreter = block.get("ext", "python").lower()
        phase = block.get("phase", "start")

        if not code:
            return

        # =========================================================
        # 🔒 CRIA SCRIPT TEMPORÁRIO
        # =========================================================
        suffix = f".{interpreter}"
        if interpreter in ("py", "python"):
            suffix = ".py"
        elif interpreter == "ps1":
            suffix = ".ps1"

        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix, mode="w", encoding="utf-8", newline="\n") as tmp:
            tmp.write("\n".join(code))
            tmp_path = tmp.name

        try:
            os.chmod(tmp_path, 0o755)
        except Exception:
            pass

        # =========================================================
        # 🔒 MONTA ARGUMENTOS (CONTRATO OBRIGATÓRIO)
        # =========================================================
        if interpreter in ("py", "python"):
            args = [sys.executable, tmp_path]
        elif interpreter == "ps1" and os.name == "nt":
            args = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", tmp_path]
        elif os.name == "nt":
            args = ["cmd.exe", "/c", tmp_path]
        else:
            args = ["bash", tmp_path]

        # 🔒 ARG1: path do .syncdownload (OBRIGATÓRIO)
        args.append(sync_path)
        
        args.append(os.path.basename(downloaded_file) if downloaded_file else "")
        args.append(downloaded_file if downloaded_file else "")

        show_message(f"[SCRIPT:{phase}] Exec → {os.path.basename(sync_path)}", "i")

        # =========================================================
        # 🔒 EXECUÇÃO ISOLADA
        # =========================================================
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=os.path.dirname(sync_path)
        )

        if result.stdout:
            show_message(result.stdout.strip(), "d")

        if result.stderr:
            show_message(result.stderr.strip(), "w")

        if result.returncode != 0:
            show_message(f"Script retornou código {result.returncode}", "w")

        # 🔒 cleanup obrigatório
        try:
            os.remove(tmp_path)
        except Exception:
            pass

    except Exception as e:
        try:
            if 'tmp_path' in locals() and os.path.exists(tmp_path):
                os.remove(tmp_path)
        except Exception:
            pass
        show_message(f"Erro ao executar script: {e}", "e")
