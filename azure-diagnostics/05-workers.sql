/*
================================================================================
  FILE   : 05-workers.sql
  WHAT   : Active worker threads vs. the Hyperscale 128 vCore limit
  WHEN   : Run during load test peak; alert if worker % is above 80%
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series

  CONTEXT
  -------
  Each concurrent SQL request consumes one worker thread.  Azure SQL has a
  per-database limit on concurrent workers:

    Hyperscale 128 vCores Premium-series:
      Max concurrent workers = 3,200
      (General formula: 20 workers per vCore + 800 base ≈ varies by tier/gen;
       always verify in the Azure portal under "Compute + storage" → "Max
       concurrent workers", or by checking sys.dm_os_sys_info.)

  If the worker count approaches the limit, new requests queue as THREADPOOL
  waits.  Under high latency (zone-redundant commits), each request holds its
  worker thread for LONGER, which means the worker pool is consumed faster and
  the effective throughput drops.

  HOW TO INTERPRET
  ----------------
  - Section A: Current active, runnable, and suspended workers.
    "suspended" = waiting for I/O / lock / commit (not CPU-bound).
    If suspended >>> running+runnable, threads are stalled waiting on the DB.

  - Section B: Max worker limit from sys.dm_os_sys_info.
    Compare active_workers_count vs max_workers_count (live) and
    scheduler-level queue depths.

  - Section C: THREADPOOL wait — if non-zero, some requests waited for a free
    thread.  Even low counts are meaningful under 15K RPS.

  - Section D: Azure Monitor Workers percentage — complement this query with
    the "Workers percentage" metric in Azure portal (Monitoring → Metrics).
    This metric is the authoritative view and updates every minute.

  NOTES FOR HYPERSCALE
  --------------------
  - The worker limit in Hyperscale scales with vCores; 128 vCores Premium-series
    has a substantially higher limit than smaller SKUs, but it can still be
    reached when commit latency keeps workers suspended for 5-10 ms each.
  - sys.dm_os_schedulers and sys.dm_os_sys_info are available in Hyperscale.
================================================================================
*/

-- ===========================================================================
-- A. Request state distribution — running vs. runnable vs. suspended
-- ===========================================================================
SELECT
    r.status,
    r.wait_type,
    COUNT(*)                        AS request_count,
    AVG(r.wait_time)                AS avg_wait_ms,
    MAX(r.wait_time)                AS max_wait_ms,
    AVG(r.cpu_time)                 AS avg_cpu_ms
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions  AS s ON r.session_id = s.session_id
WHERE s.is_user_process = 1
GROUP BY r.status, r.wait_type
ORDER BY request_count DESC;


-- ===========================================================================
-- B. Worker thread utilisation — live totals
-- ===========================================================================
SELECT
    -- From sys.dm_os_sys_info
    osi.max_workers_count,
    -- Aggregate from schedulers
    SUM(sc.current_workers_count)   AS active_workers_total,
    SUM(sc.active_workers_count)    AS workers_running_or_runnable,
    SUM(sc.runnable_tasks_count)    AS tasks_waiting_for_cpu,
    SUM(sc.work_queue_count)        AS tasks_in_queue,
    SUM(sc.pending_disk_io_count)   AS pending_disk_io,
    -- Derived metric
    CAST(SUM(sc.current_workers_count) * 100.0
         / NULLIF(osi.max_workers_count, 0) AS DECIMAL(5,2))
                                    AS worker_utilisation_pct
FROM sys.dm_os_schedulers AS sc
CROSS JOIN (SELECT max_workers_count FROM sys.dm_os_sys_info) AS osi
WHERE sc.status = 'VISIBLE ONLINE'  -- online user schedulers only
GROUP BY osi.max_workers_count;


-- ===========================================================================
-- C. Per-scheduler breakdown — detect hot schedulers (uneven load)
-- ===========================================================================
SELECT
    sc.scheduler_id,
    sc.cpu_id,
    sc.status,
    sc.current_workers_count,
    sc.active_workers_count,
    sc.runnable_tasks_count,
    sc.work_queue_count,
    sc.pending_disk_io_count,
    sc.load_factor
FROM sys.dm_os_schedulers AS sc
WHERE sc.status = 'VISIBLE ONLINE'
ORDER BY sc.work_queue_count DESC, sc.current_workers_count DESC;


-- ===========================================================================
-- D. THREADPOOL wait — worker exhaustion signal
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,3))
                                    AS avg_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type = 'THREADPOOL';


-- ===========================================================================
-- E. System-level limits reference (read-only info)
-- ===========================================================================
SELECT
    max_workers_count,
    scheduler_count,
    hyperthread_ratio,
    cpu_count,
    physical_memory_kb / 1024       AS physical_memory_mb,
    committed_kb / 1024             AS committed_mb,
    committed_target_kb / 1024      AS committed_target_mb
FROM sys.dm_os_sys_info;
