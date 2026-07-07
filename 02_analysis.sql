-- =========================================================================
-- Delivery Operations Analysis: Late Delivery Impact on Support Load
-- =========================================================================
-- Data: 5,000 completed/cancelled deliveries across 6 cities, 137 couriers,
-- 3,000 clients, 786 support tickets over a 4-month window.
--
-- Analysis goals:
--   1. Late delivery rate by city  (find logistics outliers)
--   2. Impact of delays on "where is the courier" ticket volume
--   3. Delay severity ladder — how ticket rate scales with delay length
--   4. Per-courier late rate ranking (window functions)
--   5. Weekly trend + rolling averages (window functions)
--   6. Business impact estimate for push-notification proposal
-- =========================================================================


-- =========================================================================
-- 1. Late delivery rate by city
-- =========================================================================

WITH delivery_stats AS (
    SELECT
        c.city_name,
        COUNT(*)                                                    AS total_deliveries,
        SUM(CASE WHEN d.delay_minutes > 30 THEN 1 ELSE 0 END)       AS late_deliveries,
        ROUND(AVG(CASE WHEN d.delay_minutes > 0
                       THEN d.delay_minutes END), 1)                AS avg_delay_when_late
    FROM deliveries d
    JOIN cities c ON d.city_id = c.city_id
    WHERE d.delivery_status = 'completed'
    GROUP BY c.city_name
)
SELECT
    city_name,
    total_deliveries,
    late_deliveries,
    ROUND(100.0 * late_deliveries / total_deliveries, 2) AS late_rate_pct,
    avg_delay_when_late
FROM delivery_stats
ORDER BY late_rate_pct DESC;


-- =========================================================================
-- 2. Ticket rate for late vs on-time deliveries
--
-- Note: we join tickets to deliveries via delivery_id (not client_id + date).
-- Joining on client_id/date creates a Cartesian product when a client has
-- multiple deliveries per day and inflates the ticket count.
-- =========================================================================

WITH delivery_labeled AS (
    SELECT
        d.delivery_id,
        CASE WHEN d.delay_minutes > 30 THEN 'late' ELSE 'on_time' END AS quality
    FROM deliveries d
    WHERE d.delivery_status = 'completed'
),
tickets_per_delivery AS (
    SELECT
        dl.quality,
        dl.delivery_id,
        COUNT(t.ticket_id) AS wic_tickets
    FROM delivery_labeled dl
    LEFT JOIN support_tickets t
        ON t.delivery_id = dl.delivery_id
       AND t.issue_category = 'where_is_courier'
    GROUP BY dl.quality, dl.delivery_id
)
SELECT
    quality,
    COUNT(*)                                    AS deliveries,
    SUM(wic_tickets)                            AS total_wic_tickets,
    ROUND(100.0 * SUM(CASE WHEN wic_tickets > 0
                           THEN 1 ELSE 0 END)
              / COUNT(*), 2)                    AS ticket_rate_pct,
    ROUND(1.0 * SUM(wic_tickets) / COUNT(*), 3) AS tickets_per_delivery
FROM tickets_per_delivery
GROUP BY quality
ORDER BY quality;


-- =========================================================================
-- 3. Delay severity ladder — how ticket rate scales with delay length
--
-- This is the analytical backbone of the push-notification recommendation:
-- it shows the >30 min threshold is not arbitrary — that is where
-- ticket rate jumps.
-- =========================================================================

WITH labeled AS (
    SELECT
        d.delivery_id,
        CASE
            WHEN d.delay_minutes < 15 THEN '00_under_15'
            WHEN d.delay_minutes < 30 THEN '01_15_to_30'
            WHEN d.delay_minutes < 60 THEN '02_30_to_60'
            WHEN d.delay_minutes < 120 THEN '03_60_to_120'
            ELSE '04_over_120'
        END AS delay_bucket
    FROM deliveries d
    WHERE d.delivery_status = 'completed'
      AND d.delay_minutes IS NOT NULL
),
joined AS (
    SELECT
        l.delay_bucket,
        l.delivery_id,
        MAX(CASE WHEN t.ticket_id IS NOT NULL THEN 1 ELSE 0 END) AS had_ticket
    FROM labeled l
    LEFT JOIN support_tickets t
        ON t.delivery_id = l.delivery_id
       AND t.issue_category = 'where_is_courier'
    GROUP BY l.delay_bucket, l.delivery_id
)
SELECT
    delay_bucket,
    COUNT(*)                                          AS deliveries,
    SUM(had_ticket)                                   AS deliveries_with_ticket,
    ROUND(100.0 * SUM(had_ticket) / COUNT(*), 2)      AS ticket_rate_pct
FROM joined
GROUP BY delay_bucket
ORDER BY delay_bucket;


-- =========================================================================
-- 4. Courier late-rate ranking within each city (window functions)
--
-- Uses ROW_NUMBER over PARTITION BY city to identify the worst-performing
-- couriers per city — actionable list for ops managers.
-- =========================================================================

WITH courier_stats AS (
    SELECT
        c.city_name,
        d.courier_id,
        cu.tier,
        COUNT(*)                                              AS deliveries,
        SUM(CASE WHEN d.delay_minutes > 30 THEN 1 ELSE 0 END) AS late,
        ROUND(100.0 * SUM(CASE WHEN d.delay_minutes > 30 THEN 1 ELSE 0 END)
                  / COUNT(*), 2)                              AS late_rate_pct
    FROM deliveries d
    JOIN cities   c  ON d.city_id    = c.city_id
    JOIN couriers cu ON d.courier_id = cu.courier_id
    WHERE d.delivery_status = 'completed'
    GROUP BY c.city_name, d.courier_id, cu.tier
    HAVING COUNT(*) >= 10          -- exclude couriers with too few deliveries
)
SELECT *
FROM (
    SELECT
        city_name,
        courier_id,
        tier,
        deliveries,
        late_rate_pct,
        RANK() OVER (PARTITION BY city_name ORDER BY late_rate_pct DESC) AS worst_rank_in_city
    FROM courier_stats
) ranked
WHERE worst_rank_in_city <= 3
ORDER BY city_name, worst_rank_in_city;


-- =========================================================================
-- 5. Weekly late-delivery trend with 4-week rolling average
--
-- Uses AVG() OVER (ROWS BETWEEN) to smooth the noisy weekly series so a
-- real trend can be seen rather than week-to-week jitter.
-- =========================================================================

WITH weekly AS (
    SELECT
        STRFTIME('%Y-%W', scheduled_time)                       AS week,
        COUNT(*)                                                AS deliveries,
        SUM(CASE WHEN delay_minutes > 30 THEN 1 ELSE 0 END)     AS late_deliveries
    FROM deliveries
    WHERE delivery_status = 'completed'
    GROUP BY STRFTIME('%Y-%W', scheduled_time)
)
SELECT
    week,
    deliveries,
    late_deliveries,
    ROUND(100.0 * late_deliveries / deliveries, 2)              AS late_rate_pct,
    ROUND(
        AVG(100.0 * late_deliveries / deliveries) OVER (
            ORDER BY week
            ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
        ), 2)                                                    AS late_rate_4wk_avg
FROM weekly
ORDER BY week;


-- =========================================================================
-- 6. Business impact estimate for push-notification recommendation
--
-- Assumption: proactive push at 30-minute delay mark converts X% of
-- would-be "where is the courier" callers into passive waiters.
-- We take conservative X = 40% (industry benchmark: 30-50%).
--
-- Support cost inputs (for a mid-size RU FinTech support team):
--   average handle time per WIC ticket   = 8 minutes
--   fully loaded cost per support minute = 12 RUB
--   cost per WIC ticket                  = 96 RUB
-- =========================================================================

WITH wic_ticket_stats AS (
    SELECT
        COUNT(*)                          AS wic_tickets_period,
        COUNT(*) * 96.0                   AS wic_cost_period_rub
    FROM support_tickets
    WHERE issue_category = 'where_is_courier'
),
period_length AS (
    SELECT
        (JULIANDAY(MAX(scheduled_time)) - JULIANDAY(MIN(scheduled_time))) / 30.0
            AS months
    FROM deliveries
)
SELECT
    wic_tickets_period,
    ROUND(wic_tickets_period / months, 0)                           AS wic_tickets_per_month,
    ROUND(wic_cost_period_rub, 0)                                   AS wic_cost_period_rub,
    ROUND(wic_cost_period_rub / months, 0)                          AS wic_cost_per_month_rub,
    ROUND(wic_tickets_period * 0.40 / months, 0)                    AS estimated_tickets_saved_per_month,
    ROUND(wic_cost_period_rub * 0.40 / months, 0)                   AS estimated_savings_per_month_rub,
    ROUND(wic_cost_period_rub * 0.40 * 12 / months, 0)              AS estimated_annual_savings_rub
FROM wic_ticket_stats, period_length;
