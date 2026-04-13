<#
.SYNOPSIS
    Standard Autonomous Installer Specification (SAIS) - v1.5
    Biblioteca "Reader" para Manifestos de Instalação Cross-Language.

.DESCRIPTION
    Define o padrão para o componente LEITOR. Sua função é estritamente de Parsing, 
    Validação e Iteração. A biblioteca NÃO executa instalações nem downloads; 
    ela processa a árvore de dependências e entrega dados saneados para o Orquestrador.

    ESTRUTURA DO DOCUMENTO (DATA SCHEMA)
    ------------------------------------------------------------------------------
    RAIZ:
      apps:     [Lista!] Definições globais de pacotes (Obrigatório: id, name).
      profiles: [Lista!] Grupos de execução (Obrigatório: name, items OU include_profiles).

    ESQUEMA DE OBJETOS 'APPS' (AppObject):
      - id:        (string) Identificador único para referenciamento interno.
      - name:      (string) Nome fixo canonico referencial de filename (igual à linha 3 de .syncdownload) (opcional)
      - canonico():(string) Nome fixo canonico, verdadeiro, um nome de software identificável,
                            baseado em name, conforme regras de negócio (inalterável)
      - extension: (string) Extensão preferencial (ex: exe, msi) (opcional - na ausência 
                            inferida, a partir da url ou HEADER).
      - url:       (string) Link direto ou Notação Parser DSL para resolução dinâmica.
                            * a presença se DSL é automaticamente resolvida pelo script
      - hash:      (string) Checksum sha256 puro (ex: sha256) (opcional, apenas
                            para fixar versão).
      - tags:      (lista)  Metadados para filtragem e agrupamento (opcional).      
      - script:    (string) Comando CLI (ps1/bash) para instalação silenciosa (opcional).

    ESQUEMA DE OBJETOS 'PROFILES' (ProfileObject):
      - name:             (string) Nome identificador do perfil.
      - include_profiles: (lista)  Nomes de outros perfis para herança (recursivo).
      - items:            (lista)  Objetos contendo 'ref' (ID ou Path Externo) 
                                   OU definição local (Inline AppObject).

    [MODUS OPERANDI (FLUXO LÓGICO)]
    1. INICIALIZAÇÃO: Carregamento seguro da fonte (Caminho Local, URL ou String YAML).
    2. RESOLUÇÃO: Mapeamento de 'ref' locais para 'apps' globais. Se inexistente,
       tratar 'ref' como Path (URL/Local) para arquivo .syncdownload ou .yml externo.
    3. PARSING POSICIONAL (inferir propriedade a partir de .syncdownload):
       - L1: Origem Link direto, (ext[+tag]|url) ou DSL [@attr='val']. Deve resolver URL final.
       - L2: SHA256 (opcional) (Hex). Fixa versão do software;
       - L3: Nome Customizado/Canônico com placeholders espcífico para
             version, subversão, build - para nomeação do arquivo final.
             - o '{}', os não alfanuméricos (imediatamente interligados) ao '{}', 
               e aqueles posteriores ao '{}': não canónico;
             - caracteres não alfanuméricos de bordas (left/right): não canônicos;             
        Todas as resoluções devem usar apenas url ou HEADER para metadados, sincronamente,
        baixando o destino real apenas se necessário.
    4. HERANÇA: Processamento de 'include_profiles' (Flattening para lista linear).
    5. INTEGRIDADE: Validação de tipos obrigatórios e detecção de referências circulares.
    6. ENTREGA: Disponibilização de um iterador idempotente com metadados resolvidos.    

    [IMPLEMENTATION_CONTRACT - INTERFACE DE ACESSO]
    As funções abaixo devem ser implementadas seguindo a lógica de retorno de objetos:
    - load_manifest(source: String) -> Object
        - Ponto de entrada. Aceita Path, URL ou String bruta. Retorna o objeto validado.
    - get_app(id: String) -> AppObject
        - Busca no dicionário global ou resolve via Path externo. Retorna $null se falhar.
    - get_apps_by_tag(tag: String) -> List<AppObject>        
        - Filtra apps onde a tag informada esteja contida no campo (seja ele String ou Lista/vetor).
    - get_value(app_id: String, key: String) -> Any
        - Acesso direto a uma propriedade específica de um app via ID.
    - resolve_profile(manifest: Object, profile_name: String) -> List<AppObject>
        - Resolve heranças e referências de um perfil específico.
        - Retorno: Lista linear, ordenada e sem duplicatas de AppObjects prontos.

    [RESTRIÇÕES / VEDAÇÕES (HARD RULES)]
    - ❌ PROIBIDO: Realizar download de binários ou execução de scripts (Papel do Orquestrador).
    - ❌ PROIBIDO: Permitir inconsistência de tipos ou ausência de campos obrigatórios.
    - ❌ PROIBIDO: Omitir erros de parsing; o leitor deve "falhar rápido" (Fail-Fast).
    - ❌ PROIBIDO: Assumir codificação; o processamento deve ser estritamente UTF-8 
                   (não na origem [não administrável], mas cnvertido na recepção).
    - ❌ PROIBIDO: Mutação de dados; o leitor não deve alterar o manifesto original.

    [FAIL-SAFE / RESILIÊNCIA]
    - Erros de Sintaxe: Interromper imediatamente e reportar posição (linha/coluna).
    - Referência Ausente (ref): Se não for Path ou ID, lançar exceção de integridade.
    - Divergência de Hash: Linha 2 do .syncdownload invalida cache e força reprocessamento.
    - Herança Infinita: Trava de profundidade máxima (Recursion Limit) para evitar loops.

    [COMPATIBILIDADE / ESTILO]
    - Runtime: PowerShell 5.1 | PowerShell 7.4+ | PHP 8.x | Node.js
    - OS Context: Windows 11+ | Linux | WinPE | SYSTEM Context.    

    [PARSER]    

    - Parser em ./parser.ps1:
        - has_parser_expression ([string]$source) -> [bool]: Valida presença de expressão DSL ${"..."}.
        - resolve_dsl ([string]$source, [ScriptBlock]$callback) -> [string]: Resolve DSL para URL final ou $null.

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
