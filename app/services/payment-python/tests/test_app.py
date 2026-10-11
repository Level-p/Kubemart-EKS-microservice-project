import os

import pytest
from fastapi.testclient import TestClient

from app import LIMIT_CENTS, app


@pytest.fixture()
def client(monkeypatch):
    monkeypatch.delenv("DB_HOST", raising=False)  # in-memory store
    with TestClient(app) as c:
        yield c


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"


def test_small_payment_is_approved(client):
    body = {"orderId": "ord-1", "userId": "u-1", "amountCents": 1200}
    response = client.post("/payments", json=body)
    assert response.status_code == 200
    assert response.json()["status"] == "approved"


def test_large_payment_is_declined(client):
    body = {"orderId": "ord-2", "userId": "u-1", "amountCents": LIMIT_CENTS + 1}
    response = client.post("/payments", json=body)
    assert response.status_code == 200
    assert response.json()["status"] == "declined"


def test_negative_amount_is_rejected(client):
    body = {"orderId": "ord-3", "userId": "u-1", "amountCents": -5}
    assert client.post("/payments", json=body).status_code == 422


def test_same_order_is_never_charged_twice(client):
    body = {"orderId": "ord-4", "userId": "u-1", "amountCents": 700}
    first = client.post("/payments", json=body).json()
    second = client.post("/payments", json=body).json()
    assert first["paymentId"] == second["paymentId"]
    assert client.get(f"/payments/{first['paymentId']}").json()["orderId"] == "ord-4"


def test_unknown_payment_is_404(client):
    assert client.get("/payments/pay-nope").status_code == 404


def test_metrics_use_route_templates(client):
    client.get("/payments/pay-abc")
    body = client.get("/metrics").text
    assert 'route="/payments/{payment_id}"' in body
    assert "pay-abc" not in body
    assert "payments_total" in body


@pytest.mark.skipif(not os.getenv("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL not set")
def test_postgres_store():
    import concurrent.futures
    import uuid

    from store import PostgresStore

    store = PostgresStore(os.environ["TEST_DATABASE_URL"])
    order = f"ord-{uuid.uuid4().hex[:8]}"

    def pay(_):
        return store.save_once({"id": f"pay-{uuid.uuid4().hex[:10]}", "order_id": order, "user_id": "u",
                                "amount_cents": 100, "currency": "GBP", "status": "approved", "reason": None})

    # 10 simultaneous attempts to pay the same order: exactly one is created
    with concurrent.futures.ThreadPoolExecutor(10) as pool:
        results = list(pool.map(pay, range(10)))
    assert sum(created for _, created in results) == 1
    assert len({row["id"] for row, _ in results}) == 1
    assert store.get(results[0][0]["id"])["order_id"] == order
    store.close()
