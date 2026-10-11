"""KubeMart storefront (Python, Flask).

The only service exposed to the internet (through the ALB Ingress).
It renders HTML and calls the internal services:
  product-catalog (Go), cart (Rust), orders (Java)
Each browser gets an anonymous user id stored in a cookie.
GET /metrics serves Prometheus metrics (blocked at the ALB, see the Ingress).
"""
import json
import logging
import os
import sys
import time
import uuid
from datetime import datetime, timezone

import requests
from flask import Flask, Response, flash, g, redirect, render_template, request, url_for
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

CATALOG_URL = os.getenv("CATALOG_URL", "http://localhost:8081")
CART_URL = os.getenv("CART_URL", "http://localhost:8082")
ORDERS_URL = os.getenv("ORDERS_URL", "http://localhost:8083")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")
TIMEOUT = 5  # seconds for every downstream call

# ---- Metrics (one process per pod, see the Dockerfile, so plain counters are correct) ----
HTTP_REQUESTS = Counter("http_requests_total", "HTTP requests by method, route and status code.",
                        ["method", "route", "status"])
HTTP_DURATION = Histogram("http_request_duration_seconds", "HTTP request duration by method and route.",
                          ["method", "route"], buckets=(.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5))
CHECKOUTS = Counter("frontend_checkouts_total", "Checkout attempts by result.", ["result"])
# Start every series at 0, so dashboards show "0" instead of "no data"
for _result in ("confirmed", "payment_declined", "out_of_stock", "failed", "unavailable"):
    CHECKOUTS.labels(_result)


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "log.level": record.levelname.lower(),
            "service.name": "frontend",
            "message": record.getMessage(),
        }
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("frontend")
log.addHandler(handler)
log.setLevel(logging.INFO)
log.propagate = False

app = Flask(__name__)
app.secret_key = os.getenv("SECRET_KEY", "dev-only-change-me")


def money(cents: int, currency: str = "GBP") -> str:
    symbol = {"GBP": "£", "USD": "$", "EUR": "€"}.get(currency, currency + " ")
    return f"{symbol}{cents / 100:,.2f}"


app.jinja_env.filters["money"] = money


@app.before_request
def identify_user():
    g.start = time.perf_counter()
    g.user_id = request.cookies.get("kubemart_uid") or f"u-{uuid.uuid4().hex[:12]}"


@app.after_request
def remember_user(response):
    if request.cookies.get("kubemart_uid") != g.get("user_id"):
        response.set_cookie("kubemart_uid", g.user_id, max_age=60 * 60 * 24 * 30, httponly=True, samesite="Lax")
    # The route rule ("/cart/add"), never the raw path, keeps metric series few
    route = request.url_rule.rule if request.url_rule else "unmatched"
    HTTP_REQUESTS.labels(request.method, route, str(response.status_code)).inc()
    HTTP_DURATION.labels(request.method, route).observe(time.perf_counter() - g.get("start", time.perf_counter()))
    return response


@app.context_processor
def inject_globals():
    return {"environment": ENVIRONMENT, "pod_name": os.getenv("HOSTNAME", "local")}


def get_products() -> list[dict]:
    response = requests.get(f"{CATALOG_URL}/products", timeout=TIMEOUT)
    response.raise_for_status()
    return response.json()


def get_cart(user_id: str) -> dict:
    response = requests.get(f"{CART_URL}/cart/{user_id}", timeout=TIMEOUT)
    response.raise_for_status()
    return response.json()


@app.get("/health")
def health():
    return {"status": "ok", "service": "frontend"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/")
def index():
    try:
        products = get_products()
        cart = get_cart(g.user_id)
    except requests.RequestException as exc:
        log.error("catalog or cart unavailable", extra={"fields": {"error": str(exc)}})
        return render_template("error.html", message="The shop is having a moment. Please try again."), 503
    return render_template("index.html", products=products, cart_count=cart.get("totalItems", 0))


@app.post("/cart/add")
def add_to_cart():
    product_id = request.form.get("product_id", "")
    try:
        response = requests.post(
            f"{CART_URL}/cart/{g.user_id}/items",
            json={"productId": product_id, "quantity": 1},
            timeout=TIMEOUT,
        )
        response.raise_for_status()
        flash("Added to your cart.")
    except requests.RequestException as exc:
        log.error("add to cart failed", extra={"fields": {"error": str(exc), "productId": product_id}})
        flash("Could not add the item. Please try again.")
    return redirect(url_for("index"))


@app.get("/cart")
def view_cart():
    try:
        cart = get_cart(g.user_id)
        catalog = {p["id"]: p for p in get_products()}
    except requests.RequestException:
        return render_template("error.html", message="Your cart is unavailable right now."), 503

    lines, total = [], 0
    for item in cart.get("items", []):
        product = catalog.get(item["productId"])
        if not product:
            continue
        line_total = product["priceCents"] * item["quantity"]
        total += line_total
        lines.append({"product": product, "quantity": item["quantity"], "line_total": line_total})
    return render_template("cart.html", lines=lines, total=total, cart_count=cart.get("totalItems", 0))


@app.post("/cart/remove")
def remove_from_cart():
    product_id = request.form.get("product_id", "")
    try:
        requests.delete(f"{CART_URL}/cart/{g.user_id}/items/{product_id}", timeout=TIMEOUT).raise_for_status()
    except requests.RequestException:
        flash("Could not remove the item.")
    return redirect(url_for("view_cart"))


@app.post("/checkout")
def checkout():
    try:
        response = requests.post(f"{ORDERS_URL}/orders", json={"userId": g.user_id}, timeout=15)
    except requests.RequestException as exc:
        log.error("checkout failed", extra={"fields": {"error": str(exc)}})
        CHECKOUTS.labels("unavailable").inc()
        flash("Checkout is unavailable right now.")
        return redirect(url_for("view_cart"))

    order = response.json() if response.content else {}
    if response.status_code == 201:
        CHECKOUTS.labels("confirmed").inc()
        log.info("checkout completed", extra={"fields": {"orderId": order.get("id"), "userId": g.user_id}})
        flash(f"Thank you! Order {order.get('id')} is confirmed.")
        return redirect(url_for("view_orders"))
    if response.status_code == 402:
        CHECKOUTS.labels("payment_declined").inc()
        flash("Payment was declined (the demo limit is £500). Remove some items and try again.")
    elif response.status_code == 409:
        CHECKOUTS.labels("out_of_stock").inc()
        flash("Sorry, we do not have enough stock for one of your items. Lower the quantity and try again.")
    else:
        CHECKOUTS.labels("failed").inc()
        flash(order.get("error", "Checkout failed."))
    return redirect(url_for("view_cart"))


@app.get("/orders")
def view_orders():
    try:
        response = requests.get(f"{ORDERS_URL}/orders", params={"userId": g.user_id}, timeout=TIMEOUT)
        response.raise_for_status()
        orders = response.json()
        cart_count = get_cart(g.user_id).get("totalItems", 0)
    except requests.RequestException:
        return render_template("error.html", message="Order history is unavailable right now."), 503
    return render_template("orders.html", orders=orders, cart_count=cart_count)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), debug=False)
