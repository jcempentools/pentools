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
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

trap 'log ERROR "Falha inesperada linha=$LINENO cmd=${BASH_COMMAND:-unknown}"' ERR

# --- CONFIGURAÇÕES ---
DIR_SAIDA="./autounattend"
ARQUIVO_MODELO="autounattend.model.xml"
ARQUIVO_SCRIPT="modelo_script_embutido.ps1"
MAX_JOBS=4

# timeout opcional
if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
else
  HAS_TIMEOUT=0
fi

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
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(date +%F\ %T)" "$level" "$*" >&2
}

# --- VALIDAÇÕES ---
log INFO "Validando arquivos de entrada"

[[ -f "$ARQUIVO_MODELO" ]] || { log ERROR "Modelo XML não encontrado"; exit 1; }
[[ -f "$ARQUIVO_SCRIPT" ]] || { log ERROR "Script PS1 não encontrado"; exit 1; }

mkdir -p "$DIR_SAIDA"

# --- CACHE ---
log INFO "Carregando cache de arquivos"

SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
[[ -n "$SCRIPT_CACHE" ]] || { log ERROR "Script PS1 vazio"; exit 1; }

# Remoção segura de comentários XML
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

      substituicao=$(printf '%s' "$SCRIPT_CACHE" | sed \
        "s|#{{MODE}}#|$modo_esc|g; s|#{{APPSLST}}#|$tgt_esc|g")

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

  while IFS= read -r linha || [[ -n "$linha" ]]; do
    ((count++))
    ((count < MAX_LINHAS)) || { log ERROR "Loop detectado"; return 1; }

    local out
    out=$(processar_linha "$linha" "$nome" "$serial" "$target") || return 1

    printf '%s\n' "$out" >> "$tmp"
  done <<<"$MODELO_PROCESSADO"

  [[ -s "$tmp" ]] || { log ERROR "Arquivo vazio: $destino"; rm -f "$tmp"; return 1; }

  # 🔴 substituição GLOBAL (correção principal)
  sed "s|$CHAVE_SENTINELA|$serial|g" "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"

  mv "$tmp" "$destino"

  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$destino" || return 1
  fi
}

export DIR_SAIDA SCRIPT_CACHE MODELO_PROCESSADO CHAVE_SENTINELA
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
      if ((HAS_TIMEOUT)); then
        timeout 30s bash -c "processar_modelo \"$NOME\" \"$SERIAL\" \"$TGT\""
      else
        bash -c "processar_modelo \"$NOME\" \"$SERIAL\" \"$TGT\""
      fi
    ) && log INFO "OK: $NOME [$TGT]" || {
      log ERROR "ERRO: $NOME [$TGT]"
      exit 1
    } &

    pids+=("$!")
    job_count=$((job_count + 1))

    if ((job_count >= MAX_JOBS)); then
      for pid in "${pids[@]}"; do
        wait "$pid" || fail=1
      done
      pids=()
      job_count=0
    fi
  done
done

for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

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