# 10 — Guia Prático: Testar e Aplicar Mudança de Collation

> **Contexto:** Investigação de gargalo Keycloak / RHBK 26 contra Azure SQL
> Hyperscale em 6K RPS.  
> **Objetivo deste guia:** Fornecer os passos para medir o impacto real de
> collation, aplicar a mudança com o menor risco possível, e validar o resultado.  
> **Premissa:** Execute `09_collation_diagnostics.sql` primeiro para confirmar
> se há mismatches reais antes de iniciar qualquer migração.

---

## 1. Teste Comparativo (Antes de Qualquer Mudança)

### 1.1 Pré-requisitos

- Ambiente de homologação ou snapshot do banco de produção.
- Acesso ao SSMS, Azure Data Studio, ou `sqlcmd`.
- Dados de sessão/usuário representativos (ao menos 10 K usuários, 50 K sessões).

### 1.2 Metodologia

Execute cada etapa em sequência; registre os resultados.

**Passo 1 — Capturar o estado baseline (collation atual)**

```tsql
-- Em <nome_do_banco> com collation SQL_Latin1_General_CP1_CI_AS
-- Executar os blocos 4A e 4C de 09_collation_diagnostics.sql
-- Anotar:
--   - Logical Reads (SET STATISTICS IO ON)
--   - Elapsed time (SET STATISTICS TIME ON)
--   - Tipo de operação no plano: Seek ou Scan
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
-- ... colar query de 4A / 4C aqui ...
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

**Passo 2 — Capturar com COLLATE override (simula collation recomendado)**

```tsql
-- Mesmo banco, mesma query, mas com COLLATE override nas comparações
-- Executar os blocos 4B e 4D de 09_collation_diagnostics.sql
-- Anotar os mesmos indicadores
```

**Passo 3 — Comparar resultados**

| Indicador                   | Collation atual (CP1) | Com COLLATE override (100) | Variação |
|-----------------------------|----------------------|---------------------------|----------|
| Logical Reads (lookup user) | ?                    | ?                         | ?        |
| Elapsed ms (lookup user)    | ?                    | ?                         | ?        |
| Tipo de operação (Seek/Scan)| ?                    | ?                         | ?        |
| Logical Reads (session)     | ?                    | ?                         | ?        |
| Elapsed ms (session)        | ?                    | ?                         | ?        |

**Interpretação:**
- Se a operação muda de **Scan para Seek** com o override: há collation mismatch
  ativo afetando queries. A mudança de collation vai beneficiar este cenário.
- Se a operação **mantém Seek** em ambos: não há mismatch neste caso; mudança
  de collation não trará ganho de seek/scan.
- Se **Logical Reads caem**: o mismatch estava causando reads extras; migrar
  o collation reduzirá a carga de I/O.

### 1.3 Teste de carga comparativo (avançado)

Para medir o impacto em throughput real:

1. Clone o banco para um segundo servidor/instância de homologação.
2. Mude o collation do clone (ver Seção 3).
3. Execute o mesmo teste de carga (ex.: JMeter, Gatling) apontando para ambas
   as instâncias alternadamente, mesma carga, mesma duração.
4. Compare RPS, latência p95/p99, e métricas do banco (CPU, I/O, lock waits).

---

## 2. Alternativa de Baixo Risco: Mudar Apenas Colunas-Chave

Em vez de mudar o collation do banco inteiro (operação custosa, ver Seção 3),
mude apenas as **colunas do hot path** do schema Keycloak.

### 2.1 Identificar as colunas-chave

Execute a PARTE 1 de `09_collation_diagnostics.sql` e filtre pelas colunas com
`hot_path_flag = 'HOT PATH candidato'` e `collation_status = '*** MISMATCH ***'`.

Colunas típicas de hot path no schema Keycloak:

| Tabela          | Coluna          | Uso                               |
|-----------------|-----------------|-----------------------------------|
| `USER_ENTITY`   | `USERNAME`      | Lookup de usuário por nome        |
| `USER_ENTITY`   | `EMAIL`         | Lookup de usuário por e-mail      |
| `USER_ENTITY`   | `REALM_ID`      | Filter por realm                  |
| `USER_SESSION`  | `ID`            | Lookup de sessão por ID           |
| `USER_SESSION`  | `LOGIN_USERNAME`| Lookup de sessão por usuário      |
| `CLIENT`        | `CLIENT_ID`     | Lookup de cliente por ID          |
| `REALM`         | `ID`            | Lookup de realm por ID            |

### 2.2 Roteiro de mudança de coluna individual

> **Atenção:** Mudar o tipo/collation de uma coluna requer:
> - Remover foreign keys que referenciam a coluna.
> - Remover índices que incluem a coluna.
> - Alterar a coluna.
> - Recriar índices.
> - Recriar foreign keys.
>
> Teste em homologação antes de aplicar em produção.

```tsql
-- Exemplo: mudar collation da coluna USERNAME em USER_ENTITY
-- Substitua <nome_do_banco> e ajuste conforme seu schema real

USE [<nome_do_banco>];
GO

-- Passo 1: remover índices que incluem USERNAME
-- (execute a PARTE 2 de 09_collation_diagnostics.sql para listar os índices)
-- Exemplo:
DROP INDEX IF EXISTS [IDX_USER_NAME] ON [dbo].[USER_ENTITY];
GO

-- Passo 2: alterar a collation da coluna
-- Mantenha o tipo, tamanho e nullability iguais ao atual
ALTER TABLE [dbo].[USER_ENTITY]
    ALTER COLUMN [USERNAME]
        VARCHAR(255) COLLATE Latin1_General_100_CI_AS_SC_UTF8
        NOT NULL;
GO

-- Passo 3: recriar o índice com a nova collation
CREATE INDEX [IDX_USER_NAME]
    ON [dbo].[USER_ENTITY] ([USERNAME], [REALM_ID]);
GO
```

**Repita este roteiro para cada coluna identificada na PARTE 1.**

### 2.3 Validação pós-mudança de coluna

```tsql
-- Confirma que a coluna agora tem a nova collation
SELECT
    c.name AS column_name,
    c.collation_name,
    tp.name AS data_type
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE t.name = 'USER_ENTITY'
  AND c.name IN ('USERNAME', 'EMAIL', 'REALM_ID');
GO

-- Reexecutar blocos 4A/4B de 09_collation_diagnostics.sql
-- e confirmar que a operação agora é Index Seek (sem COLLATE override)
```

---

## 3. Mudança de Collation do Banco Inteiro (Operação Custosa)

> **Aviso:** Mudar o collation de um banco existente é uma **operação disruptiva
> de alto risco**. Exige recriação de todos os índices em colunas de string,
> potencialmente com downtime. Reserve para quando o ambiente de homologação
> confirmar ganho significativo.

### 3.1 O que acontece internamente

Mudar o collation do banco não retroage nas colunas existentes (elas mantêm
sua collation original). Para que as colunas herdem a nova collation, é
necessário:

1. Recriar as tabelas com `CREATE TABLE ... WITH (collation)` ou usar
   `ALTER COLUMN` para cada coluna de string.
2. Recriar todos os índices e constraints.

O SQL Server **não tem** um `ALTER DATABASE ... SET COLLATION` que migre as
colunas automaticamente.

### 3.2 Abordagem recomendada (se for necessário)

```tsql
-- Passo 1: mudar o collation padrão do banco
-- (afeta novas colunas sem collation explícita criadas no futuro)
ALTER DATABASE [<nome_do_banco>]
    COLLATE Latin1_General_100_CI_AS_SC_UTF8;
GO

-- Passo 2: para cada tabela/coluna de string, usar o roteiro da Seção 2.2
-- Este passo é a maior parte do trabalho e exige um script gerado
-- dinamicamente (ver Passo 3 abaixo)
```

**Passo 3 — Gerar script de ALTER COLUMN para todas as colunas de string**

```tsql
-- Gera um script ALTER COLUMN para todas as colunas de string do banco
-- Execute, revise, e aplique em homologação antes de produção
SELECT
    'ALTER TABLE [' + s.name + '].[' + t.name + '] '
    + 'ALTER COLUMN [' + c.name + '] '
    + tp.name
    + CASE
        WHEN c.max_length = -1 THEN '(MAX)'
        WHEN tp.name IN ('nvarchar','nchar') THEN '(' + CAST(c.max_length/2 AS VARCHAR) + ')'
        ELSE '(' + CAST(c.max_length AS VARCHAR) + ')'
      END
    + ' COLLATE Latin1_General_100_CI_AS_SC_UTF8'
    + CASE WHEN c.is_nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END + ';'
    AS alter_script
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE tp.name IN ('varchar', 'nvarchar', 'char', 'nchar')
  AND t.is_ms_shipped = 0
  AND c.collation_name <> 'Latin1_General_100_CI_AS_SC_UTF8'
ORDER BY s.name, t.name, c.name;
GO
```

### 3.3 Impacto e downtime estimado

| Fator                                     | Estimativa             |
|-------------------------------------------|------------------------|
| Tabelas afetadas (schema Keycloak típico) | 20–40 tabelas          |
| Colunas de string a alterar              | 50–150 colunas         |
| Índices a recriar                         | 30–100 índices         |
| Downtime (banco pequeno, < 10 GB)        | 30–90 minutos          |
| Downtime (banco grande, > 100 GB)        | Várias horas           |
| Impacto em FK constraints                 | Todas as FKs em string devem ser verificadas |

**Alternativa online:** No Azure SQL Hyperscale, use `CREATE INDEX ... WITH (ONLINE=ON)`
para recriar índices sem bloquear leituras. `ALTER COLUMN` ainda requer lock
breve na tabela, mas o impacto de índice pode ser online.

---

## 4. Métricas de Sucesso Pós-Mudança

Após aplicar a mudança (seja de coluna individual ou banco inteiro), execute
o ciclo de validação:

### 4.1 Verificação de plano de execução

```tsql
-- Após a mudança, executar os blocos 4A e 4C de 09_collation_diagnostics.sql
-- (sem COLLATE override desta vez — o novo collation nativo deve dar seek)
-- Esperar: Index Seek em vez de Index Scan para queries de lookup por username/session
```

### 4.2 Verificação de implicit conversions

```tsql
-- Executar PARTE 3 de 09_collation_diagnostics.sql
-- Esperar: ausência de CONVERT_IMPLICIT em queries de hot path
-- (ou redução significativa vs o baseline)
```

### 4.3 Teste de carga comparativo

Reexecutar o teste de carga nas mesmas condições do baseline e comparar:

| Métrica                      | Antes da mudança | Após a mudança | Variação esperada |
|------------------------------|-----------------|----------------|-------------------|
| RPS sustentado (pico)        | 6 K             | ?              | +5–15 % (se havia mismatch) |
| Latência p95 (login)         | ?               | ?              | Redução se havia scan |
| Logical reads por login      | ?               | ?              | Queda se havia scan→seek |
| Lock waits (`LCK_M_S`)       | ?               | ?              | Queda se havia scans concorrentes |
| CPU do banco no pico         | < 60 %          | ?              | Pode aumentar levemente (sort 100) |

### 4.4 Interpretação dos resultados

| Resultado observado                              | Interpretação                                                      |
|--------------------------------------------------|--------------------------------------------------------------------|
| RPS aumenta 5–15 %, reads caem, locks caem       | Collation mismatch estava causando scans; migração valeu          |
| RPS sem mudança significativa                    | Gargalo não era collation — foco no ciclo de vida da transação   |
| CPU do banco sobe ligeiramente                   | Normal — sort 100 é mais caro; aceitável se throughput subiu     |
| RPS piora                                        | Improvável; se ocorrer, investigar queries que tinham seek e agora têm scan |

---

## 5. Rollback

Se a mudança de coluna causar problemas:

```tsql
-- Reverter coluna para collation original
-- (substitua o nome da coluna, tipo, e collation original)
ALTER TABLE [dbo].[USER_ENTITY]
    ALTER COLUMN [USERNAME]
        VARCHAR(255) COLLATE SQL_Latin1_General_CP1_CI_AS
        NOT NULL;
GO

-- Recriar índice original
CREATE INDEX [IDX_USER_NAME]
    ON [dbo].[USER_ENTITY] ([USERNAME], [REALM_ID]);
GO
```

---

## 6. Checklist de Decisão

```
[ ] 1. Executar 09_collation_diagnostics.sql PARTE 1 e PARTE 3
       → Há collation mismatch em colunas hot path?
       → Há CONVERT_IMPLICIT em planos de queries de sessão/usuário?

[ ] 2. Se SIM para qualquer um acima:
       → Executar teste comparativo (Seção 1) em homologação
       → Logical reads caem? Seek substitui Scan?

[ ] 3. Se o teste comparativo mostrar ganho:
       → Aplicar mudança nas colunas-chave (Seção 2) — baixo risco
       → Reexecutar teste de carga comparativo (Seção 4.3)

[ ] 4. Se o ganho justificar:
       → Planejar mudança do banco inteiro (Seção 3) com janela de manutenção

[ ] 5. Se NÃO houver mismatch ou o ganho for < 5 %:
       → Collation não é o gargalo
       → Focar no ciclo de vida da transação (script 04) e thread dumps (script 05)
```

---

> **Lembrete:** O teto de 6K RPS no seu cenário tem como causa raiz o tempo
> que as transações ficam abertas sem trabalhar (98 % ocioso — 1800 abertas /
> 40 executando). Mesmo que a mudança de collation libere 5–10 %, a alavanca
> principal é encurtar o escopo `BEGIN..COMMIT`.  
> Consulte `07_rhbk26_transaction_scope.md` para as configurações de
> encurtamento de transação no RHBK 26.

---

> **Segurança:** Nenhum segredo ou credencial deve ser commitado.  
> Substitua todos os placeholders (`<nome_do_banco>`, `<usuario_teste>`,
> `<realm_teste>`, `<session_id_teste>`) por valores reais **apenas** em
> execução local — jamais no repositório.
