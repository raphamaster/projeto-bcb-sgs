-- 02_tables.sql
-- Tabelas + índices + dados iniciais (seed)

-- ======================
-- Catálogo de séries (ETL)
-- ======================
CREATE TABLE IF NOT EXISTS etl.series_catalog (
  series_id    INTEGER PRIMARY KEY,
  series_name  TEXT        NOT NULL,
  unit         TEXT,
  frequency    TEXT        NOT NULL DEFAULT 'daily',
  source       TEXT        NOT NULL DEFAULT 'BCB/SGS',
  source_url   TEXT        NOT NULL,
  active       BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índice por ativo (para buscas no n8n)
CREATE INDEX IF NOT EXISTS ix_series_catalog_active ON etl.series_catalog(active);

-- Seed das séries padrão
INSERT INTO etl.series_catalog (series_id, series_name, unit, frequency, source, source_url, active)
VALUES
  (1  , 'USD_BRL_PTAX_VENDA',   'BRL por USD', 'daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.1/dados',   TRUE),
  (11 , 'SELIC_DIARIA_AD',      '% a.d.',      'daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.11/dados',  TRUE),
  (432, 'SELIC_META_AA',        '% a.a.',      'daily',   'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.432/dados', TRUE),
  (433, 'IPCA_MENSAL_MM',       '% m/m',       'monthly', 'BCB/SGS', 'https://api.bcb.gov.br/dados/serie/bcdata.sgs.433/dados', TRUE)
ON CONFLICT (series_id) DO NOTHING;

-- ======================
-- Run log (opcional, para auditoria)
-- ======================
CREATE TABLE IF NOT EXISTS etl.run_log (
  run_id        BIGSERIAL PRIMARY KEY,
  workflow_name TEXT        NOT NULL,
  rows_written  INTEGER,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at   TIMESTAMPTZ,
  status        TEXT        NOT NULL DEFAULT 'OK',
  details       JSONB
);

-- ======================
-- Bronze
-- ======================
CREATE TABLE IF NOT EXISTS bcb_bronze.series_raw (
  series_id    INTEGER     NOT NULL REFERENCES etl.series_catalog(series_id) ON DELETE CASCADE,
  ref_date     DATE        NOT NULL,
  value_raw    TEXT        NOT NULL,
  payload_json JSONB,
  source       TEXT        NOT NULL DEFAULT 'BCB/SGS',
  ingested_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (series_id, ref_date)
);
CREATE INDEX IF NOT EXISTS ix_bronze_ingested_at ON bcb_bronze.series_raw(ingested_at);

-- ======================
-- Silver
-- ======================
CREATE TABLE IF NOT EXISTS bcb_silver.series_daily (
  series_id   INTEGER     NOT NULL REFERENCES etl.series_catalog(series_id) ON DELETE CASCADE,
  series_name TEXT        NOT NULL,
  ref_date    DATE        NOT NULL,
  value_num   NUMERIC,
  unit        TEXT,
  source      TEXT        NOT NULL DEFAULT 'BCB/SGS',
  load_ts     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (series_id, ref_date)
);
CREATE INDEX IF NOT EXISTS ix_silver_load_ts ON bcb_silver.series_daily(load_ts);

-- ======================
-- Gold (tabela já pivotada por data)
-- ======================
CREATE TABLE IF NOT EXISTS bcb_gold.dm_macro_daily (
  ref_date        DATE PRIMARY KEY,
  selic_meta_aa   NUMERIC,
  selic_diaria_ad NUMERIC,
  usd_brl_ptax    NUMERIC,
  ipca_mm         NUMERIC,
  ipca_12m        NUMERIC,
  load_ts         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ======================
-- Eventos (alertas)
-- ======================
CREATE TABLE IF NOT EXISTS bcb_gold.dm_events (
  event_id   BIGSERIAL PRIMARY KEY,
  ref_date   DATE        NOT NULL,
  series_id  INTEGER     NOT NULL,
  event_type TEXT        NOT NULL,
  event_value NUMERIC,
  zscore     NUMERIC,
  details    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_event UNIQUE (ref_date, series_id, event_type)
);
CREATE INDEX IF NOT EXISTS ix_events_created_at ON bcb_gold.dm_events(created_at);
