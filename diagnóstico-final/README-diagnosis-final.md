# Toolkit de diagnóstico final (fim do túnel)

Este diretório entrega os 3 testes críticos para fechar a causa raiz do cenário **1800 abertas / 40 executando / 6K RPS**.

## Arquivos

1. `01-extended-events-transaction-lifecycle.sql`
   - Captura ciclo de vida de transação (BEGIN → comandos → COMMIT) com versão **PaaS** e **IaaS**.
2. `02-thread-dumps-correlated.sh`
   - Captura thread dumps em OpenShift e snapshot de sessões SQL no mesmo instante.
3. `03-querystore-analyzer.sql`
   - Lista top queries no Query Store e classifica **SEEK vs SCAN**.
4. `results-template.csv`
   - Planilha modelo para comparar resultados e concluir hipótese A/B/C.

---

## Pré-requisitos

- Acesso SQL no Hyperscale PaaS e SQL Server IaaS.
- Acesso `oc` ao namespace do Keycloak/RHBK.
- Carga ativa no mesmo workload para PaaS e IaaS.

### Baseline de connection string para os testes

Para evitar timeouts muito agressivos sem mascarar problema de latência:

- `loginTimeout=30` (segundos)
- `socketTimeout=60000` (milissegundos)
- Porta `1433`

Exemplo JDBC SQL Server:

```text
jdbc:sqlserver://<host>:1433;databaseName=<db>;encrypt=true;hostNameInCertificate=*.database.windows.net;loginTimeout=30;socketTimeout=60000;
```

---

## Teste 1 (crítico): Extended Events PaaS vs IaaS

1. Rode PARTE A do `01-extended-events-transaction-lifecycle.sql` no PaaS.
2. Execute o teste de carga por 3–5 minutos.
3. Rode PARTE C e exporte os resultados.
4. Repita no IaaS (PARTE B para criar sessão, PARTE C para leitura).
5. Preencha `results-template.csv`.

**Interpretação:**

- `tx_total_ms (PaaS)` ≈ 2x–3x `tx_total_ms (IaaS)` com `round_trips` semelhantes → **Hipótese A (path/latência)**.
- `tx_total_ms (PaaS)` ≈ `tx_total_ms (IaaS)` → path não é o principal, siga para Teste 2.

---

## Teste 2 (crítico): thread dumps correlacionados

1. Configure variáveis do script:
   - `NAMESPACE`
   - `LABEL_SELECTOR`
   - opcional `SQL_SERVER`, `SQL_DATABASE`, `SQL_USER`, `SQL_PASSWORD` para snapshot automático.
2. Rode:

```bash
bash 02-thread-dumps-correlated.sh
```

3. Classifique no resultado o estado das threads:
   - `socketRead` / NIO read
   - `lock` / `park` / `ReentrantLock`
   - `Infinispan` / JGroups RPC

**Interpretação:**

- 80%+ em `socketRead` → **Hipótese A (path)**.
- 80%+ em lock/Infinispan → **Hipótese C (contenção JVM)**.
- mistura sem moda clara → cruzar com Teste 1 para decidir entre A/B/C.

---

## Teste 3 (validação): Query Store (Seek vs Scan)

1. Rode `03-querystore-analyzer.sql` no Hyperscale.
2. Verifique resumo `SEEK` vs `SCAN`.
3. Registre no `results-template.csv`.

**Interpretação:**

- Predomínio de `SEEK` → queries não são gargalo principal.
- Predomínio de `SCAN` + `CONVERT_IMPLICIT` → collation/índice contribui, porém secundário ao 1800/40.

---

## Ordem sugerida (48h)

1. Teste 1 (EE PaaS vs IaaS)
2. Teste 2 (thread dumps correlacionados)
3. Teste 3 (Query Store)

Com a planilha preenchida, a decisão de ação fica objetiva:

- **A (path)**: investigar rota/rede/redirect ou considerar IaaS.
- **B (escopo de transação)**: reduzir trabalho não-DB dentro de BEGIN..COMMIT no RHBK.
- **C (lock JVM/Infinispan)**: ajustar modo de replicação/escopo de lock.
