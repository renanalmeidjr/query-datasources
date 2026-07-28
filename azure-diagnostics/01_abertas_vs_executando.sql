/*
  Arquivo  : 01_abertas_vs_executando.sql
  O que faz: Quantifica, num único instante, a diferença entre transações
             ABERTAS e sessões EXECUTANDO de fato — a métrica "1800 abertas /
             40 executando" que define o diagnóstico de idle-in-transaction.
  Quando rodar: durante ou imediatamente após um pico de carga.
  Como interpretar:
    - abertas_total  : sessões com open_transaction_count > 0 (BEGIN sem COMMIT).
    - executando     : sessões em status running/runnable (SQL em voo agora).
    - idle_in_transaction: transações abertas que NÃO estão executando SQL
                          (thread da aplicação segurou a transação, mas não envia
                          comando para o banco — aqui mora o gargalo).
    - razao_execucao_pct: ~2 % = 98 % do tempo de vida de cada transação está
                          gasto FORA da execução SQL → o banco está ocioso,
                          o gargalo está na aplicação / no caminho.
    Uma razão muito baixa (< 5 %) confirma que aumentar o pool NÃO resolve —
    a alavanca é ENCURTAR o escopo BEGIN..COMMIT.
*/

WITH sessoes AS (
    SELECT
        s.session_id,
        s.status,
        s.open_transaction_count,
        s.program_name,
        s.host_name,
        s.login_name,
        r.status          AS request_status
    FROM sys.dm_exec_sessions   s
    LEFT JOIN sys.dm_exec_requests r
        ON  r.session_id = s.session_id
    WHERE s.is_user_process = 1
)
SELECT
    -- (a) transações abertas (BEGIN sem COMMIT ainda)
    COUNT(CASE WHEN open_transaction_count > 0 THEN 1 END)
        AS abertas_total,

    -- (b) sessões realmente executando um comando neste instante
    COUNT(CASE WHEN request_status IN ('running', 'runnable') THEN 1 END)
        AS executando,

    -- (c) idle-in-transaction: abertas MAS sem comando ativo
    COUNT(CASE
              WHEN open_transaction_count > 0
               AND (request_status IS NULL OR request_status = 'sleeping')
              THEN 1
          END)
        AS idle_in_transaction,

    -- (d) razão de execução útil (Lei de Little: ~2 % = 98 % ocioso)
    CAST(
        100.0
        * COUNT(CASE WHEN request_status IN ('running', 'runnable') THEN 1 END)
        / NULLIF(COUNT(CASE WHEN open_transaction_count > 0 THEN 1 END), 0)
    AS DECIMAL(6, 2))
        AS razao_execucao_pct,

    -- (e) total de sessões de usuário para contexto
    COUNT(*)
        AS sessoes_usuario_total,

    GETDATE() AS capturado_em

FROM sessoes;
