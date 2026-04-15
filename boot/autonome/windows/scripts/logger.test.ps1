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

# volta para nível DB

_logger "SELECT permissoes FROM roles WHERE id = 5" "s" $db
_logger "Tempo de Resposta: 8ms" "i"
_logger "Resultado: Sucesso" "i"

# volta para AUTH

$jwt = _logger "Verificando Assinatura do Token" "s" $auth
_logger "Status: Token Válido" "i"

$cache = _logger "Atualizando Sessão do Usuário" "s" ":"
_logger "Chave: sess_45892" "i"

# BLOCO CORE (irmão de AUTH)

$core = _logger "Processando Pedido de Compra" "t" ":"

$stock = _logger "Verificando Disponibilidade" "s"
$sku1 = _logger "SKU: 8829-X" "s"
_logger "Qtd_Disponivel: 15" "i"
_logger "Status: Em_Estoque" "i"

# volta para STOCK

$sku2 = _logger "SKU: 1102-Y" "s" $stock
_logger "Qtd_Disponivel: 3" "i"
_logger "Status: Em_Estoque" "i"

# PAY dentro de CORE

$pay = _logger "Iniciando Checkout Externo" "s" $core
_logger "Gateway: Stripe" "i"
_logger "Status: Aguardando Callback" "i"

# FINALIZAÇÃO GLOBAL (salto explícito para ROOT)

_logger "Fim do Processo (Status: Pendente)" "t" $root
