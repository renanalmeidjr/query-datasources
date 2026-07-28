/*
================================================================================
  FILE   : 06-transaction-age.sql
  WHAT   : Age and duration of open transactions — find the oldest and hottest
  WHEN   : Run at peak load; look for transactions open for > a few seconds
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series, Zone Redundant

  CONTEXT
  -------
  Long-lived or accumulating idle-in-transaction sessions can cause:
    - Lock retention: any row locked by the transaction stays locked.
    - Version store growth: if RCSI/snapshot isolation is on, old row versions
      must be retained until the oldest open transaction completes.
    - Log truncation blocking: the log cannot be truncated past the LSN of the
      oldest active transaction.

  RHBK 26 with persistent-user-sessions should commit quickly per session event.
  If transactions are staying open for seconds or minutes, it indicates the
  app thread is not reaching the commit point — diagnose with thread dumps
  (see README.md) to find where the thread is stalled.

  HOW TO INTERPRET
  ----------------
  - Section A: Oldest active transactions by elapsed time.
    Any transaction older than 1-2 seconds during a load test is suspicious.

  - Section B: Version store size — if RCSI is on and you have long transactions,
    the version store grows and eventually consumes memory / tempdb space.
    In Hyperscale, version store may behave differently (persisted vs tempdb).

  - Section C: Active transaction count per session — sessions holding multiple
    nested transactions (transaction_count > 1) are unusual for simple RHBK writes.

  NOTES FOR HYPERSCALE
  --------------------
  - sys.dm_tran_active_transactions and sys.dm_tran_session_transactions behave
    identically to General Purpose in Hyperscale.
  - Accelerated Database Recovery (ADR) is enabled by default in Azure SQL
    Hyperscale.  ADR uses a persistent version store (PVS) instead of tempdb.
    Long open transactions grow the PVS, not tempdb.  Monitor via:
      sys.dm_tran_persistent_version_store_stats  (if available in your version)
================================================================================
*/

-- ===========================================================================
-- A. Active transactions ranked by age (oldest first)
-- ===========================================================================
SELECT
    at.transaction_id,
    at.name                                         AS transaction_name,
    at.transaction_begin_time,
    DATEDIFF(MILLISECOND,
             at.transaction_begin_time,
             GETDATE())                             AS age_ms,
    DATEDIFF(SECOND,
             at.transaction_begin_time,
             GETDATE())                             AS age_sec,
    at.transaction_type,
    at.transaction_state,
    at.dtc_state,
    -- Join to sessions to get app context
    st.session_id,
    s.status                                        AS session_status,
    s.open_transaction_count,
    s.login_name,
    s.program_name,
    s.host_name,
    -- Last SQL executed by this session
    SUBSTRING(c_qt.text, 1, 512)                    AS last_sql_snippet
FROM sys.dm_tran_active_transactions    AS at
JOIN sys.dm_tran_session_transactions   AS st ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions               AS s  ON st.session_id     = s.session_id
LEFT JOIN sys.dm_exec_connections       AS c  ON s.session_id      = c.session_id
OUTER APPLY (
    SELECT TOP 1 text
    FROM   sys.dm_exec_sql_text(c.most_recent_sql_handle)
) AS c_qt
WHERE s.is_user_process = 1
ORDER BY at.transaction_begin_time ASC;   -- oldest first


-- ===========================================================================
-- B. Summary: transaction age distribution (bucketed)
-- ===========================================================================
SELECT
    CASE
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 100
            THEN '< 100 ms'
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 500
            THEN '100 ms – 500 ms'
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 1000
            THEN '500 ms – 1 s'
        WHEN DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) < 5
            THEN '1 s – 5 s'
        WHEN DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) < 30
            THEN '5 s – 30 s'
        ELSE '> 30 s'
    END                              AS age_bucket,
    COUNT(*)                         AS transaction_count,
    MIN(DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE())) AS min_age_ms,
    MAX(DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE())) AS max_age_ms,
    AVG(DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE())) AS avg_age_ms
FROM sys.dm_tran_active_transactions  AS at
JOIN sys.dm_tran_session_transactions AS st ON at.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions             AS s  ON st.session_id     = s.session_id
WHERE s.is_user_process = 1
GROUP BY
    CASE
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 100
            THEN '< 100 ms'
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 500
            THEN '100 ms – 500 ms'
        WHEN DATEDIFF(MILLISECOND, at.transaction_begin_time, GETDATE()) < 1000
            THEN '500 ms – 1 s'
        WHEN DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) < 5
            THEN '1 s – 5 s'
        WHEN DATEDIFF(SECOND, at.transaction_begin_time, GETDATE()) < 30
            THEN '5 s – 30 s'
        ELSE '> 30 s'
    END
ORDER BY min_age_ms;


-- ===========================================================================
-- C. Version store size (Accelerated Database Recovery / RCSI)
--    In Hyperscale, ADR is on by default; PVS grows with long open transactions.
-- ===========================================================================
-- Standard tempdb version store (if RCSI without ADR)
SELECT
    'tempdb_version_store'                          AS source,
    SUM(version_store_reserved_page_count) * 8.0
        / 1024                                      AS version_store_mb
FROM sys.dm_db_file_space_usage
WHERE database_id = 2;   -- tempdb

-- ADR persistent version store (Hyperscale; may require VIEW DATABASE STATE)
-- NOTE: sys.dm_tran_persistent_version_store_stats availability varies by
-- SQL version/build.  If this errors, comment it out.
SELECT
    'adr_pvs'                                       AS source,
    pvs_filegroup_name,
    persistent_version_store_size_kb / 1024.0       AS pvs_size_mb,
    online_index_version_store_size_kb / 1024.0     AS online_idx_pvs_mb,
    current_aborted_transaction_count,
    oldest_active_transaction_id,
    oldest_committed_transaction_id
FROM sys.dm_tran_persistent_version_store_stats;
