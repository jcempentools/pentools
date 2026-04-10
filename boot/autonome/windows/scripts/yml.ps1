<#
# ==============================================================================
# [ESPECIFICAÇÃO DO MANIFESTO DE INSTALAÇÃO (SAIS v1.5)]
# ==============================================================================
# CONTRATO DE IMPLEMENTAÇÃO PARA BIBLIOTECA "READER" (PARSER & ITERATOR)
#
# ESTRUTURA DO DOCUMENTO (DATA SCHEMA)
# ------------------------------------------------------------------------------
# RAIZ:
#   apps:     [Lista!] Definições globais de pacotes (Obrigatório: id, name).
#   profiles: [Lista!] Grupos de execução (Obrigatório: name, items OU include_profiles).
#
# ESQUEMA DE OBJETOS 'APPS' (AppObject):
#   - id:        (string) Identificador único para referenciamento interno.
#   - name:      (string) Nome legível do software/pacote.
#   - filename:  (string) Nome fixo para o arquivo local (sobrescreve o nome remoto).
#   - extension: (string) Extensão preferencial (ex: exe, msi, msp, zip).
#   - url:       (string) Link direto ou Notação Parser DSL para resolução dinâmica.
#   - hash:      (string) Checksum no formato Algoritmo:Hash (ex: sha256:a1b2c3...).
#   - tags:      (lista)  Metadados para filtragem e agrupamento.
#   - script:    (string) Comando CLI (ps1/bash) para instalação silenciosa.
#
# ESQUEMA DE OBJETOS 'PROFILES' (ProfileObject):
#   - name:             (string) Nome identificador do perfil.
#   - include_profiles: (lista)  Nomes de outros perfis para herança (recursivo).
#   - items:            (lista)  Objetos contendo 'ref' (ID de um app existente) 
#                                OU definição local (Inline AppObject).
# ------------------------------------------------------------------------------

.SYNOPSIS
    Standard Autonomous Installer Specification (SAIS) - v1.5
    Biblioteca "Reader" para Manifestos de Instalação Cross-Language.

.DESCRIPTION
    Define o padrão para o componente LEITOR. Sua função é estritamente de Parsing, 
    Validação e Iteração. A biblioteca NÃO executa instalações nem downloads; 
    ela processa a árvore de dependências e entrega dados saneados para o Orquestrador.

[MODUS OPERANDI (FLUXO LÓGICO)]
1. INICIALIZAÇÃO: Carregamento seguro da fonte (Caminho Local, URL ou String YAML).
2. RESOLUÇÃO: Mapeamento de referências ('ref') locais para os objetos globais 'apps'.
3. HERANÇA: Processamento de 'include_profiles' (Flattening da hierarquia para lista linear).
4. INTEGRIDADE: Validação de tipos obrigatórios e detecção de referências circulares.
5. ENTREGA: Disponibilização de um iterador idempotente com metadados resolvidos.

[IMPLEMENTATION_CONTRACT - INTERFACE DE ACESSO]
As funções abaixo devem ser implementadas seguindo a lógica de retorno de objetos:

- load_manifest(source: String) -> Object
    - Ponto de entrada. Aceita Path, URL ou String bruta. Retorna o objeto validado.
    
- get_app(id: String) -> AppObject
    - Busca um app no dicionário global. Retorna $null/None se não encontrado.
    
- get_apps_by_tag(tag: String) -> List<AppObject>
    - Filtra e retorna todos os apps que contenham a tag especificada.
    
- get_value(app_id: String, key: String) -> Any
    - Acesso direto a uma propriedade específica de um app via ID.
    
- resolve_profile(manifest: Object, profile_name: String) -> List<AppObject>
    - Resolve heranças e referências de um perfil específico.
    - Retorno: Lista linear, ordenada e sem duplicatas de AppObjects prontos.

[RESTRIÇÕES / VEDAÇÕES (HARD RULES)]
- ❌ PROIBIDO: Realizar download de binários ou execução de scripts (Papel do Orquestrador).
- ❌ PROIBIDO: Permitir inconsistência de tipos ou ausência de campos obrigatórios.
- ❌ PROIBIDO: Omitir erros de parsing; o leitor deve "falhar rápido" (Fail-Fast).
- ❌ PROIBIDO: Assumir codificação; o processamento deve ser estritamente UTF-8.
- ❌ PROIBIDO: Mutação de dados; o leitor não deve alterar o manifesto original.

[FAIL-SAFE / RESILIÊNCIA]
- Erros de Sintaxe: Interromper imediatamente e reportar posição (linha/coluna se possível).
- Referência Ausente (ref): Marcar o item como "Broken Reference" ou lançar exceção de integridade.
- Herança Infinita: Implementar trava de profundidade máxima (Recursion Limit) para evitar loops.

[COMPATIBILIDADE]
- Runtime: PowerShell 7.6+ | Python 3.x | Bash 4.0+ | PHP 8.x | Node.js
- OS Context: Windows 11+ | Linux | WinPE | SYSTEM Context.

[ESTILO & DESIGN]
- Imutabilidade: O estado do leitor deve ser consistente durante toda a sessão.
- Baixo Acoplamento: Independência total de módulos de rede ou IO de arquivos de terceiros.
- Nomenclatura: Manter suporte a camelCase e snake_case para compatibilidade entre linguagens.

[RESUMO OPERACIONAL]
FUNÇÃO: PARSER TÉCNICO, RESOLUTOR DE DEPENDÊNCIAS E ITERADOR DETERMINÍSTICO.
FOCO: SANEAMENTO DE DADOS E PADRONIZAÇÃO DE CONTRATO PARA O ORQUESTRADOR.
#>
