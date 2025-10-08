-- 03_views.sql
-- Views auxiliares

-- 1) View básica (retorna a gold inteira)
CREATE OR REPLACE VIEW bcb_gold.v_macro_daily AS
SELECT *
FROM bcb_gold.dm_macro_daily
ORDER BY ref_date;

-- 2) View com forward-fill simples (LOCF) usando múltiplos LAGs (cobre lacunas curtas)
--    *Para séries com grandes buracos (ex.: IPCA mensal), use a gold original.
CREATE OR REPLACE VIEW bcb_gold.v_macro_daily_ffill AS
WITH base AS (
  SELECT
    ref_date,
    selic_meta_aa,
    selic_diaria_ad,
    usd_brl_ptax,
    ipca_mm,
    ipca_12m,
    -- ffill simples até 7 dias (ajuste se quiser)
    COALESCE(selic_meta_aa,
             LAG(selic_meta_aa,1) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,2) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,3) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,4) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,5) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,6) OVER (ORDER BY ref_date),
             LAG(selic_meta_aa,7) OVER (ORDER BY ref_date)
    ) AS selic_meta_ff,
    COALESCE(selic_diaria_ad,
             LAG(selic_diaria_ad,1) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,2) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,3) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,4) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,5) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,6) OVER (ORDER BY ref_date),
             LAG(selic_diaria_ad,7) OVER (ORDER BY ref_date)
    ) AS selic_diaria_ff,
    COALESCE(usd_brl_ptax,
             LAG(usd_brl_ptax,1) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,2) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,3) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,4) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,5) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,6) OVER (ORDER BY ref_date),
             LAG(usd_brl_ptax,7) OVER (ORDER BY ref_date)
    ) AS usd_brl_ptax_ff,
    COALESCE(ipca_12m,
             LAG(ipca_12m,1) OVER (ORDER BY ref_date),
             LAG(ipca_12m,2) OVER (ORDER BY ref_date),
             LAG(ipca_12m,3) OVER (ORDER BY ref_date),
             LAG(ipca_12m,4) OVER (ORDER BY ref_date),
             LAG(ipca_12m,5) OVER (ORDER BY ref_date),
             LAG(ipca_12m,6) OVER (ORDER BY ref_date),
             LAG(ipca_12m,7) OVER (ORDER BY ref_date)
    ) AS ipca_12m_ff
  FROM bcb_gold.dm_macro_daily
)
SELECT * FROM base
ORDER BY ref_date;

-- 3) Pivot genérico (útil para explorar rapidamente as séries da silver)
--    Cria uma tabela com colunas fixas das 4 séries padrão.
CREATE OR REPLACE VIEW bcb_silver.v_series_pivot AS
WITH s AS (
  SELECT series_id, ref_date, value_num FROM bcb_silver.series_daily
),
d AS (SELECT DISTINCT ref_date FROM s),
selic_meta AS (SELECT ref_date, value_num AS selic_meta_aa FROM s WHERE series_id = 432),
selic_diaria AS (SELECT ref_date, value_num AS selic_diaria_ad FROM s WHERE series_id = 11),
usd AS (SELECT ref_date, value_num AS usd_brl_ptax FROM s WHERE series_id = 1),
ipca AS (SELECT ref_date, value_num AS ipca_mm FROM s WHERE series_id = 433)
SELECT d.ref_date, sm.selic_meta_aa, sd.selic_diaria_ad, u.usd_brl_ptax, i.ipca_mm
FROM d
LEFT JOIN selic_meta sm   ON sm.ref_date = d.ref_date
LEFT JOIN selic_diaria sd ON sd.ref_date = d.ref_date
LEFT JOIN usd u           ON u.ref_date = d.ref_date
LEFT JOIN ipca i          ON i.ref_date = d.ref_date
ORDER BY d.ref_date;
