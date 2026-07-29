#!/usr/bin/env bash
set -euo pipefail

# 02-thread-dumps-correlated.sh
# Captura thread dumps de pods Keycloak sincronizados com snapshot de sessões SQL.
# Requisitos: oc, date, awk. Opcional: sqlcmd para snapshot de banco automático.

NAMESPACE="${NAMESPACE:-<namespace-keycloak>}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app.kubernetes.io/name=keycloak}"
DUMPS_PER_POD="${DUMPS_PER_POD:-3}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-2}"
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostico-output-$(date -u +%Y%m%dT%H%M%SZ)}"

SQLCMD_BIN="${SQLCMD_BIN:-sqlcmd}"
SQL_SERVER="${SQL_SERVER:-}"
SQL_DATABASE="${SQL_DATABASE:-}"
SQL_USER="${SQL_USER:-}"
SQL_PASSWORD="${SQL_PASSWORD:-}"

mkdir -p "$OUTPUT_DIR"

DB_SNAPSHOT_QUERY=$(cat <<'SQL'
SET NOCOUNT ON;
SELECT
  GETUTCDATE() AS captured_utc,
  s.session_id,
  s.status,
  s.open_transaction_count,
  s.last_request_end_time,
  DATEDIFF(millisecond, s.last_request_end_time, GETDATE()) AS idle_ms_since_last_request,
  s.host_name,
  s.program_name,
  s.login_name
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
WHERE s.is_user_process = 1
  AND s.open_transaction_count > 0
  AND r.session_id IS NULL
ORDER BY idle_ms_since_last_request DESC;
SQL
)

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

capture_db_snapshot() {
  local out_file="$1"
  if [[ -n "$SQL_SERVER" && -n "$SQL_DATABASE" && -n "$SQL_USER" && -n "$SQL_PASSWORD" ]]; then
    log "Capturando snapshot SQL em $out_file"
    "$SQLCMD_BIN" -S "$SQL_SERVER" -d "$SQL_DATABASE" -U "$SQL_USER" -P "$SQL_PASSWORD" -W -s "," -Q "$DB_SNAPSHOT_QUERY" > "$out_file"
  else
    log "Variáveis SQL_* não configuradas; pulando snapshot automático de banco"
    cat > "$out_file" <<'TXT'
# Snapshot SQL não coletado automaticamente.
# Configure SQL_SERVER, SQL_DATABASE, SQL_USER e SQL_PASSWORD para habilitar sqlcmd.
# Alternativa manual: execute 02_idle_in_transaction_detail.sql no mesmo segundo do dump.
TXT
  fi
}

capture_dump_for_pod() {
  local pod="$1"
  local out_file="$2"

  log "Capturando thread dumps do pod $pod"
  {
    echo "# pod=$pod namespace=$NAMESPACE utc_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for i in $(seq 1 "$DUMPS_PER_POD"); do
      echo "===== dump_${i} utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
      if oc exec -n "$NAMESPACE" "$pod" -- jcmd 1 Thread.print >/tmp/jcmd_out.$$ 2>/tmp/jcmd_err.$$; then
        cat /tmp/jcmd_out.$$
      else
        echo "[WARN] jcmd falhou, tentando kill -3 + logs"
        oc exec -n "$NAMESPACE" "$pod" -- kill -3 1 || true
        sleep 1
        oc logs -n "$NAMESPACE" "$pod" --tail=1200 || true
        cat /tmp/jcmd_err.$$ || true
      fi
      rm -f /tmp/jcmd_out.$$ /tmp/jcmd_err.$$ || true
      sleep "$INTERVAL_SECONDS"
    done
    echo "# utc_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$out_file"
}

log "Listando pods label=$LABEL_SELECTOR namespace=$NAMESPACE"
mapfile -t PODS < <(oc get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --no-headers | awk '{print $1}')

if [[ ${#PODS[@]} -eq 0 ]]; then
  log "Nenhum pod encontrado. Ajuste NAMESPACE/LABEL_SELECTOR."
  exit 1
fi

log "Pods encontrados: ${PODS[*]}"

SNAPSHOT_FILE="$OUTPUT_DIR/db_idle_snapshot_$(date -u +%Y%m%dT%H%M%SZ).csv"
capture_db_snapshot "$SNAPSHOT_FILE"

for pod in "${PODS[@]}"; do
  capture_dump_for_pod "$pod" "$OUTPUT_DIR/threaddump_${pod}.txt"
done

cat > "$OUTPUT_DIR/README.txt" <<EOF
Arquivos gerados:
- $SNAPSHOT_FILE
- threaddump_<pod>.txt

Como correlacionar:
1) Compare host_name da snapshot SQL com nome/IP do pod.
2) Classifique threads em socketRead, lock/park, Infinispan RPC, wait.
3) Calcule distribuição (%) para identificar hipótese dominante.
EOF

log "Captura finalizada em $OUTPUT_DIR"
