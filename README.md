# Projeto: Pipeline Macro (BCB/SGS → Postgres → BI)

Ingestão e modelagem de séries econômicas do Banco Central (SGS) usando **Docker**, **n8n** e **PostgreSQL** nas camadas **bronze → silver → gold**, com orquestração diária e eventos simples.

## 🔎 Visão Geral

- **Fontes**: API pública do BCB/SGS (séries 1, 11, 432, 433 por padrão)
- **Orquestração**: n8n (Workflows W1–W4 + Orquestrador)
- **Persistência**: Postgres (camadas bronze/silver/gold + catálogos e logs)
- **Dashboards**: Power BI conectado direto no Postgres (sem CSV)
- **Eventos**: spikes em USD/BRL e mudança de meta Selic gravados no banco

## 🧱 Arquitetura (alto nível)

```
        +-----------------+
        |   Orchestrator  |  (Cron 07:30 BRT)
        +--------+--------+
                 |
                 v
+-------- W1: Ingest (Code) --------+
| Get series -> Build windows ->    |
| Fetch SGS -> Upsert Bronze        |
+-------------------+---------------+
                    v
         +----------+-----------+
         | W2: Bronze  -> Silver|
         +----------+-----------+
                    v
         +----------+-----------+
         | W3: Silver -> Gold   |
         +----------+-----------+
                    v
         +----------+-----------+
         | W4: Alertas (DB)     |
         +----------------------+
```

## 📁 Estrutura de Pastas

```
projeto-bcb-sgs/
├─ docker-compose.yml
├─ .env
├─ n8n/
│  └─ (dados internos do n8n)
├─ postgres/
│  └─ data/               # volume de dados do Postgres
├─ ddl/
│  ├─ 01_schemas.sql
│  ├─ 02_tables.sql
│  └─ 03_views.sql
├─ workflows/
│  ├─ W1_ingest_bronze.json
│  ├─ W2_bronze_silver.json
│  ├─ W3_silver_gold.json
│  ├─ W4_alertas.json
│  └─ W0_orchestrator.json
├─ README.md
└─ .gitignore
```

> Se preferir, você pode importar os workflows direto pelo **Import → From Clipboard** com os JSONs fornecidos nesta doc.

## 🚀 Subindo o ambiente

1) **Copie o compose** (ajuste portas se precisar):
```yaml
version: "3.8"
services:
  postgres:
    image: postgres:15
    container_name: bcb-postgres
    environment:
      POSTGRES_USER: ${PGUSER}
      POSTGRES_PASSWORD: ${PGPASSWORD}
      POSTGRES_DB: ${PGDATABASE}
    ports:
      - "5432:5432"
    volumes:
      - ./postgres/data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PGUSER} -d ${PGDATABASE}"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:1.64.0
    container_name: bcb-n8n
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=localhost
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - GENERIC_TIMEZONE=America/Sao_Paulo
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${PGDATABASE}
      - DB_POSTGRESDB_USER=${PGUSER}
      - DB_POSTGRESDB_PASSWORD=${PGPASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./n8n:/home/node/.n8n
```

2) **Crie o `.env`**:
```
PGUSER=bcb_user
PGPASSWORD=bcb_pass
PGDATABASE=bcb
```

3) **Suba**:
```bash
docker compose up -d
```

4) Acesse **n8n**: http://localhost:5678

## 🗄️ Banco: DDL (rodar no DBeaver/psql)

1. `01_schemas.sql` — cria `etl`, `bcb_bronze`, `bcb_silver`, `bcb_gold`.
2. `02_tables.sql` — cria:
   - `etl.series_catalog` (com séries iniciais e `active=true`)
   - `etl.run_log`
   - `bcb_bronze.series_raw`
   - `bcb_silver.series_daily`
   - `bcb_gold.dm_macro_daily`
   - `bcb_gold.dm_events`
3. `03_views.sql` — cria views de apoio (ex.: `bcb_gold.v_macro_daily_ffill` para gráficos, opcional).

> Depois de aplicar, confirme:
```sql
SELECT * FROM etl.series_catalog ORDER BY series_id;
```

## 🔧 n8n: credencial Postgres

Crie uma credencial no n8n chamada **pg-bcb**:
- **Host**: `postgres`
- **Port**: `5432`
- **Database**: `bcb`
- **User**: `bcb_user`
- **Password**: `bcb_pass`

## 🔁 Workflows

### W1 — Ingest (SGS → Bronze)
- Implementado com **Code (JS)** para evitar diferenças de versão do HTTP node.
- Passos:
  1. **Get Active Series** (Postgres)
  2. **Fan Out Series (Code)**
  3. **Build Windows (Code)** — janela por série (sugestão: 30 dias no dia a dia; use `2015-01-01` para backfill)
  4. **Fetch + Map to Bronze (Code)** — chama SGS via `this.helpers.httpRequest`, tipa datas
  5. **Upsert Bronze** (Postgres)

Validação:
```sql
SELECT series_id, MIN(ref_date), MAX(ref_date), COUNT(*) AS n
FROM bcb_bronze.series_raw
GROUP BY series_id
ORDER BY series_id;
```

### W2 — Bronze → Silver
- Anti-join para inserir apenas o que falta.
- Converte `value_raw` “pt-BR” → `value_num` (`Number`).
- UPSERT em `bcb_silver.series_daily`.

### W3 — Silver → Gold
- Pivota por `ref_date` e calcula `ipca_12m` (janela móvel de 12 pontos sobre `433`).
- UPSERT em `bcb_gold.dm_macro_daily`.

### W4 — Alertas (DB only)
- USD spike (|Δ d/d| ≥ 2.5%) e mudança de meta Selic.
- Insere em `bcb_gold.dm_events` (PK evita duplicatas).

### Orquestrador (W0)
- Encadeia **W1 → W2 → W3 → W4** com **Execute Workflow (wait for completion)**.
- Já vem com **Cron 07:30 BRT** (ajuste à vontade).

## 🕒 Agendamento (sugestão)

- W0 Orquestrador: **07:30**  
(Se preferir agendar em cada filho: W1 07:30, W2 07:40, W3 07:45, W4 07:47)

## 🧪 Backfill & Operação

- **Backfill histórico**: em **Build Windows (Code)** troque:
  ```js
  const start = new Date('2015-01-01');
  const end   = new Date();
  ```
  Rode **W1 → W2 → W3** manualmente.  
- **Operação diária**: volte para 30 dias:
  ```js
  start.setDate(start.getDate() - 30);
  ```

## 📊 Power BI

- **Get Data → PostgreSQL**  
  - Server: `localhost`  
  - Database: `bcb`  
- Tabelas sugeridas:
  - `bcb_gold.dm_macro_daily` (base)
  - `bcb_gold.v_macro_daily_ffill` (gráficos mais “suaves”)
  - `bcb_gold.dm_events` (marcadores)
- Exemplos de visuais:
  - Cartões (Selic meta atual, IPCA 12m, USD/BRL)
  - Linhas: USD/BRL, Selic diária, IPCA 12m
  - Tabela de eventos (últimos 20)

## 🔍 Troubleshooting

- **Só serie 1 na bronze**: verifique `etl.series_catalog.active = TRUE` para as demais séries (11, 432, 433).  
- **Fetch + Map sem saída**: confirme que o node recebeu **N itens** do Build Windows; veja mensagens de erro no node (ele loga quando URL falha).  
- **Erro `undefined` no UPSERT**: significa campos vazios — cheque o node anterior (se há `series_id/ref_date/value_raw`).  
- **Nada na Gold**: rode W2 e W3 depois de popular bronze; verifique `dm_macro_daily`:
  ```sql
  SELECT * FROM bcb_gold.dm_macro_daily ORDER BY ref_date DESC LIMIT 20;
  ```
- **TZ**: timezone do n8n/containers está como `America/Sao_Paulo`. Ajuste se necessário.

## 🔒 Boas práticas

- **.gitignore**:
  ```
  postgres/data/
  n8n/
  .env
  ```
- **Credenciais**: nunca commitar `.env`.
- **Backups**:
  ```bash
  docker exec -i bcb-postgres pg_dump -U bcb_user bcb > backup_bcb.sql
  ```

## 📌 Séries padrão (pode expandir)
- **1**   — USD/BRL PTAX (venda) — diária  
- **11**  — Selic diária (a.d.) — diária  
- **432** — Selic meta (a.a.) — por decisão  
- **433** — IPCA var. mensal (m/m) — mensal

Para adicionar mais séries, inclua-as em `etl.series_catalog` (`active = TRUE`) e rode W1→W3.

---

### Licença
MIT
