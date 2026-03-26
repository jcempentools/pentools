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
# ==============================================================================


set -euo pipefail;
IFS=$'\n\t';

trap 'log ERROR "Falha inesperada linha=$LINENO cmd=${BASH_COMMAND:-unknown}"' ERR

# --- CONFIGURAÇÕES ---
DIR_SAIDA="./autounattend";
ARQUIVO_MODELO="autounattend.model.xml";
ARQUIVO_SCRIPT="modelo_script_embutido.ps1";
MAX_JOBS=4;

TARGETS=(
    "Cru"
    "Basico"
    "Designer"
    "Gamer"
    "Dev"
    "Full"
);

CHAVE_SENTINELA="VK7JG-NPHTM-C97JM-9MPGT-3V66T";

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
);

# --- LOG ---
log() {
    local level="$1";
    shift;
    printf '[%s] [%s] %s\n' "$(date +%F\ %T)" "$level" "$*" >&2;
};

# --- VALIDAÇÕES DE AMBIENTE ---
log INFO "Validando arquivos de entrada";

if [ ! -f "$ARQUIVO_MODELO" ]; then
    log ERROR "Modelo XML não encontrado ($ARQUIVO_MODELO)";
    exit 1;
fi;

if [ ! -f "$ARQUIVO_SCRIPT" ]; then
    log ERROR "Script PS1 não encontrado ($ARQUIVO_SCRIPT)";
    exit 1;
fi;

mkdir -p "$DIR_SAIDA";

# --- MINIFICAÇÃO SEGURA ---
minificar_xml() {
    sed -E 's/>[[:space:]]+</></g';
};

# --- CARREGAMENTO DE CACHE ---
log INFO "Carregando cache de arquivos";

SCRIPT_CACHE="$(<"$ARQUIVO_SCRIPT")";

if [[ -z "$SCRIPT_CACHE" ]]; then
    log ERROR "Script PS1 está vazio";
    exit 1;
fi;

MODELO_MINIFICADO="$(minificar_xml < "$ARQUIVO_MODELO")";

if [[ -z "$MODELO_MINIFICADO" ]]; then
    log ERROR "modelo XML vazio após minificação";
    exit 1;
fi;

# --- UTILIDADES ---
xml_escape() {
    sed -e 's/&\([^a]\|$\)/\&amp;\1/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g";
};

escape_sed_replacement() {
    sed 's/[\/&]/\\&/g';
};

safe_filename() {
    local out;
    out=$(tr -cd '[:alnum:]_.-' <<< "$1");
    [[ -n "$out" ]] && echo "$out" || echo "invalid_name";
};

get_replacement() {
    local chave="$1";
    local nome="$2";

    case "$chave" in
        "WINDOWS_EDITION") echo "$nome" ;;
        "NOME_PC") echo "PC-${nome^^}" ;;
        "IDIOMA") echo "pt-BR" ;;
        "TIMEZONE") echo "E. South America Standard Time" ;;
        *)
            log ERROR "chave não mapeada: $chave (edicao=$nome)";
            return 1;
            ;;
    esac;
};

# --- PROCESSADOR ---
processar_linha() {
    local linha="$1";
    local nome="$2";
    local serial="$3";
    local target="$4";

    log DEBUG "Linha len=${#linha} edicao=$nome target=$target"

    local saida="";
    local resto="$linha";

    while [[ "$resto" =~ (.*?)\#\{\{([a-zA-Z0-9:_.-]+)\}\}\#(.*) ]]; do
        local antes="${BASH_REMATCH[1]}";
        local chave="${BASH_REMATCH[2]}";
        local depois="${BASH_REMATCH[3]}";
        local substituicao="";

        saida+="$antes";

        if [[ "$chave" == SCRIPT::* ]]; then
            local modo="${chave#SCRIPT::}";
            log DEBUG "SCRIPT modo=$modo target=$target";

            local modo_esc; modo_esc=$(printf '%s' "$modo" | escape_sed_replacement);
            local tgt_esc; tgt_esc=$(printf '%s' "$target" | escape_sed_replacement);

            local script_proc;
            if ! script_proc=$(printf '%s' "$SCRIPT_CACHE" | sed "s|#{{MODE}}#|$modo_esc|g; s|#{{APPSLST}}#|$tgt_esc|g;"); then
                log ERROR "falha script embutido modo=$modo target=$target";
                return 1;
            fi;

            substituicao=$(printf '%s' "$script_proc" | xml_escape);
        else
            if ! substituicao=$(get_replacement "$chave" "$nome"); then
                return 1;
            fi;
            substituicao=$(printf '%s' "$substituicao" | xml_escape);
        fi;

        saida+="$substituicao";
        resto="$depois";
    done;

    saida+="$resto";

    if [[ "$saida" == *"<Key>"*"$CHAVE_SENTINELA"*"</Key>"* ]]; then
        saida="${saida//$CHAVE_SENTINELA/$serial}";
    fi;

    if [[ "$saida" =~ \#\{\{[a-zA-Z0-9:_.-]+\}\}\# ]]; then
        log ERROR "placeholder órfão (edicao=$nome target=$target)";
        return 1;
    fi;

    printf '%s' "$saida";
};

processar_modelo() {
    local nome="$1";
    local serial="$2";
    local target="$3";

    local destino="$DIR_SAIDA/$(safe_filename "$nome")/$(safe_filename "$target").xml";

    log INFO "Gerando XML: $destino"

    mkdir -p "$(dirname "$destino")";

    while IFS= read -r linha || [ -n "$linha" ]; do
        local linha_original="$linha";

        if ! linha=$(processar_linha "$linha" "$nome" "$serial" "$target"); then
            log ERROR "Falha linha edicao=$nome target=$target"
            log DEBUG "Original: $linha_original"
            log DEBUG "Parcial: $linha"
            return 1;
        fi;

        printf '%s\n' "$linha";
    done <<< "$MODELO_MINIFICADO" > "$destino";

    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$destino" || return 1;
    fi;
};

# --- EXECUÇÃO PARALELA ---
job_count=0;
pids=();
fail=0;

log INFO "Iniciando geração da matriz";

for item in "${EDICOES[@]}"; do
    IFS="|" read -r NOME SERIAL <<< "$item";

    for TGT in "${TARGETS[@]}"; do
        (
            if processar_modelo "$NOME" "$SERIAL" "$TGT"; then
                log INFO "OK: $NOME [$TGT]";
            else
                log ERROR "ERRO: $NOME [$TGT]";
                exit 1;
            fi;
        ) &

        pids+=($!);
        ((job_count++));

        if (( job_count >= MAX_JOBS )); then
            for pid in "${pids[@]}"; do
                wait "$pid" || fail=1;
            done;
            pids=();
            job_count=0;
        fi;
    done;
done;

for pid in "${pids[@]}"; do wait "$pid" || fail=1; done;
[ "$fail" -ne 0 ] && { log ERROR "FALHA NA MATRIZ"; exit 1; };

TOTAL=$(find "$DIR_SAIDA" -name "*.xml" | wc -l);
log INFO "SUCESSO: $TOTAL gerados em $DIR_SAIDA";