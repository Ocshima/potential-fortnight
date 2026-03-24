-- ============================================================
-- error-analysis.sql
-- Analyse 4xx/5xx errors to identify broken links or attacks.
-- ============================================================

SELECT
    sc_status                                   AS status_code,
    cs_uri_stem                                 AS path,
    cs_referrer                                 AS referrer, -- Fixed spelling to match template.yaml
    COUNT(*)                                    AS occurrences,
    COUNT(DISTINCT c_ip)                        AS unique_ips,
    MIN(CONCAT(date, ' ', time))                AS first_seen,
    MAX(CONCAT(date, ' ', time))                AS last_seen
FROM cloudfront_access_logs
WHERE CAST(date AS DATE) >= CURRENT_DATE - INTERVAL '7' DAY
  AND sc_status >= 400
GROUP BY sc_status, cs_uri_stem, cs_referrer -- Updated here as well
ORDER BY occurrences DESC
LIMIT 50;


-- ============================================================
-- geographic-distribution.sql
-- Traffic breakdown by CloudFront edge location (proxy for region).
-- ============================================================

SELECT
    x_edge_location                             AS edge_location,
    COUNT(*)                                    AS requests,
    COUNT(DISTINCT c_ip)                        AS unique_visitors,
    ROUND(SUM(sc_bytes) / 1048576.0, 2)         AS total_mb_served,
    ROUND(AVG(time_taken), 3)                   AS avg_response_s,
    SUM(CASE WHEN x_edge_result_type = 'Hit'
             THEN 1 ELSE 0 END) * 100.0
      / NULLIF(COUNT(*), 0)                     AS cache_hit_pct
FROM cloudfront_access_logs
WHERE CAST(date AS DATE) >= CURRENT_DATE - INTERVAL '30' DAY -- Fixed casting
GROUP BY x_edge_location
ORDER BY requests DESC;


-- ============================================================
-- waf-blocked-requests.sql
-- Requests blocked by WAF (x_edge_result_type = 'Error' with 403).
-- Use alongside WAF sampled requests in the console for full picture.
-- ============================================================

SELECT
    date,
    c_ip                                        AS client_ip,
    cs_method                                   AS method,
    cs_uri_stem                                 AS path,
    cs_user_agent                               AS user_agent,
    COUNT(*)                                    AS blocked_count
FROM cloudfront_access_logs
WHERE CAST(date AS DATE) >= CURRENT_DATE - INTERVAL '7' DAY -- Fixed casting
  AND sc_status = 403
GROUP BY date, c_ip, cs_method, cs_uri_stem, cs_user_agent
ORDER BY blocked_count DESC
LIMIT 50;


-- ============================================================
-- cache-performance.sql
-- Cache hit/miss ratio by day — helps validate caching config.
-- A high Hit% means fewer origin requests → lower cost and latency.
-- ============================================================

SELECT
    date,
    COUNT(*)                                             AS total_requests,
    SUM(CASE WHEN x_edge_result_type = 'Hit'
             THEN 1 ELSE 0 END)                         AS cache_hits,
    SUM(CASE WHEN x_edge_result_type = 'Miss'
             THEN 1 ELSE 0 END)                         AS cache_misses,
    SUM(CASE WHEN x_edge_result_type = 'RefreshHit'
             THEN 1 ELSE 0 END)                         AS refresh_hits,
    ROUND(
        SUM(CASE WHEN x_edge_result_type = 'Hit' THEN 1 ELSE 0 END)
        * 100.0 / NULLIF(COUNT(*), 0), 2
    )                                                    AS cache_hit_pct,
    ROUND(SUM(sc_bytes) / 1048576.0, 2)                 AS total_mb_served
FROM cloudfront_access_logs
WHERE CAST(date AS DATE) >= CURRENT_DATE - INTERVAL '30' DAY -- Fixed casting
GROUP BY date
ORDER BY date DESC;
