# Azure Function: Stage → tabela Always Encrypted (com Managed Identity)

Esta Azure Function carrega dados da tabela de **Stage** (`HR.Employees_stg2`) para a
tabela com **Always Encrypted** (`HR.Employees2`), usando a **Managed Identity** da
própria Function para:

1. **Logar no Azure SQL** (sem usuário/senha, via Entra ID); e
2. **Destravar a Column Master Key (CMK) no Azure Key Vault** (necessário para o
   driver criptografar `SSN` e `Salary` automaticamente).

> **Pré-requisito crítico:** a sua CMK precisa estar no **Azure Key Vault**, não no
> Certificate Store do Windows. Uma Function na nuvem não acessa o certificado da sua
> máquina local. Se hoje a CMK está em certificado, recrie/rotacione a CMK para o
> Key Vault antes de usar esta Function.

---

## Conteúdo deste projeto

| Arquivo | Para que serve |
| --- | --- |
| `StageToAlwaysEncrypted.csproj` | Projeto .NET 8 isolated + pacotes NuGet necessários |
| `Program.cs` | Cria a credencial (Managed Identity) e registra o provedor do Key Vault para Always Encrypted |
| `LoadEmployeesFunction.cs` | Função agendada (Timer) que lê do Stage e insere na tabela criptografada |
| `host.json` | Configuração do host das Functions |
| `local.settings.json.example` | Modelo das configurações locais (copie para `local.settings.json`) |
| `.gitignore` | Evita commitar `bin/`, `obj/` e o `local.settings.json` (que pode ter segredos) |

---

## Etapa 0 — O que instalar (você não precisa "saber programar")

- **VS Code** (gratuito) — caminho mais simples para publicar com poucos cliques.
- Extensões no VS Code: **Azure Account**, **Azure Functions**, **C#**.
- **.NET SDK** (LTS, ex.: .NET 8).
- **Azure Functions Core Tools** (v4).
- Conta no Azure com permissão para criar recursos.

> Alternativa sem VS Code: publicar por linha de comando (`func azure functionapp publish`)
> ou por ZIP Deploy no Portal. O VS Code é o caminho mais guiado.

---

## Etapa 1 — Criar a Function App no Portal

1. Portal do Azure → **Create a resource** → **Function App**.
2. Preencha:
   - **Runtime stack**: .NET, versão **Isolated**, **.NET 8**.
   - **Plan**: **Consumption** (mais barato; suficiente para uma carga simples).
   - **Region**: a mesma do seu Azure SQL e Key Vault (menor latência).
3. Crie e aguarde o deploy.

## Etapa 2 — Ativar a Managed Identity

1. Function App → **Identity** → aba **System assigned** → **Status = On** → **Save**.
2. Isso cria uma identidade no Entra ID com o **mesmo nome da Function App**. Anote o nome.

## Etapa 3 — Dar acesso da Managed Identity ao Azure SQL

Conecte no banco (SSMS / Azure Data Studio) **com um admin Entra ID** e rode, no banco
de destino, algo como (peça ajuda ao DBA — princípio do menor privilégio, **sem** `db_owner`):

```sql
-- Substitua <nome-da-function-app> pelo nome exato da Function App
CREATE USER [<nome-da-function-app>] FROM EXTERNAL PROVIDER;

-- Leitura na tabela de stage
GRANT SELECT ON OBJECT::HR.Employees_stg2 TO [<nome-da-function-app>];

-- Inserção na tabela de destino (Always Encrypted)
GRANT INSERT ON OBJECT::HR.Employees2 TO [<nome-da-function-app>];
```

## Etapa 4 — Dar acesso da Managed Identity ao Key Vault (CMK)

No Key Vault que guarda a CMK, conceda à Managed Identity:

- **Access Policies**: permissões de **chave** → `Get`, `Unwrap Key`, `Wrap Key`.
- **RBAC**: role **Key Vault Crypto User**.

Garanta que o firewall/rede do Key Vault permita o acesso da Function.

## Etapa 5 — Conectividade de rede

- Azure SQL deve permitir a Function: **"Allow Azure services"** ou
  **Private Endpoint** + **VNet Integration** (mais seguro).
- Com Private Endpoints (SQL e Key Vault), a Function precisa de **VNet Integration**
  para enxergá-los.

---

## Etapa 6 — Abrir/usar este projeto no VS Code

Este projeto já está pronto — você **não** precisa rodar "Create Function...".

1. Abra a pasta `AzureFunction/AlwaysEncrypted` no VS Code.
2. Copie `local.settings.json.example` para `local.settings.json`.
3. No `local.settings.json`, ajuste a `SqlConnectionString` com o seu servidor e banco.

> O `local.settings.json` **não** é publicado e está no `.gitignore` (pode conter dados sensíveis).

## Etapa 7 — Pacotes NuGet (já incluídos no `.csproj`)

- `Microsoft.Data.SqlClient` — Always Encrypted + autenticação Entra ID/Managed Identity.
- `Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider` — ponte com a CMK no Key Vault.
- `Azure.Identity` — credencial da Managed Identity (`DefaultAzureCredential`).

## Etapa 8 — O que o código faz

- `Program.cs`: cria `DefaultAzureCredential` e **registra o provedor do Key Vault** uma vez.
- `LoadEmployeesFunction.cs` (gatilho **Timer**, padrão diário às 02:00 UTC):
  1. Lê a connection string da configuração `SqlConnectionString`.
  2. Abre a conexão (login via Managed Identity, sem senha).
  3. Lê do Stage com query simples (`CAST` no decimal + filtro `IS NOT NULL`).
  4. Insere na tabela destino usando **parâmetros** (o driver criptografa `SSN` e `Salary`).
  5. Loga **apenas** a quantidade de linhas — nunca valores sensíveis.

Connection string (já modelada em `local.settings.json.example`):

```text
Server=tcp:<servidor>.database.windows.net,1433;
Database=<db>;
Authentication=Active Directory Default;
Encrypt=True;
TrustServerCertificate=False;
Column Encryption Setting=Enabled;
Connect Timeout=30;
```

> **`Column Encryption Setting=Enabled` é obrigatório** para o Always Encrypted funcionar.

---

## Etapa 9 — Testar localmente (opcional)

- Localmente, `DefaultAzureCredential` usa a **sua** identidade (`az login` / VS Code),
  não a Managed Identity. Então o **seu usuário** também precisa de acesso ao SQL e ao Key Vault.
- No VS Code, pressione **F5** para executar. Verifique conexão, leitura e insert sem erro.
- Para disparar o Timer manualmente em teste, use o painel de execução do VS Code/Core Tools.

## Etapa 10 — Deploy

1. VS Code → ícone do Azure → no projeto → **Deploy to Function App...**.
2. Selecione a Function App da Etapa 1 e confirme a sobrescrita.
3. Em produção, a Function usará automaticamente a **Managed Identity** (não usa mais o seu `az login`).
4. No Portal → Function App → **Configuration** → adicione a application setting
   **`SqlConnectionString`** com o mesmo valor usado localmente.

## Etapa 11 — Validar em produção

1. Portal → Function App → **Functions** → **LoadEmployees** → **Monitor** / Logs (Application Insights).
2. Dispare (no horário do Timer, ou via "Run").
3. Confirme: login sem senha OK, sem erro de CMK no Key Vault, e linhas inseridas.
4. Confira no banco: quem consulta **sem** `Column Encryption Setting=Enabled` vê apenas
   blobs criptografados em `SSN`/`Salary`.

---

## Erros comuns

- **CMK no Certificate Store, não no Key Vault** → migre a CMK para o Key Vault.
- **Faltou `Column Encryption Setting=Enabled`** → obrigatório na connection string.
- **Managed Identity sem `Get/Unwrap/Wrap` no Key Vault** → falha de criptografia.
- **Managed Identity sem usuário/permissão no SQL** → falha de login ou de INSERT.
- **Mismatch de decimal** (`decimal(9,4)` vs `19,4`) → o `CAST(... AS decimal(19,4))` e
  `Precision=19, Scale=4` no parâmetro já tratam isso.
- **Linhas com NULL** em colunas NOT NULL → já filtradas com `WHERE ... IS NOT NULL`.
- **Rede/firewall** bloqueando a Function → libere acesso ou use Private Endpoint + VNet Integration.

---

## Checklist de permissões

- [ ] Managed Identity habilitada na Function App.
- [ ] Usuário Entra ID da identidade criado no SQL com SELECT (stage) + INSERT (destino).
- [ ] Permissões de chave no Key Vault: `Get` / `Unwrap` / `Wrap` (ou role Crypto User).
- [ ] CMK no Azure Key Vault.
- [ ] Rede liberada entre Function ↔ SQL ↔ Key Vault.
- [ ] Application setting `SqlConnectionString` com `Authentication=Active Directory Default`
      + `Column Encryption Setting=Enabled`.

---

## Modelo de dados (igual ao usado no diretório `SSIS/AlwaysEncrypted`)

- Origem: `HR.Employees_stg2` (`SSN nvarchar(11)`, `Salary decimal(19,4)`, anuláveis).
- Destino: `HR.Employees2`
  - `SSN nvarchar(11)` criptografado **Randomized** (NOT NULL)
  - `Salary decimal(19,4)` criptografado **Deterministic** (NOT NULL)
