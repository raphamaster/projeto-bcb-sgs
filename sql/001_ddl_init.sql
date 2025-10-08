-- ============================================================================
-- Projeto: BCB/SGS – Data Mart Econômico
-- Arquivo: 001_ddl_init.sql
-- Objetivo: criar schemas, tabelas (bronze/silver/gold) e tabelas de apoio
-- Compatível: PostgreSQL 16+
-- ============================================================================

-- 1) Schemas
CREATE SCHEMA IF NOT EXISTS etl;
CREATE SCHEMA IF NOT EXISTS bcb_bronze;
CREATE SCHEMA IF NOT EXISTS bcb_silver;
CREATE SCHEMA IF NOT EXISTS bcb_gold;

-- 2) Tabelas de apoio (etl)
-- 2.1) Catálogo de séries (usado pelos fluxos do n8n)
CREATE TABLE IF NOT EXISTS etl.series_catalog (
    series_id      INTEGER      PRIMARY KEY,             -- ex.: 432, 11, 1, 433
    series_name    TEXT         NOT NULL,                -- ex.: SELIC_META_AA
    unit           TEXT         NOT NULL,                -- ex.: '% a.a.', 'BRL/USD', '% m/m'
    frequency      TEXT         NOT NULL,                -- ex.: 'daily', 'monthly'
    source         TEXT         NOT NULL DEFAULT 'BCB/SGS',
    source_url     TEXT         NOT NULL,                -- endpoint documentado
    active         BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- 2.2) Checkpoints simples por fluxo (última execução/última data processada)
CREATE TABLE IF NOT EXISTS etl.checkpoints (
    checkpoint_key TEXT         PRIMARY KEY,             -- ex.: 'ingest.sgs', 'silver.upsert'
    checkpoint_val TEXT         NOT NULL,                -- valor livre (pode ser data ISO)
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- 2.3) Log de execuções (para auditabilidade)
CREATE TABLE IF NOT EXISTS etl.run_log (
    run_id         BIGSERIAL    PRIMARY KEY,
    workflow_name  TEXT         NOT NULL,                -- nome amigável do fluxo n8n
    status         TEXT         NOT NULL CHECK (status IN ('SUCCESS','ERROR','WARN')),
    started_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    finished_at    TIMESTAMPTZ,
    rows_read      BIGINT       NOT NULL DEFAULT 0,
    rows_written   BIGINT       NOT NULL DEFAULT 0,
    details        JSONB
);
CREATE INDEX IF NOT EXISTS idx_run_log_started_at ON etl.run_log(started_at DESC);

-- 3) Camada BRONZE (raw, auditável)
CREATE TABLE IF NOT EXISTS bcb_bronze.series_raw (
    series_id      INTEGER      NOT NULL,
    ref_date       DATE         NOT NULL,                -- data de referência publicada
    value_raw      TEXT         NOT NULL,                -- como veio da API
    payload_json   JSONB,                                -- linha crua da API
    source         TEXT         NOT NULL DEFAULT 'BCB/SGS',
    ingested_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_series_raw PRIMARY KEY (series_id, ref_date)
);
CREATE INDEX IF NOT EXISTS idx_series_raw_ingested_at ON bcb_bronze.series_raw(ingested_at DESC);
CREATE INDEX IF NOT EXISTS idx_series_raw_payload_gin ON bcb_bronze.series_raw USING GIN(payload_json);

-- 4) Camada SILVER (limpa/tipada)
CREATE TABLE IF NOT EXISTS bcb_silver.series_daily (
    series_id      INTEGER      NOT NULL,
    series_name    TEXT         NOT NULL,
    ref_date       DATE         NOT NULL,
    value_num      NUMERIC(18,6) NOT NULL,              -- tipagem numérica
    unit           TEXT         NOT NULL,
    source         TEXT         NOT NULL DEFAULT 'BCB/SGS',
    load_ts        TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_series_daily PRIMARY KEY (series_id, ref_date)
);
CREATE INDEX IF NOT EXISTS idx_series_daily_name_ref ON bcb_silver.series_daily(series_name, ref_date);
CREATE INDEX IF NOT EXISTS idx_series_daily_load_ts ON bcb_silver.series_daily(load_ts DESC);

-- 5) Camada GOLD (pronta para BI/alertas)
-- 5.1) Fato macro agregado por dia
CREATE TABLE IF NOT EXISTS bcb_gold.dm_macro_daily (
    ref_date           DATE          PRIMARY KEY,
    selic_meta_aa      NUMERIC(12,6),    -- série 432 (nível)
    selic_diaria_ad    NUMERIC(12,6),    -- série 11
    usd_brl_ptax       NUMERIC(18,6),    -- série 1 (venda)
    ipca_mm            NUMERIC(12,6),    -- série 433 (variação mensal %)
    ipca_12m           NUMERIC(12,6),    -- rolling 12m calculado
    load_ts            TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_dm_macro_daily_load_ts ON bcb_gold.dm_macro_daily(load_ts DESC);

-- 5.2) Eventos (spikes, cruzamento de médias, mudanças de meta, etc.)
CREATE TABLE IF NOT EXISTS bcb_gold.dm_events (
    ref_date       DATE         NOT NULL,
    series_id      INTEGER      NOT NULL,
    event_type     TEXT         NOT NULL CHECK (event_type IN ('SPIKE_UP','SPIKE_DOWN','CROSS_MM','POLICY_CHANGE')),
    event_value    NUMERIC(18,6),
    zscore         NUMERIC(18,6),
    details        JSONB,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_dm_events PRIMARY KEY (series_id, ref_date, event_type)
);
CREATE INDEX IF NOT EXISTS idx_dm_events_type_date ON bcb_gold.dm_events(event_type, ref_date);
CREATE INDEX IF NOT EXISTS idx_dm_events_details_gin ON bcb_gold.dm_events USING GIN(details);

-- 6) Catálogo inicial de séries (pode ajustar depois)
INSERT INTO etl.series_catalog (series_id, series_name, unit, frequency, source, source_url, active)
VALUES
    (432, 'SELIC_META_AA',     '% a.a.', 'daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.432/dados', TRUE),
    (11,  'SELIC_DIARIA_AD',   '% a.d.', 'daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.11/dados',  TRUE),
    (1,   'USD_BRL_PTAX_VENDA','BRL/USD','daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.1/dados',   TRUE),
    (433, 'IPCA_MENSAL_PCT',   '% m/m',  'monthly', 'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados', TRUE)
ON CONFLICT (series_id) DO NOTHING;

-- 7) Views utilitárias (opc.)
-- 7.1) Pivot simples da silver para acelerar exploração
CREATE OR REPLACE VIEW bcb_gold.v_series_pivot AS
SELECT
    sd.ref_date,
    MAX(CASE WHEN sd.series_id = 432 THEN sd.value_num END) AS selic_meta_aa,
    MAX(CASE WHEN sd.series_id = 11  THEN sd.value_num END) AS selic_diaria_ad,
    MAX(CASE WHEN sd.series_id = 1   THEN sd.value_num END) AS usd_brl_ptax,
    MAX(CASE WHEN sd.series_id = 433 THEN sd.value_num END) AS ipca_mm
FROM bcb_silver.series_daily sd
GROUP BY sd.ref_date;

-- 8) Permissões básicas (ajuste o usuário se necessário)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'bcb_user'
    ) THEN
        RAISE NOTICE 'Role bcb_user não existe (usando credenciais já definidas no .env)';
    END IF;
END$$;

GRANT USAGE ON SCHEMA etl, bcb_bronze, bcb_silver, bcb_gold TO bcb_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA etl        TO bcb_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bcb_bronze TO bcb_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bcb_silver TO bcb_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bcb_gold   TO bcb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA etl        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bcb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA bcb_bronze GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bcb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA bcb_silver GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bcb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA bcb_gold   GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO bcb_user;

-- 9) Check rápido (retorno vazio é ok em instalação nova)
-- SELECT * FROM etl.series_catalog;
-- SELECT * FROM bcb_bronze.series_raw LIMIT 5;
-- SELECT * FROM bcb_silver.series_daily LIMIT 5;
-- SELECT * FROM bcb_gold.dm_macro_daily LIMIT 5;
