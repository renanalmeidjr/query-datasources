# RHBK 26 / Keycloak — Escopo da transação com `persistent-user-sessions`

## O que este guia faz

Documenta como o **RHBK 26** (Red Hat Build of Keycloak 26) com a feature
`persistent-user-sessions` gerencia o escopo das transações de banco de dados,
e fornece um checklist de configuração para **encurtar o tempo que cada
transação fica aberta** — a alavanca central do diagnóstico de 1800/40.

---

## Contexto: por que `persistent-user-sessions` importa aqui

A partir do Keycloak 23+ / RHBK 26, as sessões de usuário são persistidas no
banco de dados por padrão (modo `persistent-user-sessions`). Isso significa que
**cada login, refresh de token e validação de sessão** pode gerar uma transação
de escrita no banco.

O problema diagnosticado (1800 transações abertas, ~40 executando) é a assinatura
de uma ou mais das seguintes situações:

1. A transação é aberta **cedo** (antes de todo o trabalho necessário ser feito)
   e mantida aberta enquanto ocorre trabalho não-DB (lógica JVM, round-trip de
   rede, replicação Infinispan).
2. O **commit síncrono da replicação Infinispan** acontece **dentro** do mesmo
   escopo `BEGIN..COMMIT`, fazendo a transação esperar a sincronização de cache
   antes de commitar.
3. O path de tratamento do request envolve **múltiplos round-trips ao banco**
   dentro de uma única transação longa (read → lógica → write → lógica → write),
   fazendo a transação ficar aberta por toda a duração do processamento.

---

## O que acontece dentro do `BEGIN..COMMIT` num fluxo de login do RHBK 26

```
[BEGIN TRAN]
  1. SELECT sessão existente (ou INSERT nova)
  ---- gap: lógica JVM (validação de token, claim enrichment) ----
  2. UPDATE sessão (last_access, state)
  ---- gap: replicação Infinispan (se síncrona) ----
  3. INSERT/UPDATE realm session events (auditoria)
[COMMIT]
```

O problema não é o tempo de execução dos SQLs (cada um leva < 5 ms),
mas os **gaps entre eles**: lógica de validação, chamadas externas, e
sincronização de cache Infinispan que ocorrem **dentro** do escopo da transação.

---

## Checklist de configuração para encurtar o escopo da transação

### 1. Modo de escrita de sessão: síncrono vs assíncrono/batch

| Configuração                                       | Comportamento                                                                  | Impacto na transação                                    |
|-----------------------------------------------------|--------------------------------------------------------------------------------|---------------------------------------------------------|
| `spi-sticky-session-encoder-infinispan-should-attach-route=false` | Evita que o nó atual seja "sticky" — pode reduzir replicação síncrona | Reduz espera de replicação dentro da transação          |
| `cache-embedded-mtls-enabled`                      | TLS na replicação Infinispan — adiciona latência de handshake                  | Evite se não for obrigatório para reduzir latência intra-cluster |
| `spi-user-sessions-infinispan-async-sessions-persistence=true` (KC 24+) | Escreve sessões no banco de forma assíncrona               | **Remove a escrita de sessão do caminho síncrono da transação** |

> **Verificar**: no RHBK 26, se `persistent-user-sessions` está habilitado,
> o fluxo padrão é síncrono. Verifique se existe uma opção de modo assíncrono
> ou batch nas release notes do RHBK 26.

### 2. Escopo da transação por request vs transação de longa duração

O Keycloak usa o `EntityManager` do JPA/Hibernate, que por padrão abre uma
transação por request completo. Verifique:

```bash
# No log do RHBK (DEBUG), procure por:
grep -i "begin transaction\|commit\|rollback" /var/log/keycloak/keycloak.log \
  | head -50
```

Se uma única request HTTP gera múltiplas transações aninhadas ou mantém uma
transação por toda a duração do request, o escopo está largo demais.

### 3. Número de round-trips por transação

Use a sessão de Extended Events (`04_extended_events_lifecycle.sql`) para
contar quantos eventos SQL existem por `transaction_id`. Se cada transação
contiver > 5-10 eventos, há oportunidade de reduzir via:

- **Read-your-writes cache**: cachear o SELECT de sessão no Infinispan para
  evitar re-leitura do banco dentro da mesma transação.
- **Batch de writes**: agrupar múltiplos UPDATEs de sessão num único statement
  (Hibernate batch size).
- **Write-behind**: postergar escritas de atualização de `last_access` para
  depois do COMMIT do request principal.

### 4. Interação transação de banco ↔ replicação Infinispan síncrona

```
Fluxo problemático:
  [BEGIN TRAN banco]
    SQL write
    → Infinispan.put() (síncrono — espera ACK das réplicas)   ← gap aqui
    SQL write
    → Infinispan.put() (síncrono)                             ← gap aqui
  [COMMIT banco]

Fluxo melhorado:
  [BEGIN TRAN banco]
    SQL write
    SQL write
  [COMMIT banco]
  → Infinispan.put() (após commit — assíncrono ou best-effort) ← fora da transação
```

Verifique se o RHBK 26 permite configurar a replicação Infinispan para ocorrer
**depois** do commit do banco, e não **dentro** da transação.

### 5. Configurações do JPA/Hibernate relevantes

```properties
# Tamanho do batch de INSERT/UPDATE (reduz round-trips)
quarkus.hibernate-orm.jdbc.statement-batch-size=50

# Habilita batch de writes automático
quarkus.hibernate-orm.jdbc.batch-versioned-data=true

# Timeout de transação (previne transações abertas indefinidamente)
quarkus.transaction-manager.default-transaction-timeout=30S
```

### 6. Timeout de transação no Agroal (safety net)

```properties
# Aborta transações abertas por mais que N segundos (previne leak)
quarkus.datasource.jdbc.transaction-requirement=warn
# Em RHBK, verificar se há equivalente em standalone.xml / KC config
```

---

## Checklist de diagnóstico

- [ ] Verificar no log do RHBK 26 se `persistent-user-sessions` está ativo e
      qual o modo de persistência (síncrono / assíncrono).
- [ ] Verificar se existe configuração de async session persistence no RHBK 26
      (release notes e SPI de sessão).
- [ ] Com Extended Events (`04_extended_events_lifecycle.sql`), contar quantos
      SQLs existem por transação e medir os gaps entre eles.
- [ ] Comparar os gaps em PaaS vs IaaS: se iguais → custo é da JVM/Infinispan;
      se maiores no PaaS → custo é round-trip de rede.
- [ ] Verificar se a replicação Infinispan ocorre dentro ou fora do escopo
      da transação de banco.
- [ ] Habilitar Hibernate batch (`statement-batch-size`) para reduzir
      round-trips por transação.
- [ ] Definir `default-transaction-timeout` para evitar transações abertas
      indefinidamente (protection layer).
- [ ] Correlacionar thread dumps (guia `05_correlation_thread_dumps.md`) com
      as sessões idle-in-transaction para confirmar se o gap é Infinispan
      (threads em `park`/Infinispan) ou latência de rede (`socketRead`).

---

## Referências

- [RHBK 26 Release Notes — Persistent User Sessions](https://access.redhat.com/documentation/en-us/red_hat_build_of_keycloak/26.0/html/release_notes/)
- [Keycloak — Persistent User Sessions feature flag](https://www.keycloak.org/server/features)
- [Quarkus — Agroal datasource configuration](https://quarkus.io/guides/datasource)
- [Hibernate ORM — JDBC batch](https://docs.jboss.org/hibernate/orm/6.4/userguide/html_single/Hibernate_User_Guide.html#batch)
