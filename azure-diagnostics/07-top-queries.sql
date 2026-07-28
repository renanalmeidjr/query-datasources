/*
================================================================================
  FILE   : 07-top-queries.sql
  WHAT   : Top queries by wait time, executions, and duration — from the plan
           cache and Query Store
  WHEN   : Run during load test peak and immediately after
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series

  HOW TO INTERPRET
  ----------------
  - Section A (plan cache): Shows the SQL text and aggregated stats for the
    hottest queries in memory RIGHT NOW.  Sort by total_worker_time to find
    CPU hogs, or by total_elapsed_time to find the slowest overall queries.
    Look for INSERT/UPDATE/DELETE on RHBK session tables — these are the
    persistent-user-sessions writes.

  - Section B (Query Store): Query Store persists statistics across restarts
    and provides richer aggregation.  Filter by a specific time interval to
    focus on the load test window.  Look for high total_duration and
    high execution_count for session-write queries.

  - Section C (wait stats per query from Query Store): Available in SQL Server
    2017+ / Azure SQL.  sys.query_store_wait_stats links each query plan to
    its dominant wait type, which directly maps to the bottleneck for that
    specific query.  This is the single most useful view for correlating
    "this Keycloak query" → "waits on WRITELOG" → "zone-redundancy tax".

  NOTES FOR HYPERSCALE
  --------------------
  - Query Store is enabled by default in Azure SQL and works in Hyperscale.
  - sys.dm_exec_query_stats reflects only the primary replica cache; in
    Hyperscale with secondary replicas, the secondary replicas have their own
    plan caches.
  - For very high-frequency short queries (< 1 ms each), the plan cache may
    not capture them if they parameterize away; use Query Store with
    QUERY_CAPTURE_MODE = ALL during the test window.
================================================================================
*/

-- ===========================================================================
-- A. Top queries from the plan cache — current snapshot
-- ===========================================================================
SELECT TOP 50
    qs.execution_count,
    qs.total_elapsed_time / 1000          AS total_elapsed_ms,
    qs.total_elapsed_time
        / NULLIF(qs.execution_count, 0)   AS avg_elapsed_ms,
    qs.total_worker_time / 1000           AS total_cpu_ms,
    qs.total_worker_time
        / NULLIF(qs.execution_count, 0)   AS avg_cpu_ms,
    qs.total_logical_reads,
    qs.total_logical_reads
        / NULLIF(qs.execution_count, 0)   AS avg_logical_reads,
    qs.total_logical_writes,
    qs.total_logical_writes
        / NULLIF(qs.execution_count, 0)   AS avg_logical_writes,
    qs.total_rows,
    qs.total_rows
        / NULLIF(qs.execution_count, 0)   AS avg_rows,
    SUBSTRING(qt.text,
              (qs.statement_start_offset / 2) + 1,
              ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                ELSE qs.statement_end_offset END
               - qs.statement_start_offset) / 2) + 1)
                                          AS statement_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS qt
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE qt.dbid = DB_ID()          -- current database only
ORDER BY qs.total_elapsed_time DESC;


-- ===========================================================================
-- B. Query Store — top queries by total duration in the test window
--    Adjust the interval_start_time filter to match your load test window.
-- ===========================================================================
SELECT TOP 50
    qt.query_sql_text,
    qrs.execution_type_desc,
    qrs.count_executions,
    CAST(qrs.avg_duration / 1000.0 AS DECIMAL(10,3))          AS avg_duration_ms,
    CAST(qrs.max_duration / 1000.0 AS DECIMAL(10,3))          AS max_duration_ms,
    CAST(qrs.avg_cpu_time / 1000.0 AS DECIMAL(10,3))          AS avg_cpu_ms,
    CAST(qrs.avg_logical_io_reads AS DECIMAL(10,1))           AS avg_logical_reads,
    CAST(qrs.avg_logical_io_writes AS DECIMAL(10,1))          AS avg_logical_writes,
    CAST(qrs.avg_rowcount AS DECIMAL(10,1))                   AS avg_rows,
    qp.compatibility_level,
    qrs.last_execution_time,
    q.query_id,
    qp.plan_id
FROM sys.query_store_query       AS q
JOIN sys.query_store_query_text  AS qt ON q.query_text_id    = qt.query_text_id
JOIN sys.query_store_plan        AS qp ON q.query_id         = qp.query_id
JOIN sys.query_store_runtime_stats AS qrs ON qp.plan_id      = qrs.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON qrs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())  -- last 2 hours; adjust as needed
ORDER BY qrs.avg_duration DESC;


-- ===========================================================================
-- C. Query Store wait stats — dominant wait type per query
--    (Azure SQL / SQL Server 2019+)
--    Maps each query to its PRIMARY wait type; WRITELOG = log/commit bottleneck
-- ===========================================================================
SELECT TOP 50
    qt.query_sql_text,
    qws.wait_category_desc,
    qws.execution_type_desc,
    qws.total_query_wait_time_ms,
    qws.avg_query_wait_time_ms,
    qws.max_query_wait_time_ms,
    q.query_id,
    qws.plan_id
FROM sys.query_store_query_text    AS qt
JOIN sys.query_store_query         AS q   ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan          AS qp  ON q.query_id       = qp.query_id
JOIN sys.query_store_wait_stats    AS qws ON qp.plan_id       = qws.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON qws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
  AND qws.avg_query_wait_time_ms > 0.5    -- filter trivial waits
ORDER BY qws.total_query_wait_time_ms DESC;


-- ===========================================================================
-- D. Identify the Keycloak session-write queries specifically
--    Adjust LIKE patterns to match your RHBK schema / table names.
-- ===========================================================================
SELECT TOP 20
    qt.query_sql_text,
    qrs.count_executions,
    CAST(qrs.avg_duration / 1000.0 AS DECIMAL(10,3))  AS avg_duration_ms,
    CAST(qrs.max_duration / 1000.0 AS DECIMAL(10,3))  AS max_duration_ms,
    CAST(qrs.avg_logical_io_writes AS DECIMAL(10,1))   AS avg_writes,
    qrs.last_execution_time
FROM sys.query_store_query      AS q
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan       AS qp ON q.query_id      = qp.query_id
JOIN sys.query_store_runtime_stats AS qrs ON qp.plan_id  = qrs.plan_id
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON qrs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
  AND (
       qt.query_sql_text LIKE '%USER_SESSION%'
    OR qt.query_sql_text LIKE '%OFFLINE_USER_SESSION%'
    OR qt.query_sql_text LIKE '%SINGLE_USE_OBJECT%'
    OR qt.query_sql_text LIKE '%PERSISTENT_USER_SESSION%'
    OR qt.query_sql_text LIKE '%OFFLINE_FLAG%'
  )
ORDER BY qrs.avg_duration DESC;
