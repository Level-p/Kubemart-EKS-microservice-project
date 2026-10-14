"""KubeMart payment service (Python, FastAPI).

POST /payments   {"orderId", "userId", "amountCents", "currency"} -> approved or declined
GET  /payments/{payment_id}
GET  /health
GET  /metrics    Prometheus metrics

This is a fake payment provider for learning. Rules:
  * amounts above PAYMENT_LIMIT_CENTS (default 50000 = 500.00) are declined
  * everything else is approved
A declined payment is a normal business result, so it returns HTTP 200 with
status "declined" (the orders service decides what to do with it).

Payments are stored in PostgreSQL (database "payments" on the kubemart-db
cluster). Without DB_HOST they are kept in memory (tests and quick demos only).
"""
import json
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.concurrency import run_in_threadpool
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

from store import MemoryStore, PaymentStore, PostgresStore, conninfo_from_env

LIMIT_CENTS = int(os.getenv("PAYMENT_LIMIT_CENTS", "50000"))

# ---- Metrics ----
HTTP_REQUESTS = Counter("http_requests_total", "HTTP requests by method, route and status code.",
                        ["method", "route", "status"])
HTTP_DURATION = Histogram("http_request_duration_seconds", "HTTP request duration by method and route.",
                          ["method", "route"], buckets=(.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5))
PAYMENTS = Counter("payments_total", "Payments by result (approved, declined).", ["status"])
PAYMENT_AMOUNT = Counter("payment_amount_cents_total", "Value of payments by result, in cents.", ["status"])


class JsonFormatter(logging.Formatter):
    """One JSON object per log line, ready for Grafana Alloy and Loki."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "@timestamp": datetime.now(timezone.utc).isoformat(),
            "log.level": record.levelname.lower(),
            "service.name": "payment",
            "message": record.getMessage(),
        }
        entry.update(getattr(record, "fields", {}))
        return json.dumps(entry)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("payment")
log.addHandler(handler)
log.setLevel(logging.INFO)
log.propagate = False


class PaymentRequest(BaseModel):
    orderId: str = Field(min_length=1)
    userId: str = Field(min_length=1)
    amountCents: int = Field(ge=0)
    currency: str = "GBP"


class PaymentResponse(BaseModel):
    paymentId: str
    orderId: str
    status: str
    reason: str | None = None


def create_store() -> PaymentStore:
    conninfo = conninfo_from_env()
    if conninfo is None:
        log.warning("DB_HOST is not set: payments are kept in memory and lost on restart")
        return MemoryStore()
    store = PostgresStore(conninfo)
    log.info("connected to PostgreSQL", extra={"fields": {"host": os.getenv("DB_HOST")}})
    return store


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.store = create_store()
    yield
    if isinstance(app.state.store, PostgresStore):
        app.state.store.close()


app = FastAPI(title="KubeMart Payment", version="1.1.0", lifespan=lifespan)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    # The route template ("/payments/{payment_id}"), never the raw path
    route = getattr(request.scope.get("route"), "path", "unmatched")
    HTTP_REQUESTS.labels(request.method, route, str(response.status_code)).inc()
    HTTP_DURATION.labels(request.method, route).observe(time.perf_counter() - start)
    return response


def to_response(row: dict) -> PaymentResponse:
    return PaymentResponse(paymentId=row["id"], orderId=row["order_id"], status=row["status"], reason=row["reason"])


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "service": "payment"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/payments", response_model=PaymentResponse)
async def create_payment(request: PaymentRequest) -> PaymentResponse:
    if request.amountCents > LIMIT_CENTS:
        status = "declined"
        reason = f"amount exceeds limit of {LIMIT_CENTS / 100:.2f} {request.currency}"
    else:
        status, reason = "approved", None

    payment = {
        "id": f"pay-{uuid.uuid4().hex[:10]}",
        "order_id": request.orderId,
        "user_id": request.userId,
        "amount_cents": request.amountCents,
        "currency": request.currency,
        "status": status,
        "reason": reason,
    }
    try:
        stored, created = await run_in_threadpool(app.state.store.save_once, payment)
    except Exception as exc:  # database unreachable: the order is not charged
        log.error("payment store unavailable", extra={"fields": {"orderId": request.orderId, "error": str(exc)}})
        raise HTTPException(status_code=503, detail="payment service temporarily unavailable") from exc

    if created:
        PAYMENTS.labels(stored["status"]).inc()
        PAYMENT_AMOUNT.labels(stored["status"]).inc(stored["amount_cents"])
    log.info(
        "payment processed" if created else "duplicate payment request, returning the first result",
        extra={"fields": {
            "paymentId": stored["id"],
            "orderId": request.orderId,
            "userId": request.userId,
            "amountCents": request.amountCents,
            "paymentStatus": stored["status"],
        }},
    )
    return to_response(stored)


@app.get("/payments/{payment_id}", response_model=PaymentResponse)
async def get_payment(payment_id: str) -> PaymentResponse:
    row = await run_in_threadpool(app.state.store.get, payment_id)
    if row is None:
        raise HTTPException(status_code=404, detail="payment not found")
    return to_response(row)
