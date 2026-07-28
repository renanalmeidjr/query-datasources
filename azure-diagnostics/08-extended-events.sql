/*
================================================================================
  FILE   : 08-extended-events.sql
  WHAT   : Extended Events session to count round-trips, measure login cost,
           and capture per-operation duration for a Keycloak session event
  WHEN   : Create BEFORE the load test; read/stop AFTER or during a targeted
           single-login trace
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series

  PURPOSE
  -------
  One RHBK 26 login involves multiple SQL round-trips (SELECT session,
  INSERT user session, UPDATE token, COMMIT, etc.).  This session captures
  each completed RPC or batch, keyed by session_id, so you can:
    1. Count the number of SQL round-trips per Keycloak operation.
    2. Sum their durations to see total SQL time per login.
    3. Measure the connection establishment (login_completed) event to isolate
       TCP+TLS+TDS+Entra auth handshake cost.

  USAGE
  -----
  Step 1: Run Section A (CREATE) once — before the load test.
  Step 2: Run the load test (or a single targeted login).
  Step 3: Run Section B (READ) to retrieve events.
  Step 4: Run Section C (STOP/DROP) when done.

  IMPORTANT NOTES
  ---------------
  - The session writes to the ring buffer (in-memory).  Under 15K RPS the
    ring buffer will cycle fast.  For targeted single-login tracing, set
    MAX_DISPATCH_LATENCY low (1 SECONDS) and read quickly.
  - For production load capture, use FILE target instead of ring buffer.
    Replace the ring_buffer target below with:
      ADD TARGET package0.event_file(
          SET filename = 'rhbk_trace',      -- prefix only; Azure stores in blob
          max_file_size = 50,               -- MB per file
          max_rollover_files = 5
      )
  - Extended Events sessions are limited in Azure SQL Managed Instance and
    Azure SQL Database.  The events used here (rpc_completed, sql_batch_completed,
    login_completed) are available in Azure SQL Database.
  - Replace <your_application_name> with the ApplicationName set in the RHBK
    JDBC URL (e.g., RHBK26-Pod1) or filter by host_name / client_app_name.

  AZURE SQL HYPERSCALE NOTES
  --------------------------
  - Extended Events work identically in Hyperscale vs General Purpose.
  - Secondary read-scale replicas have their own XEvent sessions; this session
    runs on the PRIMARY replica only.
================================================================================
*/

-- ===========================================================================
-- A. CREATE the Extended Events session
--    Captures: completed RPCs, SQL batches, logins, and connection resets
-- ===========================================================================
IF EXISTS (
    SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'RHBK_RoundTrip_Trace'
)
    ALTER EVENT SESSION RHBK_RoundTrip_Trace ON DATABASE STATE = STOP;

DROP EVENT SESSION IF EXISTS RHBK_RoundTrip_Trace ON DATABASE;

CREATE EVENT SESSION RHBK_RoundTrip_Trace ON DATABASE

    -- Completed RPC calls (sp_executesql, parameterised statements via JDBC)
    ADD EVENT sqlserver.rpc_completed(
        WHERE (
            [package0].[greater_than_uint64]([duration], 0)
            -- Optionally filter to Keycloak connections only:
            -- AND [client_app_name] LIKE N'%RHBK%'
        )
        ACTION (
            sqlserver.session_id,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.database_name,
            sqlserver.sql_text,
            sqlserver.transaction_id
        )
    ),

    -- Completed ad-hoc SQL batches (rare for JDBC parameterised, but capture anyway)
    ADD EVENT sqlserver.sql_batch_completed(
        WHERE (
            [package0].[greater_than_uint64]([duration], 0)
        )
        ACTION (
            sqlserver.session_id,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.database_name,
            sqlserver.sql_text,
            sqlserver.transaction_id
        )
    ),

    -- Login completed — measures cost of connection establishment
    -- Includes TCP, TLS, TDS negotiate, and Entra/SQL auth handshake
    ADD EVENT sqlserver.login_completed(
        ACTION (
            sqlserver.session_id,
            sqlserver.client_app_name,
            sqlserver.client_hostname,
            sqlserver.username,
            sqlserver.database_name
        )
    ),

    -- Connection reset (sp_reset_connection) — measures pool reuse cost
    -- Each JDBC connection pool "borrow" from an idle physical connection
    -- calls sp_reset_connection; its duration shows pool-reuse overhead.
    ADD EVENT sqlserver.sql_statement_completed(
        WHERE (
            sqlserver.like_i_sql_unicode_string(N'%sp_reset_connection%', 0)
        )
        ACTION (
            sqlserver.session_id,
            sqlserver.client_app_name
        )
    )

ADD TARGET package0.ring_buffer(
    SET MAX_MEMORY = 51200          -- 50 MB ring buffer
)

WITH (
    MAX_DISPATCH_LATENCY  = 5 SECONDS,
    EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY       = ON,     -- causality chain across async events
    STARTUP_STATE         = OFF
);

-- Start the session
ALTER EVENT SESSION RHBK_RoundTrip_Trace ON DATABASE STATE = START;

-- Confirm it is running
SELECT name, target_name, execution_count
FROM sys.dm_xe_database_session_targets AS t
JOIN sys.dm_xe_database_sessions        AS s ON t.event_session_address = s.address
WHERE s.name = N'RHBK_RoundTrip_Trace';


-- ===========================================================================
-- B. READ events from the ring buffer
--    Run this DURING or AFTER the test to retrieve captured events.
--    Requires xml processing; adjust TOP as needed for volume.
-- ===========================================================================
;WITH RawXml AS (
    SELECT CAST(target_data AS XML) AS xdata
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s
           ON t.event_session_address = s.address
    WHERE  s.name        = N'RHBK_RoundTrip_Trace'
      AND  t.target_name = N'ring_buffer'
),
Events AS (
    SELECT
        n.value('(@name)[1]',           'varchar(100)')  AS event_name,
        n.value('(@timestamp)[1]',      'datetime2(7)')  AS event_time,
        n.value('(data[@name="duration"]/value)[1]',     'bigint')
                                                          AS duration_us,
        n.value('(action[@name="session_id"]/value)[1]', 'int')
                                                          AS session_id,
        n.value('(action[@name="transaction_id"]/value)[1]', 'bigint')
                                                          AS transaction_id,
        n.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')
                                                          AS client_app,
        n.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)')
                                                          AS client_host,
        n.value('(action[@name="username"]/value)[1]',   'nvarchar(256)')
                                                          AS username,
        n.value('(action[@name="sql_text"]/value)[1]',   'nvarchar(max)')
                                                          AS sql_text,
        n.value('(data[@name="statement"]/value)[1]',    'nvarchar(max)')
                                                          AS statement,
        n.value('(data[@name="result"]/text)[1]',        'varchar(50)')
                                                          AS result
    FROM RawXml
    CROSS APPLY xdata.nodes('RingBufferTarget/event') AS x(n)
)
SELECT TOP 1000
    event_name,
    event_time,
    session_id,
    transaction_id,
    duration_us,
    CAST(duration_us / 1000.0 AS DECIMAL(10,3)) AS duration_ms,
    client_app,
    client_host,
    username,
    SUBSTRING(COALESCE(statement, sql_text, ''), 1, 200) AS sql_snippet,
    result
FROM Events
ORDER BY event_time DESC;


-- ===========================================================================
-- C. Aggregate round-trips and duration PER transaction_id
--    Use this to count "how many SQL calls per Keycloak login transaction"
--    and total time spent in SQL per transaction.
-- ===========================================================================
;WITH RawXml AS (
    SELECT CAST(target_data AS XML) AS xdata
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s
           ON t.event_session_address = s.address
    WHERE  s.name        = N'RHBK_RoundTrip_Trace'
      AND  t.target_name = N'ring_buffer'
),
Events AS (
    SELECT
        n.value('(@name)[1]',               'varchar(100)') AS event_name,
        n.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        n.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id,
        n.value('(action[@name="transaction_id"]/value)[1]', 'bigint') AS transaction_id,
        n.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app
    FROM RawXml
    CROSS APPLY xdata.nodes('RingBufferTarget/event') AS x(n)
    WHERE n.value('(@name)[1]', 'varchar(100)') IN ('rpc_completed', 'sql_batch_completed')
)
SELECT
    transaction_id,
    client_app,
    COUNT(*)                                   AS round_trip_count,
    SUM(duration_us)                           AS total_duration_us,
    CAST(SUM(duration_us) / 1000.0 AS DECIMAL(10,3)) AS total_duration_ms,
    CAST(AVG(duration_us * 1.0) / 1000.0 AS DECIMAL(10,3)) AS avg_per_trip_ms,
    MAX(duration_us) / 1000                    AS max_trip_ms
FROM Events
WHERE transaction_id IS NOT NULL
  AND transaction_id <> 0
GROUP BY transaction_id, client_app
ORDER BY total_duration_us DESC;


-- ===========================================================================
-- D. Login-completion events — measure connection establishment cost
--    (TCP + TLS + TDS + Entra/SQL auth handshake)
-- ===========================================================================
;WITH RawXml AS (
    SELECT CAST(target_data AS XML) AS xdata
    FROM   sys.dm_xe_database_session_targets AS t
    JOIN   sys.dm_xe_database_sessions        AS s
           ON t.event_session_address = s.address
    WHERE  s.name        = N'RHBK_RoundTrip_Trace'
      AND  t.target_name = N'ring_buffer'
),
LoginEvents AS (
    SELECT
        n.value('(@timestamp)[1]',      'datetime2(7)')   AS event_time,
        n.value('(data[@name="duration"]/value)[1]', 'bigint') AS duration_us,
        n.value('(action[@name="session_id"]/value)[1]', 'int') AS session_id,
        n.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS client_app,
        n.value('(action[@name="client_hostname"]/value)[1]', 'nvarchar(256)') AS client_host,
        n.value('(action[@name="username"]/value)[1]',   'nvarchar(256)') AS username
    FROM RawXml
    CROSS APPLY xdata.nodes('RingBufferTarget/event') AS x(n)
    WHERE n.value('(@name)[1]', 'varchar(100)') = 'login_completed'
)
SELECT
    client_app,
    client_host,
    username,
    COUNT(*)                                    AS login_count,
    CAST(AVG(duration_us * 1.0) / 1000.0 AS DECIMAL(10,3)) AS avg_login_ms,
    CAST(MAX(duration_us) / 1000.0 AS DECIMAL(10,3)) AS max_login_ms,
    CAST(MIN(duration_us) / 1000.0 AS DECIMAL(10,3)) AS min_login_ms
FROM LoginEvents
GROUP BY client_app, client_host, username
ORDER BY avg_login_ms DESC;


-- ===========================================================================
-- E. STOP and DROP the session (run when done tracing)
-- ===========================================================================
-- ALTER EVENT SESSION RHBK_RoundTrip_Trace ON DATABASE STATE = STOP;
-- DROP EVENT SESSION RHBK_RoundTrip_Trace ON DATABASE;
