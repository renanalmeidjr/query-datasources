-- ============================================================
-- 09_collation_diagnostics.sql
-- Diagnóstico de Collation: Keycloak × Azure SQL Hyperscale
-- ============================================================
-- Contexto: Investigação de gargalo Keycloak/RHBK 26 contra Azure SQL
-- Hyperscale em 6K RPS. Este script detecta collation mismatches, implicit
-- conversions causadas por collation, e compara planos de execução de queries
-- típicas do Keycloak sob collation atual vs collation recomendado.
--
-- Como interpretar:
--   PARTE 1 — Identifica colunas de string com collation diferente do banco.
--             Mismatches aqui indicam risco de implicit conversion em queries.
--   PARTE 2 — Lista índices em colunas de string e suas collations.
--             Mismatch índice/coluna ou coluna/query força index scan.
--   PARTE 3 — Detecta implicit conversions ativas em planos de execução.
--             Se collation mismatch causa scan, aparece aqui como "CONVERT_IMPLICIT".
--   PARTE 4 — Compara plano de execução de query típica Keycloak com
--             collation atual vs collation recomendado (COLLATE override).
--
-- Substitua <nome_do_banco> pelo nome real do banco antes de executar.
-- Nenhum segredo ou credencial deve ser commitado.
-- ============================================================

USE [<nome_do_banco>];
GO

-- ============================================================
-- PARTE 1 — Colunas de string e detecção de collation mismatch
-- ============================================================
-- Lista todas as colunas VARCHAR/NVARCHAR/CHAR/NCHAR do banco,
-- sua collation, e compara com a collation do banco.
-- Colunas com collation diferente da collation do banco podem causar
-- implicit conversion em queries, forçando index scan em vez de seek.
-- ============================================================

SELECT
    s.name                              AS schema_name,
    t.name                              AS table_name,
    c.name                              AS column_name,
    tp.name                             AS data_type,
    c.max_length,
    c.collation_name                    AS column_collation,
    DATABASEPROPERTYEX(DB_NAME(), 'Collation')
                                        AS database_collation,
    CASE
        WHEN c.collation_name IS NULL THEN 'N/A (não é string)'
        WHEN c.collation_name = DATABASEPROPERTYEX(DB_NAME(), 'Collation')
            THEN 'OK — igual ao banco'
        ELSE '*** MISMATCH — diferente do banco ***'
    END                                 AS collation_status,
    -- Flag se é coluna potencialmente no hot path do Keycloak
    CASE
        WHEN c.name IN (
            'USER_NAME', 'EMAIL', 'REALM_ID', 'CLIENT_ID',
            'SESSION_ID', 'USER_ID', 'ID', 'NAME',
            'SECRET', 'CLIENT_SCOPE_ID', 'SCOPE_ID'
        ) THEN 'HOT PATH candidato'
        ELSE ''
    END                                 AS hot_path_flag
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE tp.name IN ('varchar', 'nvarchar', 'char', 'nchar')
  AND t.is_ms_shipped = 0                -- exclui tabelas do sistema
ORDER BY
    collation_status DESC,               -- mismatches primeiro
    s.name,
    t.name,
    c.name;
GO

-- ============================================================
-- PARTE 2 — Índices em colunas de string e collation dos índices
-- ============================================================
-- Um índice em coluna de string herda a collation da coluna.
-- Se a collation da coluna difere da collation esperada pelo driver JDBC
-- (ex.: driver envia parâmetro como nvarchar(unicode) e a coluna é
-- varchar(CP1252)), o optimizer pode não usar o índice.
-- ============================================================

SELECT
    s.name                              AS schema_name,
    t.name                              AS table_name,
    i.name                              AS index_name,
    i.type_desc                         AS index_type,
    c.name                              AS column_name,
    ic.key_ordinal,
    ic.is_included_column,
    tp.name                             AS data_type,
    c.collation_name                    AS column_collation,
    DATABASEPROPERTYEX(DB_NAME(), 'Collation')
                                        AS database_collation,
    CASE
        WHEN c.collation_name IS NULL THEN 'N/A'
        WHEN c.collation_name = DATABASEPROPERTYEX(DB_NAME(), 'Collation')
            THEN 'OK'
        ELSE '*** MISMATCH ***'
    END                                 AS collation_status
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id
                          AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id
                   AND c.column_id = ic.column_id
JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE tp.name IN ('varchar', 'nvarchar', 'char', 'nchar')
  AND t.is_ms_shipped = 0
  AND i.type > 0                         -- exclui heap (type=0)
ORDER BY
    collation_status DESC,
    s.name,
    t.name,
    i.name,
    ic.key_ordinal;
GO

-- ============================================================
-- PARTE 3 — Implicit conversions em planos de execução ativos
-- ============================================================
-- Detecta queries em cache que contêm CONVERT_IMPLICIT no plano XML.
-- CONVERT_IMPLICIT causado por collation mismatch aparece como:
--   ConvertIssue="Implicit conversion may affect seek plan"
-- ou simplesmente como CONVERT em predicados de índice (impede seek).
-- ============================================================

-- 3A: Queries com implicit conversion no plano (alto nível)
SELECT TOP 50
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000.0   AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000.0  AS avg_elapsed_ms,
    qs.total_logical_reads / qs.execution_count          AS avg_logical_reads,
    SUBSTRING(st.text, (qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
          END - qs.statement_start_offset)/2)+1)         AS query_text,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%CONVERT_IMPLICIT%'
  AND st.text LIKE N'%keycloak%'        -- ajuste ao padrão real do app
   OR CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%ConvertIssue%'
ORDER BY avg_logical_reads DESC;
GO

-- 3B: Implicit conversions via sys.dm_exec_plan_attributes
-- Mais granular — identifica o tipo de conversão e se afeta cardinalidade
SELECT TOP 50
    st.text                                             AS query_text,
    pa.attribute,
    pa.value,
    qs.execution_count,
    qs.total_logical_reads / qs.execution_count        AS avg_logical_reads
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) pa
WHERE pa.attribute = N'set_options'
  AND qs.total_logical_reads / qs.execution_count > 1000  -- foco em leituras altas
ORDER BY avg_logical_reads DESC;
GO

-- 3C: Queries com alto logical reads — candidatas a scans por collation mismatch
-- Foca nas queries do Keycloak com leituras anormalmente altas
SELECT TOP 30
    qs.execution_count,
    qs.total_logical_reads / qs.execution_count        AS avg_logical_reads,
    qs.total_worker_time / qs.execution_count / 1000.0 AS avg_cpu_ms,
    qs.total_elapsed_time / qs.execution_count / 1000.0 AS avg_elapsed_ms,
    SUBSTRING(st.text, (qs.statement_start_offset/2)+1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
          END - qs.statement_start_offset)/2)+1)       AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE qs.total_logical_reads / qs.execution_count > 500   -- threshold de scan suspeito
  AND (st.text LIKE N'%USER_ENTITY%'
    OR st.text LIKE N'%USER_SESSION%'
    OR st.text LIKE N'%CLIENT%'
    OR st.text LIKE N'%REALM%')
ORDER BY avg_logical_reads DESC;
GO

-- ============================================================
-- PARTE 4 — Comparação de plano: collation atual vs recomendado
-- ============================================================
-- Esta parte executa queries típicas do Keycloak com COLLATE override
-- para simular o comportamento sob a collation recomendada.
-- Use SET STATISTICS IO ON para comparar logical reads (seek vs scan).
--
-- ATENÇÃO: Execute cada bloco separadamente com SHOWPLAN_XML para
-- capturar o plano. Em produção, execute em horário de baixo tráfego.
-- ============================================================

-- Habilita estatísticas de I/O e tempo para os blocos abaixo
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

-- ------------------------------------------------------------
-- 4A: Lookup de usuário por USER_NAME — collation atual (sem override)
-- Representa o comportamento atual do Keycloak via JDBC
-- ------------------------------------------------------------
SELECT
    u.ID,
    u.USERNAME,
    u.EMAIL,
    u.REALM_ID,
    u.ENABLED
FROM USER_ENTITY u
WHERE u.USERNAME = N'<usuario_teste>'   -- substitua por um usuário real de teste
  AND u.REALM_ID = N'<realm_teste>';    -- substitua pelo realm de teste
GO

-- ------------------------------------------------------------
-- 4B: Lookup de usuário com COLLATE override para collation recomendado
-- Simula o comportamento se a coluna tivesse collation Latin1_General_100_CI_AS_SC_UTF8
-- Compare o plano e logical reads com 4A
-- ------------------------------------------------------------
SELECT
    u.ID,
    u.USERNAME,
    u.EMAIL,
    u.REALM_ID,
    u.ENABLED
FROM USER_ENTITY u
WHERE u.USERNAME COLLATE Latin1_General_100_CI_AS_SC_UTF8 = N'<usuario_teste>' COLLATE Latin1_General_100_CI_AS_SC_UTF8
  AND u.REALM_ID COLLATE Latin1_General_100_CI_AS_SC_UTF8 = N'<realm_teste>'   COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

-- ------------------------------------------------------------
-- 4C: Busca de sessão por USER_SESSION_ID — collation atual
-- ------------------------------------------------------------
SELECT
    s.ID,
    s.AUTH_METHOD,
    s.IP_ADDRESS,
    s.STARTED,
    s.LAST_SESSION_REFRESH,
    s.REALM_ID,
    s.LOGIN_USERNAME
FROM USER_SESSION s
WHERE s.ID = N'<session_id_teste>'      -- substitua por um ID de sessão real de teste
   OR s.LOGIN_USERNAME = N'<usuario_teste>';
GO

-- ------------------------------------------------------------
-- 4D: Mesma query com COLLATE override
-- ------------------------------------------------------------
SELECT
    s.ID,
    s.AUTH_METHOD,
    s.IP_ADDRESS,
    s.STARTED,
    s.LAST_SESSION_REFRESH,
    s.REALM_ID,
    s.LOGIN_USERNAME
FROM USER_SESSION s
WHERE s.ID COLLATE Latin1_General_100_CI_AS_SC_UTF8 = N'<session_id_teste>' COLLATE Latin1_General_100_CI_AS_SC_UTF8
   OR s.LOGIN_USERNAME COLLATE Latin1_General_100_CI_AS_SC_UTF8 = N'<usuario_teste>' COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ============================================================
-- PARTE 5 — Waits de lock causados por scans (evidência de contenção)
-- ============================================================
-- Se queries estão fazendo scans por collation mismatch, espera-se
-- wait_type = LCK_M_S (shared lock) ou PAGEIOLATCH_SH em páginas
-- do índice durante o scan. Execute durante o pico de carga.
-- ============================================================

SELECT
    r.session_id,
    r.status,
    r.wait_type,
    r.wait_time / 1000.0                AS wait_segundos,
    r.blocking_session_id,
    r.logical_reads,
    r.cpu_time / 1000.0                 AS cpu_segundos,
    SUBSTRING(st.text, (r.statement_start_offset/2)+1,
        ((CASE r.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE r.statement_end_offset
          END - r.statement_start_offset)/2)+1)         AS query_text_atual,
    qp.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.wait_type IN (
    'LCK_M_S', 'LCK_M_X', 'LCK_M_U',          -- locks de linha/página
    'PAGEIOLATCH_SH', 'PAGEIOLATCH_EX',          -- I/O de página (scan)
    'PAGELATCH_SH', 'PAGELATCH_EX'               -- latches de página
)
  AND r.database_id = DB_ID()
ORDER BY r.wait_time DESC;
GO

-- ============================================================
-- PARTE 6 — Resumo: collation do banco e das colunas hot path
-- ============================================================
-- Vista rápida para documentar o estado atual antes de qualquer mudança.
-- ============================================================

SELECT
    'Banco'                             AS nivel,
    DB_NAME()                           AS objeto,
    DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS collation_atual,
    NULL                                AS data_type
UNION ALL
SELECT
    'Servidor'                          AS nivel,
    @@SERVERNAME                        AS objeto,
    SERVERPROPERTY('Collation')         AS collation_atual,
    NULL                                AS data_type
UNION ALL
SELECT
    'Coluna hot-path'                   AS nivel,
    s.name + '.' + t.name + '.' + c.name AS objeto,
    c.collation_name                    AS collation_atual,
    tp.name                             AS data_type
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE tp.name IN ('varchar', 'nvarchar', 'char', 'nchar')
  AND t.is_ms_shipped = 0
  AND c.name IN (
      'USER_NAME', 'USERNAME', 'EMAIL', 'REALM_ID', 'CLIENT_ID',
      'SESSION_ID', 'USER_ID', 'ID', 'NAME', 'LOGIN_USERNAME'
  )
ORDER BY nivel, objeto;
GO
