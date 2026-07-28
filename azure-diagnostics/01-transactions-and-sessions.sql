/*
================================================================================
  FILE   : 01-transactions-and-sessions.sql
  WHAT   : Active requests vs. idle-in-transaction sessions
  WHEN   : Run continuously during load test peak (every 15-30 seconds)
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series, Redirect, Zone Redundant

  HOW TO INTERPRET
  ----------------
  - Section A  →  Sessions actively executing SQL (running / runnable / suspended).
                  Healthy baseline: count should scale roughly with your RPS.
                  If capped at a very low number (e.g. ~40) while hundreds of
                  connections exist, you are looking at a contention bottleneck
                  (lock, pool exhaustion, or log throttling), NOT a query problem.

  - Section B  →  Sessions sleeping WITH an open transaction ("idle-in-transaction").
                  This is the RHBK 26 symptom: persistent-user-sessions writes open
                  a transaction, the JVM thread gets preempted (lock contention,
                  pool wait, Infinispan RPC) before commit, and the SQL connection
                  stays in idle-in-transaction meanwhile.
                  High numbers here (thousands) mean the app is not committing fast
                  enough — diagnose the APP side first (thread dumps, pool queue,
                  Infinispan SYNC vs ASYNC), not the database.

  - Section C  →  Summary counter: active vs idle-in-transaction vs idle (no txn).
                  Quick status at a glance; track over time to see trajectory.

  NOTES FOR HYPERSCALE
  --------------------
  - sys.dm_exec_requests and sys.dm_exec_sessions behave the same as General Purpose.
  - The column open_transaction_count in dm_exec_sessions is reliable in Hyperscale.
  - program_name / host_name come from the JDBC connection string; ensure RHBK sets
    ApplicationName in the JDBC URL so you can distinguish Keycloak from other tools.
    Example JDBC suffix: ;applicationName=RHBK26-Pod1
================================================================================
*/

-- ===========================================================================
-- A. Sessions actively executing SQL RIGHT NOW
--    (status IN ('running','runnable','suspended'))
-- ===========================================================================
SELECT
    r.session_id,
    r.status,
    r.wait_type,
    r.wait_time               AS wait_time_ms,
    r.cpu_time                AS cpu_time_ms,
    r.total_elapsed_time      AS elapsed_ms,
    r.logical_reads,
    r.writes,
    r.blocking_session_id,
    s.login_name,
    s.program_name,
    s.host_name,
    s.open_transaction_count,
    SUBSTRING(qt.text, (r.statement_start_offset/2)+1,
              ((CASE r.statement_end_offset
                     WHEN -1 THEN DATALENGTH(qt.text)
                     ELSE r.statement_end_offset END
                - r.statement_start_offset)/2)+1) AS current_statement
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions  AS s  ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
WHERE s.is_user_process = 1
  AND r.status NOT IN ('background', 'sleeping')
ORDER BY r.total_elapsed_time DESC;


-- ===========================================================================
-- B. Idle-in-transaction sessions
--    (sleeping but holding an open transaction — the RHBK 26 symptom)
-- ===========================================================================
SELECT
    s.session_id,
    s.status,
    s.open_transaction_count,
    s.login_time,
    s.last_request_start_time,
    s.last_request_end_time,
    DATEDIFF(SECOND, s.last_request_end_time, GETDATE()) AS idle_seconds,
    s.login_name,
    s.program_name,
    s.host_name,
    s.client_interface_name,
    s.reads,
    s.writes,
    -- Last SQL text executed by this session (may be NULL if cache evicted)
    SUBSTRING(qt.text, 1, 512)                          AS last_sql_snippet
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id
OUTER APPLY (
    SELECT TOP 1 text
    FROM   sys.dm_exec_sql_text(c.most_recent_sql_handle)
) AS qt
WHERE s.is_user_process        = 1
  AND s.status                 = 'sleeping'
  AND s.open_transaction_count > 0
ORDER BY idle_seconds DESC;


-- ===========================================================================
-- C. Summary: count by state × open_transaction_count
-- ===========================================================================
SELECT
    s.status,
    CASE
        WHEN s.open_transaction_count > 0 THEN 'has_open_transaction'
        ELSE 'no_open_transaction'
    END                          AS txn_state,
    COUNT(*)                     AS session_count,
    MIN(DATEDIFF(SECOND, s.last_request_end_time, GETDATE())) AS min_idle_sec,
    MAX(DATEDIFF(SECOND, s.last_request_end_time, GETDATE())) AS max_idle_sec,
    AVG(DATEDIFF(SECOND, s.last_request_end_time, GETDATE())) AS avg_idle_sec
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY
    s.status,
    CASE WHEN s.open_transaction_count > 0 THEN 'has_open_transaction' ELSE 'no_open_transaction' END
ORDER BY session_count DESC;
