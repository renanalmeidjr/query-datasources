# 08 — Análise Técnica de Collation: Impacto em Performance e Throughput

> **Contexto:** Investigação de gargalo Keycloak / RHBK 26 contra Azure SQL Hyperscale
> em 6K RPS (1800 transações abertas, 40 executando, banco < 60 % util).  
> **Pergunta central:** a collation do banco (`SQL_Latin1_General_CP1_CI_AS`) pode
> explicar ou contribuir para o teto de 6K?  
> **Resposta curta:** collation mismatch *pode contribuir* (index scans, conversões
> implícitas), mas dado que o banco está ocioso com 2 % de razão de execução, a
> **causa raiz está fora do banco** (caminho/JVM). Collation é uma otimização
> auxiliar que pode liberar alguns pontos percentuais, não a causa raiz.

---

## 1. O que é Collation

Collation é o conjunto de regras que define como o SQL Server:

- **Compara** dois valores de string (igualdade, ORDER BY, WHERE, JOIN).
- **Ordena** resultados (ORDER BY, GROUP BY, DISTINCT).
- **Armazena** em índice: a ordenação física das chaves de um índice em coluna
  de string segue a collation da coluna.

Cada collation codifica quatro decisões:

| Decisão       | Símbolo | Descrição                                       |
|---------------|---------|-------------------------------------------------|
| Case          | CI / CS | Case Insensitive / Case Sensitive               |
| Accent        | AS / AI | Accent Sensitive / Accent Insensitive           |
| Kana          | KS / —  | Kana Sensitive (japonês)                        |
| Width         | WS / —  | Width Sensitive (caracteres half/full width)    |

---

## 2. Collation Atual vs Recomendado

### 2.1 `SQL_Latin1_General_CP1_CI_AS` — padrão do servidor / banco atual

| Componente               | Significado                                                    |
|--------------------------|----------------------------------------------------------------|
| `SQL_Latin1_General`     | Família SQL Server legada (pré-Windows, sort rules próprias)   |
| `CP1`                    | Code Page 1252 — Latin-1 ocidental                            |
| `CI`                     | Case Insensitive                                               |
| `AS`                     | Accent Sensitive                                               |

**Características:**
- Sort rules derivadas do legado SYBASE/SQL Server; não mapeiam diretamente ao
  padrão Unicode ICU/ISO.
- Colunas `VARCHAR` armazenam dados em CP-1252 (1 byte/char para Latin).
- Colunas `NVARCHAR` usam UCS-2; comparação usa a sort rule SQL legada.
- Comparação de string é relativamente **simples e rápida** para o subconjunto
  Latin-1 — "fast path" no kernel do SQL Server.
- **Limitação:** comportamento de sort pode divergir de aplicações modernas que
  esperam sort Unicode ICU-100; caracteres suplementares (fora do BMP) podem
  ser comparados de forma inesperada (tratados como par substituto em UCS-2).

### 2.2 `Latin1_General_100_CI_AS_SC_UTF8` — recomendado

| Componente               | Significado                                                                  |
|--------------------------|------------------------------------------------------------------------------|
| `Latin1_General`         | Família Windows/ISO — compatível com sort Unicode padrão                     |
| `100`                    | Versão 100 da sort table (mais recente, maior cobertura linguística)         |
| `CI`                     | Case Insensitive                                                              |
| `AS`                     | Accent Sensitive                                                              |
| `SC`                     | Supplementary Characters — suporte completo ao plano BMP+SMP do Unicode      |
| `UTF8`                   | Encoding físico UTF-8 para colunas `VARCHAR`/`CHAR` (SQL Server 2019+)       |

**Características:**
- Sort rules derivadas do padrão Unicode ICU-100 — mais correto linguisticamente.
- Colunas `VARCHAR` com `_UTF8` armazenam em UTF-8: Latin characters (1 byte),
  caracteres multi-byte quando necessário.
- Colunas `NVARCHAR` continuam UCS-2 (UTF-16), independente de `_UTF8`.
- Comparação de string usa **mais CPU** por operação — a tabela de sort de
  versão 100 + SC é mais densa que a CP1 legada.
- `SC` resolve o problema de pares substitutos; sem `SC`, caracteres fora do
  BMP (emojis, CJK Ext B) são comparados byte-a-byte.

---

## 3. Impacto em Performance — Análise Técnica

### 3.1 Implicit Conversion e Index Seek vs Scan

Este é o **achado mais crítico para o cenário Keycloak**.

Quando a collation de uma coluna indexada diverge da collation da expressão na
query (literal, parâmetro, coluna de outra tabela), o SQL Server **não pode usar
o índice diretamente** para comparação — precisa converter um dos lados para a
collation comparável antes de checar. O resultado é:

```
-- Exemplo: coluna col_usuario tem collation A, literal na query chega com collation B
SELECT * FROM USER_ENTITY WHERE USER_NAME = N'alice'
   -- Se a collation do literal diferir da collation do índice:
   -- Optimizer emite IMPLICIT CONVERSION → o índice vira um Index Scan ao invés de Index Seek
```

| Operação     | I/O lido   | Locks mantidos              | Impacto em concorrência              |
|--------------|------------|-----------------------------|--------------------------------------|
| Index Seek   | páginas da linha (O(log n)) | lock na linha/página         | Baixo                       |
| Index Scan   | todas as páginas do índice  | lock em range de páginas     | **Alto — serializa acesso** |

Sob 6K RPS com escritas síncronas de sessão, **scans frequentes causam contenção
de lock / I/O sequencial**, mesmo que a CPU do banco fique baixa — as transações
esperam umas às outras para varrer o índice.

### 3.2 CPU por comparação

`_100_SC_UTF8` usa tabelas de sort maiores; cada comparação de string custa
levemente mais CPU do que `CP1`. O delta é pequeno por query, mas perceptível
em workloads altamente select-heavy (ex.: busca de sessão por user ID).

- Com CPU já < 60 %: o overhead adicional não vai saturar o banco, mas pode
  empurrar ligeiramente o custo de queries de lookup.
- Se o banco já estiver perto do limite de CPU, a mudança para 100+SC+UTF8
  pode **degradar** ligeiramente o throughput de leitura.

### 3.3 ORDER BY / GROUP BY / DISTINCT

Ordenações em colunas com collation diferente do esperado podem forçar **sort
adicional** no plano de execução. Isso afeta queries que retornam listas
ordenadas de usuários, clientes, roles — menos crítico para o workload de
sessão do Keycloak (predominantemente lookup por chave), mas pode impactar
queries administrativas.

### 3.4 UTF-8 e armazenamento em disco

Para o esquema Keycloak (colunas dominantemente Latin/ASCII):

- `VARCHAR CP1252` ≈ `VARCHAR UTF-8` em bytes para strings com apenas caracteres
  Latin-1 (ambas 1 byte/char).
- Para strings com caracteres não-Latin (ex.: nomes com caracteres CJK, árabe),
  UTF-8 pode ser mais compacto que UCS-2 (`NVARCHAR`) ou equivalente ao CP1252.
- A diferença de I/O de disco é desprezível para o workload de sessão.

---

## 4. Pode o Collation Explicar o Gargalo de 6K?

### 4.1 Análise do cenário (1800 abertas / 40 executando)

A evidência central do seu cenário é:

```
razao_execucao_pct = 40 / 1800 ≈ 2 %
```

Isso significa que **98 % do tempo de vida de cada transação é gasto fora da
execução SQL** — a transação está aberta e ociosa enquanto a thread da JVM faz
outra coisa (round-trip de rede, lógica de validação, replicação Infinispan,
espera de lock em memória, custo de latência PaaS inter-zona).

**Se o gargalo fosse collation mismatch (index scans):**
- O banco estaria com CPU próxima de 100 % e/ou waits em `LCK_M_*` altos.
- As 40 sessões "executando" estariam com `wait_type = LCK_M_S` ou
  `PAGEIOLATCH_SH` durante scans.
- O I/O do banco estaria elevado (muitas páginas lidas por query).
- O dado que você tem — banco < 60 % util, sem waits relevantes — **não é
  compatível com um gargalo de collation mismatch**.

### 4.2 Conclusão

| Situação                                    | Collation como causa raiz? |
|---------------------------------------------|---------------------------|
| Banco saturado (CPU > 80 %, I/O alto, waits LCK/PAGEIO) | **Possível** — investigar |
| Banco ocioso (CPU < 60 %, waits baixos, 40/1800 exec)   | **Não** — causa está fora do banco |

**No seu cenário: collation não é a causa raiz do teto de 6K.**

O teto de 6K é causado pelo tempo que as transações ficam abertas sem trabalhar
(98 % ocioso), o que é determinado pela **latência do caminho** (round-trips
adicionais do PaaS gerenciado vs IaaS, latência inter-zona do Zone Redundant,
custo de auth Entra, replicação Infinispan dentro da transação).

### 4.3 O que collation *pode* fazer no seu cenário

Se existirem collation mismatches (colunas/índices com collation diferente da
collation usada pelos parâmetros JDBC), queries de lookup de sessão/usuário
podem estar fazendo **index scans em vez de seeks**. Isso:

- Não é a causa do teto de 6K (banco está ocioso).
- Mas adiciona I/O e locks desnecessários, podendo contribuir com alguns % de
  overhead nas queries SQL que *são* executadas.
- Correção de collation mismatch pode liberar **5–15 % de throughput** se as
  queries de hot path estão fazendo scans por este motivo.
- É uma **otimização auxiliar**, não a correção do problema principal.

---

## 5. Resumo dos Trade-offs das duas Collations

| Aspecto                             | `SQL_Latin1_General_CP1_CI_AS` | `Latin1_General_100_CI_AS_SC_UTF8` |
|-------------------------------------|-------------------------------|-------------------------------------|
| CPU por comparação de string        | Menor (fast path CP1)         | Maior (sort table 100 + SC)         |
| Suporte a Unicode completo (BMP+SMP)| Parcial (UCS-2 sem SC)        | Completo (SC + UTF-8)               |
| Compatibilidade com apps modernas   | Legada — possível divergência de sort | Padrão Unicode ICU-100        |
| Risco de implicit conversion        | Baixo em ambiente homogêneo CP1 | Baixo — mas *diferente* do CP1      |
| Index seek em queries JDBC          | OK se driver usa CP1 encoding | OK se driver usa UTF-8 / Unicode    |
| Impacto de migração                 | — (status quo)                | Alto: recria índices, colunas, constraints |
| Recomendação para novos bancos      | Não recomendado (legado)      | **Recomendado** para SQL Server 2019+ |

---

## 6. Próximos Passos Recomendados

1. **Execute `09_collation_diagnostics.sql`** para detectar collation mismatches
   reais no seu banco Keycloak e implicit conversions em execução.
2. **Se mismatches forem encontrados:** avalie se as colunas afetadas são do
   hot path de sessão/usuário. Se sim, a correção (script `10`) pode liberar
   alguns %.
3. **Se não houver mismatches:** collation não contribui para o gargalo; foque
   na análise de ciclo de vida da transação (script `04`) e thread dumps
   (script `05`) para localizar os 98 % de tempo ocioso.
4. **A causa raiz do teto de 6K** está no tempo fora do SQL — veja o fluxo
   priorizado no README deste toolkit.

---

> **Lembrete:** Nenhum segredo ou credencial deve ser commitado.
> Substitua `<nome_do_banco>` pelo nome real antes de executar.
