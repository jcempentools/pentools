<#
===============================================================================
AUTONOME BOOTSTRAP ENGINE — SPEC HEADER (PS2.0 -> PS7.6+)
===============================================================================

[OBJETIVO]
Garantir a transição segura do ambiente legado (PS 2.0-5.1) para o runtime 
moderno (PS 7.6+), assegurando privilégios SYSTEM/Admin e estabilidade do 
subsistema antes da execução do payload principal.

-------------------------------------------------------------------------------
[REGRAS DE NEGÓCIO]
- Execução estritamente síncrona, sequencial e bloqueante.
- Cada etapa deve reportar status via Callback tipado antes de prosseguir.
- Detecção cirúrgica de arquitetura (x64/ARM64) e versão de OS (WinPE/Full).
- Verificação de integridade do binário PS7 antes da invocação.
- Falha no Bootstrap = Aborto seguro com notificação imediata via Callback.

-------------------------------------------------------------------------------
[SISTEMA DE EVENTOS / CALLBACK] (OBRIGATÓRIO)
- O script não gerencia arquivos de log ou saída de console diretamente.
- Toda telemetria deve ser enviada para um ScriptBlock [callback($msg, $type)].
- Tipos de Mensagem (Parâmetro 2):
    - [t] Title: Cabeçalhos de etapa ou seções principais.
    - [l] Log: Registro padrão de fluxo e operações.
    - [i] Info: Detalhes informativos ou diagnósticos.
    - [w] Warn: Alertas de falhas não críticas ou retentativas.
    - [e] Error: Falhas críticas que exigem atenção ou aborto.

-------------------------------------------------------------------------------
[DIRETRIZES TÉCNICAS]
- Código 100% compatível com PowerShell 2.0 (Bootstrap Core).
- Independência total de Host (WinPE Shell, Task Scheduler, Session 0).
- Suporte nativo a execução em contexto SYSTEM e TrustedInstaller.
- Uso exclusivo de comandos nativos (cmd, reg, robocopy, tasklist).

-------------------------------------------------------------------------------
[RESTRIÇÕES / VEDAÇÕES]
- ❌ Não gerenciar instalação de aplicações ou configurações de UI.
- ❌ Não possuir lógica de escrita direta em disco (Delegado ao Callback).
- ❌ Não carregar perfis de usuário ($Profile = $null).
- ❌ Não permitir múltiplas instâncias concorrentes (Mutex Atômico).

-------------------------------------------------------------------------------
[MODUS OPERANDI (THE BOOTSTRAP PIPELINE)]
1. Inicialização de Barreira: Configuração de TLS, ExecutionPolicy e Mutex.
2. Context Discovery: Identifica privilégios e ambiente (WinPE vs Full OS).
3. Runtime Audit: Localiza PS7.6+ em (1) Pasta de Origem -> (2) Program Files.
4. Integrity Check: Validação funcional do pwsh.exe (smoke test).
5. Payload Handoff: Invocação do PS7 passando argumentos e contexto original.
6. Monitoring: Aguarda o processo filho e repassa o ExitCode via Callback [l].

-------------------------------------------------------------------------------
[FAIL-SAFE / RESILIÊNCIA]
- PS7 Ausente/Corrompido: Disparar [e] Error e abortar imediatamente.
- Barreira DISM/CBS: Aguardar operações pendentes com aviso via [w] Warn.
- Se Callback ausente: Silêncio operacional (fail-safe para evitar erro de script).

-------------------------------------------------------------------------------
[COMPATIBILIDADE]
- Host: Windows Setup (Shift+F10), WinPE, Windows 10/11.
- Engine: PowerShell 2.0 (mínimo) até PowerShell 7.6+ (alvo).
- Privilégio: SYSTEM, Administrator, TrustedInstaller.

-------------------------------------------------------------------------------
[RESUMO OPERACIONAL]
SCRIPT = PONTE DE RUNTIME COM EMISSÃO DE EVENTOS TIPADOS
FOCO = DESCOBERTA, INTEGRIDADE E TRANSIÇÃO PARA PS-CORE
===============================================================================
#>
