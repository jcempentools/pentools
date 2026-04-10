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
- Cada etapa deve reportar status via Callback antes de prosseguir.
- Detecção cirúrgica de arquitetura (x64/ARM64) e versão de OS (WinPE/Full).
- Verificação de integridade do binário PS7 antes da invocação.
- Falha no Bootstrap = Aborto seguro com notificação imediata via Callback.

-------------------------------------------------------------------------------
[SISTEMA DE EVENTOS / CALLBACK] (OBRIGATÓRIO)
- O script não gerencia arquivos de log ou saída de console diretamente.
- Toda telemetria (status, erro, verbose) deve ser enviada para um ScriptBlock
  de callback injetado ou definido no escopo do chamador.
- O callback é responsável pela persistência ou exibição dos dados.

-------------------------------------------------------------------------------
[DIRETRIZES TÉCNICAS]
- Código 100% compatível com PowerShell 2.0 (Bootstrap Core).
- Independência total de Host (WinPE Shell, Task Scheduler, Session 0).
- Suporte nativo a execução em contexto SYSTEM e TrustedInstaller.
- Auto-elevação de privilégios se executado como USER.
- Uso exclusivo de comandos nativos (cmd, reg, robocopy, tasklist).

-------------------------------------------------------------------------------
[RESTRIÇÕES / VEDAÇÕES]
- ❌ Impedir múltiplas instâncias concorrentes (Mutex Atômico).

-------------------------------------------------------------------------------
[MODUS OPERANDI (THE BOOTSTRAP PIPELINE)]
1. Inicialização de Barreira: Configuração de TLS, ExecutionPolicy e Mutex.
2. Context Discovery: Identifica privilégios e ambiente (WinPE vs Full OS).
3. Prevenção de Interferência: Inibição de Sleep/Hibernação e verificação de CBS.
4. Runtime Audit: Localiza PS7.6+ em (1) Pasta de Origem -> (2) Program Files.
5. Integrity Check: Validação funcional do pwsh.exe (smoke test).
6. Payload Handoff: Invocação do PS7 passando argumentos e contexto original.
7. Monitoring: Aguarda o processo filho e repassa o ExitCode final ao Callback.

-------------------------------------------------------------------------------
[FAIL-SAFE / RESILIÊNCIA]
- PS7 Ausente/Corrompido: 
    - Disparar Evento de Erro Crítico via Callback.
    - Abortar execução (O bootstrap não instala o PS7, apenas o localiza).
- Travamento do Filho: Timeout controlado com reporte de "Process Hang".
- Barreira DISM/CBS: Aguardar operações pendentes do Windows antes do handoff.

-------------------------------------------------------------------------------
[COMPATIBILIDADE]
- Host: Windows Setup (Shift+F10), WinPE, Windows 10/11.
- Engine: PowerShell 2.0 (mínimo) até PowerShell 7.6+ (alvo).
- Privilégio: SYSTEM, Administrator, TrustedInstaller.

-------------------------------------------------------------------------------
[RESUMO OPERACIONAL]
SCRIPT = PONTE DE RUNTIME COM EMISSÃO DE EVENTOS
FOCO = DESCOBERTA, INTEGRIDADE E TRANSIÇÃO PARA PS-CORE
===============================================================================
#>
