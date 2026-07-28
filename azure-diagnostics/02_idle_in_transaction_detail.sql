/*
  Arquivo  : 02_idle_in_transaction_detail.sql
  O que faz: Lista, por sessão, todas as transações abertas que NÃO estão
             executando SQL neste instante (idle-in-transaction).
             Mostra quanto tempo cada transação já está aberta e parada —
             o dado primário para entender "o que a thread da aplicação está
             fazendo enquanto a transação fica aberta no banco".
  Quando rodar: durante o pico de carga, preferencialmente em conjunto com
                thread dumps dos pods Keycloak (ver 05_correlation_thread_dumps.md).
  Como interpretar:
    - idle_segundos_desde_ultimo_cmd: quantos segundos esta transação está
      aberta sem executar SQL — cada segundo aqui é tempo que a thread da JVM
      está com a conexão "presa" sem trabalhar no banco.
    - program_name / host_name: filtre por 'keycloak' ou 'RHBK' para focar
      nas sessões de interesse.
    - Ordene por idle_segundos_desde_ultimo_cmd DESC para encontrar as
      transações mais antigas abertas sem trabalho.
    - Se a maioria mostrar > 100 ms de idle e apenas ~40 de 1800 executam,
      o banco está ocioso enquanto a aplicação (ou o caminho de rede) retém
      as transações abertas.
*/

SELECT
    s.session_id,
    s.status                        AS session_status,
    s.open_transaction_count,
    s.last_request_start_time,
    s.last_request_end_time,

    -- Tempo desde o último comando (quanto está parado com transação aberta)
    DATEDIFF(MILLISECOND, s.last_request_end_time, GETDATE()) / 1000.0
        AS idle_segundos_desde_ultimo_cmd,

    -- Identificação da origem
    s.program_name,
    s.host_name,
    s.login_name,
    s.client_interface_name,

    -- Número de transações aninhadas abertas
    (
        SELECT COUNT(*)
        FROM sys.dm_tran_session_transactions tst
        WHERE tst.session_id = s.session_id
    ) AS transacoes_aninhadas,

    -- Texto do último batch executado (pode estar em cache)
    SUBSTRING(
        COALESCE(qt.text, ''),
        (r2.statement_start_offset / 2) + 1,
        CASE
            WHEN r2.statement_end_offset = -1 THEN LEN(COALESCE(qt.text, '')) * 2
            ELSE r2.statement_end_offset
        END - r2.statement_start_offset + 2
    ) AS ultimo_sql_executado

FROM sys.dm_exec_sessions s
-- Garante que não há request ativo agora
LEFT JOIN sys.dm_exec_requests r
    ON  r.session_id = s.session_id
-- Último request para pegar o texto SQL
LEFT JOIN sys.dm_exec_requests r2
    ON  r2.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(r2.sql_handle) qt

WHERE
    s.is_user_process = 1
    AND s.open_transaction_count > 0
    AND r.session_id IS NULL  -- sem request ativo = idle-in-transaction

ORDER BY
    idle_segundos_desde_ultimo_cmd DESC;
