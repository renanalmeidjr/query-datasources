/*
================================================================================
  FILE   : 02-wait-stats.sql
  WHAT   : Wait statistics snapshot — global and per-session
  WHEN   : Run at start of test (baseline) and at peak load; diff the two sets
  SCOPE  : Azure SQL Hyperscale 128 vCores Premium-series, Zone Redundant

  HOW TO INTERPRET
  ----------------
  Take two snapshots 30-60 seconds apart during peak load, then subtract.
  The wait type with the highest delta "waiting_tasks_count" OR "wait_time_ms"
  is the primary bottleneck.

  KEY WAIT TYPES FOR THIS SCENARIO
  ----------------------------------
  WRITELOG
      Log buffer flush waiting to write to the transaction log.
      High WRITELOG in Hyperscale zone-redundant = the primary log service is
      waiting for the zone-redundant log replica to acknowledge before returning.
      THIS is the expected culprit for persistent-user-sessions write latency.
      Each RHBK session write (login / refresh / logout) issues a synchronous
      COMMIT, which blocks until the Hyperscale log service writes AND the
      zone-redundant secondary replica acknowledges.

  HADR_SYNC_COMMIT / HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING
      Synchronous HA commit wait — confirms zone-redundant replication is the
      bottleneck.  NOTE: Azure SQL uses an internal HA mechanism; these waits
      may surface under different internal names.  Also look for:
        HADR_WORK_QUEUE
        HADR_CLUSAPI_CALL

  RBIO_RG_STORAGE / RBIO_RG_DESTAGE / RBIO_RG_FLUSH (Hyperscale-specific)
      Waits on the Hyperscale log service (resilient buffer I/O).
      High values = log service is saturated or backpressure from page servers.
      In a 128 vCore Premium Hyperscale these should stay very low at rest;
      spikes under write-heavy load indicate log throughput saturation.

  PAGEIOLATCH_SH / PAGEIOLATCH_EX / PAGEIOLATCH_UP
      Waiting for a data page to be read from a Hyperscale page server.
      In Hyperscale, pages not in the local RBPEX cache are fetched over the
      network from page servers.  These waits are expected but should be short
      (<5 ms each) at low latency in the same zone.

  RESOURCE_SEMAPHORE
      Memory grant queue — a query needs more memory than available.
      Rare at 15K RPS for OLTP-sized Keycloak queries, but worth checking.

  SOS_SCHEDULER_YIELD
      CPU pressure — threads voluntarily yielding the scheduler.
      High values indicate CPU saturation; cross-check Azure Monitor CPU %.

  LCK_M_* (LCK_M_X, LCK_M_U, LCK_M_S, etc.)
      Row/page/table lock waits.
      High LCK_M_X on the Keycloak session table = row-level lock serialization
      on persistent-user-sessions writes (see 04-lock-contention.sql for detail).

  THREADPOOL
      Worker thread exhaustion — no free thread to pick up a request.
      On 128 vCores Hyperscale, the limit is very high (see 05-workers.sql),
      but check if the count is climbing toward it.

  ASYNC_NETWORK_IO
      Waiting for the client to consume result data from the network buffer.
      Irrelevant for RHBK's INSERT/UPDATE pattern, but noteworthy if SELECT-heavy.

  NOTES FOR HYPERSCALE
  --------------------
  - sys.dm_os_wait_stats is cumulative since engine start; always take a diff.
  - In Hyperscale, RBIO_* waits are specific to the log service and page servers.
    They do NOT appear in SQL Server on-prem or General Purpose.
  - HADR_* waits surface the zone-redundant replication acknowledgement cost.
  - Run DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR) only in non-prod; on PaaS
    this is often blocked — use the snapshot-diff approach instead.
================================================================================
*/

-- ===========================================================================
-- A. Global wait stats — snapshot (run twice and subtract)
--    Filtered to the waits relevant to this scenario
-- ===========================================================================
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    CAST(wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS DECIMAL(10,2))
                                     AS avg_wait_ms,
    signal_wait_time_ms,
    CAST(signal_wait_time_ms * 100.0 / NULLIF(wait_time_ms, 1) AS DECIMAL(5,2))
                                     AS signal_pct
FROM sys.dm_os_wait_stats
WHERE wait_type IN (
    -- Log / commit
    'WRITELOG',
    'LOGBUFFER',
    -- Hyperscale-specific log service
    'RBIO_RG_STORAGE',
    'RBIO_RG_DESTAGE',
    'RBIO_RG_FLUSH',
    'RBIO_RG_REPLICATION',
    -- Zone-redundant HA replication
    'HADR_SYNC_COMMIT',
    'HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING',
    'HADR_WORK_QUEUE',
    'HADR_CLUSAPI_CALL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    -- Page I/O (Hyperscale page servers)
    'PAGEIOLATCH_SH',
    'PAGEIOLATCH_EX',
    'PAGEIOLATCH_UP',
    'PAGEIOLATCH_DT',
    'PAGEIOLATCH_KP',
    'PAGEIOLATCH_NL',
    -- Lock contention
    'LCK_M_X',
    'LCK_M_U',
    'LCK_M_S',
    'LCK_M_IX',
    'LCK_M_IU',
    'LCK_M_IS',
    'LCK_M_SIX',
    'LCK_M_SIU',
    'LCK_M_UIX',
    'LCK_M_SCH_S',
    'LCK_M_SCH_M',
    'LCK_M_BU',
    'LCK_M_RS_U',
    'LCK_M_RS_S',
    'LCK_M_RIN_X',
    'LCK_M_RIN_U',
    'LCK_M_RIn_S',
    'LCK_M_RX_X',
    'LCK_M_RX_U',
    'LCK_M_RX_S',
    -- CPU pressure
    'SOS_SCHEDULER_YIELD',
    -- Memory grant
    'RESOURCE_SEMAPHORE',
    'RESOURCE_SEMAPHORE_QUERY_COMPILE',
    -- Worker thread pool
    'THREADPOOL',
    -- Network
    'ASYNC_NETWORK_IO'
)
  AND waiting_tasks_count > 0
ORDER BY wait_time_ms DESC;


-- ===========================================================================
-- B. Per-session wait stats — what each RHBK session is waiting on right now
--    (cumulative per session since connection was established)
-- ===========================================================================
SELECT
    sw.session_id,
    s.status                        AS session_status,
    s.program_name,
    s.host_name,
    s.open_transaction_count,
    sw.wait_type,
    sw.waiting_tasks_count,
    sw.wait_time_ms,
    sw.max_wait_time_ms,
    CAST(sw.wait_time_ms * 1.0 / NULLIF(sw.waiting_tasks_count, 0) AS DECIMAL(10,2))
                                    AS avg_wait_ms
FROM sys.dm_exec_session_wait_stats AS sw
JOIN sys.dm_exec_sessions           AS s  ON sw.session_id = s.session_id
WHERE s.is_user_process = 1
  AND sw.wait_type NOT IN (
        'SLEEP_TASK', 'WAITFOR', 'BROKER_TO_FLUSH',
        'BROKER_TASK_STOP', 'CLR_AUTO_EVENT',
        'DISPATCHER_QUEUE_SEMAPHORE', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'HADR_WORK_QUEUE',   -- background, not session-level I/O
        'ONDEMAND_TASK_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE', 'SERVER_IDLE_CHECK', 'SLEEP_DBSTARTUP',
        'SLEEP_DBRECOVER', 'SLEEP_DBTASK', 'SLEEP_MASTERDBREADY',
        'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED',
        'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK', 'SLEEP_TEMPDBSTARTUP',
        'SNI_HTTP_ACCEPT', 'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH', 'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',
        'XE_DISPATCHER_WAIT', 'XE_TIMER_EVENT'
  )
  AND sw.wait_time_ms > 0
ORDER BY sw.wait_time_ms DESC;


-- ===========================================================================
-- C. Aggregate per-session waits — top wait per session (summary view)
-- ===========================================================================
SELECT
    s.session_id,
    s.program_name,
    s.host_name,
    s.open_transaction_count,
    top_w.wait_type                 AS dominant_wait_type,
    top_w.wait_time_ms              AS dominant_wait_ms,
    top_w.waiting_tasks_count       AS dominant_wait_count
FROM sys.dm_exec_sessions AS s
CROSS APPLY (
    SELECT TOP 1 wait_type, wait_time_ms, waiting_tasks_count
    FROM   sys.dm_exec_session_wait_stats AS sw
    WHERE  sw.session_id = s.session_id
    ORDER BY wait_time_ms DESC
) AS top_w
WHERE s.is_user_process = 1
ORDER BY top_w.wait_time_ms DESC;
