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

if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
else
  HAS_TIMEOUT=0
fi

TARGETS=("Cru" "Basico" "Designer" "Gamer" "Dev" "Full")

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

WINDOWS_DA_BIOS_MAPA_SUBSTITUICAO=(
  '<Key>[A-Z0-9]{5}(-[A-Z0-9]{5}){4}<\/Key>[\s\S]*?<WillShowUI>[\s\S]*?<\/WillShowUI>|<WillShowUI>Never</WillShowUI>'
  '<ProductKey>\s*[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\s*<\/ProductKey>| '
)

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

# --- VALIDAÇÃO ---
log INFO "Validando arquivos de entrada"

[[ -f "$ARQUIVO_MODELO" ]] || { log ERROR "Modelo XML não encontrado"; exit 1; }
[[ -f "$ARQUIVO_SCRIPT" ]] || { log ERROR "Script PS1 não encontrado"; exit 1; }

mkdir -p "$DIR_SAIDA"

# --- CACHE ---
log INFO "Carregando cache de arquivos"

SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
[[ -n "$SCRIPT_CACHE" ]] || { log ERROR "Script vazio"; exit 1; }

MODELO_PROCESSADO="$(<"$ARQUIVO_MODELO")"
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
  tr -cd '[:alnum:]_.-' <<<"$1"
}

get_replacement() {
  case "$1" in
    WINDOWS_EDITION) printf '%s' "$2" ;;
    NOME_PC) printf 'PC-%s' "${2^^}" ;;
    IDIOMA) printf 'pt-BR' ;;
    TIMEZONE) printf 'E. South America Standard Time' ;;
    *) log ERROR "chave não mapeada: $1"; return 1 ;;
  esac
}

# --- PROCESSAMENTO BASE ---
processar_linha() {
  local linha="$1" nome="$2" serial="$3" target="$4"

  local saida="" resto="$linha"

  while [[ "$resto" == *"#{{"* ]]; do
    [[ "$resto" == *"}}#"* ]] || { log ERROR "Placeholder malformado"; return 1; }

    local antes="${resto%%#{{*}"
    local tmp="${resto#*#{{}"
    local chave="${tmp%%}}#*}"
    local depois="${tmp#*}}#}"

    saida+="$antes"

    if [[ "$chave" == SCRIPT::* ]]; then
      local modo="${chave#SCRIPT::}"
      local script_proc
      script_proc=$(printf '%s' "$SCRIPT_CACHE" | sed \
        "s|#{{MODE}}#|$modo|g; s|#{{APPSLST}}#|$target|g")
      saida+="$(printf '%s' "$script_proc" | xml_escape)"
    else
      local val
      val=$(get_replacement "$chave" "$nome") || return 1
      saida+="$(printf '%s' "$val" | xml_escape)"
    fi

    resto="$depois"
  done

  saida+="$resto"
  printf '%s' "$saida"
}

# --- PROCESSADOR PADRÃO ---
processar_modelo() {
  local nome="$1" serial="$2" target="$3"

  local destino="$DIR_SAIDA/$nome/$target.xml"
  local tmp="${destino}.tmp"

  log INFO "Gerando XML: $destino"

  mkdir -p "$(dirname "$destino")"
  : > "$tmp"

  while IFS= read -r linha || [[ -n "$linha" ]]; do
    processar_linha "$linha" "$nome" "$serial" "$target" >> "$tmp"
    printf '\n' >> "$tmp"
  done <<<"$MODELO_PROCESSADO"

  sed "s|$CHAVE_SENTINELA|$serial|g" "$tmp" > "${tmp}.2"
  mv "${tmp}.2" "$destino"
  rm -f "$tmp"
}

# --- PROCESSADOR OEM ---
processar_oem() {
  local target="$1"
  local destino="$DIR_SAIDA/OEM/$target.xml"
  local tmp="${destino}.tmp"

  log INFO "Gerando XML OEM: $destino"

  mkdir -p "$(dirname "$destino")"
  printf '%s' "$MODELO_PROCESSADO" > "$tmp"

  for regra in "${WINDOWS_DA_BIOS_MAPA_SUBSTITUICAO[@]}"; do
    local busca="${regra%%|*}"
    local repl="${regra#*|}"
    perl -0777 -pe "s|$busca|$repl|gs" -i "$tmp"
  done

  mv "$tmp" "$destino"
}

# --- EXECUÇÃO PARALELA ---
job_count=0
pids=()
fail=0

log INFO "Iniciando geração da matriz"

# OEM
for TGT in "${TARGETS[@]}"; do
  (
    processar_oem "$TGT"
  ) && log INFO "OK: OEM [$TGT]" || { log ERROR "ERRO: OEM [$TGT]"; exit 1; } &
done

# EDIÇÕES
for item in "${EDICOES[@]}"; do
  IFS="|" read -r NOME SERIAL <<<"$item"

  for TGT in "${TARGETS[@]}"; do
    (
      if ((HAS_TIMEOUT)); then
        timeout 30s processar_modelo "$NOME" "$SERIAL" "$TGT"
      else
        processar_modelo "$NOME" "$SERIAL" "$TGT"
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

((fail)) && { log ERROR "FALHA NA MATRIZ"; exit 1; }

TOTAL=$(find "$DIR_SAIDA" -name "*.xml" | wc -l)

((TOTAL == 0)) && { log ERROR "Nenhum XML gerado"; exit 1; }

log INFO "SUCESSO: $TOTAL gerados em $DIR_SAIDA"