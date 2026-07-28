/*
================================================================================
  FILE   : 04-lock-contention.sql
  WHAT   : Lock contention — blocking chains, wait types, hot rows
  WHEN   : Run at peak load when idle-in-transaction count is high
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series, Zone Redundant

  CONTEXT
  -------
  RHBK 26 persistent-user-sessions writes to a small set of session/token
  tables.  At 15K RPS, multiple threads may UPDATE the same session row
  (refresh token, concurrent requests for same user).  If row-level locking
  serializes these updates, the lock holder blocks all waiters — and under
  high commit latency (zone-redundancy tax), the lock is held for LONGER,
  worsening the queue.

  HOW TO INTERPRET
  ----------------
  - Section A: Live blocking chain — the head-blocker is the root cause.
    If the head-blocker's wait_type is WRITELOG or RBIO_*, the lock is held
    while waiting for commit, which is the zone-redundancy scenario.
    If the head-blocker's wait_type is LCK_* itself, there is a circular
    deadlock candidate.

  - Section B: LCK_* global waits snapshot — total lock wait time.
    Delta between two snapshots = lock wait accumulation rate during load.
    LCK_M_X (exclusive row lock) on RHBK session tables is the hot path.

  - Section C: sys.dm_tran_locks — which objects / rows are contended right now.
    resource_type = 'KEY' means row-level locking (row in an index key range).
    object_name will reveal the exact Keycloak table being serialized.

  - Section D: Deadlock detection supplement — recent deadlock victims.
    (Requires Query Store or Extended Events; see 08-extended-events.sql.)

  NOTES FOR HYPERSCALE
  --------------------
  - Locking behavior in Hyperscale is the same as General Purpose for row/page
    locks on the primary replica.
  - Row versioning (READ COMMITTED SNAPSHOT — RCSI) can eliminate most shared
    lock waits.  Verify RCSI is ON:
      SELECT is_read_committed_snapshot_on FROM sys.databases WHERE name = DB_NAME();
    If it is OFF, turning it ON may significantly reduce LCK_M_S contention
    for reads while RHBK's writes hold exclusive locks.
================================================================================
*/

-- ===========================================================================
-- A. Live blocking chain — who is blocking whom, and why
-- ===========================================================================
WITH BlockingChain AS (
    -- Anchor: sessions that are blocking others (head-blockers)
    SELECT
        r.session_id                                AS blocked_session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time                                 AS wait_ms,
        r.total_elapsed_time                        AS elapsed_ms,
        s.open_transaction_count,
        s.status                                    AS session_status,
        s.program_name,
        s.host_name,
        s.login_name,
        SUBSTRING(qt.text,
                  (r.statement_start_offset / 2) + 1,
                  ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                    ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1)
                                                    AS blocked_statement,
        0                                           AS depth
    FROM sys.dm_exec_requests AS r
    JOIN sys.dm_exec_sessions  AS s ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
    WHERE r.blocking_session_id > 0
)
SELECT
    bc.*,
    -- Details of the HEAD BLOCKER (the session blocking others without being blocked)
    hb.status                                       AS head_blocker_status,
    hb.wait_type                                    AS head_blocker_wait_type,
    hb.wait_time                                    AS head_blocker_wait_ms,
    hb_s.open_transaction_count                     AS head_blocker_open_txn,
    SUBSTRING(hb_qt.text,
              (ISNULL(hb.statement_start_offset, 0) / 2) + 1,
              ((CASE hb.statement_end_offset WHEN -1 THEN DATALENGTH(hb_qt.text)
                ELSE hb.statement_end_offset END
               - ISNULL(hb.statement_start_offset, 0)) / 2) + 1)
                                                    AS head_blocker_statement
FROM BlockingChain AS bc
LEFT JOIN sys.dm_exec_requests AS hb
       ON hb.session_id = bc.blocking_session_id
LEFT JOIN sys.dm_exec_sessions AS hb_s
       ON hb_s.session_id = bc.blocking_session_id
OUTER APPLY sys.dm_exec_sql_text(hb.sql_handle) AS hb_qt
ORDER BY bc.wait_ms DESC;


-- ===========================================================================
-- B. LCK_* global wait-stats snapshot
--    Run at baseline and peak; subtract to find lock wait accumulation rate.
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,3))
                                    AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE 'LCK_%'
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


-- ===========================================================================
-- C. Active lock holders and waiters on specific tables
--    Replace N'<schema>' / N'<table>' placeholders if you want to filter.
--    Otherwise, this shows ALL currently held / requested locks.
-- ===========================================================================
SELECT
    tl.resource_type,
    tl.resource_subtype,
    tl.resource_database_id,
    OBJECT_NAME(tl.resource_associated_entity_id,
                tl.resource_database_id)              AS object_name,
    tl.resource_description,
    tl.request_mode,
    tl.request_type,
    tl.request_status,
    tl.request_session_id,
    s.status                                          AS session_status,
    s.open_transaction_count,
    s.program_name,
    s.host_name,
    r.wait_type                                       AS request_wait_type,
    r.wait_time                                       AS wait_ms,
    r.blocking_session_id
FROM sys.dm_tran_locks        AS tl
JOIN sys.dm_exec_sessions     AS s  ON tl.request_session_id = s.session_id
LEFT JOIN sys.dm_exec_requests AS r  ON r.session_id          = s.session_id
WHERE s.is_user_process = 1
  AND tl.resource_type  IN ('OBJECT', 'PAGE', 'KEY', 'ROW', 'RID')
  -- Uncomment to filter to Keycloak tables only (adjust names as needed):
  -- AND OBJECT_NAME(tl.resource_associated_entity_id, tl.resource_database_id)
  --     IN ('USER_SESSION', 'OFFLINE_USER_SESSION', 'SINGLE_USE_OBJECT')
ORDER BY
    OBJECT_NAME(tl.resource_associated_entity_id, tl.resource_database_id),
    tl.request_status,
    tl.request_mode;


-- ===========================================================================
-- D. Row versioning status — confirm RCSI is enabled
--    RCSI eliminates shared-read lock waits; should be ON for Keycloak OLTP.
-- ===========================================================================
SELECT
    name                              AS database_name,
    is_read_committed_snapshot_on,
    snapshot_isolation_state_desc
FROM sys.databases
WHERE name = DB_NAME();


-- ===========================================================================
-- E. Summary: blocked session count (quick heartbeat query)
--    Run every 5 seconds during load to track blocking trend.
-- ===========================================================================
SELECT
    COUNT(*)                           AS total_blocked_sessions,
    COUNT(DISTINCT r.blocking_session_id) AS distinct_head_blockers,
    MAX(r.wait_time)                   AS max_wait_ms,
    AVG(r.wait_time)                   AS avg_wait_ms
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions  AS s ON r.session_id = s.session_id
WHERE r.blocking_session_id > 0
  AND s.is_user_process = 1;
