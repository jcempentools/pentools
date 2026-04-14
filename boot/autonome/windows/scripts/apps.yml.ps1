#requires -version 5.1
<#
.SYNOPSIS
    BIBLIOTECA PARSER DSL (PowerShell 5.1 + 7.4+).    
    Biblioteca "Reader" para Manifestos de Instalação Cross-Language.

.DESCRIPTION
    Define o padrão para o componente LEITOR. Sua função é estritamente de
    parsing, validação e iteração. A biblioteca NÃO executa instalações nem
    downloads; ela processa a árvore de dependências e entrega dados saneados
    para o Orquestrador.

    ESTRUTURA DO DOCUMENTO (DATA SCHEMA)
    ------------------------------------------------------------------------------
    RAIZ:
      apps:     [Lista!] Definições globais de pacotes (Obrigatório: id, name).
      profiles: [Lista!] Grupos de execução (Obrigatório: name, items OU
                include_profiles).

    ESQUEMA DE OBJETOS 'APPS' (AppObject):
      - id():      (string) Identificador único para referenciamento interno no
                            estilo Winget (mesmo que não exista no Winget).
      - name():    (string) Nome fixo de referência (equivalente à linha 3 de
                            .syncdownload) (opcional)
      - canonico():(string) Nome canônico fixo e identificável, baseado em name,
                            conforme regras de negócio (inalterável).
                            Tokenizável de forma aglutinada; por exemplo,
                            Photoshop-Elevel e Photoshop-Crima são tratados como
                            softwares distintos.
                            * a presença de DSL é resolvida automaticamente pelo
                              script uma única vez (lazy resolution) e armazenada
                              para acesso futuro.
                            * não contém tags como x64, x86, arm32, arm64,
                              amd64, etc.;
                            * '{}', não alfanuméricos adjacentes a '{}', e os
                              posteriores a '{}': não canônicos;
                            * caracteres não alfanuméricos nas bordas (left/right):
                              não canônicos;
      - extension(): (string) Extensão preferencial (permitidas: .exe, .msi, .7z,
                            .zip e .gz) (opcional). Na ausência, é inferida a
                            partir da URL ou HEADER.
                            Resolvida uma única vez (lazy resolution) e
                            armazenada para acesso futuro.
      - url():     (string) Link direto ou notação Parser DSL para resolução
                            dinâmica.
                            * a presença de DSL é resolvida automaticamente pelo
                              script uma única vez (lazy resolution) e armazenada
                              para acesso futuro.
      - version(): (string) Versão do software (opcional; inferida da URL ou
                            HEADER).
                            Resolvida uma única vez (lazy resolution) e
                            armazenada para acesso futuro.
                            Conteúdo: [\d]([,\.\-][\d]){0,2}(rc|beta|alfa)?
      - filename(): (string) Nome do arquivo final, baseado em regras de negócio
                            específicas (opcional; inferido da URL ou HEADER).
                            Resolvido uma única vez (lazy resolution) e
                            armazenado para acesso futuro.
                            Baseado em name ou canonico, com placeholders para
                            version, subversão, build e extensão.
                             - utiliza separadores normalizados para ".";
                             - garante extensão compatível com URL ou mimetype;
                             - nome em minúsculas, sem espaços.
      - hash():    (string) Checksum sha256 puro (ex: sha256) (opcional, apenas
                            para fixar versão).
      - tags():    (lista)  Metadados para filtragem e agrupamento (x86, x64,
                            arm32, amd64, arm64, etc.) (opcional).
      - script():  (string) Comando CLI (cmd/ps1/bash) para instalação silenciosa
                            (opcional).

    ESQUEMA DE OBJETOS 'PROFILES' (ProfileObject):
      - name:             (string) Nome identificador do perfil.
      - include_profiles: (lista)  Nomes de outros perfis para herança
                                   (recursivo).
      - items:            (lista)  Objetos contendo 'ref' (ID ou Path externo)
                                   OU definição local (Inline AppObject).

    [MODUS OPERANDI (FLUXO LÓGICO)]
    1. INICIALIZAÇÃO: Carregamento seguro da fonte (caminho local, URL ou string
       YAML).
    2. RESOLUÇÃO: Mapeamento de 'ref' locais para 'apps' globais. Se inexistente,
       tratar 'ref' como path (URL/local) para arquivo .syncdownload ou .yml
       externo.
    3. PARSING POSICIONAL (inferir propriedade a partir de .syncdownload):
       - L1: Origem (link direto), (ext[+tag]|url) ou DSL [@attr='val'].
             Deve resolver a URL final.
       - L2: SHA256 (opcional) (Hex). Fixa versão do software;
       - L3: Nome customizado/canônico com placeholders específicos para version,
             subversão, build (nomeação do arquivo final).
             - '{}', não alfanuméricos adjacentes a '{}', e posteriores a '{}':
               não canônicos;
             - caracteres não alfanuméricos nas bordas: não canônicos;
       Todas as resoluções devem usar apenas URL ou HEADER para metadados,
       de forma síncrona, baixando o destino real apenas se necessário.
    4. HERANÇA: Processamento de 'include_profiles' (flattening para lista
       linear).
    5. INTEGRIDADE: Validação de tipos obrigatórios e detecção de referências
       circulares.
    6. ENTREGA: Disponibilização de um iterador idempotente com metadados
       resolvidos.
    * O processamento de DSL/URL é síncrono; todos os dados lazy (canonico,
      extensão, versão, filename) devem ser resolvidos apenas a partir da URL ou
      HEADER e armazenados para acesso futuro.

    [IMPLEMENTATION_CONTRACT - INTERFACE DE ACESSO]
    As funções abaixo devem ser implementadas seguindo a lógica de retorno de
    objetos:
    - load_manifest(source: String) -> Object
        - Ponto de entrada. Aceita path, URL ou string bruta. Retorna o objeto
          validado.
    - get_app(id: String) -> AppObject
        - Busca no dicionário global ou resolve via path externo. Retorna $null
          se falhar.
    - get_apps_by_tag(tag: String) -> List<AppObject>
        - Filtra apps onde a tag esteja contida no campo (string ou lista).
    - get_value(app_id: String, key: String) -> Any
        - Acesso direto a uma propriedade específica de um app via ID.
    - resolve_profile(manifest: Object, profile_name: String) -> List<AppObject>
        - Resolve heranças e referências de um perfil específico.
        - Retorno: lista linear, ordenada e sem duplicatas de AppObjects prontos.

    [RESTRIÇÕES / VEDAÇÕES (HARD RULES)]
    - ❌ PROIBIDO: Realizar download de binários ou execução de scripts (papel do
                   Orquestrador).
    - ❌ PROIBIDO: Permitir inconsistência de tipos ou ausência de campos
                   obrigatórios.
    - ❌ PROIBIDO: Omitir erros de parsing; o leitor deve falhar rápido
                   (fail-fast).
    - ❌ PROIBIDO: Assumir codificação; o processamento deve ser estritamente
                   UTF-8 (não na origem, mas convertido na recepção).
    - ❌ PROIBIDO: Mutação de dados; o leitor não deve alterar o manifesto
                   original.

    [FAIL-SAFE / RESILIÊNCIA]
    - Erros de sintaxe: interromper imediatamente e reportar posição
      (linha/coluna).
    - Referência ausente (ref): se não for path ou ID, lançar exceção de
      integridade.
    - Divergência de hash: linha 2 do .syncdownload invalida cache e força
      reprocessamento.
    - Herança infinita: limite máximo de profundidade (recursion limit) para
      evitar loops.

    [COMPATIBILIDADE / ESTILO]
    - Runtime: PowerShell 5.1 | PowerShell 7.4+ | PHP 8.x | Node.js
    - OS Context: Windows 11+ | Linux | WinPE | SYSTEM Context.

    [PARSER]
    - Parser em ./parser.ps1:
        - has_parser_expression ([string]$source) -> [bool]:
          Valida presença de expressão DSL ${"..."}.
        - resolve_dsl ([string]$source, [ScriptBlock]$callback) -> [string]:
          Resolve DSL para URL final ou $null.

.NOTES
    ================================================================================
    REGRAS DE NEGÓCIO GLOBAIS DO PROJETO    
    POWERSHELL MISSION-CRITICAL FRAMEWORK - ESPECIFICAÇÃO DE EXECUÇÃO
    ================================================================================

    [CAPACIDADES GERAIS]
    Orquestração determinística, resiliente e idempotente para Windows.
    Compatibilidade Dual-Engine (5.1 + 7.4+) em contextos SYSTEM e USER.

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
#>

Set-StrictMode -Version Latest

# -------------------------
# [UTIL] UTF-8 SAFE LOAD (MULTI-FALLBACK)
# -------------------------
function _read_source {
  param(
    [Parameter(Mandatory)][string]$source
  )

  if ([string]::IsNullOrWhiteSpace($source)) {
    throw "Fonte inválida ou vazia."
  }

  # URL (prioridade para evitar falso positivo em Test-Path)
  if ($source -match '^https?://') {
    try {
      $wc = New-Object System.Net.WebClient
      $wc.Encoding = [System.Text.Encoding]::UTF8
      return $wc.DownloadString($source)
    }
    catch {
      throw "Falha ao carregar URL: $source"
    }
  }

  # Path local
  if ($source -match '^[a-zA-Z]:\\|^\.\\|^\/' -and (Test-Path $source)) {
    try {
      $resolved = (Resolve-Path $source).ProviderPath
      $bytes = [System.IO.File]::ReadAllBytes($resolved)
      return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
      throw "Falha ao ler arquivo local: $source"
    }
  }    
    

  return $source
}

# -------------------------
# [UTIL] YAML/JSON PARSER (DEFENSIVO)
# -------------------------
function _parse_yaml {
  param(
    [Parameter(Mandatory)][string]$content
  )

  try {
    $trim = $content.Trim()

    # JSON direto
    if ($trim.StartsWith("{") -or $trim.StartsWith("[")) {
      return $content | ConvertFrom-Json -ErrorAction Stop
    }

    # YAML mínimo -> tentativa via conversão indireta (fallback)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
      try {
        if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
          return ConvertFrom-Yaml $content -ErrorAction Stop
        }
      }
      catch {}
    }

    throw "Parser YAML indisponível no runtime atual."
  }
  catch {
    throw "Erro de parsing: formato não suportado ou inválido. Conteúdo inicial: $($content.Substring(0, [Math]::Min(120, $content.Length)))"
  }
}

# -------------------------
# [VALIDATION - HARDENED]
# -------------------------
function _validate_manifest {
  param(
    [Parameter(Mandatory)]$manifest
  )

  if (-not $manifest.apps -or -not ($manifest.apps -is [System.Collections.IEnumerable])) {
    throw "Campo obrigatório inválido: apps"
  }

  if (-not $manifest.profiles -or -not ($manifest.profiles -is [System.Collections.IEnumerable])) {
    throw "Campo obrigatório inválido: profiles"
  }

  foreach ($app in $manifest.apps) {
    if (-not $app.id -or -not ($app.id -is [string])) {
      throw "App inválido: id obrigatório e deve ser string."
    }
  }

  foreach ($profile in $manifest.profiles) {
    if (-not $profile.name -or -not ($profile.name -is [string])) {
      throw "Profile inválido: name obrigatório."
    }

    if (-not ($profile.items -or $profile.include_profiles)) {
      throw "Profile inválido: items ou include_profiles obrigatório."
    }
  }

  return $true
}

# -------------------------
# [INDEX BUILD - IMMUTABLE SAFE]
# -------------------------
function _build_index {
  param(
    [Parameter(Mandatory)]$manifest
  )

  $index = @{}

  foreach ($app in $manifest.apps) {
    if ($index.ContainsKey($app.id)) {
      throw "Duplicidade de id detectada: $($app.id)"
    }

    # clone defensivo (evita mutação externa)
    $cloned = ($app | ConvertTo-Json -Depth 10 | ConvertFrom-Json)

    if ($cloned.url -and $cloned.url -is [string]) {
      if (Get-Command has_parser_expression -ErrorAction SilentlyContinue) {
        if (has_parser_expression $cloned.url) {
          if (Get-Command resolve_dsl -ErrorAction SilentlyContinue) {
            $resolved = resolve_dsl $cloned.url { param($x) return $null }
            if ($resolved) {
              $cloned.url_resolved = $resolved
            }
          }
        }
      }
    }

    $index[$app.id] = $cloned                
  }

  return $index
}

# -------------------------
# [PUBLIC] load_manifest
# -------------------------
function load_manifest {
  param(
    [Parameter(Mandatory)][string]$source
  )

  $raw = _read_source -source $source
  $manifest = _parse_yaml -content $raw

  _validate_manifest -manifest $manifest | Out-Null

  $index = _build_index -manifest $manifest

  return [PSCustomObject]@{
    raw      = $raw
    manifest = $manifest
    index    = $index
  }
}

# -------------------------
# [PUBLIC] get_app (FIX: retorno consistente)
# -------------------------
function get_app {
  param(
    [Parameter(Mandatory)]$ctx,
    [Parameter(Mandatory)][string]$id
  )

  if ($ctx.index.ContainsKey($id)) {
    return $ctx.index[$id]
  }

  # fallback externo (normalizado para app único)
  if ($id -match '^https?://' -or (Test-Path $id)) {
    $ext = load_manifest -source $id

    if (-not $ext.manifest.apps -or $ext.manifest.apps.Count -ne 1) {
      throw "Manifesto externo inválido (esperado 1 app)."
    }

    $app = $ext.manifest.apps[0]
    return ($app | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
  }

  return $null
}

# -------------------------
# [PUBLIC] get_apps_by_tag (FIX ENUM BUG)
# -------------------------
function get_apps_by_tag {
  param(
    [Parameter(Mandatory)]$ctx,
    [Parameter(Mandatory)][string]$tag
  )

  $result = @()

  foreach ($app in $ctx.manifest.apps) {
    if ($null -ne $app.tags) {

      if ($app.tags -is [string]) {
        if ($app.tags -eq $tag) {
          $result += $app
        }
      }
      elseif ($app.tags -is [array]) {
        if ($app.tags -contains $tag) {
          $result += $app
        }
      }
    }
  }

  return $result
}

# -------------------------
# [PUBLIC] get_value (SAFE ACCESS)
# -------------------------
function get_value {
  param(
    [Parameter(Mandatory)]$ctx,
    [Parameter(Mandatory)][string]$app_id,
    [Parameter(Mandatory)][string]$key
  )

  $app = get_app -ctx $ctx -id $app_id

  if (-not $app) {
    return $null
  }

  if ($app.PSObject.Properties.Name -contains $key) {
    if ($key -eq 'url' -and $app.url_resolved) {
      $value = $app.url_resolved
    }
    else {
      $value = $app.$key
    }

    return $value
  }

  return $null
}

# -------------------------
# [RECURSION GUARD]
# -------------------------
$global:_PROFILE_DEPTH_LIMIT = 32

# -------------------------
# [PUBLIC] resolve_profile (HARDENED)
# -------------------------
function resolve_profile {
  param(
    [Parameter(Mandatory)]$ctx,
    [Parameter(Mandatory)][string]$profile_name,
    [int]$depth = 0,
    [hashtable]$visited = @{}
  )

  if ($depth -gt $global:_PROFILE_DEPTH_LIMIT) {
    throw "Limite de recursão excedido (possível loop de herança)."
  }

  if ($visited.ContainsKey($profile_name)) {
    return @()
  }

  $visited[$profile_name] = $true

  $profile = $ctx.manifest.profiles | Where-Object { $_.name -eq $profile_name }

  if (-not $profile -or $profile.Count -ne 1) {
    throw "Profile inválido ou duplicado: $profile_name"
  }

  $result = @()

  # Herança
  if ($profile.include_profiles) {
    foreach ($p in $profile.include_profiles) {
      $result += resolve_profile -ctx $ctx -profile_name $p -depth ($depth + 1) -visited $visited
    }
  }

  # Items
  if ($profile.items) {
    foreach ($item in $profile.items) {

      if ($item.ref) {

        if (-not ($item.ref -is [string])) {
          throw "Ref inválido (tipo não suportado)."
        }

        $app = get_app -ctx $ctx -id $item.ref

        if (-not $app) {
          throw "Ref inválido: $($item.ref)"
        }

        $result += $app
      }
      else {
        if (-not $item.id) {
          throw "Inline AppObject sem id."
        }

        $result += ($item | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
      }
    }
  }

  # Deduplicação determinística
  $seen = @{}
  $final = @()

  foreach ($app in $result) {
    if ($app.id -and -not $seen.ContainsKey($app.id)) {
      $seen[$app.id] = $true
      $final += $app
    }
  }

  return $final
}