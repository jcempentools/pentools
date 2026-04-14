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
      apps:     [Lista!] Definições globais de pacotes (id, [name ou path]).
      profiles: [Lista!] Grupos de execução (name, items OU include).

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
      - name:    (string) Nome identificador do perfil.
      - include: (lista)  Nomes de outros perfis para herança (recursivo).
      - items:   (lista)  IDs de apps (strings) OU definição local (Inline AppObject).

    [MODUS OPERANDI (FLUXO LÓGICO)]
    1. INICIALIZAÇÃO: Carregamento seguro da fonte (caminho local, URL ou string
       YAML).
    2. RESOLUÇÃO: Mapeamento de items de profiles locais para 'apps' globais.       
    2.a. Se Apps equivalente contiver path, e o path for de um arquivo 
         .json, importá-lo e lê-lo/parseá-lo como AppObject;
    2.b. Se Apps equivalente contiver path, e o path for um arquivo
        .suncdownload:
        PARSING POSICIONAL (inferir propriedade a partir de .syncdownload):
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
    3. HERANÇA: Processamento de 'include' (flattening para lista
       linear).
    4. INTEGRIDADE: Validação de tipos obrigatórios e detecção de referências
       circulares.
    5. ENTREGA: Disponibilização de um iterador idempotente com metadados
       resolvidos.
    * O processamento de DSL/URL é síncrono; todos os dados lazy (canonico,
      extensão, versão, filename) devem ser resolvidos apenas a partir da URL ou
      HEADER e armazenados para acesso futuro.

    [IMPLEMENTATION_CONTRACT - INTERFACE DE ACESSO]
    As funções abaixo devem ser implementadas seguindo a lógica de retorno de 
    objetos nativos (PSCustomObject) com membros injetados (ScriptMethod):

    - load_manifest(source: String) -> PSCustomObject
        - Ponto de entrada via ConvertFrom-Json. Aceita path, URL ou string bruta. 
          Realiza a injeção dos Callables e retorna o objeto raiz validado.
    - get_app(id: String) -> AppObject
        - Busca no dicionário global de 'apps'. Retorna o objeto com seus 
          métodos de Lazy Resolution ou $null se falhar.
    - get_apps_by_tag(tag: String) -> AppObject[]
        - Filtra a coleção de apps onde a tag esteja contida na lista 'tags'. 
          Busca case-insensitive.
    - get_value(app_id: String, key: String) -> Object
        - Atalho para execução de callable ou acesso à propriedade:
          (get_app "id").key().
    - resolve_profile(manifest: PSCustomObject, profile_name: String) -> AppObject[]
        - Resolve recursivamente o campo 'include' e achata o campo 'items'.
        - Retorno: lista linear, ordenada e sem duplicatas de AppObjects, 
          substituindo IDs de strings pelos objetos reais correspondentes.


    [RESTRIÇÕES / VEDAÇÕES (HARD RULES)]
    - ❌ Realizar download de binários ou execução de scripts (papel do Orquestrador).
    - ❌ Permitir inconsistência de tipos ou ausência de campos obrigatórios.
    - ❌ Omitir erros de parsing; o leitor deve falhar rápido (fail-fast).
    - ❌ Assumir codificação; o processamento deve ser estritamente UTF-8 (não na
          origem, mas convertido na recepção).
    - ❌ Mutação de dados; o leitor não deve alterar o manifesto original.

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
    - Este script NÃO implementa Parser/DSL;
    - Parser/DSL em ./parser-DSL.ps1:
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
#>

#requires -version 5.1
<#
[... CABEÇALHO ORIGINAL PRESERVADO INTEGRALMENTE ...]
#>

#region GLOBALS (imutáveis)
Set-StrictMode -Version Latest

# integração parser DSL externo
$__dslPath = Join-Path $PSScriptRoot 'parser-DSL.ps1'
if (Test-Path $__dslPath) {
  . $__dslPath
}
else {
  throw "[parser] parser DSL externo não encontrado (parser-DSL.ps1)"
}

$script:__MANIFEST = $null
$script:__APP_INDEX = @{}
$script:__PROFILE_INDEX = @{}
$script:__CACHE = @{}
$script:__RECURSION_LIMIT = 32
#endregion

#region UTILS
function _fail([string]$msg) {
  throw "[parser] $msg"
}

function _is_url([string]$s) {
  return $s -match '^https?://'
}

function _read_source([string]$source) {
  if ([string]::IsNullOrWhiteSpace($source)) {
    _fail "source vazio"
  }

  $attempts = 0
  $max = 3

  while ($attempts -lt $max) {
    try {
      if (Test-Path $source) {
        return [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
      }
      elseif (_is_url $source) {
        $req = [System.Net.WebRequest]::Create($source)
        $req.Method = "GET"
        $req.Timeout = 15000

        $res = $null
        $stream = $null
        $reader = $null

        try {
          $res = $req.GetResponse()
          $stream = $res.GetResponseStream()
          $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
          return $reader.ReadToEnd()
        }
        catch {
          _fail "falha HTTP ao acessar '$source': $($_.Exception.Message)"
        }
        finally {
          if ($reader) { $reader.Dispose() }
          if ($stream) { $stream.Dispose() }
          if ($res) { $res.Dispose() }
        }
      }
      else {
        return $source
      }
    }
    catch {
      # retry apenas para IO/local (não HTTP)
      if (-not (_is_url $source)) {
        Start-Sleep -Milliseconds (200 * ($attempts + 1))
        $attempts++
        if ($attempts -ge $max) {
          _fail "falha ao carregar source após retry: $($_.Exception.Message)"
        }
      }
      else {
        throw
      }
    }
  }
}

function _parse_json([string]$raw) {
  try {
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop

    if (-not ($obj -is [psobject])) {
      _fail "JSON root inválido (esperado objeto)"
    }

    return $obj
  }
  catch {
    _fail "formato inválido (esperado JSON válido): $($_.Exception.Message)"
  }
}

function _parse_syncdownload([string]$raw) {
  $lines = ($raw -split "`r?`n") | Where-Object { $_ -and $_.Trim() -ne "" }

  if ($lines.Count -lt 1) {
    _fail ".syncdownload inválido (sem linhas)"
  }

  $l1 = $lines[0].Trim()
  $l2 = if ($lines.Count -ge 2) { $lines[1].Trim() } else { $null }
  $l3 = if ($lines.Count -ge 3) { $lines[2].Trim() } else { $null }

  $ext = $null
  $tags = @()
  $url = $null

  # --- MODO 1: formato completo ext,tags|url ---
  if ($l1 -match '\|') {
    $parts = $l1 -split '\|'
    if ($parts.Count -ne 2) {
      _fail "L1 inválida (.syncdownload)"
    }

    $meta = $parts[0].Split(',')
    $url = $parts[1].Trim()

    foreach ($m in $meta) {
      $m = $m.Trim()

      if ($m -match '^\.\w+$') {
        $ext = $m.ToLower()
      }
      else {
        # normalização de tag
        $tag = ($m -replace '[^a-zA-Z0-9]', '').ToLower()
        if ($tag) { $tags += $tag }
      }
    }
  }
  else {
    # --- MODO 2: URL direta ou DSL ---
    $url = $l1.Trim()
  }
  
  # validação sintática apenas (sem resolver ainda)
  if (-not (_is_url $url) -and -not (has_parser_expression $url)) {
    _fail "L1 inválida: nem URL nem DSL"
  }

  # valida extensão permitida
  if ($ext -and $ext -notin @('.exe', '.msi', '.zip', '.7z', '.gz')) {
    _fail "extensão inválida em L1"
  }

  # L2 hash
  if ($l2 -and $l2 -notmatch '^[A-Fa-f0-9]{64}$') {
    _fail "hash inválido em L2"
  }

  # L3 tratamento completo conforme regra
  $name = $l3
  if ($name) {
    # remove {} e tudo após
    $name = $name -replace '\{.*$', ''
    $name = $name.Trim()
  }

  $canon = _canonical $name

  return [PSCustomObject]@{
    url       = $url
    extension = $ext
    hash      = $l2
    name      = $name
    canonico  = $canon
    version   = $null
    tags      = $tags
  }
}

function _validate_manifest($m) {
  if (-not $m.profiles) {
    _fail "estrutura inválida: 'profiles' é obrigatório"
  }

  if ($m.apps) {
    foreach ($a in $m.apps) {
      if (-not $a.id) { _fail "app sem id" }

      if (-not ($a.name -or $a.path)) {
        _fail "app '$($a.id)' inválido (name ou path obrigatório)"
      }
    }
  }

  foreach ($p in $m.profiles) {
    if (-not $p.name) { _fail "profile sem name" }
    if (-not ($p.items -or $p.include)) {
      _fail "profile '$($p.name)' inválido"
    }
  }
}

function _index_manifest($m) {
  $script:__APP_INDEX = @{}

  if ($m.apps) {
    foreach ($a in $m.apps) {
      if ($script:__APP_INDEX.ContainsKey($a.id)) {
        _fail "id duplicado: $($a.id)"
      }
      $script:__APP_INDEX[$a.id] = $a
    }
  }

  $script:__PROFILE_INDEX = @{}
  if (-not ($m.profiles -is [System.Collections.IEnumerable])) {
    _fail "'profiles' deve ser coleção enumerável"
  }

  foreach ($p in $m.profiles) {
    $script:__PROFILE_INDEX[$p.name] = $p
  }
}
#endregion

#region LAZY RESOLUTION
function _lazy($app, [string]$key, [ScriptBlock]$resolver) {
  # invalidação por hash
  if ($app.hash) {
    if (-not $script:__CACHE[$app.id]) {
      $script:__CACHE[$app.id] = @{}
    }
    elseif ($script:__CACHE[$app.id].__hash -and $script:__CACHE[$app.id].__hash -ne $app.hash) {
      $script:__CACHE[$app.id] = @{}
    }

    $script:__CACHE[$app.id].__hash = $app.hash
  }
  
  if (-not $script:__CACHE.ContainsKey($app.id)) {
    $script:__CACHE[$app.id] = @{}
  }

  if (-not $script:__CACHE[$app.id].ContainsKey($key)) {
    $script:__CACHE[$app.id][$key] = & $resolver
  }

  return $script:__CACHE[$app.id][$key]
}

function _infer_extension([string]$url) {
  if (-not $url) { return $null }

  if ($url -match '\.(exe|msi|zip|7z|gz)(\?|$)') {
    return ".$($Matches[1])"
  }

  try {
    # fallback HEAD
    $req = [System.Net.WebRequest]::Create($url)
    $req.Method = "HEAD"
    $req.Timeout = 5000

    $res = $null
    try {
      $res = $req.GetResponse()
      $ct = $res.ContentType

      if ($ct -match 'application/octet-stream') { return ".exe" }
      if ($ct -match 'zip') { return ".zip" }
    }
    finally {
      if ($res) { $res.Dispose() }
    }
  }
  catch {}

  return $null
}

function _infer_version([string]$url) {
  if (-not $url) { return $null }

  if ($url -match '\b(\d+(?:[.\-]\d+){1,2})(?:[-_]?(rc|beta|alfa))?\b') {
    return $Matches[1]
  }

  return $null
}

function _canonical([string]$name) {
  if (-not $name) { return $null }

  # remove {} e conteúdo posterior
  $name = $name -replace '\{.*?\}', ''

  # remove não alfanuméricos nas bordas
  $name = $name -replace '^[^a-zA-Z0-9]+|[^a-zA-Z0-9]+$', ''

  # remove internos não alfanuméricos
  $name = $name -replace '[^a-zA-Z0-9]', ''

  return $name.ToLower()
}
#endregion

#region CORE API
function load_manifest([string]$source) {
  $raw = _read_source $source
  $obj = _parse_json $raw
  _validate_manifest $obj
  _index_manifest $obj

  # injeção de interface (contract)
  $obj | Add-Member ScriptMethod get_app { param($id) get_app $id } -Force
  $obj | Add-Member ScriptMethod get_apps_by_tag { param($tag) get_apps_by_tag $tag } -Force
  $obj | Add-Member ScriptMethod get_value { param($id, $key) get_value $id $key } -Force
  $obj | Add-Member ScriptMethod resolve_profile { param($name) resolve_profile $this $name } -Force

  $script:__MANIFEST = $obj
  return $obj
}

function get_app([string]$id) {
  if ($script:__APP_INDEX.ContainsKey($id)) {
    $app = $script:__APP_INDEX[$id]

    # resolução via path (novo comportamento)
    if ($app.path) {
      return _lazy $app "__resolved_path" {
        $raw = _read_source $app.path

        if ($raw -match '\|') {
          $parsed = _parse_syncdownload $raw

          $clone = [PSCustomObject]@{}
          $parsed.psobject.Properties | ForEach-Object {
            $clone | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value
          }
          $clone | Add-Member -NotePropertyName id -NotePropertyValue $app.id

          return $clone
        }

        return $app
      }
    }

    return $app
  }

  return $null
}

function get_apps_by_tag([string]$tag) {
  $out = @()
  $tagNorm = $tag.ToLower()

  foreach ($a in $script:__APP_INDEX.Values) {

    $app = get_app $a.id

    if (-not $app.tags) { continue }

    if ($app.tags -is [string]) {
      if ($app.tags.ToLower() -eq $tagNorm) { $out += $app }
    }
    elseif ($app.tags | ForEach-Object { $_.ToLower() } -contains $tagNorm) {
      $out += $app
    }
  }
  return $out
}

function get_value([string]$app_id, [string]$key) {
  $app = get_app $app_id
  if (-not $app) { return $null }

  switch ($key) {
    "canonico" {
      return _lazy $app $key {
        if ($app.canonico) { return $app.canonico }
        return _canonical $app.name
      }
    }
    "extension" {
      return _lazy $app $key {
        if ($app.extension) { return $app.extension }

        $url = $app.url
        if (has_parser_expression $url) {
          $url = resolve_dsl $url { param($u) $u }
          if (-not $url) { return $null }
        }

        return _infer_extension $url
      }
    }
    "version" {
      return _lazy $app $key {
        if ($app.version) { return $app.version }

        $url = $app.url
        if (has_parser_expression $url) {
          $url = resolve_dsl $url { param($u) $u }
          if (-not $url) { return $null }
        }

        return _infer_version $url
      }
    }
    "filename" {
      return _lazy $app $key {
        $name = (_canonical $app.name)
        $ver = get_value $app.id "version"
        $ext = get_value $app.id "extension"

        if ($name -and $ext) {
          if ($ver) {
            return "$name.$ver$ext"
          }
          return "$name$ext"
        }
        return $null
      }
    }
    default {
      return $app.$key
    }
  }
}

function resolve_profile($manifest, [string]$profile_name) {
  $visited = @{}
  $result = @()

  function _walk([string]$name, [int]$depth) {
    if ($depth -gt $script:__RECURSION_LIMIT) {
      _fail "loop de herança detectado"
    }

    if ($visited[$name]) { return }
    $visited[$name] = $true

    $p = $script:__PROFILE_INDEX[$name]
    if (-not $p) {
      _fail "profile inexistente: $name"
    }

    if ($p.include) {
      foreach ($inc in $p.include) {
        _walk $inc ($depth + 1)
      }
    }

    if ($p.items) {
      foreach ($i in $p.items) {

        # modo string direta (ID)
        if ($i -is [string]) {
          $app = get_app $i
          if (-not $app) {
            _fail "ref inválido: $i"
          }
          $result += $app
          continue
        }

        # modo objeto com ref
        # modo inline AppObject
        if ($i.id) {
          if (-not ($i.name -or $i.path)) {
            _fail "inline app '$($i.id)' inválido"
          }

          if ($i.path) {
            $raw = _read_source $i.path

            # suporte a .json (2.a)
            if ($i.path -match '\.json$') {
              $parsedJson = _parse_json $raw
              $result += $parsedJson
              continue
            }

            if ($raw -match '\|') {
              $parsed = _parse_syncdownload $raw

              $clone = [PSCustomObject]@{}
              $parsed.psobject.Properties | ForEach-Object {
                $clone | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value
              }
              $clone | Add-Member -NotePropertyName id -NotePropertyValue $i.id

              $result += $clone
              continue
            }
          }

          $result += $i
          continue
        }

        _fail "item inválido no profile '$($p.name)'"
      }
    }
  }

  _walk $profile_name 0

  # deduplicação por id
  $seen = @{}
  $final = @()
  foreach ($a in $result) {
    if (-not $seen[$a.id]) {
      $seen[$a.id] = $true
      $final += $a
    }
  }

  return $final
}
#endregion

#region ENTRYPOINT
function main {
  param(
    [string]$source,
    [string]$profile
  )

  $m = load_manifest $source

  if ($profile) {
    return resolve_profile $m $profile
  }

  return $m
}

if ($MyInvocation.InvocationName -ne '.') {
  main @args
}
#endregion