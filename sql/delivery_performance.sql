-- =============================================================
-- Breakfast Delivery Platform — SQL Analysis Queries
-- Author: Philippe Godfroy
-- Purpose: Operational KPI monitoring & supplier performance
-- Database: PostgreSQL / SQL Server compatible (minor tweaks)
-- =============================================================


-- ---------------------------------------------------------------
-- QUERY 1: Delivery Performance by Supplier + Postal Code Zone
-- Purpose: Identify underperforming supplier/zone combinations
-- Used in: Operations dashboard (weekly review)
-- ---------------------------------------------------------------

SELECT
    s.name                                                          AS supplier_name,
    o.delivery_postal_code,
    COUNT(o.id)                                                     AS total_orders,
    ROUND(AVG(
        EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60
    ), 1)                                                           AS avg_delivery_minutes,
    ROUND(
        SUM(CASE WHEN o.delivered_at <= o.promised_at THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*), 1
    )                                                               AS on_time_pct,
    ROUND(AVG(o.order_value), 2)                                    AS avg_order_value,
    ROUND(AVG(o.consumer_rating), 2)                                AS avg_rating
FROM orders o
JOIN suppliers s ON o.supplier_id = s.id
WHERE
    o.placed_at >= NOW() - INTERVAL '3 months'
    AND o.status = 'delivered'
GROUP BY
    s.name,
    o.delivery_postal_code
HAVING
    COUNT(o.id) > 10
ORDER BY
    on_time_pct ASC;


-- ---------------------------------------------------------------
-- QUERY 2: Supplier Churn Risk Detection
-- Purpose: Flag suppliers with significant volume decline (>25% MoM)
-- Used in: Supplier Relations team — weekly alert
-- ---------------------------------------------------------------

WITH monthly_volume AS (
    SELECT
        o.supplier_id,
        DATE_TRUNC('month', o.placed_at)                            AS month,
        COUNT(o.id)                                                 AS orders,
        SUM(o.platform_fee)                                         AS platform_revenue
    FROM orders o
    WHERE o.placed_at >= NOW() - INTERVAL '6 months'
    GROUP BY o.supplier_id, DATE_TRUNC('month', o.placed_at)
),
with_lag AS (
    SELECT
        *,
        LAG(orders) OVER (
            PARTITION BY supplier_id ORDER BY month
        )                                                           AS prev_month_orders,
        LAG(platform_revenue) OVER (
            PARTITION BY supplier_id ORDER BY month
        )                                                           AS prev_month_revenue
    FROM monthly_volume
)
SELECT
    s.name                                                          AS supplier_name,
    s.email                                                         AS supplier_email,
    w.month,
    w.orders                                                        AS current_month_orders,
    w.prev_month_orders,
    ROUND(
        (w.orders - w.prev_month_orders) * 100.0
        / NULLIF(w.prev_month_orders, 0), 1
    )                                                               AS mom_change_pct,
    ROUND(w.platform_revenue, 2)                                    AS platform_revenue
FROM with_lag w
JOIN suppliers s ON w.supplier_id = s.id
WHERE
    w.prev_month_orders IS NOT NULL
    AND w.orders < w.prev_month_orders * 0.75   -- flag: >25% drop
ORDER BY
    mom_change_pct ASC;


-- ---------------------------------------------------------------
-- QUERY 3: Consumer Retention Cohort Analysis
-- Purpose: Track 7d / 14d / 30d retention by signup cohort
-- Used in: Product & Growth weekly review
-- ---------------------------------------------------------------

WITH cohorts AS (
    SELECT
        c.id                                                        AS consumer_id,
        DATE_TRUNC('week', c.created_at)                            AS cohort_week,
        MIN(o.placed_at)                                            AS first_order_date
    FROM consumers c
    LEFT JOIN orders o ON o.consumer_id = c.id AND o.status = 'delivered'
    GROUP BY c.id, DATE_TRUNC('week', c.created_at)
),
retention AS (
    SELECT
        cohort_week,
        COUNT(DISTINCT consumer_id)                                 AS cohort_size,
        COUNT(DISTINCT CASE
            WHEN first_order_date <= cohort_week + INTERVAL '7 days'
            THEN consumer_id END)                                   AS retained_7d,
        COUNT(DISTINCT CASE
            WHEN first_order_date <= cohort_week + INTERVAL '14 days'
            THEN consumer_id END)                                   AS retained_14d,
        COUNT(DISTINCT CASE
            WHEN first_order_date <= cohort_week + INTERVAL '30 days'
            THEN consumer_id END)                                   AS retained_30d
    FROM cohorts
    GROUP BY cohort_week
)
SELECT
    cohort_week,
    cohort_size,
    ROUND(retained_7d  * 100.0 / NULLIF(cohort_size, 0), 1)        AS retention_7d_pct,
    ROUND(retained_14d * 100.0 / NULLIF(cohort_size, 0), 1)        AS retention_14d_pct,
    ROUND(retained_30d * 100.0 / NULLIF(cohort_size, 0), 1)        AS retention_30d_pct
FROM retention
WHERE cohort_week >= NOW() - INTERVAL '6 months'
ORDER BY cohort_week DESC;


-- ---------------------------------------------------------------
-- QUERY 4: Revenue Breakdown by Product Category
-- Purpose: Understand which categories drive GMV + margin
-- Used in: Finance / quarterly business review
-- ---------------------------------------------------------------

SELECT
    p.category,
    COUNT(DISTINCT o.id)                                            AS total_orders,
    SUM(oi.quantity)                                                AS units_sold,
    ROUND(SUM(oi.quantity * oi.unit_price), 2)                      AS gross_revenue,
    ROUND(SUM(oi.quantity * oi.platform_fee_per_unit), 2)           AS platform_revenue,
    ROUND(AVG(oi.unit_price), 2)                                    AS avg_unit_price,
    ROUND(
        SUM(oi.quantity * oi.platform_fee_per_unit) * 100.0
        / NULLIF(SUM(oi.quantity * oi.unit_price), 0), 1
    )                                                               AS take_rate_pct
FROM order_items oi
JOIN products p ON oi.product_id = p.id
JOIN orders o ON oi.order_id = o.id
WHERE
    o.placed_at >= DATE_TRUNC('quarter', NOW())
    AND o.status = 'delivered'
GROUP BY p.category
ORDER BY gross_revenue DESC;
