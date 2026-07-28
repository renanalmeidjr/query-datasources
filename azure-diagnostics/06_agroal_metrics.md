# Métricas do Agroal — pool de conexões alinhado ao dado de ~1800 conexões ativas

## O que este guia faz

Documenta como coletar e interpretar as métricas do pool de conexões **Agroal**
(usado pelo Quarkus / RHBK) alinhadas ao dado observado de **~1800 conexões
abertas simultaneamente**, com apenas ~40 de fato executando SQL no banco.

---

## Por que o pool importa neste diagnóstico

Se ~1800 conexões estão em uso (`activeCount ≈ 1800`) mas apenas ~40 executam
SQL, o pool está sendo **retido** por threads que abriram uma transação e não a
fecharam rapidamente.

> **Aumentar o `max-size` do pool NÃO resolve o problema.**
> Aumentar o pool apenas cria mais conexões/transações abertas ociosas —
> amplifica o sintoma, não trata a causa raiz. A alavanca é **encurtar o escopo
> do `BEGIN..COMMIT`**, não dar mais conexões para as threads segurarem por mais
> tempo.

---

## Métricas a coletar

### Via endpoint de métricas Quarkus / MicroProfile (HTTP)

```bash
# Substitua <pod-ip> e <porta-management> conforme o ambiente
curl -s http://<pod-ip>:<porta-management>/q/metrics \
  | grep -E 'agroal|datasource'
```

Ou via Prometheus/Grafana se as métricas já estiverem sendo exportadas.

### Via Management REST API do RHBK / Keycloak (se habilitada)

```bash
curl -s http://<pod-ip>:9000/health/ready
curl -s http://<pod-ip>:9000/metrics | grep -i agroal
```

---

## Métricas-chave e como interpretá-las no cenário de 1800/40

| Métrica Agroal                         | O que significa                                                      | Valor esperado / alerta no cenário atual                                                     |
|----------------------------------------|----------------------------------------------------------------------|----------------------------------------------------------------------------------------------|
| `agroal_active_count`                  | Conexões em uso neste instante (em uso por uma thread)               | ~1800 no pico — confirma que 1800 threads têm uma conexão "presa"                           |
| `agroal_max_used_count`                | Pico histórico de conexões em uso desde o último reset               | Se ≈ `max-size`, o pool já esgotou em algum momento                                         |
| `agroal_available_count`               | Conexões disponíveis no pool agora (ociosas, prontas para uso)       | ~0 no pico → pool esgotado; novas threads ficam bloqueadas esperando uma conexão              |
| `agroal_blocking_time_total_seconds`   | Tempo total gasto por threads bloqueadas esperando uma conexão livre  | Cresce no pico → indica pool esgotado; latência percebida pelo cliente sobe                  |
| `agroal_created_count`                 | Total de conexões criadas desde o início (pool growth)               | Se cresce continuamente, o pool está criando conexões extras (acima do steady-state)         |
| `agroal_acquire_count`                 | Total de aquisições de conexão                                        | Normalizado pela duração do teste para ver taxa de aquisição/s                              |
| `agroal_flush_count`                   | Conexões descartadas por timeout ou erro                              | Alto valor indica instabilidade (erros de conexão, timeout de rede)                         |
| `agroal_reap_count`                    | Conexões removidas por `idle-removal-timeout` (ficaram ociosas demais)| Se alto, o pool está oscilando muito — ajustar `idle-removal-timeout`                       |

### Configuração a verificar

```properties
# No persistence.xml, standalone.xml, ou quarkus.properties:
quarkus.datasource.jdbc.max-size=<valor>      # deve ser ≥ agroal_active_count observado no pico
quarkus.datasource.jdbc.min-size=<valor>
quarkus.datasource.jdbc.acquisition-timeout=  # se muito baixo, threads falham; se muito alto, enfileiram
quarkus.datasource.jdbc.transaction-requirement=warn  # habilite para detectar transações não fechadas
```

---

## Análise: o que os números dizem

### Cenário 1 — `active_count` ≈ `max-size` (pool esgotado)

```
active_count     ≈ 1800
max-size         = 1800   ← pool completamente ocupado
available_count  ≈ 0
blocking_time    aumentando
```

**Leitura**: o pool está esgotado porque **cada thread abre uma transação e a
mantém aberta por muito tempo** (as ~1800 abertas ociosas). Novas threads ficam
bloqueadas em `acquisition-timeout` esperando uma conexão ficar livre.

**Consequência**: throughput trava não porque o banco não aguenta, mas porque
**nenhuma thread nova consegue uma conexão** — o banco está ocioso mas o pool
está cheio de transações ociosas.

**Ação**: encurtar a transação (ver `07_rhbk26_transaction_scope.md`) é a única
alavanca real. Aumentar `max-size` apenas cria mais transações ociosas e aumenta
a pressão sobre o banco que, apesar de ocioso, precisa gerenciar mais
conexões/locks abertos.

### Cenário 2 — `active_count` << `max-size` (pool com folga mas banco ocioso)

```
active_count     ≈ 1800
max-size         = 3000   ← pool tem folga
available_count  ≈ 1200
```

**Leitura**: o pool não está esgotado, mas ainda há 1800 conexões ativas e só
40 executando. Significa que as threads estão com conexão, abriram transação,
e estão paradas — não é falta de conexão, é tempo de transação longo.

**Ação**: mesma — encurtar a transação.

---

## Como coletar os números em série durante o pico

```bash
# Coleta em série (10 amostras, intervalo de 5 s)
for i in $(seq 1 10); do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  curl -s http://<pod-ip>:<porta>/q/metrics \
    | grep -E 'agroal_(active|available|blocking|max_used|created|flush|reap)'
  sleep 5
done
```

Salve a saída em arquivo para comparar PaaS vs IaaS. Se `blocking_time` cresce
mais rápido em um ambiente, o pool esgota mais rápido nele.

---

## Relação com as queries de banco

| Métrica Agroal                 | Equivalente no banco (queries SQL)                           |
|--------------------------------|--------------------------------------------------------------|
| `active_count` (~1800)         | `abertas_total` em `01_abertas_vs_executando.sql`            |
| `active_count` - ~40 executando | `idle_in_transaction` em `01_abertas_vs_executando.sql`      |
| `blocking_time` crescente      | Sinal de que novas requisições não conseguem conexão         |
| `available_count` ≈ 0          | Pool esgotado — banco pode estar ocioso mas app está bloqueada|

---

## Resumo executivo

> Com ~1800 conexões ativas e ~40 executando SQL, **o pool está ocupado por
> threads que abriram transação e não a fecharam rápido**. O banco está ocioso.
> **Aumentar `max-size` não resolve** — apenas cria mais transações ociosas.
> A única alavanca é encurtar o escopo `BEGIN..COMMIT` para que cada thread
> libere a conexão mais cedo. Consulte `07_rhbk26_transaction_scope.md` para o
> checklist de configuração do RHBK 26.
