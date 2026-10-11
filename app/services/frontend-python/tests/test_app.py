from unittest.mock import MagicMock, patch

import requests

from app import app, money

client = app.test_client()


def test_money_filter():
    assert money(4500) == "£45.00"
    assert money(123456, "USD") == "$1,234.56"


def test_health():
    assert client.get("/health").json["status"] == "ok"


def fake_get(url, **kwargs):
    response = MagicMock()
    response.raise_for_status.return_value = None
    if url.endswith("/products"):
        response.json.return_value = [{
            "id": "p-1", "name": "Mug", "description": "d", "priceCents": 1200,
            "currency": "GBP", "imageUrl": "x", "stock": 1, "category": "kitchen",
        }]
    else:
        response.json.return_value = {"userId": "u", "items": [], "totalItems": 0}
    return response


@patch("app.requests.get", side_effect=fake_get)
def test_index_lists_products(_mock):
    fresh_client = app.test_client()  # no cookie yet, so the app must set one
    response = fresh_client.get("/")
    assert response.status_code == 200
    assert b"Mug" in response.data
    assert "kubemart_uid" in response.headers.get("Set-Cookie", "")


@patch("app.requests.get", side_effect=requests.ConnectionError("down"))
def test_index_handles_catalog_outage(_mock):
    assert client.get("/").status_code == 503


def test_sold_out_products_cannot_be_added():
    def zero_stock(url, **kwargs):
        response = fake_get(url, **kwargs)
        if url.endswith("/products"):
            response.json.return_value[0]["stock"] = 0
        return response

    with patch("app.requests.get", side_effect=zero_stock):
        body = client.get("/").data
    assert b"Sold out" in body


@patch("app.requests.post")
def test_checkout_out_of_stock_message(mock_post):
    mock_post.return_value = MagicMock(status_code=409, content=b"{}", json=lambda: {"error": "not enough stock"})
    response = client.post("/checkout")
    assert response.status_code == 302
    with client.session_transaction() as session:
        assert any("enough stock" in message for _, message in session["_flashes"])


def test_metrics_use_route_rules():
    client.get("/health")
    body = client.get("/metrics").data.decode()
    assert 'route="/health"' in body
    assert "http_request_duration_seconds" in body
