#!/usr/bin/env bash

# ==============================================================================
# DESCRIÇÃO: Processador de Matriz Unattend para Linux (Bash/CI-CD Ready)
# DIRETRIZES E OBJETIVOS:
#   1. Compatível com Bash 4+ (não POSIX puro).
#   2. Substituição de padrões ${{CHAVE}}# baseada em regras dinâmicas.
#   3. Injeção de scripts: ${{SCRIPT::VALOR}}# importa 'modelo_script_embutido.ps1'
#      substituindo ${{mode}}$ pelo valor capturado.
#   4. Resiliência: Execução segura sem falhas silenciosas.
#   5. Automação: Gera derivações XML para todas as edições de Windows.
#   6. CI/CD: Projetado para workflows do GitHub Actions e similares.
#
# NOTA IMPORTANTE:
#   A chave VK7JG-NPHTM-C97JM-9MPGT-3V66T é tratada como SENTINELA fixa,
#   pois o gerador de XML não permite placeholders neste campo.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURAÇÕES ---
DIR_SAIDA="./autounattend"
ARQUIVO_MODELO="autounattend.model.xml"
ARQUIVO_SCRIPT="modelo_script_embutido.ps1"
ARQUIVO_LOG="deploy_error.log"
MAX_JOBS=4

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

# --- MATRIZ ---
EDICOES=(
    "Home|TX9XD-98N7V-6WMQ6-BX7FG-H8Q99"
    "HomeSingleLanguage|7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH"
    "Pro|W269N-WFGWX-YVC9B-4J6C9-T83GX"
    "ProEducation|6TP4R-GNPTD-KYYHQ-7B7DP-JWBTM"
    "ProWorkstation|NRG8B-V9WV7-BCY92-WRCYJ-TWR9J"
    "Enterprise|NPPR9-FWDCX-D2C8J-H872K-2YT43"
    "EnterpriseG|YYVX9-NTFWV-6MDM3-9PT4T-4M68B"
    "Education|NW6C2-QMPVW-D7KKK-3GKT6-VCFB2"
    "IoTEnterprise|XQQYW-N6F4G-GP8W7-GGHRC-86BWK"
    "EnterpriseLTSC_2024|M7XTQ-FN8P6-TTKYV-9D4CC-J462D"
    "IoTEnterpriseLTSC_2024|6G99N-FBXGH-8X39X-G4XBR-3GHVR"
    "Server2022Standard|VDNW8-C886R-JX8CP-M3CDX-639TB"
    "Server2022Datacenter|WX4NM-KYWYW-QJJR4-XV3QB-6VM33"
)

# --- LOG ---
log() {
    printf '[%s] %s\n' "$(date +%F\ %T)" "$1" | tee -a "$ARQUIVO_LOG"
}

# --- VALIDAÇÕES ---
[ -f "$ARQUIVO_MODELO" ] || { log "ERRO: Modelo XML não encontrado"; exit 1; }
[ -f "$ARQUIVO_SCRIPT" ] || { log "ERRO: Script PS1 não encontrado"; exit 1; }

mkdir -p "$DIR_SAIDA"

# --- MINIFICAÇÃO SEGURA ---
minificar_xml() {
    sed -E '
        s/<!--[^>]*-->//g;
        s/>[[:space:]]+</></g;
    '
}

# --- CACHE ---
SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")"
MODELO_MINIFICADO="$(minificar_xml < "$ARQUIVO_MODELO")"

# --- UTILIDADES ---

xml_escape() {
    sed -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

escape_sed_replacement() {
    sed 's/[\/&]/\\&/g'
}

safe_filename() {
    tr -cd '[:alnum:]_.-'
}

get_replacement() {
    local chave=$1
    local nome=$2

    case "$chave" in
        "WINDOWS_EDITION") echo "$nome" ;;
        "NOME_PC")         echo "PC-${nome^^}" ;;
        "IDIOMA")          echo "pt-BR" ;;
        "TIMEZONE")        echo "E. South America Standard Time" ;;
        *)
            log "WARN: chave não mapeada: $chave"
            echo "\${{$chave}}#"
        ;;
    esac
}

# --- PROCESSADOR SEM LOOP INFINITO ---
processar_linha() {
    local linha="$1"
    local nome="$2"
    local serial="$3"

    local saida=""
    local resto="$linha"

    while [[ "$resto" =~ (.*?)\$\{\{([a-zA-Z0-9:_.-]+)\}\}\#(.*) ]]; do
        local antes="${BASH_REMATCH[1]}"
        local chave="${BASH_REMATCH[2]}"
        local depois="${BASH_REMATCH[3]}"
        local substituicao=""

        saida+="$antes"

        if [[ "$chave" == SCRIPT::* ]]; then
            local modo="${chave#SCRIPT::}"

            local modo_escaped
            modo_escaped=$(printf '%s' "$modo" | escape_sed_replacement)

            local script_processado
            script_processado=$(printf '%s' "$SCRIPT_CACHE" | sed "s|\${{mode}}\$|$modo_escaped|g")

            substituicao=$(printf '%s' "$script_processado" | xml_escape)
        else
            substituicao=$(get_replacement "$chave" "$nome")
            substituicao=$(printf '%s' "$substituicao" | xml_escape)
        fi

        saida+="$substituicao"
        resto="$depois"
    done

    saida+="$resto"

    # --- SENTINELA WINDOWS KEY ---
    if [[ "$saida" == *"<Key>"*"$CHAVE_SENTINELA"*"</Key>"* ]]; then
        saida="${saida//$CHAVE_SENTINELA/$serial}"
    fi

    printf '%s' "$saida"
}

processar_modelo() {
    local nome=$1
    local serial=$2

    local nome_safe
    nome_safe=$(printf '%s' "$nome" | safe_filename)

    local destino="$DIR_SAIDA/autounattend_${nome_safe}.xml"

    while IFS= read -r linha || [ -n "$linha" ]; do
      linha=$(processar_linha "$linha" "$nome" "$serial")
      printf '%s\n' "$linha"
    done <<< "$MODELO_MINIFICADO" > "$destino"
}

# --- EXECUÇÃO PARALELA ---
job_count=0

log "Iniciando geração..."

for item in "${EDICOES[@]}"; do
    IFS="|" read -r NOME SERIAL <<< "$item"

    (
        processar_modelo "$NOME" "$SERIAL"
        log "OK: $NOME"
    ) &

    ((job_count++))
    if (( job_count >= MAX_JOBS )); then
        wait
        job_count=0
    fi
done

wait

TOTAL=$(find "$DIR_SAIDA" -type f | wc -l)
log "SUCESSO: $TOTAL arquivos gerados em $DIR_SAIDA"