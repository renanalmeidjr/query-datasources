/*
================================================================================
  FILE   : 03-commit-latency.sql
  WHAT   : Commit / transaction-log latency — the zone-redundancy tax
  WHEN   : Run during load test peak; compare baseline (idle) vs under load
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series, Zone Redundant

  CONTEXT
  -------
  RHBK 26 with `persistent-user-sessions` performs a SYNCHRONOUS write to the
  database on every session event (login, token refresh, logout).  Each write
  ends with a COMMIT.

  In a Hyperscale database with zone redundancy enabled:
    1. The commit is sent to the Hyperscale Log Service.
    2. The Log Service writes to its primary log replica.
    3. Zone redundancy = the Log Service MUST acknowledge durability on a
       secondary replica in a DIFFERENT Availability Zone before returning.
    4. Cross-zone RTT on Azure = typically 1-3 ms.
    5. At 15K logins/sec × 1 COMMIT each = 15,000 cross-zone round-trips/sec.

  If WRITELOG avg_wait_ms climbs to 3-10 ms, that ALONE caps throughput:
    1000 ms / 3 ms per commit = ~333 commits/sec per connection thread.
  To reach 6K TPS you need at least 18 threads doing nothing but committing.
  The idle-in-transaction accumulation is the direct consequence.

  HOW TO INTERPRET
  ----------------
  - Section A: WRITELOG wait — direct measure of log-flush latency (includes
    zone-redundant replication acknowledgement).
    Healthy:   avg_wait_ms < 1 ms (single-zone or low-latency path)
    Elevated:  avg_wait_ms 2-10 ms → zone-redundant cross-AZ latency visible
    Critical:  avg_wait_ms > 10 ms → log service backpressure or saturation

  - Section B: HADR* waits — confirm zone-redundant replication is involved.
    Non-zero counts during writes confirm synchronous HA replication is in path.

  - Section C: Hyperscale RBIO* log-service waits — show if the Hyperscale log
    service itself is backpressured (distinct from the zone-redundancy AZ hop).

  - Section D: Live per-request log waits — what executing requests are waiting
    on RIGHT NOW; if WRITELOG dominates, commits are the bottleneck.

  NOTES FOR HYPERSCALE
  --------------------
  - Azure SQL Hyperscale does NOT use SQL Server AlwaysOn internally; the HA
    mechanism is proprietary (Log Service + Page Servers).  HADR_* waits may or
    may not surface depending on the Hyperscale version.  RBIO_* waits are the
    Hyperscale-native equivalents for log-service latency.
  - sys.dm_io_virtual_file_stats is available in Hyperscale but measures the
    log service I/O, not on-prem disk I/O.  Use it to observe log write latency.
================================================================================
*/

-- ===========================================================================
-- A. WRITELOG wait — direct log-flush / commit latency signal
--    Run twice (baseline and peak) and compute the delta yourself.
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,3))
                                     AS avg_wait_ms,
    signal_wait_time_ms,
    CAST(signal_wait_time_ms * 100.0 / NULLIF(wait_time_ms, 1) AS DECIMAL(5,2))
                                     AS signal_pct_of_total
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    'WRITELOG',
    'LOGBUFFER',
    'LOG_RATE_GOVERNOR'   -- present in some Azure SQL tiers; throttles log writes
)
ORDER BY wait_time_ms DESC;


-- ===========================================================================
-- B. HADR / HA replication waits — zone-redundant synchronous commit
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,3))
                                     AS avg_wait_ms,
    max_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE 'HADR%'
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


-- ===========================================================================
-- C. Hyperscale RBIO* waits — log service / page-server specific
--    These are NOT present on General Purpose or Business Critical.
--    On Hyperscale, they indicate log-service or page-server backpressure.
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,3))
                                     AS avg_wait_ms,
    max_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type LIKE 'RBIO%'
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


-- ===========================================================================
-- D. Live requests currently waiting on log / commit waits
-- ===========================================================================
SELECT
    r.session_id,
    r.status,
    r.wait_type,
    r.wait_time                       AS wait_time_ms,
    r.total_elapsed_time              AS elapsed_ms,
    s.open_transaction_count,
    s.program_name,
    s.host_name,
    SUBSTRING(qt.text,
              (r.statement_start_offset / 2) + 1,
              ((CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                ELSE r.statement_end_offset END - r.statement_start_offset) / 2) + 1)
                                      AS current_statement
FROM sys.dm_exec_requests  AS r
JOIN sys.dm_exec_sessions   AS s  ON r.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS qt
WHERE r.wait_type IN (
    'WRITELOG', 'LOGBUFFER', 'LOG_RATE_GOVERNOR',
    'RBIO_RG_STORAGE', 'RBIO_RG_DESTAGE', 'RBIO_RG_FLUSH',
    'HADR_SYNC_COMMIT', 'HADR_WORK_QUEUE'
)
  AND s.is_user_process = 1
ORDER BY r.wait_time DESC;


-- ===========================================================================
-- E. Transaction-log virtual file stats — measure log write throughput
--    and I/O latency at the log-service level.
--    io_stall_write_ms / num_of_writes = average write latency per log write.
-- ===========================================================================
SELECT
    DB_NAME(vfs.database_id)              AS database_name,
    mf.physical_name,
    mf.type_desc                          AS file_type,
    vfs.num_of_writes,
    vfs.num_of_bytes_written / 1048576.0  AS written_mb,
    vfs.io_stall_write_ms,
    CAST(vfs.io_stall_write_ms * 1.0 / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,3))
                                          AS avg_write_latency_ms,
    vfs.num_of_reads,
    vfs.io_stall_read_ms,
    CAST(vfs.io_stall_read_ms * 1.0 / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(10,3))
                                          AS avg_read_latency_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
JOIN sys.master_files AS mf ON vfs.database_id = mf.database_id
                             AND vfs.file_id    = mf.file_id
WHERE DB_NAME(vfs.database_id) = DB_NAME()   -- current database only
ORDER BY mf.type_desc, vfs.io_stall_write_ms DESC;
