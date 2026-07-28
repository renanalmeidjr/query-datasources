# azure-diagnostics — Toolkit de Diagnóstico: Keycloak / RHBK 26 × Azure SQL Hyperscale PaaS

## Contexto e evidência central

Investigação de gargalo em **15K RPS** contra Keycloak / RHBK 26 em pods
OpenShift (ARO), App Gateway na frente, contra Azure SQL Hyperscale 128 vCores
Premium (Zone Redundant, SQL Auth, Private Endpoint na VNet do ARO).

**Comparativo de throughput:**

| Banco / Caminho              | RPS atingido |
|------------------------------|:------------:|
| Oracle / Postgres — VM IaaS  | **15 K**     |
| SQL Server — VM IaaS         | 11.5 K       |
| SQL Server — Hyperscale PaaS | **6 K**      |

### Dado crítico: 1800 abertas / 40 executando

Medição no pico:

| Métrica                         | Valor |
|---------------------------------|------:|
| Sessões com transação aberta    | ~1800 |
| Sessões executando SQL (running/runnable) | ~40 |
| Sessões idle-in-transaction     | ~1760 |
| **Razão de execução útil**      | **~2 %** |
| Utilização do banco (CPU/IO)    | < 60 % |

### Leitura via Lei de Little

> L = λ × W
>
> Se há 1800 transações abertas e apenas 40 trabalhando num dado instante,
> a razão trabalho-útil/tempo-aberto é **40/1800 ≈ 2 %**.
> **98 % do tempo de vida de cada transação é gasto fora da execução SQL** —
> a transação está aberta e ociosa enquanto a thread da JVM faz outra coisa
> (round-trip de rede, lógica de validação, replicação Infinispan, espera de
> lock em memória).

**Conclusão**: o banco está ocioso. Um banco ocioso não pode ser o gargalo.
O gargalo está no tempo que cada transação fica aberta sem trabalhar —
comportamento da **aplicação / do caminho**, não do banco.

---

## A alavanca correta

> **Aumentar o pool de conexões NÃO resolve.**
> Com `max-size` em 1800, 1800 threads seguram conexões+transações abertas
> ociosas. Aumentar para 3600 apenas criaria 3600 transações ociosas —
> o banco ainda estaria ocioso, mas com o dobro de transações pendentes.
>
> **A alavanca é encurtar o escopo `BEGIN..COMMIT`**: remover round-trips,
> lógica JVM, e replicação síncrona de dentro da transação, para que cada
> thread libere a conexão mais rápido.

---

## Fluxo priorizado de diagnóstico

```
1. Extended Events (ciclo de vida da transação)   → medir gaps entre comandos
        ↓
2. Thread dumps dos pods Keycloak (correlação)    → descobrir o que a thread faz no gap
        ↓
3. Agroal metrics                                 → confirmar pool esgotado por retenção
        ↓
4. Queries de banco (confirmação negativa)         → banco ocioso, confirma gargalo fora do DB
```

---

## Conteúdo da pasta

| Arquivo                                  | O que faz                                                                                        |
|------------------------------------------|--------------------------------------------------------------------------------------------------|
| `01_abertas_vs_executando.sql`           | Snapshot ao vivo: abertas / executando / idle-in-transaction / razão de execução                |
| `02_idle_in_transaction_detail.sql`      | Lista cada sessão idle-in-transaction com quanto tempo está aberta e parada                     |
| `03_transaction_age_distribution.sql`    | Distribuição de idade das transações abertas (histograma de duração)                            |
| `04_extended_events_lifecycle.sql`       | Sessão de EE para capturar e agregar o ciclo de vida completo e os gaps entre comandos           |
| `05_correlation_thread_dumps.md`         | Guia de correlação transação-aberta-no-banco ↔ estado da thread na JVM (OpenShift)              |
| `06_agroal_metrics.md`                   | Métricas do pool Agroal alinhadas ao dado de ~1800 conexões ativas                              |
| `07_rhbk26_transaction_scope.md`         | Checklist de configuração do RHBK 26 para encurtar o escopo da transação                        |

---

## Tabela sintoma → ação → conclusão

| Sintoma observado                                                       | Ação de diagnóstico                                                                               | Conclusão esperada                                                                                           |
|-------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| 1800 abertas / 40 executando / banco < 60 % util                        | EE ciclo de vida (`04`) + thread dumps correlacionados (`05`)                                     | Prova que o tempo é gasto fora da execução SQL; revela se é path (socketRead) ou JVM (lock/Infinispan)      |
| razao_execucao_pct < 5 %                                                | `01_abertas_vs_executando.sql` ao vivo                                                            | Banco ocioso — gargalo não está no banco; investigar aplicação/caminho                                       |
| idle_segundos_desde_ultimo_cmd elevado (> 0.5 s por transação)          | `02_idle_in_transaction_detail.sql` + thread dump (`05`)                                          | Transação aberta por muito tempo sem SQL — identificar o que a thread está fazendo                           |
| Transações com duração > 500 ms mas soma_exec_ms < 20 ms                | `04_extended_events_lifecycle.sql` (resumo por transação, coluna pct_ocioso)                     | > 95 % do ciclo de vida é ocioso — encurtar BEGIN..COMMIT é a ação                                          |
| Threads em `socketRead` no thread dump                                  | Comparar gap_ms no EE entre PaaS e IaaS (`04`)                                                   | Custo é round-trip/latência de rede (PaaS adiciona ms por chamada); batching de operações reduz              |
| Threads em `park`/Infinispan no thread dump                             | Verificar se replicação Infinispan ocorre dentro da transação (`07`)                             | Custo é JVM/Infinispan — ocorre igual em PaaS e IaaS; mover replicação para fora do BEGIN..COMMIT           |
| `agroal_active_count` ≈ `max-size` + `blocking_time` crescente         | `06_agroal_metrics.md` + `01_abertas_vs_executando.sql`                                          | Pool esgotado por retenção — aumentar max-size não resolve; encurtar transação libera conexões               |
| Benchmark direto (HammerDB) no SQL PaaS entrega >> 6K TPS               | Comparar HammerDB vs Keycloak→PaaS                                                               | Banco tem capacidade de sobra; os 6K são limite da aplicação/caminho, não do banco                          |
| SQL IaaS trava em 11.5K (não 15K)                                       | Isolar variável motor vs caminho (célula Postgres PaaS vs Keycloak)                              | Parte do gargalo não é o banco — é a app/caminho; SQL IaaS abaixo de 15K prova isso                        |

---

## Interpretação rápida dos resultados do Extended Events (script 04)

```
Transação típica capturada no PaaS:
  duracao_total_ms = 420 ms
  soma_exec_ms     =   8 ms
  soma_gaps_ms     = 412 ms
  pct_execucao     =   2 %
  pct_ocioso       =  98 %
```

**Dois cenários para os 412 ms de gap:**

| Cenário | O que o thread dump mostra | Causa | Ação |
|---------|---------------------------|-------|------|
| A — gaps maiores no PaaS do que no IaaS | Threads em `socketRead` | Cada round-trip ao banco custa mais ms no PaaS (latência de rede gerenciada) | Reduzir round-trips por transação (batch, cache read-your-writes) |
| B — gaps iguais em PaaS e IaaS | Threads em `park`/Infinispan/`lock` | Custo é JVM — replicação de cache, lock de fila, lógica da aplicação, não o banco | Mover replicação/lógica para fora do BEGIN..COMMIT; async Infinispan |

---

## Como usar este toolkit em ordem

### Durante o pico de carga

1. Execute `01_abertas_vs_executando.sql` para confirmar a proporção.
2. Execute `02_idle_in_transaction_detail.sql` para ver quais sessões estão
   paradas e há quanto tempo.
3. Se a sessão de EE do script `04` já estiver ativa, leia os dados agora.

### Antes do próximo teste de carga

1. Execute a PARTE 1 do `04_extended_events_lifecycle.sql` para criar e iniciar
   a sessão de EE.
2. Durante o pico, colete thread dumps dos pods (guia `05`).
3. Após o pico, execute as partes 2A, 2B, 2C do script `04` para agregar os gaps.
4. Colete métricas do Agroal (guia `06`) em série durante o pico.
5. Execute a PARTE 3 do script `04` para limpar a sessão de EE.

### Análise pós-teste

1. Compare `pct_ocioso` por `transaction_id` — qual é a mediana?
2. Verifique os estados de thread no dump do horário de pico — maioria em
   `socketRead` (rede) ou `park`/Infinispan (JVM)?
3. Consulte `07_rhbk26_transaction_scope.md` para configurações de encurtamento
   de transação no RHBK 26.

---

## Placeholders — substitua antes de usar

| Placeholder               | O que substituir                                                    |
|---------------------------|---------------------------------------------------------------------|
| `<nome_do_banco>`         | Nome do banco de dados no SQL Server (ex.: `keycloak`)             |
| `<namespace-keycloak>`    | Namespace OpenShift onde os pods RHBK/Keycloak estão rodando       |
| `<label-keycloak>`        | Label do pod (ex.: `app.kubernetes.io/name=keycloak`)              |
| `<pod-ip>`                | IP do pod para curl das métricas                                    |
| `<porta-management>`      | Porta de management do Quarkus (padrão: `9000`)                     |
| `%keycloak%`              | Fragmento do `program_name` usado pelo driver JDBC do Keycloak     |

> **Nenhum segredo ou credencial deve ser commitado.** Todos os valores
> sensíveis (strings de conexão, senhas, tokens) ficam fora do repositório.
