# query-datasources

Repositório de scripts, queries e guias de diagnóstico para diferentes fontes de dados.

## Conteúdo

| Pasta / Arquivo                | Descrição                                                                                      |
|--------------------------------|-----------------------------------------------------------------------------------------------|
| `azure-diagnostics/`           | Toolkit de diagnóstico para gargalos Keycloak/RHBK × Azure SQL Hyperscale PaaS               |
| `diagnóstico-final/`           | Toolkit “fim do túnel” com os 3 testes críticos (EE, thread dumps correlacionados e Query Store) |
| `AzureFunction/`               | Azure Functions de exemplo (Always Encrypted, Managed Identity)                              |
| `SSIS/`                        | Pacotes e guias SSIS (Always Encrypted, ODBC)                                                 |
| `Databricks_Cloud_To_VNet_*`   | Notebooks Databricks — conectividade Cloud → VNet                                             |
| `PlanB_Databricks_*`           | Notebooks Databricks — conexões pessoais                                                      |

## azure-diagnostics — destaque

O diretório [`azure-diagnostics/`](./azure-diagnostics/README.md) contém o
toolkit completo para investigar o cenário de **1800 transações abertas /
40 executando / banco < 60 % de utilização** observado em testes de carga de
15K RPS contra Keycloak/RHBK 26 no OpenShift (ARO) com Azure SQL Hyperscale PaaS.

### Evidência central (Lei de Little)

Com 1800 transações abertas e apenas 40 executando SQL num dado instante,
**98 % do tempo de vida de cada transação é gasto fora da execução SQL**.
O banco está ocioso. O gargalo está no tempo que cada transação fica aberta
sem trabalhar — comportamento da **aplicação / do caminho**, não do banco.

**Aumentar o pool de conexões não resolve** — apenas cria mais transações
abertas ociosas. A alavanca é encurtar o escopo `BEGIN..COMMIT`.

Consulte [`azure-diagnostics/README.md`](./azure-diagnostics/README.md) para
o fluxo completo de diagnóstico, scripts SQL, Extended Events, guia de
correlação com thread dumps e checklist de configuração do RHBK 26.

Para execução focada na próxima janela de carga (48h), use o roteiro em
[`diagnóstico-final/README-diagnosis-final.md`](./diagnóstico-final/README-diagnosis-final.md).