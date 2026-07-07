-- Schema: FinTech delivery operations
-- All timestamps in UTC. Currency: RUB (kopeks for support cost fields).

CREATE TABLE cities (
    city_id      SERIAL PRIMARY KEY,
    city_name    VARCHAR(50) NOT NULL,
    region       VARCHAR(50) NOT NULL
);

CREATE TABLE couriers (
    courier_id   SERIAL PRIMARY KEY,
    city_id      INT NOT NULL REFERENCES cities(city_id),
    hire_date    DATE NOT NULL,
    tier         VARCHAR(20) NOT NULL  -- 'new' | 'regular' | 'top'
);

CREATE TABLE clients (
    client_id    SERIAL PRIMARY KEY,
    city_id      INT NOT NULL REFERENCES cities(city_id),
    signup_date  DATE NOT NULL,
    segment      VARCHAR(20) NOT NULL  -- 'new' | 'active' | 'vip'
);

CREATE TABLE deliveries (
    delivery_id       BIGSERIAL PRIMARY KEY,
    client_id         INT NOT NULL REFERENCES clients(client_id),
    courier_id        INT REFERENCES couriers(courier_id),
    city_id           INT NOT NULL REFERENCES cities(city_id),
    scheduled_time    TIMESTAMP NOT NULL,
    actual_time       TIMESTAMP,
    delivery_status   VARCHAR(20) NOT NULL,  -- 'completed' | 'rescheduled' | 'cancelled'
    delay_minutes     INT  -- computed at load time for query performance
);

CREATE TABLE support_tickets (
    ticket_id         BIGSERIAL PRIMARY KEY,
    client_id         INT NOT NULL REFERENCES clients(client_id),
    delivery_id       BIGINT REFERENCES deliveries(delivery_id),
    created_at        TIMESTAMP NOT NULL,
    issue_category    VARCHAR(50) NOT NULL,  -- 'where_is_courier' | 'app_error' | ...
    resolution_min    INT  -- support handling time in minutes
);

CREATE INDEX ix_deliveries_scheduled ON deliveries(scheduled_time);
CREATE INDEX ix_deliveries_client    ON deliveries(client_id);
CREATE INDEX ix_tickets_created      ON support_tickets(created_at);
CREATE INDEX ix_tickets_client       ON support_tickets(client_id);
CREATE INDEX ix_tickets_delivery     ON support_tickets(delivery_id);
