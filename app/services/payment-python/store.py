"""Where payments are kept: PostgreSQL in Kubernetes, memory in tests.

Each order can be paid only once: payments.order_id is UNIQUE, so if the orders
service retries a payment (for example after a timeout), the customer is not
charged twice. The first result is returned again instead.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Protocol

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

SCHEMA = """
CREATE TABLE IF NOT EXISTS payments (
    id           TEXT PRIMARY KEY,
    order_id     TEXT NOT NULL UNIQUE,
    user_id      TEXT NOT NULL,
    amount_cents BIGINT NOT NULL CHECK (amount_cents >= 0),
    currency     TEXT NOT NULL,
    status       TEXT NOT NULL,
    reason       TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payments_user_idx ON payments (user_id);
"""

COLUMNS = "id, order_id, user_id, amount_cents, currency, status, reason"


class PaymentStore(Protocol):
    def save_once(self, payment: dict) -> tuple[dict, bool]:
        """Stores the payment unless the order was already paid.
        Returns (stored payment, created)."""

    def get(self, payment_id: str) -> dict | None: ...

    def ping(self) -> None: ...


class MemoryStore:
    def __init__(self) -> None:
        self._by_id: dict[str, dict] = {}
        self._by_order: dict[str, dict] = {}
        self._lock = threading.Lock()

    def save_once(self, payment: dict) -> tuple[dict, bool]:
        with self._lock:
            existing = self._by_order.get(payment["order_id"])
            if existing:
                return existing, False
            self._by_id[payment["id"]] = payment
            self._by_order[payment["order_id"]] = payment
            return payment, True

    def get(self, payment_id: str) -> dict | None:
        return self._by_id.get(payment_id)

    def ping(self) -> None:
        return None


class PostgresStore:
    def __init__(self, conninfo: str) -> None:
        self.pool = ConnectionPool(conninfo, min_size=1, max_size=10, open=False,
                                   kwargs={"row_factory": dict_row}, timeout=5)
        # The database may start after this service, or be failing over: retry for a minute
        deadline = time.monotonic() + 60
        while True:
            try:
                self.pool.open(wait=True, timeout=10)
                with self.pool.connection() as conn:
                    conn.execute(SCHEMA)
                return
            except Exception:
                if time.monotonic() > deadline:
                    raise
                time.sleep(3)

    def save_once(self, payment: dict) -> tuple[dict, bool]:
        with self.pool.connection() as conn:
            row = conn.execute(
                f"""INSERT INTO payments ({COLUMNS})
                    VALUES (%(id)s, %(order_id)s, %(user_id)s, %(amount_cents)s, %(currency)s, %(status)s, %(reason)s)
                    ON CONFLICT (order_id) DO NOTHING
                    RETURNING {COLUMNS}""",
                payment,
            ).fetchone()
            if row:
                return row, True
            existing = conn.execute(f"SELECT {COLUMNS} FROM payments WHERE order_id = %s",
                                    (payment["order_id"],)).fetchone()
            return existing, False

    def get(self, payment_id: str) -> dict | None:
        with self.pool.connection() as conn:
            return conn.execute(f"SELECT {COLUMNS} FROM payments WHERE id = %s", (payment_id,)).fetchone()

    def ping(self) -> None:
        with self.pool.connection() as conn:
            conn.execute("SELECT 1")

    def close(self) -> None:
        self.pool.close()


def conninfo_from_env() -> str | None:
    """Built from the Secret the postgres-operator creates. TLS is required."""
    host = os.getenv("DB_HOST")
    if not host:
        return None
    parts = {
        "host": host,
        "port": os.getenv("DB_PORT", "5432"),
        "dbname": os.getenv("DB_NAME", "payments"),
        "user": os.getenv("DB_USER", "payment"),
        "password": os.getenv("DB_PASSWORD", ""),
        "sslmode": os.getenv("DB_SSLMODE", "require"),
        "connect_timeout": "5",
    }
    from psycopg.conninfo import make_conninfo
    return make_conninfo(**parts)
