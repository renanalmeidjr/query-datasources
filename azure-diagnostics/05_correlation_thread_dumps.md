# Correlação: transação aberta no banco ↔ estado da thread na JVM

## O que este guia faz

Explica como capturar, **no mesmo instante do pico**, as ~1800 sessões
idle-in-transaction no banco e os thread dumps dos pods Keycloak/RHBK no
OpenShift (ARO), e como correlacioná-los para descobrir **o que cada thread da
JVM está fazendo enquanto a transação correspondente fica aberta e ociosa no
banco**.

Esta correlação fecha o diagnóstico: ela responde se os ~98 % de tempo ocioso de
cada transação são gastos em **round-trip de rede** (thread em `socketRead`) ou
em **trabalho/espera da JVM** (lock em memória, replicação Infinispan, GC,
lógica de sessão).

---

## Pré-requisitos

- Acesso `oc` ao cluster ARO com permissão de `exec` nos pods Keycloak.
- Acesso ao banco (SSMS, Azure Data Studio, sqlcmd) para rodar as queries
  `01_abertas_vs_executando.sql` e `02_idle_in_transaction_detail.sql`.
- Coordenação de horário entre quem executa no banco e quem executa no cluster
  (use NTP / relógio UTC em ambos os lados).

---

## Passo 1 — Identificar os pods Keycloak em execução

```bash
# Liste os pods do namespace onde o RHBK/Keycloak está rodando
oc get pods -n <namespace-keycloak> -l app=<label-keycloak> --no-headers \
  | awk '{print $1}'
```

Guarde os nomes dos pods. Em produção haverá N réplicas; colete thread dumps de
**todos** (ou pelo menos de 3-5 pods representativos).

---

## Passo 2 — Capturar o estado do banco (no pico)

No mesmo instante, execute:

```sql
-- Snapshot 1: quantos abertos vs executando (01_abertas_vs_executando.sql)
-- Snapshot 2: lista detalhada de idle-in-transaction (02_idle_in_transaction_detail.sql)
```

Salve o resultado em CSV com timestamp UTC. Colunas importantes:
`session_id`, `host_name`, `idle_segundos_desde_ultimo_cmd`, `program_name`.

> **Dica**: o `host_name` no banco corresponde ao nome do pod (ou hostname da
> JVM). Use-o para correlacionar com o thread dump do pod correto.

---

## Passo 3 — Capturar thread dumps dos pods (no mesmo instante)

Repita o dump 3 a 5 vezes em série, com intervalo de ~2 s entre cada, para
pegar threads que estejam em estados transitórios.

### Opção A — jcmd (recomendado; requer JDK no container)

```bash
POD=<nome-do-pod>
NS=<namespace-keycloak>

for i in 1 2 3; do
  echo "=== DUMP $i — $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> /tmp/threaddump_${POD}.txt
  oc exec -n $NS $POD -- jcmd 1 Thread.print >> /tmp/threaddump_${POD}.txt 2>&1
  sleep 2
done
```

### Opção B — kill -3 (envia SIGQUIT, grava em stdout/log do container)

```bash
POD=<nome-do-pod>
NS=<namespace-keycloak>

oc exec -n $NS $POD -- kill -3 1
# Leia o log do container logo em seguida
oc logs -n $NS $POD --tail=2000 > /tmp/threaddump_${POD}_log.txt
```

### Opção C — jstack via oc exec

```bash
POD=<nome-do-pod>
NS=<namespace-keycloak>
PID=$(oc exec -n $NS $POD -- jps | grep -i keycloak | awk '{print $1}')

oc exec -n $NS $POD -- jstack $PID > /tmp/jstack_${POD}.txt
```

---

## Passo 4 — Correlacionar banco ↔ JVM

### 4.1 Identificar qual pod dono de cada sessão ociosa

O campo `host_name` na query `02_idle_in_transaction_detail.sql` retorna o
hostname da JVM que abriu a conexão. Faça o match com o nome do pod.

Se o driver JDBC usar um hostname genérico (ex.: endereço IP), mapeie via:

```bash
# Descobrir IP dos pods
oc get pods -n <namespace-keycloak> -o wide | grep <label>
```

### 4.2 Analisar o thread dump do pod correspondente

Para cada sessão idle-in-transaction no banco, procure no thread dump a thread
que está associada à conexão JDBC. O pool Agroal nomeia threads de forma
previsível; busque por:

```
"pool-<N>-thread-<M>"
"agroal"
"keycloak-worker"
"executor-thread"
```

### 4.3 Interpretar o estado da thread

| Estado da thread JVM                              | Significado                                                                      | Causa provável da transação aberta ociosa                       | Ação                                                                                 |
|---------------------------------------------------|----------------------------------------------------------------------------------|------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| `java.net.SocketInputStream.socketRead`           | Thread esperando resposta do banco (blocked no I/O de rede)                      | Round-trip/latência de rede — transação segura conexão enquanto espera próxima resposta do banco | Verificar latência p99 do PE/VNet; considerar batching de operações                  |
| `sun.nio.ch.SocketChannelImpl.read` / NIO blocked | Thread em NIO aguardando dados — semelhante ao anterior                           | Round-trip latência                                              | Idem                                                                                 |
| `java.util.concurrent.locks.LockSupport.park`     | Thread suspensa aguardando lock em memória (não está fazendo I/O)                 | Contensão de lock JVM — Infinispan, cache local, fila interna    | Identificar qual lock (próximo frame no stack); reduzir contenção de cache           |
| `org.infinispan.*` / `infinispan`                 | Thread na replicação síncrona do cache Infinispan                                  | Transação aberta enquanto Infinispan sincroniza réplicas          | Avaliar modo async do Infinispan ou `persistent-user-sessions` non-blocking          |
| `java.lang.Thread.sleep`                          | Thread em sleep intencional dentro do escopo da transação                          | Lógica de retry/backoff dentro do BEGIN..COMMIT                  | Mover retry para fora do escopo da transação                                        |
| `RUNNABLE` (sem I/O nem lock visível)             | Thread ocupada com CPU (GC, deserialização, lógica)                                | Trabalho de CPU/lógica da JVM mantendo a transação aberta        | Profile com async-profiler/JFR para identificar o hotspot                           |
| `TIMED_WAITING` em `Object.wait`                  | Thread aguardando notify (provavelmente queue interna)                             | Transação aberta enquanto espera item numa fila ou pool interno   | Verificar se o pool Agroal está esgotado (ver 06_agroal_metrics.md)                 |
| Thread não encontrada / ausente no dump           | Thread pode ter liberado a conexão e outro mecanismo manteve a transação aberta    | Transação esquecida / connection leak                            | Verificar se Agroal tem timeout de transação configurado                            |

### 4.4 Conclusão por tipo de estado

**Se a maioria das threads estiver em `socketRead` / NIO blocked:**
- O custo é **latência de rede / round-trip** (PaaS acrescenta ms extras por
  chamada; com muitas chamadas por transação, isso multiplica).
- Cada round-trip adicional dentro da transação aumenta o tempo que ela fica
  aberta.
- Ação: reduzir o número de round-trips por transação (batch, pipeline),
  ou reduzir a latência de rede (PE na mesma VNet, zona).

**Se a maioria das threads estiver em `park` / Infinispan / lock:**
- O custo é **trabalho/espera da JVM** — a transação está aberta enquanto a
  thread faz algo que não é SQL (replicação de cache, lock de fila, etc.).
- Isso ocorreria igualmente em PaaS e IaaS → não é culpa do banco.
- Ação: mover a replicação Infinispan para fora do escopo do BEGIN..COMMIT,
  ou usar modo async (ver 07_rhbk26_transaction_scope.md).

---

## Passo 5 — Registrar e comparar PaaS vs IaaS

Repita a coleta (banco + thread dumps) em ambos os ambientes no mesmo cenário
de carga. Compare:

| Métrica                              | SQL PaaS | SQL IaaS |
|--------------------------------------|----------|----------|
| Abertas / Executando                 |          |          |
| Razão execução útil (%)              |          |          |
| Mediana idle_segundos_ultimo_cmd     |          |          |
| % threads em socketRead              |          |          |
| % threads em park/Infinispan         |          |          |
| pct_ocioso médio (EE — script 04)    |          |          |

Se os estados de thread forem iguais em PaaS e IaaS, o gargalo é **a aplicação**,
não o banco. Se as threads em `socketRead` forem proporcionalmente maiores no PaaS,
o gargalo é a **latência de rede do serviço gerenciado**.
