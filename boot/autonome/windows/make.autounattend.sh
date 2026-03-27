#!/usr/bin/env bash

# ==============================================================================
# DESCRIÇÃO: Processador de Matriz Unattend para Linux (Bash/CI-CD Ready)
# DIRETRIZES E OBJETIVOS:
#   1. Compatível com Bash 4+ (não POSIX puro).
#   2. Substituição de padrões #{{CHAVE}}# baseada em regras dinâmicas.
#   3. Injeção de scripts: #{{SCRIPT::VALOR}}#
#   4. Resiliência: Execução segura sem falhas silenciosas.
#   5. Automação: Geração de matriz completa.
#   6. CI/CD ready.
#   7. NÃO minificar PS1.
#   8. Log apenas em stderr (compatível com GitHub Actions).
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

trap 'log ERROR "Falha inesperada linha=$LINENO cmd=${BASH_COMMAND:-unknown}"' ERR

# --- CONFIG ---
DIR_SAIDA="./autounattend"
ARQUIVO_MODELO="autounattend.model.xml"
ARQUIVO_SCRIPT="modelo_script_embutido.ps1"
MAX_JOBS=4

HAS_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAS_TIMEOUT=1

TARGETS=("Cru" "Basico" "Designer" "Gamer" "Dev" "Full")

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

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
  printf '[%s] [%s] %s\n' "$(date +%F\ %T)" "$1" "${*:2}" >&2
}

# --- VALIDAÇÃO ---
log INFO "Validando arquivos"

[[ -f "$ARQUIVO_MODELO" ]] || { log ERROR "Modelo ausente"; exit 1; }
[[ -f "$ARQUIVO_SCRIPT" ]] || { log ERROR "PS1 ausente"; exit 1; }

mkdir -p "$DIR_SAIDA"

# --- CACHE ---
SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
[[ -n "$SCRIPT_CACHE" ]] || { log ERROR "PS1 vazio"; exit 1; }

# remover comentários XML (robusto)
MODELO_PROCESSADO="$(awk '
BEGIN{c=0}
{
  l=$0
  while(1){
    if(c){
      if(match(l,/-->/)){
        l=substr(l,RSTART+3); c=0
      } else { l=""; break }
    } else {
      if(match(l,/<!--/)){
        pre=substr(l,1,RSTART-1)
        l=substr(l,RSTART+4)
        c=1
        l=pre l
      } else break
    }
  }
  print l
}' "$ARQUIVO_MODELO")"

[[ -n "$MODELO_PROCESSADO" ]] || { log ERROR "Modelo vazio"; exit 1; }

# --- UTIL ---
xml_escape() {
  sed -e 's/&\([^a]\|$\)/\&amp;\1/g' \
      -e 's/</\&lt;/g' \
      -e 's/>/\&gt;/g' \
      -e 's/"/\&quot;/g' \
      -e "s/'/\&apos;/g"
}

safe_filename() {
  tr -cd '[:alnum:]_.-' <<<"$1" | sed 's/^$/invalid_name/'
}

get_replacement() {
  case "$1" in
    WINDOWS_EDITION) printf '%s' "$2" ;;
    NOME_PC) printf 'PC-%s' "${2^^}" ;;
    IDIOMA) printf 'pt-BR' ;;
    TIMEZONE) printf 'E. South America Standard Time' ;;
    *) log ERROR "Chave desconhecida: $1"; return 1 ;;
  esac
}

# --- CORE ---
processar_linha() {
  local linha="$1" nome="$2" serial="$3" target="$4"

  local saida="" resto="$linha"
  local guard=0 MAX_SUBS=1000

  while [[ "$resto" == *"#{{"* ]]; do
    ((guard++))
    ((guard < MAX_SUBS)) || { log ERROR "Loop infinito detectado"; return 1; }

    [[ "$resto" == *"}}#"* ]] || { log ERROR "Placeholder malformado"; return 1; }

    local antes="${resto%%#{{*}"
    local tmp="${resto#*#{{}"
    local chave="${tmp%%}}#*}"
    local depois="${tmp#*}}#}"

    [[ -n "$chave" ]] || { log ERROR "Placeholder vazio"; return 1; }

    saida+="$antes"

    local sub
    if [[ "$chave" == SCRIPT::* ]]; then
      local modo="${chave#SCRIPT::}"
      sub=$(printf '%s' "$SCRIPT_CACHE" | sed \
        "s|#{{MODE}}#|$modo|g; s|#{{APPSLST}}#|$target|g")
      sub=$(printf '%s' "$sub" | xml_escape)
    else
      sub=$(get_replacement "$chave" "$nome") || return 1
      sub=$(printf '%s' "$sub" | xml_escape)
    fi

    saida+="$sub"
    resto="$depois"
  done

  saida+="$resto"

  # 🔴 substituição SEMPRE
  saida="${saida//$CHAVE_SENTINELA/$serial}"

  # validação final
  [[ "$saida" != *"#{{"* ]] || {
    log ERROR "Placeholder não resolvido"
    return 1
  }

  printf '%s' "$saida"
}

processar_modelo() {
  local nome="$1" serial="$2" target="$3"

  local destino="$DIR_SAIDA/$(safe_filename "$nome")/$(safe_filename "$target").xml"
  local tmp="${destino}.tmp"

  log INFO "Gerando XML: $destino"

  mkdir -p "$(dirname "$destino")"
  : > "$tmp"

  local count=0 MAX=50000

  while IFS= read -r linha || [[ -n "$linha" ]]; do
    ((count++))
    ((count < MAX)) || { log ERROR "Loop leitura"; return 1; }

    local out
    out=$(processar_linha "$linha" "$nome" "$serial" "$target") || return 1
    printf '%s\n' "$out" >> "$tmp"
  done <<<"$MODELO_PROCESSADO"

  [[ -s "$tmp" ]] || { log ERROR "Arquivo vazio"; rm -f "$tmp"; return 1; }

  mv "$tmp" "$destino"

  command -v xmllint >/dev/null 2>&1 && xmllint --noout "$destino"
}

export DIR_SAIDA SCRIPT_CACHE MODELO_PROCESSADO
export -f processar_modelo processar_linha get_replacement xml_escape safe_filename log

# --- EXECUÇÃO ---
job_count=0
pids=()
fail=0

log INFO "Iniciando geração"

for item in "${EDICOES[@]}"; do
  IFS="|" read -r NOME SERIAL <<<"$item"

  for TGT in "${TARGETS[@]}"; do
    (
      if ((HAS_TIMEOUT)); then
        timeout 30s bash -c "processar_modelo \"$NOME\" \"$SERIAL\" \"$TGT\""
      else
        processar_modelo "$NOME" "$SERIAL" "$TGT"
      fi
    ) && log INFO "OK: $NOME [$TGT]" || {
      log ERROR "ERRO: $NOME [$TGT]"
      exit 1
    } &

    pids+=("$!")
    ((job_count+=1)) || true

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

((TOTAL > 0)) || { log ERROR "Nenhum XML gerado"; exit 1; }

log INFO "SUCESSO: $TOTAL gerados"