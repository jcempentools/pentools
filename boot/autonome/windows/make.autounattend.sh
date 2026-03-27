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
#   8. Log em tela, nunca em arquivo: compatibilidade com workflow e github
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

trap 'log ERROR "Falha inesperada linha=$LINENO cmd=${BASH_COMMAND:-unknown}"' ERR

# --- CONFIGURAÇÕES ---
DIR_SAIDA="./autounattend"
ARQUIVO_MODELO="autounattend.model.xml"
ARQUIVO_SCRIPT="modelo_script_embutido.ps1"
MAX_JOBS=4

command -v timeout >/dev/null 2>&1 || {
  log WARN "timeout não disponível — proteção contra loop desativada"
}

TARGETS=(
  "Cru"
  "Basico"
  "Designer"
  "Gamer"
  "Dev"
  "Full"
)

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

# --- MATRIZ ---
EDICOES=(
  "Home|TX9XD-98N7V-6WMQ6-BX7FG-H8Q99"
  "HomeSingleLanguage|7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH"
  "Pro|W269N-WFGWX-YVC9B-4J6C9-T83GX"
  "Pro-Education|6TP4R-GNPTD-KYYHQ-7B7DP-JWBTM"
  "Pro-Workstation|NRG8B-V9WV7-BCY92-WRCYJ-TWR9J"
  "Enterprise|NPPR9-FWDCX-D2C8J-H872K-2YT43"
  "Enterprise-G|YYVX9-NTFWV-6MDM3-9PT4T-4M68B"
  "Education|NW6C2-QMPVW-D7KKK-3GKT6-VCFB2"
  "IoT-Enterprise|XQQYW-N6F4G-GP8W7-GGHRC-86BWK"
  "Enterprise-LTSC_2024|M7XTQ-FN8P6-TTKYV-9D4CC-J462D"
  "IoT-Enterprise-LTSC_2024|6G99N-FBXGH-8X39X-G4XBR-3GHVR"
  "Server-2022-Standard|VDNW8-C886R-JX8CP-M3CDX-639TB"
  "Server-2022-Datacenter|WX4NM-KYWYW-QJJR4-XV3QB-6VM33"
)

# --- LOG ---
log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date +%F\ %T)" "$level" "$*" >&2
}

# --- VALIDAÇÕES ---
log INFO "Validando arquivos de entrada"

[ -f "$ARQUIVO_MODELO" ] || { log ERROR "Modelo XML não encontrado"; exit 1; }
[ -f "$ARQUIVO_SCRIPT" ] || { log ERROR "Script PS1 não encontrado"; exit 1; }

mkdir -p "$DIR_SAIDA"

# --- CACHE ---
log INFO "Carregando cache de arquivos"

SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
[[ -n "$SCRIPT_CACHE" ]] || { log ERROR "Script PS1 vazio"; exit 1; }

# 🔴 REMOÇÃO DE COMENTÁRIOS XML (SEM MINIFICAR)
MODELO_PROCESSADO="$(sed -E 's/<!--.*?-->//g' "$ARQUIVO_MODELO")"
[[ -n "$MODELO_PROCESSADO" ]] || { log ERROR "Modelo vazio após limpeza"; exit 1; }

# --- UTIL ---
xml_escape() {
  sed -e 's/&\([^a]\|$\)/\&amp;\1/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

escape_sed_replacement() {
  sed 's/[\/&]/\\&/g'
}

safe_filename() {
  local out
  out=$(tr -cd '[:alnum:]_.-' <<<"$1")
  [[ -n "$out" ]] && echo "$out" || echo "invalid_name"
}

get_replacement() {
  local chave="$1"
  local nome="$2"
  case "$chave" in
    "WINDOWS_EDITION") echo "$nome" ;;
    "NOME_PC") echo "PC-${nome^^}" ;;
    "IDIOMA") echo "pt-BR" ;;
    "TIMEZONE") echo "E. South America Standard Time" ;;
    *) log ERROR "chave não mapeada: $chave"; return 1 ;;
  esac
}

# --- PROCESSADOR ---
processar_linha() {
  local linha="$1"
  local nome="$2"
  local serial="$3"
  local target="$4"

  local saida=""
  local resto="$linha"

  while [[ "$resto" == *"#{{"* ]]; do
    [[ "$resto" == *"}}#"* ]] || { log ERROR "Placeholder malformado"; return 1; }

    local antes="${resto%%#{{*}"
    local tmp="${resto#*#{{}"
    local chave="${tmp%%}}#*}"
    local depois="${tmp#*}}#}"

    local substituicao=""
    saida+="$antes"

    if [[ "$chave" == SCRIPT::* ]]; then
      local modo="${chave#SCRIPT::}"
      local script_proc
      script_proc=$(printf '%s' "$SCRIPT_CACHE" | sed "s|#{{MODE}}#|$modo|g; s|#{{APPSLST}}#|$target|g")
      substituicao=$(printf '%s' "$script_proc" | xml_escape)
    else
      substituicao=$(get_replacement "$chave" "$nome") || return 1
      substituicao=$(printf '%s' "$substituicao" | xml_escape)
    fi

    saida+="$substituicao"
    resto="$depois"
  done

  saida+="$resto"
  saida="${saida//$CHAVE_SENTINELA/$serial}"

  printf '%s' "$saida"
}

processar_modelo() {
  local nome="$1"
  local serial="$2"
  local target="$3"

  local destino="$DIR_SAIDA/$(safe_filename "$nome")/$(safe_filename "$target").xml"
  local tmp="${destino}.tmp"

  log INFO "Gerando XML: $destino"

  mkdir -p "$(dirname "$destino")"

  : > "$tmp"

  local count=0
  while IFS= read -r linha || [[ -n "$linha" ]]; do
    ((count++))
    local out
    out=$(processar_linha "$linha" "$nome" "$serial" "$target") || return 1
    printf '%s\n' "$out" >> "$tmp"
  done <<<"$MODELO_PROCESSADO"

  # 🔴 validação crítica
  if [[ ! -s "$tmp" ]]; then
    log ERROR "Arquivo vazio gerado: $destino"
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$destino"

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$destino" || return 1
  fi
}

export DIR_SAIDA
export -f processar_modelo processar_linha get_replacement xml_escape escape_sed_replacement safe_filename log

# --- EXECUÇÃO ---
job_count=0
pids=()
fail=0

log INFO "Iniciando geração da matriz"

for item in "${EDICOES[@]}"; do
  IFS="|" read -r NOME SERIAL <<<"$item"

  for TGT in "${TARGETS[@]}"; do
    (
      if timeout 30s bash -c "processar_modelo \"$NOME\" \"$SERIAL\" \"$TGT\""; then
        log INFO "OK: $NOME [$TGT]"
      else
        log ERROR "ERRO: $NOME [$TGT]"
        exit 1
      fi
    ) &

    pids+=($!)
    ((job_count++))

    if ((job_count >= MAX_JOBS)); then
      for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
      pids=()
      job_count=0
    fi
  done
done

for pid in "${pids[@]}"; do wait "$pid" || fail=1; done

((fail)) && { log ERROR "FALHA NA MATRIZ"; exit 1; }

TOTAL=$(find "$DIR_SAIDA" -name "*.xml" | wc -l)
((TOTAL == 0)) && { log ERROR "Nenhum XML gerado"; exit 1; }

log INFO "SUCESSO: $TOTAL gerados em $DIR_SAIDA"