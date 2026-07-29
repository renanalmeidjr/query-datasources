/*
  03-querystore-analyzer.sql
  Objetivo: confirmar se as queries críticas do Keycloak estão em SEEK ou SCAN
  usando Query Store + XML do plano.
*/

/* ============================================================
   PARTE 0 — Verificar Query Store
   ============================================================ */
SELECT
    DB_NAME() AS database_name,
    desired_state_desc,
    actual_state_desc,
    readonly_reason,
    current_storage_size_mb,
    max_storage_size_mb
FROM sys.database_query_store_options;
GO

/*
-- Se Query Store estiver desativado:
ALTER DATABASE CURRENT SET QUERY_STORE = ON;
ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_WRITE);
GO
*/

/* ============================================================
   PARTE 1 — Top 10 queries do Keycloak sob carga
   ============================================================ */
;WITH top_queries AS (
    SELECT TOP (10)
        qsq.query_id,
        qsp.plan_id,
        SUM(rs.count_executions) AS executions,
        CAST(SUM(rs.avg_duration * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS decimal(18,2)) AS avg_duration_ms,
        CAST(SUM(rs.avg_cpu_time * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS decimal(18,2)) AS avg_cpu_ms,
        CAST(SUM(rs.avg_logical_io_reads * rs.count_executions) / NULLIF(SUM(rs.count_executions), 0) AS decimal(18,2)) AS avg_logical_reads,
        qsp.query_plan,
        qt.query_sql_text
    FROM sys.query_store_query_text qt
    JOIN sys.query_store_query qsq ON qsq.query_text_id = qt.query_text_id
    JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_runtime_stats rs ON rs.plan_id = qsp.plan_id
    JOIN sys.query_store_runtime_stats_interval rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -2, SYSUTCDATETIME())
      AND (
        qt.query_sql_text LIKE N'%USER_SESSION%'
        OR qt.query_sql_text LIKE N'%USER_ENTITY%'
        OR qt.query_sql_text LIKE N'%CLIENT%'
        OR qt.query_sql_text LIKE N'%REALM%'
      )
    GROUP BY qsq.query_id, qsp.plan_id, qsp.query_plan, qt.query_sql_text
    ORDER BY executions DESC
),
classified AS (
    SELECT
        query_id,
        plan_id,
        executions,
        avg_duration_ms,
        avg_cpu_ms,
        avg_logical_reads,
        CASE
            WHEN CAST(query_plan AS nvarchar(max)) LIKE N'%Index Scan%'
              OR CAST(query_plan AS nvarchar(max)) LIKE N'%Table Scan%'
              OR CAST(query_plan AS nvarchar(max)) LIKE N'%Clustered Index Scan%'
                THEN 'SCAN'
            WHEN CAST(query_plan AS nvarchar(max)) LIKE N'%Index Seek%'
              OR CAST(query_plan AS nvarchar(max)) LIKE N'%Clustered Index Seek%'
                THEN 'SEEK'
            ELSE 'OUTRO'
        END AS seek_scan_class,
        CASE
            WHEN CAST(query_plan AS nvarchar(max)) LIKE N'%CONVERT_IMPLICIT%' THEN 1
            ELSE 0
        END AS has_convert_implicit,
        query_sql_text
    FROM top_queries
)
SELECT
    query_id,
    plan_id,
    executions,
    avg_duration_ms,
    avg_cpu_ms,
    avg_logical_reads,
    seek_scan_class,
    has_convert_implicit,
    LEFT(REPLACE(REPLACE(query_sql_text, CHAR(10), ' '), CHAR(13), ' '), 600) AS query_excerpt
FROM classified
ORDER BY executions DESC;
GO

/* ============================================================
   PARTE 2 — Resumo percentual SEEK vs SCAN
   ============================================================ */
;WITH base AS (
    SELECT
        CASE
            WHEN CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%Index Scan%'
              OR CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%Table Scan%'
              OR CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%Clustered Index Scan%'
                THEN 'SCAN'
            WHEN CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%Index Seek%'
              OR CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%Clustered Index Seek%'
                THEN 'SEEK'
            ELSE 'OUTRO'
        END AS seek_scan_class,
        rs.count_executions
    FROM sys.query_store_query_text qt
    JOIN sys.query_store_query qsq ON qsq.query_text_id = qt.query_text_id
    JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
    JOIN sys.query_store_runtime_stats rs ON rs.plan_id = qsp.plan_id
    JOIN sys.query_store_runtime_stats_interval rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE rsi.start_time >= DATEADD(HOUR, -2, SYSUTCDATETIME())
      AND (
        qt.query_sql_text LIKE N'%USER_SESSION%'
        OR qt.query_sql_text LIKE N'%USER_ENTITY%'
        OR qt.query_sql_text LIKE N'%CLIENT%'
        OR qt.query_sql_text LIKE N'%REALM%'
      )
)
SELECT
    seek_scan_class,
    SUM(count_executions) AS executions,
    CAST(100.0 * SUM(count_executions) / NULLIF(SUM(SUM(count_executions)) OVER (), 0) AS decimal(6,2)) AS pct_exec
FROM base
GROUP BY seek_scan_class
ORDER BY executions DESC;
GO

/* ============================================================
   PARTE 3 — Queries com CONVERT_IMPLICIT (sinal de collation/type mismatch)
   ============================================================ */
SELECT TOP (20)
    qsq.query_id,
    qsp.plan_id,
    rs.count_executions,
    CAST(rs.avg_duration / 1000.0 AS decimal(18,2)) AS avg_duration_ms,
    LEFT(REPLACE(REPLACE(qt.query_sql_text, CHAR(10), ' '), CHAR(13), ' '), 600) AS query_excerpt
FROM sys.query_store_query_text qt
JOIN sys.query_store_query qsq ON qsq.query_text_id = qt.query_text_id
JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
JOIN sys.query_store_runtime_stats rs ON rs.plan_id = qsp.plan_id
JOIN sys.query_store_runtime_stats_interval rsi ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -2, SYSUTCDATETIME())
  AND CAST(qsp.query_plan AS nvarchar(max)) LIKE N'%CONVERT_IMPLICIT%'
ORDER BY rs.count_executions DESC;
GO
