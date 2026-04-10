# ==============================================================================
# BIBLIOTECA PARSER DSL — CONTRATO OPERACIONAL (PowerShell 7.6+)
# ==============================================================================
#
# OBJETIVO
# - Permitir definição declarativa de URLs dinâmicas via DSL embutida.
# - Abstrair fontes remotas (APIs JSON, YAML e XML) sem parsing heurístico.
# - Resolver endpoints dinâmicos de forma determinística e cacheada.
#
# ESCOPO
# - Aplicável exclusivamente à primeira linha do arquivo .syncdownload.
# - Suporta as seguintes variações de entrada:
#   • URL direta (estática).
#   • Expressão DSL pura: ${"url"}.path.to.value
#   • URL com especificação/metadados (ex: ".exe,x64 | https://github...").
#   • URL com especificação contendo DSL (ex: ".zip,x84 | ${'url'}.path").
#
# SINTAXE DSL (ESTRUTURA NAVEGACIONAL)
# - Forma base:
#     ${"https://exemplo.com"}.campo.subcampo[0].valor
#
# - Regras de Formatação:
#   • A URL de origem deve estar obrigatoriamente entre ${"..."} ou ${'...'}.
#   • O sufixo imediatamente após o fechamento '}' define o path de extração.
#   • O Path suporta navegação profunda (deep nesting):
#       - Acesso a membros de objetos: .campo
#       - Acesso a índices de arrays/coleções: [index]
#
# EXEMPLOS DE USO
# - ${"https://github.com"}.assets[0].browser_download_url
# - ${"https://exemplo.com"}.items[2].file.url
# - ".msi,x64 | ${'https://exemplo.com'}.downloads.stable.link"
#
# PIPELINE DE RESOLUÇÃO
# 1. Detectar expressão DSL na string (has_parser_expression).
# 2. Extrair URL base contida nos delimitadores (extract_parser_url).
# 3. Realizar fetch remoto com suporte a Cache TTL (fetch_and_parse).
# 4. Executar Parse estruturado:
#    • Aceita JSON, YAML ou XML (deve ser parseável/válido).
#    • Identificação automática via Content-Type ou Fallback seguro.
# 5. Resolver path determinístico sobre o objeto resultante (resolve_data_path).
# 6. Retornar valor final (conversão obrigatória para [string] de URL).
#
# CACHE / PERFORMANCE
# - Cache em memória persistente na sessão (__PARSER_CACHE).
# - TTL (Time-To-Live) padrão: 60 segundos.
# - Objetivo: Evitar múltiplos requests idênticos na mesma janela de execução.
#
# FAIL-SAFE / VALIDAÇÃO (DIRETRIZES DE ERRO)
# - O processo de parsing falha se:
#   • A URL de origem for inválida ou inacessível (Timeout/404).
#   • A resposta remota não for um formato parseável (JSON/YAML/XML).
#   • O path navegacional for inválido, inexistente ou interrompido.
#   • O resultado da navegação não puder ser convertido em string.
#
# - Comportamento em caso de erro:
#   • O parser NÃO deve interromper a execução global do script principal.
#   • Retorna $null (valor nulo idiomático do PowerShell).
#   • O erro deve ser logado via 'show_message' em tela ou via callback fornecido.
#
# DETERMINISMO
# - Mesma entrada (URL + Path) → mesma saída dentro da janela do TTL.
# - Operação idempotente: sem efeitos colaterais no servidor remoto (apenas GET).
# - Sem dependência de estado externo além da resposta HTTP da API.
#
# RESTRIÇÕES E SEGURANÇA
# - NÃO suportar parsing de documentos HTML ou Scraping.
# - NÃO executar código arbitrário ou scripts (bloqueio de Invoke-Expression).
# - NÃO permitir múltiplas expressões DSL encadeadas ou aninhadas.
# - NÃO permitir mutação de dados (operação estritamente de leitura).
#
# EXTENSIBILIDADE (ROADMAP)
# - Futuro suporte planejado para:
#   • Operadores de fallback/coalescência (ex: path.valor ?? "default").
#   • Seleção por filtros avançados (ex: items[?name=="app_v2"]).
#
# INTEGRAÇÃO SISTÊMICA
# - Consumido primariamente por:
#   • parse_syncdownload()
#   • resolve_syncdownload_cached()
#
# GARANTIAS
# - Interface uniforme para qualquer origem baseada em API estruturada.
# - Compatível com pipeline de download e rotinas de validação de hash existentes.
# - Totalmente alinhado com o princípio de "Abstração Universal de Origens".
# ==============================================================================
