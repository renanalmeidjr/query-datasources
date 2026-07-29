/*
  01-extended-events-transaction-lifecycle.sql
  Objetivo: capturar o ciclo de vida de transações do Keycloak (BEGIN -> comandos -> COMMIT)
  e comparar lado-a-lado PaaS vs IaaS por duração total, gaps entre comandos e round-trips.
*/

/* ============================================================
   PARTE A — Azure SQL Hyperscale PaaS (DATABASE-scoped XE)
   ============================================================ */

IF EXISTS (SELECT 1 FROM sys.database_event_sessions WHERE name = N'KC_TranLifecycle_PaaS')
BEGIN
    DROP EVENT SESSION [KC_TranLifecycle_PaaS] ON DATABASE;
END;
GO

CREATE EVENT SESSION [KC_TranLifecycle_PaaS] ON DATABASE
ADD EVENT sqlserver.sql_transaction
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (sqlserver.database_name = DB_NAME())
),
ADD EVENT sqlserver.rpc_completed
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (
        sqlserver.database_name = DB_NAME()
        AND sqlserver.client_app_name LIKE N'%keycloak%'
    )
),
ADD EVENT sqlserver.sql_batch_completed
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (
        sqlserver.database_name = DB_NAME()
        AND sqlserver.client_app_name LIKE N'%keycloak%'
    )
)
ADD TARGET package0.ring_buffer
(
    SET max_memory = 51200,
        max_events_limit = 50000
)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, TRACK_CAUSALITY = ON);
GO

ALTER EVENT SESSION [KC_TranLifecycle_PaaS] ON DATABASE STATE = START;
GO


/* ============================================================
   PARTE B — SQL Server IaaS (SERVER-scoped XE)
   Execute no SQL Server IaaS para coleta equivalente.
   ============================================================ */

/*
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'KC_TranLifecycle_IaaS')
BEGIN
    DROP EVENT SESSION [KC_TranLifecycle_IaaS] ON SERVER;
END;
GO

CREATE EVENT SESSION [KC_TranLifecycle_IaaS] ON SERVER
ADD EVENT sqlserver.sql_transaction
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (sqlserver.database_name = N'<nome_do_banco>')
),
ADD EVENT sqlserver.rpc_completed
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (
        sqlserver.database_name = N'<nome_do_banco>'
        AND sqlserver.client_app_name LIKE N'%keycloak%'
    )
),
ADD EVENT sqlserver.sql_batch_completed
(
    ACTION (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text,
        package0.event_sequence
    )
    WHERE (
        sqlserver.database_name = N'<nome_do_banco>'
        AND sqlserver.client_app_name LIKE N'%keycloak%'
    )
)
ADD TARGET package0.ring_buffer
(
    SET max_memory = 51200,
        max_events_limit = 50000
)
WITH (MAX_DISPATCH_LATENCY = 5 SECONDS, TRACK_CAUSALITY = ON);
GO

ALTER EVENT SESSION [KC_TranLifecycle_IaaS] ON SERVER STATE = START;
GO
*/


/* ============================================================
   PARTE C1 — LEITURA/ANÁLISE (PaaS)
   ============================================================ */

DECLARE @environment_label nvarchar(20) = N'PaaS';

;WITH target_xml AS (
    SELECT CAST(t.target_data AS xml) AS x
    FROM sys.dm_xe_database_sessions s
    JOIN sys.dm_xe_database_session_targets t
      ON t.event_session_address = s.address
    WHERE s.name = N'KC_TranLifecycle_PaaS'
      AND t.target_name = N'ring_buffer'
),
events_raw AS (
    SELECT
        @environment_label AS environment_label,
        n.value('(@name)[1]', 'sysname') AS event_name,
        n.value('(@timestamp)[1]', 'datetime2(7)') AS ts_utc,
        n.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id,
        n.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name,
        n.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
        n.value('(data[@name="transaction_id"]/value)[1]', 'bigint') AS transaction_id,
        n.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        n.value('(action[@name="event_sequence"]/value)[1]', 'bigint') AS event_sequence
    FROM target_xml
    CROSS APPLY x.nodes('//RingBufferTarget/event') AS q(n)
),
filtered AS (
    SELECT *
    FROM events_raw
    WHERE COALESCE(client_app_name, N'') LIKE N'%keycloak%'
      AND transaction_id IS NOT NULL
),
agg AS (
    SELECT
        environment_label,
        session_id,
        transaction_id,
        MIN(ts_utc) AS tx_begin_ts,
        MAX(ts_utc) AS tx_end_ts,
        DATEDIFF_BIG(microsecond, MIN(ts_utc), MAX(ts_utc)) / 1000.0 AS tx_total_ms,
        SUM(COALESCE(duration_us, 0)) / 1000.0 AS sql_exec_ms,
        COUNT(CASE WHEN event_name IN ('rpc_completed', 'sql_batch_completed') THEN 1 END) AS round_trips,
        COUNT(*) AS event_count
    FROM filtered
    GROUP BY environment_label, session_id, transaction_id
)
SELECT
    a.environment_label,
    a.session_id,
    a.transaction_id,
    a.tx_begin_ts,
    a.tx_end_ts,
    a.tx_total_ms,
    a.sql_exec_ms,
    (a.tx_total_ms - a.sql_exec_ms) AS gap_ms,
    CAST(100.0 * a.sql_exec_ms / NULLIF(a.tx_total_ms, 0) AS decimal(6,2)) AS pct_exec_ms,
    CAST(100.0 * (a.tx_total_ms - a.sql_exec_ms) / NULLIF(a.tx_total_ms, 0) AS decimal(6,2)) AS pct_gap_ms,
    a.round_trips,
    a.event_count
FROM agg a
WHERE a.event_count > 1
ORDER BY a.tx_total_ms DESC;
GO


/* ============================================================
   PARTE C2 — LEITURA/ANÁLISE (IaaS)
   Execute no SQL Server IaaS após rodar a sessão KC_TranLifecycle_IaaS
   ============================================================ */

/*
DECLARE @environment_label nvarchar(20) = N'IaaS';

;WITH target_xml AS (
    SELECT CAST(t.target_data AS xml) AS x
    FROM sys.dm_xe_sessions s
    JOIN sys.dm_xe_session_targets t
      ON t.event_session_address = s.address
    WHERE s.name = N'KC_TranLifecycle_IaaS'
      AND t.target_name = N'ring_buffer'
),
events_raw AS (
    SELECT
        @environment_label AS environment_label,
        n.value('(@name)[1]', 'sysname') AS event_name,
        n.value('(@timestamp)[1]', 'datetime2(7)') AS ts_utc,
        n.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id,
        n.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app_name,
        n.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS sql_text,
        n.value('(data[@name="transaction_id"]/value)[1]', 'bigint') AS transaction_id,
        n.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        n.value('(action[@name="event_sequence"]/value)[1]', 'bigint') AS event_sequence
    FROM target_xml
    CROSS APPLY x.nodes('//RingBufferTarget/event') AS q(n)
),
filtered AS (
    SELECT *
    FROM events_raw
    WHERE COALESCE(client_app_name, N'') LIKE N'%keycloak%'
      AND transaction_id IS NOT NULL
),
agg AS (
    SELECT
        environment_label,
        session_id,
        transaction_id,
        MIN(ts_utc) AS tx_begin_ts,
        MAX(ts_utc) AS tx_end_ts,
        DATEDIFF_BIG(microsecond, MIN(ts_utc), MAX(ts_utc)) / 1000.0 AS tx_total_ms,
        SUM(COALESCE(duration_us, 0)) / 1000.0 AS sql_exec_ms,
        COUNT(CASE WHEN event_name IN ('rpc_completed', 'sql_batch_completed') THEN 1 END) AS round_trips,
        COUNT(*) AS event_count
    FROM filtered
    GROUP BY environment_label, session_id, transaction_id
)
SELECT
    a.environment_label,
    a.session_id,
    a.transaction_id,
    a.tx_begin_ts,
    a.tx_end_ts,
    a.tx_total_ms,
    a.sql_exec_ms,
    (a.tx_total_ms - a.sql_exec_ms) AS gap_ms,
    CAST(100.0 * a.sql_exec_ms / NULLIF(a.tx_total_ms, 0) AS decimal(6,2)) AS pct_exec_ms,
    CAST(100.0 * (a.tx_total_ms - a.sql_exec_ms) / NULLIF(a.tx_total_ms, 0) AS decimal(6,2)) AS pct_gap_ms,
    a.round_trips,
    a.event_count
FROM agg a
WHERE a.event_count > 1
ORDER BY a.tx_total_ms DESC;
GO
*/


/* ============================================================
   PARTE D — PARAR/LIMPAR
   ============================================================ */

/*
-- PaaS
ALTER EVENT SESSION [KC_TranLifecycle_PaaS] ON DATABASE STATE = STOP;
DROP EVENT SESSION [KC_TranLifecycle_PaaS] ON DATABASE;

-- IaaS
ALTER EVENT SESSION [KC_TranLifecycle_IaaS] ON SERVER STATE = STOP;
DROP EVENT SESSION [KC_TranLifecycle_IaaS] ON SERVER;
*/
