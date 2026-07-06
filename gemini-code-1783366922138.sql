-- Создание таблицы доставок
CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    client_id INT NOT NULL,
    city VARCHAR(50),
    scheduled_time TIMESTAMP,
    actual_time TIMESTAMP,
    delivery_status VARCHAR(20) -- 'completed', 'rescheduled', 'cancelled'
);

-- Создание таблицы обращений в поддержку
CREATE TABLE support_tickets (
    ticket_id SERIAL PRIMARY KEY,
    client_id INT NOT NULL,
    created_at TIMESTAMP,
    issue_category VARCHAR(50) -- 'where_is_courier', 'app_error', 'product_consultation'
);

-- Генерация синтетических данных (5 доставок для примера)
INSERT INTO deliveries (client_id, city, scheduled_time, actual_time, delivery_status)
VALUES 
(101, 'Moscow', '2026-07-01 10:00:00', '2026-07-01 10:15:00', 'completed'),
(102, 'Krasnodar', '2026-07-01 11:00:00', '2026-07-01 14:30:00', 'completed'), -- Опоздание 3.5 часа
(103, 'Moscow', '2026-07-02 09:00:00', '2026-07-02 09:05:00', 'completed'),
(104, 'Krasnodar', '2026-07-02 15:00:00', NULL, 'cancelled'),
(105, 'Saint Petersburg', '2026-07-03 12:00:00', '2026-07-03 12:45:00', 'completed');

-- Генерация обращений в саппорт
INSERT INTO support_tickets (client_id, created_at, issue_category)
VALUES 
(102, '2026-07-01 12:00:00', 'where_is_courier'),
(102, '2026-07-01 15:00:00', 'product_consultation'),
(104, '2026-07-02 15:30:00', 'where_is_courier'),
(101, '2026-07-05 10:00:00', 'app_error');