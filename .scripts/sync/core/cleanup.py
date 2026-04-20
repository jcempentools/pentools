"""
BIBLIOTECA clear.py, PARTE DE SYNC ENGINE — PARSER SYNCDOWNLOAD

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
============================================================
ETAPA 1 DO PIPELINE: Limpeza controlada do destino e cache.

REGRAS ESPECÍFICAS:
- Remover apenas itens inexistentes na origem.
- Respeitar arquivos referenciados por .syncdownload.
- Proteger arquivos válidos por: existência, metadados e similaridade.
- Purge atua no DESTINO e CACHE simultaneamente.
- Preservar a versão final; usar heurística segura (nome + fallback hash).
- NUNCA remover metadados de um arquivo que ainda existe e é válido.
- Sem purge agressivo baseado apenas em nome.
"""

# =========================
# IMPORTS
# =========================
from common import *
from parserSyncDownload import *
from loggerAndProgress import *

# =========================
# MAPEAMENTO DE FUNÇÕES
# =========================

def destination_cleanup(root, dry_run=False):
    """
    Descrição: Remove itens no destino não presentes na origem.
    Parâmetros:
    - root (str): Diretório raiz.
    - dry_run (bool): Simulação sem remover.
    Retorno:
    - None
    """
    global _sync_global_map
    # --- CACHE LOCAL DE PROTEÇÃO POR DIRETÓRIO (.syncdownload) ---
    local_sync_files = []
    try:
        origin_dir_equiv = os.path.join(ORIGIN_PATH, os.path.relpath(root, destination_path))
        if os.path.exists(origin_dir_equiv):
            for f in os.listdir(origin_dir_equiv):
                if f.lower().endswith(".syncdownload"):
                    local_sync_files.append(os.path.join(origin_dir_equiv, f))
    except Exception:
        local_sync_files = []

    has_local_sync = len(local_sync_files) > 0

    for item in os.listdir(root):        
        dest_full_path = os.path.join(root, item)
        rel_path = os.path.relpath(dest_full_path, destination_path)
        origin_equivalent = os.path.join(ORIGIN_PATH, rel_path)        

        # --- IGNORA PASTAS RAIZ apps/ e Drivers/ NO DESTINO ---
        # Se estiver na raiz do destino e for uma dessas pastas, ignora completamente
        if root == destination_path and item in ("apps", "Drivers"):
            show_message(f"Remoção ignorada: {item}", "i")
            continue
        
        # protege arquivos auxiliares de sync vinculados a arquivo existente
        if dest_full_path.lower().endswith((".sha256", ".syncado")):
            origin_equivalent_sync = origin_equivalent + ".syncdownload"

            # 🔒 1. Se existir .syncdownload correspondente na origem → protege
            if os.path.exists(origin_equivalent_sync):
                try:
                    resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                    if resolved:
                        expected_name = resolved.get("filename")
                        base_dir = os.path.dirname(dest_full_path)
                        expected_full = os.path.join(base_dir, expected_name)

                        if os.path.exists(expected_full):
                            show_message(f"Remoção protegida (.syncdownload válido): {item}", "D")
                            continue
                except Exception:
                    pass

            # 🔒 2. Se o arquivo base existir localmente → SEMPRE protege
            base_file = re.sub(r'\.(sha256|syncado)$', '', dest_full_path, flags=re.IGNORECASE)

            if os.path.exists(base_file):
                show_message(f"Remoção protegida (arquivo base existente): {item}", "D")
                continue

            # 🔒 3. REMOÇÃO REAL DE METADATA ÓRFÃ (ANTES NÃO OCORRIA)
            show_message(f"Metadata órfã removida: {item}", "d")

            if not dry_run:
                try:
                    os.remove(dest_full_path)
                except Exception as e:
                    show_message(f"Falha ao remover metadata órfã: {e}", "e")

            continue        

        if re.search(IGNORED_PATHS, dest_full_path, re.IGNORECASE):
            show_message(f"Remoção ignorada [regex]: {dest_full_path}", "W")
            continue

        # --- TRATAMENTO PARA ARQUIVOS GERADOS POR .syncdownload ---
        origin_equivalent_sync = origin_equivalent + ".syncdownload"

        # --- PROTEÇÃO CONDICIONAL POR DIRETÓRIO ---
        # (já calculado no início da função)

        # =========================================================
        # 🔒 PROTEÇÃO CANÔNICA DE ARQUIVOS GERADOS POR .syncdownload
        # =========================================================

        try:
            origin_equivalent_sync = origin_equivalent + ".syncdownload"

            if os.path.exists(origin_equivalent_sync):
                resolved = resolve_syncdownload_cached(origin_equivalent_sync)

                if resolved:
                    expected_name = resolved.get("filename")

                    if expected_name:
                        expected_full = os.path.join(root, expected_name)

                        # 🔒 proteção direta (nome resolvido)
                        if os.path.abspath(dest_full_path) == os.path.abspath(expected_full):
                            show_message(f"Protegido (.syncdownload resolvido): {item}", "D")
                            continue

                        # 🔒 proteção por presença do arquivo esperado
                        if os.path.exists(expected_full):
                            current_base = normalize_product_name(os.path.basename(dest_full_path))
                            expected_base = normalize_product_name(expected_name)

                            if is_same_product(current_base, expected_base):
                                show_message(f"Protegido (grupo do .syncdownload): {item}", "D")
                                continue

        except Exception:
            pass        

        if not os.path.exists(origin_equivalent):

            # =========================================================
            # 🔒 PROTEÇÃO GLOBAL: arquivo gerado por QUALQUER .syncdownload
            # =========================================================
            try:
                protected = False

                for root_dir, _, files in os.walk(ORIGIN_PATH):
                    for f in files:
                        if not f.lower().endswith(".syncdownload"):
                            continue

                        sync_file = os.path.join(root_dir, f)

                        try:
                            resolved = resolve_syncdownload_cached(sync_file)

                            if not resolved:
                                continue

                            expected_name = resolved.get("filename")

                            if not expected_name:
                                continue

                            expected_base = normalize_product_name(expected_name)
                            current_base = normalize_product_name(os.path.basename(dest_full_path))

                            if is_same_product(expected_base, current_base):
                                show_message(f"Protegido (global .syncdownload): {item}", "D")
                                protected = True
                                break

                        except Exception:
                            pass

                    if protected:
                        break

                if protected:
                    continue

            except Exception:
                pass

        # --- RECURSÃO CONTROLADA ---
        # Executa limpeza em subdiretórios existentes (após possíveis remoções)
        if os.path.isdir(dest_full_path):
            try:
                destination_cleanup(dest_full_path, dry_run)
            except Exception as e:
                show_message(f"Erro ao acessar subdiretório {dest_full_path}: {e}", "e")

def purge_similar_installers_safe(dest_dir, target_name, canonical_name=None):
    """
    Descrição: Remove versões antigas de forma segura.
    Parâmetros:
    - dest_dir (str): Diretório destino.
    - target_name (str): Arquivo alvo.
    Retorno:
    - None
    """    
    target_full = os.path.join(dest_dir, target_name)

    if not os.path.exists(target_full):
        return

    # 🔒 prioridade: nome canônico da linha 3
    if canonical_name:
        target_base = normalize_canonical_name(canonical_name)
    else:
        target_base = normalize_product_name(target_name)

    if not target_base:
        return

    # =========================================================
    # 🔒 MODO ESTRITO (quando há subtipo explícito no canônico)
    # =========================================================
    strict_mode = False

    if canonical_name:
        canonical_clean = normalize_canonical_name(canonical_name)
        if canonical_clean and "-" in canonical_clean:
            strict_mode = True        

    candidates = []

    for f in sorted(os.listdir(dest_dir)):
        full = os.path.join(dest_dir, f)

        if not os.path.isfile(full):
            continue

        if f.lower().endswith((".sha256", ".syncado", ".syncdownload")):
            continue

        base = normalize_product_name(f)

        # =========================================================
        # 🔒 PRIORIDADE: comparação canônica (linha 3)
        # =========================================================
        candidate_canonical = normalize_canonical_name(f)

        if candidate_canonical and target_base:
            if candidate_canonical == target_base:
                candidates.append(f)
                continue

            # 🔒 modo estrito → não permite fallback
            if strict_mode:
                continue

        # =========================================================
        # fallback (compatibilidade antiga)
        # =========================================================
        base = normalize_product_name(f)

        if is_same_product(base, target_base):
            candidates.append(f)
            
    if len(candidates) <= 1:
        return

    # 🔒 mantém target + 1 fallback válido
    keep = [target_name]

    for f in candidates:
        if f == target_name:
            continue

        full = os.path.join(dest_dir, f)

        if is_cached_file_valid(full, None):
            keep.append(f)
            break

    for f in candidates:
        if f not in keep:
            try:
                os.remove(os.path.join(dest_dir, f))
                show_message(f"Removido excedente: {f}", "-", cor="yellow")
            except Exception as e:
                show_message(f"Erro ao remover {f}: {e}", "e")                

def apply_root_hidden_attribute():
    """
    Descrição: Aplica atributo oculto no root do destino (Windows).
    Parâmetros:
    - None
    Retorno:
    - None
    """        
    try:
        origin_root_items = set(os.listdir(ORIGIN_PATH))
    except Exception as e:
        show_message(f"Erro ao listar origem (root): {e}", "e")
        return

    exceptions = {"NÃO FORMATAR", "Drivers", "apps"}

    for item in os.listdir(destination_path):
        dest_full_path = os.path.join(destination_path, item)

        # Apenas itens no root que também existem na origem
        if item not in origin_root_items:
            continue

        # Exceções explícitas
        if item in exceptions:
            continue

        try:
            # Apenas aplica no item (não recursivo)
            if os.name == "nt":                
                FILE_ATTRIBUTE_HIDDEN = 0x02

                attrs = ctypes.windll.kernel32.GetFileAttributesW(dest_full_path)
                if attrs != -1 and not (attrs & FILE_ATTRIBUTE_HIDDEN):
                    ctypes.windll.kernel32.SetFileAttributesW(dest_full_path, attrs | FILE_ATTRIBUTE_HIDDEN)
                    show_message(f"Ocultado: {item}", "d")

        except Exception as e:
            show_message(f"Falha ao ocultar {item}: {e}", "e")            
