#requires -version 5.1

# ==============================

# TESTE DE HIERARQUIA DE LOG (IMPORTANDO BIBLIOTECA)

# ==============================

# Importação da biblioteca (modo script)

. "$PSScriptRoot\logger.ps1"

# ROOT

$root = _logger "Início da Transação 45892" "t"

# BLOCO AUTH

$auth = _logger "Validando Credenciais" "s"

$db = _logger "Conectando ao Pool de Usuários" "s"
$q1 = _logger "SELECT * FROM usuarios WHERE id = 10" "s"
_logger "Tempo de Resposta: 12ms" "i"
_logger "Resultado: Sucesso" "i"

# SUBNÍVEL EXTRA (TESTE DE PROFUNDIDADE)

$deep1 = _logger "Iniciando análise profunda" "s"
$deep2 = _logger "Executando validação interna" "s"
_logger "Checkpoint A OK" "i"

# FECHAMENTO PARA DB (SALTO MULTI-NÍVEL)

_logger "SELECT permissoes FROM roles WHERE id = 5" "s" $db
_logger "Tempo de Resposta: 8ms" "i"
_logger "Resultado: Sucesso" "i"

# volta para AUTH

$jwt = _logger "Verificando Assinatura do Token" "s" $auth
_logger "Status: Token Válido" "i"

# NOVO SUBNÍVEL + IRMÃO

$cache = _logger "Atualizando Sessão do Usuário" "s" ":"
_logger "Chave: sess_45892" "i"

$cacheAudit = _logger "Auditando cache distribuído" "s"
_logger "Região: us-east" "i"

# FECHAMENTO PARCIAL (VOLTA PARA AUTH)

_logger "Revalidação de sessão" "s" $auth
_logger "Status: OK" "i"

# BLOCO CORE (irmão de AUTH)

$core = _logger "Processando Pedido de Compra" "t" ":"

$stock = _logger "Verificando Disponibilidade" "s"
$sku1 = _logger "SKU: 8829-X" "s"
_logger "Qtd_Disponivel: 15" "i"
_logger "Status: Em_Estoque" "i"

# SUBNÍVEL EXTRA EM STOCK

$stockCheck = _logger "Validação de consistência de estoque" "s"
_logger "Lock: OK" "i"

# FECHAMENTO PARA STOCK

$sku2 = _logger "SKU: 1102-Y" "s" $stock
_logger "Qtd_Disponivel: 3" "i"
_logger "Status: Em_Estoque" "i"

# PAY dentro de CORE

$pay = _logger "Iniciando Checkout Externo" "s" $core
_logger "Gateway: Stripe" "i"

# SUBNÍVEL EM PAY

$retry = _logger "Aguardando confirmação externa" "s"
_logger "Tentativa 1" "i"
_logger "Timeout parcial" "w"

# FECHAMENTO DIRETO PARA CORE (SALTO MULTI-NÍVEL)

_logger "Status: Aguardando Callback" "i" $core

# REABERTURA CONTROLADA EM PAY (IRMÃO)

$pay2 = _logger "Fallback para segundo gateway" "s" ":"
_logger "Gateway: BackupPay" "i"
_logger "Status: Inicializado" "i"

# FINALIZAÇÃO GLOBAL (salto explícito para ROOT)

_logger "Fim do Processo (Status: Pendente)" "t" $root
_logger "Resumo: Execução concluída com pendências externas" "i"
_logger "Código de rastreio: TRX-45892-A" "l"
