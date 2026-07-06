/* 
ЗАДАЧА 1: Расчет доли опозданий курьеров (более 30 минут) по городам.
Цель: Найти логистические аномалии.
*/
WITH DeliveryDelays AS (
    SELECT 
        city,
        COUNT(delivery_id) AS total_deliveries,
        SUM(CASE 
            WHEN EXTRACT(EPOCH FROM (actual_time - scheduled_time))/60 > 30 THEN 1 
            ELSE 0 
        END) AS late_deliveries
    FROM deliveries
    WHERE delivery_status = 'completed'
    GROUP BY city
)
SELECT 
    city,
    total_deliveries,
    late_deliveries,
    ROUND((late_deliveries::NUMERIC / total_deliveries) * 100, 2) AS delay_rate_percent
FROM DeliveryDelays
ORDER BY delay_rate_percent DESC;

/* 
ЗАДАЧА 2: Влияние проблем с доставкой на нагрузку Customer Care.
Цель: Доказать, что опоздания генерируют лишние косты на саппорт.
*/
WITH SupportLoad AS (
    SELECT 
        d.delivery_id,
        d.client_id,
        -- Флаг: было ли опоздание больше 30 мин?
        CASE WHEN EXTRACT(EPOCH FROM (d.actual_time - d.scheduled_time))/60 > 30 THEN 'Late' ELSE 'On Time' END AS delivery_quality,
        -- Считаем тикеты категории "где курьер" в день доставки
        COUNT(s.ticket_id) AS "where_is_courier_tickets"
    FROM deliveries d
    LEFT JOIN support_tickets s 
        ON d.client_id = s.client_id 
        AND s.issue_category = 'where_is_courier'
        AND DATE(s.created_at) = DATE(d.scheduled_time)
    WHERE d.delivery_status = 'completed'
    GROUP BY d.delivery_id, d.client_id, delivery_quality
)
SELECT 
    delivery_quality,
    COUNT(delivery_id) AS deliveries_count,
    SUM(where_is_courier_tickets) AS total_support_tickets,
    ROUND(AVG(where_is_courier_tickets), 2) AS tickets_per_delivery
FROM SupportLoad
GROUP BY delivery_quality;