# RHBK Parallel Harness (Quarkus + Azure SQL)

Cenário containerizado para simular workload do `persistent-user-sessions` (RHBK 26) sem subir o Keycloak completo.

## O que está incluído

- App Quarkus (`/test/session`, `/test/user`, `/health`, `/metrics`) com JDBC MSSQL + Agroal + Micrometer.
- Simulação opcional de replicação síncrona (`CACHE_SYNC_ENABLED=true`) via update dummy periódico.
- Scripts SQL:
  - `sql/init-schema.sql`
  - `sql/seed-data.sql` (100 realms, 1k clients, 10k users, 50k sessions)
- Helm chart em `helm/rhbk-parallel-harness/`.
- Load generator Locust em `load/locustfile.py`.

## Pré-requisitos

- Java 17 + Maven 3.9+
- Docker
- kubectl + Helm 3
- Acesso ao Azure SQL (IaaS ou PaaS) na mesma VNet/path que será testada
- Python 3.10+ (para Locust) ou container Locust

## Conexão JDBC recomendada (porta 1433)

Use `loginTimeout=30` e `socketTimeout=30000` como baseline inicial:

```text
jdbc:sqlserver://<host>:1433;databaseName=keycloak_test;encrypt=true;trustServerCertificate=true;hostNameInCertificate=*.database.windows.net;loginTimeout=30;socketTimeout=30000;
```

- `loginTimeout=30`: evita fail fast agressivo durante pico de conexão.
- `socketTimeout=30000`: suficiente para diferenciar timeout real de latência transitória.

## Build e imagem Docker

```bash
cd /home/runner/work/query-datasources/query-datasources/rhbk-parallel-harness
mvn -DskipTests package
docker build -t rhbk-parallel-harness:latest .
```

## Endpoints

- `GET /test/session/{sessionId}` -> SELECT de sessão
- `PUT /test/session/{sessionId}` -> UPDATE `last_activity_time`
- `GET /test/user/{userId}` -> SELECT de usuário
- `GET /health` -> saúde básica
- `GET /metrics` -> métricas Prometheus/Micrometer

## Configuração da app (env vars)

| Variável | Padrão | Descrição |
|---|---|---|
| `JDBC_URL` | localhost | Connection string SQL Server |
| `DB_USERNAME` | sa | Usuário SQL |
| `DB_PASSWORD` | `change_me` | Senha SQL |
| `DB_POOL_MAX_SIZE` | 50 | Agroal max-size |
| `DB_POOL_INITIAL_SIZE` | 10 | Agroal initial-size |
| `DB_POOL_ACQUIRE_TIMEOUT` | 30S | Timeout de aquisição |
| `CACHE_SYNC_ENABLED` | false | Simula "Infinispan SYNC" |
| `CACHE_SYNC_INTERVAL_MS` | 100 | Frequência de update dummy |
| `CACHE_SYNC_SESSION_ID` | session-000001 | Sessão usada na simulação |

## Banco: inicialização

```sql
:r ./sql/init-schema.sql
:r ./sql/seed-data.sql
```

Ou rode os scripts no Azure Data Studio/SSMS na ordem acima.

## Deploy no AKS/ARO via Helm

```bash
cd /home/runner/work/query-datasources/query-datasources/rhbk-parallel-harness
helm upgrade --install rhbk-harness ./helm/rhbk-parallel-harness \
  --set image.repository=<seu-registro>/rhbk-parallel-harness \
  --set image.tag=latest \
  --set replicaCount=6 \
  --set app.pool.maxSize=50 \
  --set secret.jdbcUrl="jdbc:sqlserver://<host>:1433;databaseName=keycloak_test;encrypt=true;trustServerCertificate=true;hostNameInCertificate=*.database.windows.net;loginTimeout=30;socketTimeout=30000;" \
  --set secret.username="<user>" \
  -f values-private.yaml

# values-private.yaml
# secret:
#   password: "<senha>"
```

### Ajustes úteis

- Paralelismo: `replicaCount`
- Pool JDBC: `app.pool.maxSize`, `app.pool.initialSize`
- Simulação sync: `app.cacheSync.enabled=true`
- Tipo de service: `service.type=LoadBalancer` (ou App Gateway + ClusterIP)

## Geração de carga (Locust)

Distribuição: `80% GET session`, `15% PUT session`, `5% GET user`.

```bash
cd /home/runner/work/query-datasources/query-datasources/rhbk-parallel-harness/load
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

TARGET_HOST=http://<service>:8080 \
USERS=15000 \
SPAWN_RATE=50 \
DURATION=5m \
./run-headless.sh
```

Arquivos `locust-results_*.csv` são gerados para análise de RPS/latência/erros.

## Comparativo IaaS vs PaaS

1. Deploy **a mesma imagem** com `JDBC_URL` apontando para SQL Server IaaS.
2. Rode o mesmo Locust (mesmos `USERS`, `SPAWN_RATE`, `DURATION`).
3. Troque só `JDBC_URL` para Azure SQL Hyperscale PaaS.
4. Rode novamente e compare:
   - RPS efetivo
   - latência p50/p95/p99 (Locust)
   - `agroal_pool_active_count`, `agroal_pool_available_count`, `agroal_pool_total_creation_time`
   - `http_server_requests_seconds`

## Teste da hipótese de contenção (simulação Infinispan)

- **Versão A**: `CACHE_SYNC_ENABLED=false`
- **Versão B**: `CACHE_SYNC_ENABLED=true` (update dummy a cada 100ms)

Compare throughput/latência entre A e B mantendo o resto idêntico.

## Troubleshooting

- `Connection refused / timeout`: valide NSG, DNS privado, private endpoint e rota para porta 1433.
- Muitas conexões ativas e baixa execução SQL: reduza escopo transacional na app alvo (não no harness).
- Erro de credencial: confira secret do Helm (`jdbc-url`, `username`, `password`).
- `/metrics` vazio: gere tráfego primeiro para materializar séries de latência.
