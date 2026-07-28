/*
  Arquivo  : 03_transaction_age_distribution.sql
  O que faz: Mostra a distribuição de idade (duração) das transações abertas
             no momento da consulta, combinando sys.dm_tran_active_transactions
             com sys.dm_tran_database_transactions e sys.dm_tran_session_transactions.
             Permite ver se as transações ficam abertas por dezenas de milissegundos
             ou por vários segundos — a duração total do ciclo BEGIN..COMMIT.
  Quando rodar: durante o pico; compare PaaS vs IaaS para ver se os ciclos são
                mais longos no PaaS (indicativo de round-trips mais caros).
  Como interpretar:
    - duracao_ms: tempo total que a transação está aberta até este instante.
      Se a mediana for, por ex., 500 ms mas só ~40 ms são gastos executando SQL
      (medido via Extended Events — ver 04_extended_events_lifecycle.sql), então
      ~460 ms por transação são "ocioso com transação aberta" — o gap.
    - Distribuição por bucket: veja quantas transações ficam abertas > 1 s,
      > 500 ms, > 100 ms — essas são as que mais pressionam o pool.
    - transaction_type = 1 = transação de leitura/escrita normal.
    - Compare contagem neste script com 01_abertas_vs_executando.sql para
      validar consistência.
*/

-- Parte 1: detalhe por transação ativa
SELECT
    at.transaction_id,
    at.name                                             AS transaction_name,
    at.transaction_type,                                -- 1=read/write, 2=read-only, 3=system, 4=distributed
    at.transaction_state,                               -- 2=active, 3=ended, 4=commit iniciado, etc.
    at.transaction_begin_time,
    DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE())
        AS duracao_ms,
    tst.session_id,
    s.status                                            AS session_status,
    s.program_name,
    s.host_name,
    s.login_name,
    dt.database_transaction_begin_time,
    dt.database_transaction_log_bytes_used              AS log_bytes_usados,
    dt.database_transaction_log_bytes_reserved          AS log_bytes_reservados

FROM sys.dm_tran_active_transactions       at
JOIN sys.dm_tran_session_transactions      tst
    ON  tst.transaction_id = at.transaction_id
JOIN sys.dm_exec_sessions                  s
    ON  s.session_id = tst.session_id
LEFT JOIN sys.dm_tran_database_transactions dt
    ON  dt.transaction_id = at.transaction_id

WHERE
    s.is_user_process = 1
    AND at.transaction_type <> 3   -- exclui transações de sistema

ORDER BY
    duracao_ms DESC;


-- Parte 2: histograma / distribuição por bucket de duração
SELECT
    bucket,
    COUNT(*) AS qtd_transacoes,
    AVG(duracao_ms) AS media_duracao_ms,
    MAX(duracao_ms) AS max_duracao_ms
FROM (
    SELECT
        at.transaction_id,
        DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) AS duracao_ms,
        CASE
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) <   50 THEN '< 50 ms'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) <  100 THEN '50-100 ms'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) <  250 THEN '100-250 ms'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) <  500 THEN '250-500 ms'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 1000 THEN '500 ms-1 s'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 3000 THEN '1-3 s'
            WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 10000 THEN '3-10 s'
            ELSE '> 10 s'
        END AS bucket
    FROM sys.dm_tran_active_transactions at
    JOIN sys.dm_tran_session_transactions tst
        ON  tst.transaction_id = at.transaction_id
    JOIN sys.dm_exec_sessions s
        ON  s.session_id = tst.session_id
    WHERE
        s.is_user_process = 1
        AND at.transaction_type <> 3
) sub
GROUP BY
    bucket
ORDER BY
    MAX(duracao_ms);
