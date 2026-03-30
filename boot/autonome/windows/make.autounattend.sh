#!/usr/bin/env bash

# ==============================================================================
# DESCRIÇÃO: Processador de Matriz Unattend para Linux (Bash/CI-CD Ready)
# DIRETRIZES E OBJETIVOS:
#   1. Compatível com Bash 4+ (não POSIX puro).
#   2. Substituição de padrões #{{CHAVE}}# baseada em regras dinâmicas.
#   3. Injeção de scripts: #{{SCRIPT::VALOR}}# importa 'modelo_script_embutido.ps1'
#      substituindo #{{MODE}}# pelo valor capturado e #{{APPSLST}}# pelo Target.
#   4. Resiliência: Execução segura sem falhas silenciosas.
#   5. Automação: Gera derivações XML para todas as edições e Targets.
#   6. CI/CD: Projetado para workflows do GitHub Actions e similares.
#   7. Não pode minificar ps1 inseridos
#   8. Log em tela, nunca em arquivo
#   9. Paralelismo eficiente e controlado
#  10. Manter blcos de código indentificaveis como for/while segregados em 
#      microfunções para possíveis reutilizações (se aplicável) 
#      Obrigatório: target
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

trap 'log ERROR "Falha inesperada linha=$LINENO cmd=${BASH_COMMAND:-unknown}"' ERR

# --- CONFIGURAÇÕES ---
DIR_SAIDA="./autounattend"
ARQUIVO_MODELO="./autounattend.model.xml"
ARQUIVO_SCRIPT="./modelo_script_embutido.ps1"
MAX_JOBS=4

# ------------------------------------------------------------------------------
# HOOKS E MENU VENTOY
# ------------------------------------------------------------------------------
# Vetor global de handlers executados após geração de cada XML
declare -a HOOK_HANDLERS=()

# Buffer em memória do menu Ventoy (.lst)
MENU_BUFFER=""

# Arquivo temporário para agregação paralela segura
MENU_TMP_FILE="$(mktemp)"

# Caminho do arquivo final do menu
VENTOY_MENU_FILE="$DIR_SAIDA/menu.lst"

# Executa todos handlers registrados
executar_hooks() {
  local xml_path="$1"
  local edicao="$2"

  # fallback para subshell (array não exportado)
  if [[ ${#HOOK_HANDLERS[@]} -eq 0 ]]; then
    handler_ventoy_menu "$xml_path" "$edicao"
    return
  fi

  for handler in "${HOOK_HANDLERS[@]}"; do
    "$handler" "$xml_path" "$edicao"
  done
}

# Handler: constrói menu Ventoy em memória
handler_ventoy_menu() {
  local xml_path="$1"
  local edicao="$2"

  local rel_path
  rel_path="${xml_path#./}"

  local target
  target="$(basename "$xml_path" .xml)"

  {
    echo "${edicao}|${target}|/${rel_path}"
  } >> "$MENU_TMP_FILE"
}

# Mapa futuro para substituições baseadas em chave da BIOS do Windows
# (Mantido para extensões posteriores — não remover)
WINDOWS_DA_BIOS_MAPA_SUBSTITUICAO=(    
  # 1. WillShowUI (qualquer conteúdo interno, multiline seguro)
  '<WillShowUI>[^<]*</WillShowUI>|<WillShowUI>Never</WillShowUI>'

  # 2. ProductKey simples (sem <Key>)
  '<ProductKey>[[:space:]]*[^<]*[[:space:]]*</ProductKey>|$$VNTY_SERIAL_WIN_PRODUCTKEYTAG$$'

  # 3. ProductKey com <Key> interno (estrutura completa)
  '<ProductKey>[[:space:]]*<Key>[^<]*</Key>[[:space:]]*<WillShowUI>[^<]*</WillShowUI>[[:space:]]*</ProductKey>|<ProductKey>$$VNTY_SERIAL_WIN_KEYTAG$$<WillShowUI>Never</WillShowUI></ProductKey>'

  # 4. MetaData IMAGE INDEX (estrutura completa, tolerante a quebra)
  '<MetaData[^>]*>[[:space:]]*<Key>/IMAGE/INDEX</Key>[[:space:]]*<Value>[^<]*</Value>[[:space:]]*</MetaData>|<MetaData><Key>/IMAGE/INDEX</Key><Value>$$VNTY_EDICAO_WIN$$</Value></MetaData>'  
)

# timeout opcional
if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
else
  HAS_TIMEOUT=0
fi

TARGETS=(
  "Target"
#  "Basico"
#  "Designer"
#  "Gamer"
#  "Dev"
#  "Full"
)

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

# Nome lógico da edição OEM baseada em BIOS
EDICAO_OEM_NOME="Default"

# --- MATRIZ ---
EDICOES=(
#  "Home|TX9XD-98N7V-6WMQ6-BX7FG-H8Q99"
#  "HomeSingleLanguage|7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH"
#  "Pro|W269N-WFGWX-YVC9B-4J6C9-T83GX"
#  "Pro-Education|6TP4R-GNPTD-KYYHQ-7B7DP-JWBTM"
#  "Pro-Workstation|NRG8B-V9WV7-BCY92-WRCYJ-TWR9J"
#  "Enterprise|NPPR9-FWDCX-D2C8J-H872K-2YT43"
#  "Enterprise-G|YYVX9-NTFWV-6MDM3-9PT4T-4M68B"
#  "Education|NW6C2-QMPVW-D7KKK-3GKT6-VCFB2"
#  "IoT-Enterprise|XQQYW-N6F4G-GP8W7-GGHRC-86BWK"
#  "Enterprise-LTSC_2024|M7XTQ-FN8P6-TTKYV-9D4CC-J462D"
#  "IoT-Enterprise-LTSC_2024|6G99N-FBXGH-8X39X-G4XBR-3GHVR"
#  "Server-2022-Standard|VDNW8-C886R-JX8CP-M3CDX-639TB"
#  "Server-2022-Datacenter|WX4NM-KYWYW-QJJR4-XV3QB-6VM33"
)

# --- LOG ---
log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date +%F\ %T)" "$level" "$*" >&2
}

# Persistência final do menu Ventoy
escrever_menu() {
  [[ -s "$MENU_TMP_FILE" ]] || return 0

  {
    echo "# Autogerado - Ventoy Menu"    
    echo

    local last=""

    sort "$MENU_TMP_FILE" | while IFS="|" read -r edicao target path; do

      if [[ "$last" != "$edicao" ]]; then
        [[ -n "$last" ]] && echo "}"
        echo
        echo "submenu \"Windows ${edicao}\" {"
        last="$edicao"
      fi

      echo "  menuentry \"${target}\" {"
      echo "    set xml=\"/boot/autonome/windows${path}\""
      echo "    ventoy_autounattend \$xml"
      echo "  }"

    done

    echo "}"
  } > "$VENTOY_MENU_FILE"

  rm -f "$MENU_TMP_FILE"

  log INFO "Menu Ventoy atualizado: $VENTOY_MENU_FILE"
}

# Registro padrão do handler Ventoy
HOOK_HANDLERS+=(handler_ventoy_menu)

# --- VALIDAÇÕES ---
validar_entrada() {
  log INFO "Validando arquivos de entrada"

  [[ -f "$ARQUIVO_MODELO" ]] || { log ERROR "Modelo XML não encontrado"; exit 1; }
  [[ -f "$ARQUIVO_SCRIPT" ]] || { log ERROR "Script PS1 não encontrado"; exit 1; }

  mkdir -p "$DIR_SAIDA"
}

# --- CACHE ---
carregar_cache() {
  log INFO "Carregando cache de arquivos"

  SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
  [[ -n "$SCRIPT_CACHE" ]] || { log ERROR "Script PS1 vazio"; exit 1; }

  MODELO_PROCESSADO="$(awk '
BEGIN { in_comment=0 }
{
  line=$0
  while (1) {
    if (in_comment) {
      if (match(line, /-->/)) {
        line = substr(line, RSTART + 3)
        in_comment=0
      } else {
        line=""
        break
      }
    } else {
      if (match(line, /<!--/)) {
        prefix = substr(line, 1, RSTART - 1)
        line = prefix substr(line, RSTART + 4)
        in_comment=1
      } else break
    }
  }
  if (length(line)) print line
}
' "$ARQUIVO_MODELO")"

  [[ -n "$MODELO_PROCESSADO" ]] || { log ERROR "Modelo vazio"; exit 1; }
}

# --- UTIL ---
xml_escape() {
  sed -e 's/&\([^a]\|$\)/\&amp;\1/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

escape_sed_replacement() {
  # Escapa caracteres críticos para o sed:
  # /  -> delimitador alternativo possível
  # &  -> referência ao match
  # ;  -> separador de comandos do sed (CAUSA DO BUG)
  sed 's/[\/&;]/\\&/g'
}

safe_filename() {
  local out
  out=$(tr -cd '[:alnum:]_.-' <<<"$1")
  [[ -n "$out" ]] && printf '%s' "$out" || printf 'invalid_name'
}

get_replacement() {
  local chave="$1" nome="$2"
  case "$chave" in
    WINDOWS_EDITION) printf '%s' "$nome" ;;
    NOME_PC) printf 'PC-%s' "${nome^^}" ;;
    IDIOMA) printf 'pt-BR' ;;
    TIMEZONE) printf 'E. South America Standard Time' ;;
    *) log ERROR "chave não mapeada: $chave"; return 1 ;;
  esac
}

# --- PROCESSADOR ---
processar_linha() {
  local linha="$1" nome="$2" serial="$3" target="$4"

  local saida="" resto="$linha"

# Loop de substituição de placeholders dinâmicos
  while [[ "$resto" == *"#{{"* ]]; do
    [[ "$resto" == *"}}#"* ]] || { log ERROR "Placeholder malformado"; return 1; }

    local antes="${resto%%#{{*}"
    local tmp="${resto#*#{{}"
    local chave="${tmp%%}}#*}"
    local depois="${tmp#*}}#}"

    [[ -n "$chave" ]] || { log ERROR "Placeholder vazio"; return 1; }

    saida+="$antes"

    local substituicao
    if [[ "$chave" == SCRIPT::* ]]; then
      local modo="${chave#SCRIPT::}"

      local modo_esc tgt_esc
      modo_esc=$(printf '%s' "$modo" | escape_sed_replacement)
      tgt_esc=$(printf '%s' "$target" | escape_sed_replacement)

      # Substituição segura usando variáveis do awk (evita parsing do sed)
      substituicao=$(printf '%s' "$SCRIPT_CACHE" | awk \
        -v mode="$modo" \
        -v target="$target" '
        {
          gsub(/#\{\{MODE\}\}#/, mode)
          gsub(/#\{\{APPSLST\}\}#/, target)
          print
        }')

      substituicao=$(printf '%s' "$substituicao" | xml_escape)
    else
      substituicao=$(get_replacement "$chave" "$nome") || return 1
      substituicao=$(printf '%s' "$substituicao" | xml_escape)
    fi

    saida+="$substituicao"

    [[ "$resto" != "$depois" ]] || { log ERROR "Loop detectado"; return 1; }
    resto="$depois"
  done

  saida+="$resto"
  printf '%s' "$saida"
}

processar_modelo() {
  local nome="$1" serial="$2" target="$3"

  local destino="$DIR_SAIDA/$(safe_filename "$nome")/$(safe_filename "$target").xml"
  local tmp="${destino}.tmp"

  log INFO "Gerando XML: $destino"

  mkdir -p "$(dirname "$destino")"
  : > "$tmp"

  local count=0 MAX_LINHAS=50000

# Processa modelo linha a linha para evitar buffering excessivo
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    ((count++))
    ((count < MAX_LINHAS)) || { log ERROR "Loop detectado"; return 1; }

    local out
    out=$(processar_linha "$linha" "$nome" "$serial" "$target") || return 1

    printf '%s\n' "$out" >> "$tmp"
  done <<<"$MODELO_PROCESSADO"

  [[ -s "$tmp" ]] || { log ERROR "Arquivo vazio: $destino"; rm -f "$tmp"; return 1; }

  sed "s|$CHAVE_SENTINELA|$serial|g" "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"

  mv "$tmp" "$destino"

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$destino" || return 1
  fi

  # ------------------------------------------------------------------
  # HOOK: executa handlers após criação do XML
  # ------------------------------------------------------------------
  executar_hooks "$destino" "$nome"
}

# --- SUBSTITUIÇÕES OEM ---
# Aplica mapa regex -> replacement múltiplas vezes no arquivo gerado
aplicar_substituicoes_oem() {
  local arquivo="$1"

  local tmp="${arquivo}.oem"

  cp "$arquivo" "$tmp"

  # Itera pares regex|replacement definidos globalmente
  # Monta script sed único com todas substituições
  local sed_script=":a;N;\$!ba;"

  for item in "${WINDOWS_DA_BIOS_MAPA_SUBSTITUICAO[@]}"; do
    local regex="${item%%|*}"
    local repl="${item#*|}"

    # ESCAPE DOS CIFRÕES: Transforma $$ em \$ \$ para o Bash não expandir o PID
    # e para o sed não interpretar como fim de linha.
    repl=$(echo "$repl" | sed 's/\$/\\$/g')

    # Use um delimitador neutro (vírgula)
    sed_script+="s,${regex},${repl},g;"
  done

  # Executa tudo de uma vez (evita perda de contexto entre regras)
  sed -E "$sed_script" "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"

  mv "$tmp" "$arquivo"
}

# --- PROCESSADOR OEM ---
# Reutiliza processar_modelo e aplica substituições globais OEM
processar_modelo_oem() {
  local nome="$1"
  local _unused_serial="$2"
  local target="$3"

  processar_modelo "$nome" "$CHAVE_SENTINELA" "$target"

  local destino="$DIR_SAIDA/$(safe_filename "$nome")/$(safe_filename "$target").xml"

  aplicar_substituicoes_oem "$destino"
}

executar_job_generico() {
  local func="$1"
  local nome="$2"
  local serial="$3"
  local target="$4"

  # Serializa o mapa OEM para o subshell (arrays não sobrevivem ao bash -c)
  local mapa_serializado
  mapa_serializado="$(declare -p WINDOWS_DA_BIOS_MAPA_SUBSTITUICAO)"

  (
    if ((HAS_TIMEOUT)); then
      timeout 30s bash -c "$mapa_serializado; $func \"$nome\" \"$serial\" \"$target\""
    else
      bash -c "$mapa_serializado; $func \"$nome\" \"$serial\" \"$target\""
    fi
  ) && log INFO "OK: $nome [$target]" || {
    log ERROR "ERRO: $nome [$target]"
    exit 1
  }
}

executar_job() {
  executar_job_generico processar_modelo "$@"
}

executar_job_oem() {
  executar_job_generico processar_modelo_oem "$@"
}

# Aguarda todos os PIDs do lote atual
# Usa nameref para manipular array externo
aguardar_lote() {
  local -n _pids=$1
  local fail_ref=$2

  for pid in "${_pids[@]}"; do
    wait "$pid" || eval "$fail_ref=1"
  done

  _pids=()
}

# --- ITERAÇÃO DE TARGETS ---
# Itera targets reutilizando handler de execução (callback)
executar_targets_para_edicao() {
  local handler="$1"
  local nome="$2"
  local serial="${3:-}"

# Itera todos os targets definidos para a edição atual
for TGT in "${TARGETS[@]}"; do
    "$handler" "$nome" "$serial" "$TGT" &

    # Armazena PID do job para controle de paralelismo
    pids+=("$!")
    job_count=$((job_count + 1))

    # Controle de paralelismo por lote
    # Quando atinge limite, aguarda lote atual finalizar
    if ((job_count >= MAX_JOBS)); then
      aguardar_lote pids fail
      job_count=0
    fi
  done
}

# Usa variáveis globais: pids, job_count, fail
executar_matriz() {
  # Contador de jobs paralelos ativos
  local job_count=0

  # Lista de PIDs ativos
  local pids=()

  # Flag de falha global
  fail=0

  log INFO "Iniciando geração da matriz"

   # Itera cada edição definida na matriz
  for item in "${EDICOES[@]}"; do
    IFS="|" read -r NOME SERIAL <<<"$item"

    executar_targets_para_edicao executar_job "$NOME" "$SERIAL"
  done

  # --- EDIÇÃO OEM (especial) ---
  executar_targets_para_edicao executar_job_oem "$EDICAO_OEM_NOME" ""

  # Aguarda qualquer job restante
  aguardar_lote pids fail
}

finalizar_execucao() {
  if ((fail)); then
    log ERROR "FALHA NA MATRIZ"
    exit 1
  fi

  TOTAL=$(find "$DIR_SAIDA" -name "*.xml" 2>/dev/null | wc -l || echo 0)

  if ((TOTAL == 0)); then
    log ERROR "Nenhum XML gerado"
    exit 1
  fi

  log INFO "SUCESSO: $TOTAL gerados em $DIR_SAIDA"
}

# --- EXPORTS ---
export DIR_SAIDA SCRIPT_CACHE MODELO_PROCESSADO CHAVE_SENTINELA
export -f processar_modelo_oem aplicar_substituicoes_oem
export -f processar_modelo processar_linha get_replacement xml_escape escape_sed_replacement safe_filename log executar_job

# --- EXPORTS HOOKS ---
export -f executar_hooks
export -f handler_ventoy_menu
export -f escrever_menu
export MENU_TMP_FILE
export VENTOY_MENU_FILE

# --- MAIN ---
main() {
  validar_entrada
  carregar_cache
  executar_matriz
  #escrever_menu
  finalizar_execucao
}

main "$@"