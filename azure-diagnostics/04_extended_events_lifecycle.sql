/*
  Arquivo  : 04_extended_events_lifecycle.sql
  O que faz: (A) Cria uma sessão de Extended Events que captura o ciclo de vida
             COMPLETO de cada transação de uma sessão Keycloak/RHBK —
             begin/commit/rollback + cada comando SQL executado — com timestamps
             precisos para reconstruir a linha do tempo e medir os "gaps" onde
             a transação está aberta mas nenhum SQL está em execução.
             (B) Leitura e agregação dos dados capturados.
  Quando rodar:
    PARTE 1 (criação) — antes do teste de carga; valide em ambiente não-produção.
    PARTE 2 (leitura) — durante ou imediatamente após o pico.
    PARTE 3 (limpeza) — após coletar os dados.
  Como interpretar os gaps:
    - gap_antes_primeiro_cmd_ms : tempo entre BEGIN TRAN e o 1º SQL — a thread
      abriu a transação e fez outra coisa (ou a rede demorou para entregar o 1º
      comando).
    - gap_entre_cmds_ms         : tempo entre um SQL e o próximo dentro da mesma
      transação — aqui fica a espera de round-trip, lógica JVM, Infinispan sync.
    - gap_ultimo_cmd_commit_ms  : tempo entre o último SQL e o COMMIT.
    - soma_exec_ms vs duracao_total_ms: razão de execução útil.
      Ex.: duracao_total 400 ms, soma_exec 8 ms → 2 % útil, 98 % ocioso.
  Comparação PaaS vs IaaS:
    - Gaps grandes em PaaS E IaaS → o custo é lógica/espera da JVM (não o banco).
    - Gaps maiores no PaaS do que no IaaS → o custo é round-trip/latência de rede
      (o PaaS acrescenta latência; cada volta de rede dentro da transação custa mais).

  ATENÇÃO: ajuste o filtro de programa/login para focar apenas nas sessões do
  Keycloak (ex.: program_name LIKE '%keycloak%' ou login específico).
  Limite o ring_buffer_size e max_dispatch_latency para não impactar produção.
*/

-- ============================================================
-- PARTE 1: Criar a sessão de Extended Events
-- ============================================================

-- Remova a sessão anterior se existir
IF EXISTS (
    SELECT 1 FROM sys.server_event_sessions
    WHERE name = 'KC_TransactionLifecycle'
)
    DROP EVENT SESSION KC_TransactionLifecycle ON SERVER;
GO

CREATE EVENT SESSION KC_TransactionLifecycle ON SERVER

    -- Início de transação explícita
    ADD EVENT sqlserver.sql_transaction (
        WHERE (
            sqlserver.database_name = N'<nome_do_banco>'   -- substitua
        )
    ),

    -- Commit / rollback de transação
    ADD EVENT sqlserver.sql_statement_completed (
        ACTION (
            sqlserver.session_id,
            sqlserver.transaction_id,
            sqlserver.sql_text,
            sqlserver.database_name,
            sqlserver.client_hostname,
            sqlserver.client_app_name,
            sqlserver.username,
            package0.event_sequence
        )
        WHERE (
            sqlserver.database_name = N'<nome_do_banco>'   -- substitua
            AND sqlserver.client_app_name LIKE N'%keycloak%' -- ajuste ao program_name real
        )
    ),

    -- RPC completo (stored procs, parametrized queries)
    ADD EVENT sqlserver.rpc_completed (
        ACTION (
            sqlserver.session_id,
            sqlserver.transaction_id,
            sqlserver.sql_text,
            sqlserver.database_name,
            sqlserver.client_hostname,
            sqlserver.client_app_name,
            sqlserver.username,
            package0.event_sequence
        )
        WHERE (
            sqlserver.database_name = N'<nome_do_banco>'
            AND sqlserver.client_app_name LIKE N'%keycloak%'
        )
    ),

    -- Batch completo (inclui BEGIN/COMMIT explícitos enviados como batch)
    ADD EVENT sqlserver.sql_batch_completed (
        ACTION (
            sqlserver.session_id,
            sqlserver.transaction_id,
            sqlserver.sql_text,
            sqlserver.database_name,
            sqlserver.client_hostname,
            sqlserver.client_app_name,
            sqlserver.username,
            package0.event_sequence
        )
        WHERE (
            sqlserver.database_name = N'<nome_do_banco>'
            AND sqlserver.client_app_name LIKE N'%keycloak%'
        )
    )

ADD TARGET package0.ring_buffer (
    SET max_memory       = 51200,   -- 50 MB; aumente se perder eventos
        max_events_limit = 10000    -- cap para não crescer sem limite
)

WITH (
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    TRACK_CAUSALITY      = ON        -- liga correlation_id para rastrear causa
);
GO

-- Inicia a captura
ALTER EVENT SESSION KC_TransactionLifecycle ON SERVER STATE = START;
GO

SELECT 'Sessão KC_TransactionLifecycle iniciada em ' + CONVERT(VARCHAR, GETDATE(), 121) AS status;
GO


-- ============================================================
-- PARTE 2: Ler e agregar os dados capturados
-- ============================================================

/*
  Execute esta parte DURANTE ou APÓS o pico de carga para extrair os eventos
  do ring buffer e calcular os gaps entre comandos dentro de cada transação.
*/

-- 2A: Extrair eventos brutos do ring buffer
;WITH eventos_raw AS (
    SELECT
        xdr.value('(@name)',                       'VARCHAR(50)')  AS evento,
        xdr.value('(@timestamp)',                  'DATETIME2(7)') AS ts,
        xdr.value('(action[@name="session_id"]/value)[1]',        'INT')          AS session_id,
        xdr.value('(action[@name="transaction_id"]/value)[1]',    'BIGINT')       AS transaction_id,
        xdr.value('(action[@name="sql_text"]/value)[1]',          'NVARCHAR(MAX)') AS sql_text,
        xdr.value('(action[@name="client_hostname"]/value)[1]',   'NVARCHAR(256)') AS client_hostname,
        xdr.value('(action[@name="client_app_name"]/value)[1]',   'NVARCHAR(256)') AS client_app_name,
        xdr.value('(data[@name="duration"]/value)[1]',            'BIGINT')       AS duracao_us,  -- microssegundos
        xdr.value('(data[@name="transaction_type"]/text)[1]',     'VARCHAR(50)')  AS transaction_type
    FROM (
        SELECT CAST(target_data AS XML) AS target_data
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t
            ON  t.event_session_address = s.address
        WHERE s.name = 'KC_TransactionLifecycle'
          AND t.target_name = 'ring_buffer'
    ) AS sessions_xml
    CROSS APPLY target_data.nodes('//RingBufferTarget/event') AS xevents(xdr)
)
SELECT
    evento,
    ts,
    session_id,
    transaction_id,
    client_app_name,
    client_hostname,
    sql_text,
    duracao_us,
    duracao_us / 1000.0 AS duracao_ms,
    transaction_type
FROM eventos_raw
ORDER BY session_id, transaction_id, ts;
GO


-- 2B: Calcular gaps entre eventos consecutivos por (session_id, transaction_id)
;WITH eventos_raw AS (
    SELECT
        xdr.value('(@name)',                       'VARCHAR(50)')  AS evento,
        xdr.value('(@timestamp)',                  'DATETIME2(7)') AS ts,
        xdr.value('(action[@name="session_id"]/value)[1]',        'INT')          AS session_id,
        xdr.value('(action[@name="transaction_id"]/value)[1]',    'BIGINT')       AS transaction_id,
        xdr.value('(action[@name="sql_text"]/value)[1]',          'NVARCHAR(MAX)') AS sql_text,
        xdr.value('(data[@name="duration"]/value)[1]',            'BIGINT')       AS duracao_us
    FROM (
        SELECT CAST(target_data AS XML) AS target_data
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t
            ON  t.event_session_address = s.address
        WHERE s.name = 'KC_TransactionLifecycle'
          AND t.target_name = 'ring_buffer'
    ) AS sessions_xml
    CROSS APPLY target_data.nodes('//RingBufferTarget/event') AS xevents(xdr)
),
com_anterior AS (
    SELECT
        evento,
        ts,
        session_id,
        transaction_id,
        sql_text,
        duracao_us,
        LAG(ts) OVER (
            PARTITION BY session_id, transaction_id
            ORDER BY ts
        ) AS ts_anterior,
        LAG(evento) OVER (
            PARTITION BY session_id, transaction_id
            ORDER BY ts
        ) AS evento_anterior
    FROM eventos_raw
)
SELECT
    session_id,
    transaction_id,
    evento_anterior,
    evento,
    ts_anterior,
    ts,
    -- gap = tempo ENTRE o fim do evento anterior e o início deste
    -- (quanto a transação ficou aberta sem executar SQL entre dois eventos)
    DATEDIFF(MICROSECOND, ts_anterior, ts) / 1000.0 AS gap_ms,
    duracao_us / 1000.0                             AS duracao_evento_ms,
    sql_text
FROM com_anterior
WHERE ts_anterior IS NOT NULL
ORDER BY session_id, transaction_id, ts;
GO


-- 2C: Resumo por transação — duração total, soma de execução real, soma de gaps
;WITH eventos_raw AS (
    SELECT
        xdr.value('(@name)',                    'VARCHAR(50)')  AS evento,
        xdr.value('(@timestamp)',               'DATETIME2(7)') AS ts,
        xdr.value('(action[@name="session_id"]/value)[1]',     'INT')    AS session_id,
        xdr.value('(action[@name="transaction_id"]/value)[1]', 'BIGINT') AS transaction_id,
        xdr.value('(data[@name="duration"]/value)[1]',         'BIGINT') AS duracao_us
    FROM (
        SELECT CAST(target_data AS XML) AS target_data
        FROM sys.dm_xe_sessions s
        JOIN sys.dm_xe_session_targets t
            ON  t.event_session_address = s.address
        WHERE s.name = 'KC_TransactionLifecycle'
          AND t.target_name = 'ring_buffer'
    ) AS sessions_xml
    CROSS APPLY target_data.nodes('//RingBufferTarget/event') AS xevents(xdr)
)
SELECT
    session_id,
    transaction_id,
    COUNT(*)                                           AS total_eventos,
    MIN(ts)                                            AS inicio_tran,
    MAX(ts)                                            AS fim_tran,
    DATEDIFF(MILLISECOND, MIN(ts), MAX(ts))            AS duracao_total_ms,
    SUM(duracao_us) / 1000.0                           AS soma_exec_ms,
    DATEDIFF(MILLISECOND, MIN(ts), MAX(ts))
        - SUM(duracao_us) / 1000.0                     AS soma_gaps_ms,
    CAST(
        100.0 * (SUM(duracao_us) / 1000.0)
        / NULLIF(DATEDIFF(MILLISECOND, MIN(ts), MAX(ts)), 0)
    AS DECIMAL(6, 2))                                  AS pct_execucao_real,
    CAST(
        100.0
        * (DATEDIFF(MILLISECOND, MIN(ts), MAX(ts)) - SUM(duracao_us) / 1000.0)
        / NULLIF(DATEDIFF(MILLISECOND, MIN(ts), MAX(ts)), 0)
    AS DECIMAL(6, 2))                                  AS pct_ocioso
FROM eventos_raw
GROUP BY session_id, transaction_id
HAVING COUNT(*) > 1   -- ignora transações com só 1 evento
ORDER BY duracao_total_ms DESC;
GO


-- ============================================================
-- PARTE 3: Parar e remover a sessão (execute após coletar os dados)
-- ============================================================

/*
ALTER EVENT SESSION KC_TransactionLifecycle ON SERVER STATE = STOP;
DROP  EVENT SESSION KC_TransactionLifecycle ON SERVER;
*/
