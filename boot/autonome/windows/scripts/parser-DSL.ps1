#requires -version 5.1
<#
.SYNOPSIS
    BIBLIOTECA PARSER DSL (PowerShell 5.1 + 7.4+).
    Abstração universal de origens via resolução declarativa de URLs dinâmicas.

.DESCRIPTION
    Componente especializado em resolver endpoints dinâmicos a partir de APIs remotas 
    (JSON, YAML, XML) sem a necessidade de parsing heurístico ou scraping. 
    Permite que manifestos definam URLs que se auto-atualizam via navegação de objetos.

    SINTAXE DSL (ESTRUTURA NAVEGACIONAL):
    - Padrão Base: ${"URL_API"}.path.subcampo[index].valor
    - Delimitadores: URL de origem obrigatoriamente entre ${"..."} ou ${'...'}.
    - Deep Nesting: Suporta acesso a membros (.campo) e índices de arrays ([0]).
    - Hibridismo: Compatível com strings de metadados (ex: ".exe,x64 | ${DSL}").
    - Deve resolver também indices semânticos, ex.: [@attr="img"] e [@attr='img']
      onde "attr" indica onome de qualquer atributo (ex. src, name, href...) que deve
      cadar com o valor de exemplo 'img', DLS, retorna a primeira ocorrência de casar.

    PIPELINE DE RESOLUÇÃO:
    1. DETECÇÃO: Identificação de expressões DSL via 'has_parser_expression'.
    2. FETCH: Requisição remota com identificação automática de tipo (JSON/YAML/XML).
    3. NAVEGAÇÃO: Resolução determinística do path sobre o objeto retornado.
    4. CONVERSÃO: Retorno obrigatório do valor final como [string] de URL.
    5. encadeamento/Aninhamento/Profundidade: Suporte a até MAX_PROFUNDIDADE (default 7) e MAX_ENCADEAMENTOS (default 3) níveis de aninhamento
       de expressões DSL limitado a um timeout por demanda inicial (conjunto total de resoluções aninhadas+encadeadas) de MAX_BUSCA_TIMEOUT (default 30s) e
       timeout global (todas as resoluçoes do runtime) de MAX_TIMEOUT_GLOBAL (default 90s).

    GESTÃO DE CACHE & PERFORMANCE:
    - Escopo: Cache em memória persistente na sessão (__PARSER_CACHE).
    - TTL (Time-To-Live): 60 segundos por entrada (URL + Path).
    - Objetivo: Minimização de tráfego e latência em execuções repetitivas.

    RESTRIÇÕES ESPECÍFICAS (HARD RULES):
    - ❌ VEDAÇÃO: Proibido parsing de HTML ou técnicas de Scraping.
    - ❌ VEDAÇÃO: Proibida execução de código arbitrário (Bloqueio de Invoke-Expression).
    - ❌ VEDAÇÃO: Proibido encadeamento de múltiplas expressões DSL (limitar deept em 10).
    - ❌ VEDAÇÃO: Operação estritamente de leitura (Idempotência HTTP GET).

    FAIL-SAFE & TRATAMENTO DE ERROS:
    - Falhas (404, Timeout, Path Inválido) retornam obrigatoriamente $null.
    - Isolamento: Erros de parsing não devem interromper o fluxo do Orquestrador.
    - Log: Erros registrados via 'show_message' ou callback de telemetria.

.NOTES
    ================================================================================
    REGRAS DE NEGÓCIO GLOBAIS DO PROJETO
    POWERSHELL MISSION-CRITICAL FRAMEWORK - ESPECIFICAÇÃO DE EXECUÇÃO
    ================================================================================

    [CAPACIDADES GERAIS]
    Orquestração determinística, resiliente e idempotente para Windows.
    Compatibilidade Dual-Engine (5.1 + 7.4+) em contextos SYSTEM, WINPE e USER.

    [ESTILO, DESIGN & RASTREABILIDADE]
    - Design: Imutabilidade, Baixo Acoplamento e suporte a camelCase/snake_case.
    - Rastreabilidade Diff-Friendly: Alterações de código minimalistas otimizados
                                     para desempenho aliado a análise visual
                                     de mudanças.

    [CAPACIDADES TÉCNICAS (REAPROVEITÁVEIS)]
    - COMPATIBILIDADE: Identificação de versão/subversão para comandos adequados.
    - RESILIÊNCIA: Retry com backoff progressivo e múltiplas formas de tentativa.
    - OFFLINE-FIRST: Lógica global de priorização de recursos locais vs rede.
                    configurável para Online-FIRST.
    - DETERMINISMO: Validação de estado real pós-operação (não apenas ExitCode).

    [EVENTOS & TELEMETRIA (CALLBACK)]
    - DESACOPLAMENTO: Script não gerencia arquivos de log ou console diretamente,
                    salvo se explicitamente definido.
    - OBRIGATORIEDADE: Telemetria via ScriptBlock [callback($msg, $type)]
                    salvo se explicitamente definido.
    - TIPAGEM DE MENSAGEM (Parâmetro 2):
        - [t] Title: Título de etapa ou seções principais.
        - [l] Log: Registro padrão de fluxo e operações.
        - [i] Info: Detalhes informativos ou diagnósticos.
        - [w] Warn: Alertas de falhas não críticas ou retentativas.
        - [e] Error: Falhas críticas que exigem atenção ou interrupção.

    [REGRAS DE ARQUITETURA]
    - ISOLAMENTO: Mutex Global obrigatório para prevenir paralelismo.
    - MODULARIDADE: Baseado em micro-funções especialistas e reutilizáveis.
    - SINCRO: Execução 100% síncrona, bloqueante e sequencial.
    - ESTADO: Barreira de consistência (DISM/CBS) para operações de sistema.
    - NATIVO: Uso estrito de comandos nativos do OS, salvo exceção declarada.

    [DIRETRIZES DE IMPLEMENTAÇÃO]
    - IDEMPOTÊNCIA: Seguro para múltiplas execuções no mesmo ambiente.
    - HEADLESS: Operação plena sem interface gráfica ou interação de usuário.
    - TIMEOUT: Limites controlados adequados à capacidade do hardware.

    [RESTRIÇÕES / VEDAÇÕES]
    - Não prosseguir com sistema em estado inconsistente ou pendente.
    - Não assumir conectividade de rede (Offline-First por padrão)
    configurável para Online-FIRST.
    - Não depender de módulos externos ou bibliotecas não nativas.
    - Não executar etapas sem validação de sucesso posterior.

    [ESTRUTURA DE EXECUÇÃO]
    1. Inicialização segura (ExecutionPolicy, TLS, Context Check).
    2. Garantia de instância única (Global Mutex).
    3. Validação de pré-requisitos e pilha de manutenção do SO.
    4. Orquestração modular com validação individual de cada micro-função.
    5. Finalização auditável com log rastreável e saída determinística.

    [INVOCAÇãO]
    O script sempre auto identifica se foi importado ou executado:
    1. Se executado diretatamente executa função main repassando parametros 
       recebidos por linha de comando ou variáveis de ambiente.,
    2. Se importado expõe as funções públicas para serem chamadas por outros
       scripts sem executar nada.        

.COMPONENT
    Abstração de APIs, Resolutor de URLs e Parser de Dados Estruturados.
    Foco: Abstração Universal de Origens e Determinismo de Endpoints.
#>


# =========================
# ESTADO GLOBAL (CACHE)
# =========================
if (-not $script:__PARSER_CACHE) {
  $script:__PARSER_CACHE = @{}
}

# =========================
# UTIL
# =========================
function _now {
  return [DateTime]::UtcNow
}

function _emit {
  param($msg, $type, $callback)
  if ($callback -and $callback -is [ScriptBlock]) {
    & $callback $msg $type
  }
}

# =========================
# DETECÇÃO DSL
# =========================
function has_parser_expression {
  param([string]$source)
  if (-not $source) { return $false }
  return ($source -match '\$\{\s*["''].*?["'']\s*\}')
}

# =========================
# EXTRAÇÃO DSL
# =========================
function _extract_dsl {
  param([string]$source)

  if ($source -notmatch '\$\{\s*(["''])(.*?)\1\s*\}(.*)') {
    return $null
  }

  return @{
    url  = $matches[2]
    path = $matches[3]
  }
}

# =========================
# CACHE
# =========================
function _cache_get {
  param($key)

  if (-not $script:__PARSER_CACHE.ContainsKey($key)) {
    return $null
  }

  $entry = $script:__PARSER_CACHE[$key]

  if ((_now) -gt $entry.expire) {
    $script:__PARSER_CACHE.Remove($key)
    return $null
  }

  return $entry.value
}

function _cache_set {
  param($key, $value)

  $script:__PARSER_CACHE[$key] = @{
    value  = $value
    expire = (_now).AddSeconds(60)
  }
}

# =========================
# FETCH (MULTI-ESTRATÉGIA)
# =========================
function _fetch_raw {
  param(
    [string]$url,
    [ScriptBlock]$callback
  )

  $methods = @(
    { Invoke-RestMethod -Uri $url -Method GET -TimeoutSec 15 -ErrorAction Stop },
    { Invoke-WebRequest -Uri $url -Method GET -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop | Select-Object -ExpandProperty Content },
    { 
      $wc = New-Object System.Net.WebClient
      $wc.DownloadString($url)
    }
  )

  foreach ($method in $methods) {
    for ($i = 0; $i -lt 3; $i++) {
      try {
        return & $method
      }
      catch {
        _emit "fetch retry [$i] $url" "w" $callback
        Start-Sleep -Milliseconds (200 * ($i + 1))
      }
    }
  }

  _emit "fetch failed $url" "e" $callback
  return $null
}

# =========================
# PARSE (JSON/XML/YAML)
# =========================
function _parse_content {
  param(
    $raw,
    [ScriptBlock]$callback
  )

  if ($null -eq $raw) { return $null }

  # já objeto (Invoke-RestMethod)
  if ($raw -isnot [string]) {
    return $raw
  }

  # JSON
  try {
    return $raw | ConvertFrom-Json -ErrorAction Stop
  }
  catch {}

  # XML
  try {
    return [xml]$raw
  }
  catch {}

  # YAML (se disponível)
  if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
    try {
      return $raw | ConvertFrom-Yaml
    }
    catch {}
  }

  _emit "parse failed" "w" $callback
  return $null
}

# =========================
# NAVEGAÇÃO
# =========================
function _navigate {
  param(
    $obj,
    [string]$path,
    [ScriptBlock]$callback
  )

  if (-not $path) { return $obj }

  $current = $obj

  $tokens = ($path -replace '^\.', '') -split '\.'

  foreach ($token in $tokens) {
    if (-not $current) { return $null }

    if ($token -match '(.+?)\[(\d+)\]') {
      $name = $matches[1]
      $idx = [int]$matches[2]

      $current = $current.$name
      if ($current -is [System.Collections.IEnumerable]) {
        $current = @($current)[$idx]
      }
      else {
        return $null
      }
    }
    else {
      $current = $current.$token
    }
  }

  return $current
}

# =========================
# RESOLVER DSL
# =========================
function resolve_parser_expression {
  param(
    [string]$source,
    [ScriptBlock]$callback
  )

  if (-not (has_parser_expression $source)) {
    return $source
  }

  $dsl = _extract_dsl $source
  if (-not $dsl) { return $null }

  $key = "$($dsl.url)|$($dsl.path)"

  $cached = _cache_get $key
  if ($cached) {
    return [string]$cached
  }

  $raw = _fetch_raw -url $dsl.url -callback $callback
  if (-not $raw) { return $null }

  $parsed = _parse_content -raw $raw -callback $callback
  if (-not $parsed) { return $null }

  $value = _navigate -obj $parsed -path $dsl.path -callback $callback
  if ($null -eq $value) { return $null }

  $value = [string]$value

  _cache_set $key $value

  return $value
}