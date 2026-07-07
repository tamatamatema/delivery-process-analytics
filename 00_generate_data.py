"""
Synthetic data generator for delivery operations project.

Produces a SQLite database with cities, couriers, clients, deliveries and
support tickets. Ticket generation is probabilistic and correlated with
delivery delay so that the relationship has to be recovered from noisy data,
not read off from constants.
"""

import sqlite3
import random
from datetime import datetime, timedelta
from pathlib import Path

random.seed(2026)

DB_PATH = Path("delivery.db")
if DB_PATH.exists():
    DB_PATH.unlink()

conn = sqlite3.connect(DB_PATH)
c = conn.cursor()

# --- Schema ----------------------------------------------------------------

c.executescript("""
CREATE TABLE cities (
    city_id INTEGER PRIMARY KEY,
    city_name TEXT NOT NULL,
    region TEXT NOT NULL
);
CREATE TABLE couriers (
    courier_id INTEGER PRIMARY KEY,
    city_id INTEGER NOT NULL,
    hire_date TEXT NOT NULL,
    tier TEXT NOT NULL
);
CREATE TABLE clients (
    client_id INTEGER PRIMARY KEY,
    city_id INTEGER NOT NULL,
    signup_date TEXT NOT NULL,
    segment TEXT NOT NULL
);
CREATE TABLE deliveries (
    delivery_id INTEGER PRIMARY KEY,
    client_id INTEGER NOT NULL,
    courier_id INTEGER,
    city_id INTEGER NOT NULL,
    scheduled_time TEXT NOT NULL,
    actual_time TEXT,
    delivery_status TEXT NOT NULL,
    delay_minutes INTEGER
);
CREATE TABLE support_tickets (
    ticket_id INTEGER PRIMARY KEY,
    client_id INTEGER NOT NULL,
    delivery_id INTEGER,
    created_at TEXT NOT NULL,
    issue_category TEXT NOT NULL,
    resolution_min INTEGER
);
""")

# --- Cities (different reliability baselines) -----------------------------

CITIES = [
    ("Moscow",           "Central",       0.08),  # 8% base late rate
    ("Saint Petersburg", "North-West",    0.11),
    ("Krasnodar",        "South",         0.18),  # weaker logistics → higher late rate
    ("Novosibirsk",      "Siberia",       0.14),
    ("Ekaterinburg",     "Ural",          0.12),
    ("Kazan",            "Volga",         0.10),
]

city_late_rate = {}
for i, (name, region, late_rate) in enumerate(CITIES, start=1):
    c.execute(
        "INSERT INTO cities (city_id, city_name, region) VALUES (?, ?, ?)",
        (i, name, region),
    )
    city_late_rate[i] = late_rate

# --- Couriers -------------------------------------------------------------

TIERS = [("new", 0.25, 1.7), ("regular", 0.55, 1.0), ("top", 0.20, 0.5)]
courier_tier = {}
cid = 1
for city_id in city_late_rate:
    n_couriers = random.randint(15, 40)
    for _ in range(n_couriers):
        tier = random.choices(
            [t[0] for t in TIERS], weights=[t[1] for t in TIERS]
        )[0]
        hire = datetime(2024, 1, 1) + timedelta(days=random.randint(0, 900))
        c.execute(
            "INSERT INTO couriers (courier_id, city_id, hire_date, tier) "
            "VALUES (?, ?, ?, ?)",
            (cid, city_id, hire.strftime("%Y-%m-%d"), tier),
        )
        courier_tier[cid] = tier
        cid += 1
n_couriers_total = cid - 1

# --- Clients --------------------------------------------------------------

SEGMENTS = [("new", 0.35), ("active", 0.50), ("vip", 0.15)]
clients_by_city = {cid: [] for cid in city_late_rate}
cli_id = 1
N_CLIENTS = 3000
for _ in range(N_CLIENTS):
    city_id = random.choice(list(city_late_rate.keys()))
    seg = random.choices(
        [s[0] for s in SEGMENTS], weights=[s[1] for s in SEGMENTS]
    )[0]
    signup = datetime(2025, 1, 1) + timedelta(days=random.randint(0, 500))
    c.execute(
        "INSERT INTO clients (client_id, city_id, signup_date, segment) "
        "VALUES (?, ?, ?, ?)",
        (cli_id, city_id, signup.strftime("%Y-%m-%d"), seg),
    )
    clients_by_city[city_id].append(cli_id)
    cli_id += 1

# --- Deliveries + Tickets (correlated) ------------------------------------
#
# Model (transparent so it can be defended in interview):
#   1. Base probability that a delivery is "late" = city_late_rate × tier_mult.
#   2. If late, delay is drawn from a heavy-tailed distribution (many small,
#      few very long) — matches real logistics data.
#   3. Probability of a "where_is_courier" ticket:
#        p_ticket = f(delay_minutes) — sigmoid-ish shape:
#          delay < 15 min   → 3%   (baseline noise: some clients complain anyway)
#          15–30 min        → 8%
#          30–60 min        → 25%
#          60+ min          → 50–70%
#   4. Independent app_error and consultation tickets (background).

N_DELIVERIES = 5000
did = 1
tid = 1
start_day = datetime(2026, 3, 1)

def sample_delay_minutes():
    # Heavy-tailed distribution:
    #   20% of "late" cases are 15–30 min (moderate delay)
    #   50% are 30–90 min
    #   30% are 90–300 min (severe)
    r = random.random()
    if r < 0.20:
        return random.randint(15, 30)
    if r < 0.70:
        return random.randint(30, 90)
    return random.randint(90, 300)

def ticket_probability(delay_min):
    if delay_min is None or delay_min < 15:
        return 0.03
    if delay_min < 30:
        return 0.08
    if delay_min < 60:
        return 0.25
    if delay_min < 120:
        return 0.50
    return 0.70

for _ in range(N_DELIVERIES):
    city_id = random.choices(
        list(city_late_rate.keys()),
        weights=[len(clients_by_city[c_id]) for c_id in city_late_rate],
    )[0]
    if not clients_by_city[city_id]:
        continue
    client_id = random.choice(clients_by_city[city_id])
    courier_id = random.randint(1, n_couriers_total)
    tier = courier_tier[courier_id]
    tier_mult = {"new": 1.7, "regular": 1.0, "top": 0.5}[tier]

    scheduled = start_day + timedelta(
        days=random.randint(0, 120),
        hours=random.randint(8, 21),
        minutes=random.choice([0, 15, 30, 45]),
    )

    # Status distribution
    status_roll = random.random()
    if status_roll < 0.03:
        status = "cancelled"
        actual = None
        delay = None
    elif status_roll < 0.05:
        status = "rescheduled"
        actual = None
        delay = None
    else:
        status = "completed"
        p_late = min(0.95, city_late_rate[city_id] * tier_mult)
        if random.random() < p_late:
            delay = sample_delay_minutes()
        else:
            # On-time deliveries also have some jitter: ±20 min
            delay = random.randint(-20, 14)
        actual = scheduled + timedelta(minutes=delay)

    c.execute(
        "INSERT INTO deliveries "
        "(delivery_id, client_id, courier_id, city_id, scheduled_time, "
        " actual_time, delivery_status, delay_minutes) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (did, client_id, courier_id, city_id,
         scheduled.strftime("%Y-%m-%d %H:%M:%S"),
         actual.strftime("%Y-%m-%d %H:%M:%S") if actual else None,
         status, delay),
    )

    # Ticket generation — only for completed deliveries
    if status == "completed" and random.random() < ticket_probability(delay):
        # Ticket arrives some time after client notices delay
        # (or after scheduled time for on-time cases where person is anxious)
        offset_min = random.randint(10, 90)
        ticket_time = scheduled + timedelta(minutes=max(delay or 0, 0) + offset_min)
        c.execute(
            "INSERT INTO support_tickets "
            "(ticket_id, client_id, delivery_id, created_at, "
            " issue_category, resolution_min) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (tid, client_id, did,
             ticket_time.strftime("%Y-%m-%d %H:%M:%S"),
             "where_is_courier",
             random.randint(3, 15)),
        )
        tid += 1

    did += 1

# --- Background tickets (unrelated to delays) -----------------------------

for _ in range(400):
    client_id = random.randint(1, N_CLIENTS)
    day = start_day + timedelta(days=random.randint(0, 120),
                                hours=random.randint(9, 22))
    cat = random.choices(
        ["app_error", "product_consultation", "payment_issue"],
        weights=[0.4, 0.4, 0.2],
    )[0]
    c.execute(
        "INSERT INTO support_tickets "
        "(client_id, delivery_id, created_at, issue_category, resolution_min) "
        "VALUES (?, ?, ?, ?, ?)",
        (client_id, None,
         day.strftime("%Y-%m-%d %H:%M:%S"),
         cat,
         random.randint(5, 25)),
    )

conn.commit()

# --- Summary --------------------------------------------------------------

print("Database created:", DB_PATH.absolute())
for tbl in ["cities", "couriers", "clients", "deliveries", "support_tickets"]:
    n = c.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
    print(f"  {tbl}: {n:,} rows")

late_share = c.execute("""
    SELECT
        ROUND(100.0 * SUM(CASE WHEN delay_minutes > 30 THEN 1 ELSE 0 END)
              / COUNT(*), 2) AS late_pct
    FROM deliveries
    WHERE delivery_status = 'completed'
""").fetchone()[0]
print(f"\nOverall >30 min late rate: {late_share}%")

conn.close()
