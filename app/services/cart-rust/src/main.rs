//! KubeMart cart service (Rust, axum).
//!
//! GET    /health                               liveness/readiness
//! GET    /cart/{user_id}                       view a cart
//! POST   /cart/{user_id}/items                 add {"productId": "...", "quantity": 1}
//! DELETE /cart/{user_id}/items/{product_id}    remove one product
//! DELETE /cart/{user_id}                       empty the cart (used by orders after checkout)
//! GET    /metrics                              Prometheus metrics
//!
//! Carts live in Valkey (the open-source Redis fork): one hash per shopper,
//! "cart:<user>" -> {productId: quantity}, which expires after CART_TTL_DAYS
//! without activity. Every replica of this service sees the same carts, and
//! carts survive restarts because Valkey writes them to its disk (AOF).
//! Without VALKEY_ADDR carts are kept in memory (tests and quick demos only).

use std::{
    collections::HashMap,
    env,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use axum::{
    extract::{MatchedPath, Path, Request, State},
    http::{header, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use prometheus::{
    Encoder, HistogramOpts, HistogramVec, IntCounterVec, Opts, Registry, TextEncoder,
};
use redis::{aio::ConnectionManager, AsyncCommands};
use serde::{Deserialize, Serialize};
use serde_json::json;

const MAX_QUANTITY: u32 = 99;

// ---------------------------------------------------------------- storage --

/// Adds to a product's quantity, caps it at 99 and refreshes the expiry, in one
/// atomic step inside Valkey (two requests at once can never lose an update).
const ADD_SCRIPT: &str = r#"
local q = redis.call('HINCRBY', KEYS[1], ARGV[1], ARGV[2])
if q > tonumber(ARGV[3]) then
  redis.call('HSET', KEYS[1], ARGV[1], ARGV[3])
end
redis.call('EXPIRE', KEYS[1], ARGV[4])
return 1
"#;

#[derive(Clone)]
enum Backend {
    Memory(Arc<Mutex<HashMap<String, HashMap<String, u32>>>>),
    Valkey {
        conn: ConnectionManager,
        ttl_seconds: i64,
        add: Arc<redis::Script>,
    },
}

fn key(user_id: &str) -> String {
    format!("cart:{user_id}")
}

impl Backend {
    async fn get(&self, user_id: &str) -> redis::RedisResult<HashMap<String, u32>> {
        match self {
            Backend::Memory(m) => Ok(m.lock().unwrap().get(user_id).cloned().unwrap_or_default()),
            Backend::Valkey { conn, .. } => conn.clone().hgetall(key(user_id)).await,
        }
    }

    async fn add(&self, user_id: &str, product_id: &str, quantity: u32) -> redis::RedisResult<()> {
        match self {
            Backend::Memory(m) => {
                let mut carts = m.lock().unwrap();
                let qty = carts
                    .entry(user_id.to_string())
                    .or_default()
                    .entry(product_id.to_string())
                    .or_insert(0);
                *qty = (*qty + quantity).min(MAX_QUANTITY);
                Ok(())
            }
            Backend::Valkey {
                conn,
                ttl_seconds,
                add,
            } => add
                .key(key(user_id))
                .arg(product_id)
                .arg(quantity)
                .arg(MAX_QUANTITY)
                .arg(*ttl_seconds)
                .invoke_async::<i64>(&mut conn.clone())
                .await
                .map(|_| ()),
        }
    }

    async fn remove(&self, user_id: &str, product_id: &str) -> redis::RedisResult<()> {
        match self {
            Backend::Memory(m) => {
                if let Some(cart) = m.lock().unwrap().get_mut(user_id) {
                    cart.remove(product_id);
                }
                Ok(())
            }
            Backend::Valkey { conn, .. } => conn.clone().hdel(key(user_id), product_id).await,
        }
    }

    async fn clear(&self, user_id: &str) -> redis::RedisResult<()> {
        match self {
            Backend::Memory(m) => {
                m.lock().unwrap().remove(user_id);
                Ok(())
            }
            Backend::Valkey { conn, .. } => conn.clone().del(key(user_id)).await,
        }
    }
}

// ---------------------------------------------------------------- metrics --

#[derive(Clone)]
struct Metrics {
    registry: Registry,
    requests: IntCounterVec,
    duration: HistogramVec,
    items_added: IntCounterVec,
    store_errors: IntCounterVec,
}

impl Metrics {
    fn new() -> Self {
        let registry = Registry::new();
        let requests = IntCounterVec::new(
            Opts::new(
                "http_requests_total",
                "HTTP requests by method, route and status code.",
            ),
            &["method", "route", "status"],
        )
        .unwrap();
        let duration = HistogramVec::new(
            HistogramOpts::new(
                "http_request_duration_seconds",
                "HTTP request duration by method and route.",
            )
            .buckets(vec![
                0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0,
            ]),
            &["method", "route"],
        )
        .unwrap();
        let items_added = IntCounterVec::new(
            Opts::new("cart_items_added_total", "Items added to carts."),
            &["result"],
        )
        .unwrap();
        let store_errors = IntCounterVec::new(
            Opts::new("cart_store_errors_total", "Failed Valkey operations."),
            &["operation"],
        )
        .unwrap();
        for c in [&requests, &items_added, &store_errors] {
            registry.register(Box::new(c.clone())).unwrap();
        }
        registry.register(Box::new(duration.clone())).unwrap();
        // Start every series at 0, so dashboards show "0 errors" instead of "no data"
        for op in ["get", "add", "remove", "clear"] {
            store_errors.with_label_values(&[op]);
        }
        for result in ["ok", "rejected"] {
            items_added.with_label_values(&[result]);
        }
        Metrics {
            registry,
            requests,
            duration,
            items_added,
            store_errors,
        }
    }
}

// ------------------------------------------------------------------- HTTP --

#[derive(Clone)]
struct AppState {
    backend: Backend,
    metrics: Metrics,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CartItem {
    product_id: String,
    quantity: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Cart {
    user_id: String,
    items: Vec<CartItem>,
    total_items: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddItem {
    product_id: String,
    quantity: u32,
}

type ApiError = (StatusCode, Json<serde_json::Value>);

/// One JSON log line per event (collected by Grafana Alloy into Loki)
fn log(level: &str, message: &str, fields: serde_json::Value) {
    let mut line = json!({ "log.level": level, "service.name": "cart", "message": message });
    if let (Some(obj), Some(extra)) = (line.as_object_mut(), fields.as_object()) {
        for (k, v) in extra {
            obj.insert(k.clone(), v.clone());
        }
    }
    println!("{line}");
}

fn build_cart(user_id: &str, items: HashMap<String, u32>) -> Cart {
    let mut list: Vec<CartItem> = items
        .into_iter()
        .map(|(product_id, quantity)| CartItem {
            product_id,
            quantity,
        })
        .collect();
    list.sort_by(|a, b| a.product_id.cmp(&b.product_id));
    let total_items = list.iter().map(|i| i.quantity).sum();
    Cart {
        user_id: user_id.to_string(),
        items: list,
        total_items,
    }
}

/// Valkey is unreachable: tell the caller to retry instead of losing the request.
fn store_error(state: &AppState, operation: &str, err: redis::RedisError) -> ApiError {
    state
        .metrics
        .store_errors
        .with_label_values(&[operation])
        .inc();
    log(
        "error",
        "cart store unavailable",
        json!({ "operation": operation, "error": err.to_string() }),
    );
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({ "error": "cart temporarily unavailable" })),
    )
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok", "service": "cart" }))
}

async fn get_cart(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> Result<Json<Cart>, ApiError> {
    let items = state
        .backend
        .get(&user_id)
        .await
        .map_err(|e| store_error(&state, "get", e))?;
    Ok(Json(build_cart(&user_id, items)))
}

async fn add_item(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    Json(body): Json<AddItem>,
) -> Result<(StatusCode, Json<Cart>), ApiError> {
    if body.quantity == 0 || body.quantity > MAX_QUANTITY || body.product_id.is_empty() {
        state
            .metrics
            .items_added
            .with_label_values(&["rejected"])
            .inc();
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "productId is required and quantity must be between 1 and 99" })),
        ));
    }
    state
        .backend
        .add(&user_id, &body.product_id, body.quantity)
        .await
        .map_err(|e| store_error(&state, "add", e))?;
    state
        .metrics
        .items_added
        .with_label_values(&["ok"])
        .inc_by(u64::from(body.quantity));
    log(
        "info",
        "item added",
        json!({ "userId": user_id, "productId": body.product_id, "quantity": body.quantity }),
    );
    let items = state
        .backend
        .get(&user_id)
        .await
        .map_err(|e| store_error(&state, "get", e))?;
    Ok((StatusCode::CREATED, Json(build_cart(&user_id, items))))
}

async fn remove_item(
    State(state): State<AppState>,
    Path((user_id, product_id)): Path<(String, String)>,
) -> Result<Json<Cart>, ApiError> {
    state
        .backend
        .remove(&user_id, &product_id)
        .await
        .map_err(|e| store_error(&state, "remove", e))?;
    log(
        "info",
        "item removed",
        json!({ "userId": user_id, "productId": product_id }),
    );
    let items = state
        .backend
        .get(&user_id)
        .await
        .map_err(|e| store_error(&state, "get", e))?;
    Ok(Json(build_cart(&user_id, items)))
}

async fn clear_cart(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    state
        .backend
        .clear(&user_id)
        .await
        .map_err(|e| store_error(&state, "clear", e))?;
    log("info", "cart cleared", json!({ "userId": user_id }));
    Ok(StatusCode::NO_CONTENT)
}

async fn metrics(State(state): State<AppState>) -> Response {
    let mut buf = Vec::new();
    let encoder = TextEncoder::new();
    if encoder
        .encode(&state.metrics.registry.gather(), &mut buf)
        .is_err()
    {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    (
        [(header::CONTENT_TYPE, encoder.format_type().to_string())],
        buf,
    )
        .into_response()
}

/// Records request count and duration, labelled with the route pattern
/// ("/cart/{user_id}"), never the raw path, so the number of series stays small.
async fn track(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let start = Instant::now();
    let method = req.method().to_string();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map_or("unmatched", |p| p.as_str())
        .to_string();
    let response = next.run(req).await;
    let status = response.status().as_u16().to_string();
    state
        .metrics
        .requests
        .with_label_values(&[&method, &route, &status])
        .inc();
    state
        .metrics
        .duration
        .with_label_values(&[&method, &route])
        .observe(start.elapsed().as_secs_f64());
    response
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/metrics", get(metrics))
        .route("/cart/{user_id}", get(get_cart).delete(clear_cart))
        .route("/cart/{user_id}/items", post(add_item))
        .route("/cart/{user_id}/items/{product_id}", delete(remove_item))
        .route_layer(middleware::from_fn_with_state(state.clone(), track))
        .with_state(state)
}

// ---------------------------------------------------------------- startup --

/// Connects to Valkey, retrying for up to a minute (Valkey may start after us).
async fn connect_valkey(addr: &str, password: &str) -> ConnectionManager {
    let url = if password.is_empty() {
        format!("redis://{addr}/")
    } else {
        format!("redis://:{password}@{addr}/")
    };
    let client = redis::Client::open(url).expect("invalid VALKEY_ADDR");
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        match ConnectionManager::new(client.clone()).await {
            Ok(conn) => return conn,
            Err(err) if Instant::now() < deadline => {
                log(
                    "warn",
                    "waiting for Valkey",
                    json!({ "addr": addr, "error": err.to_string() }),
                );
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
            Err(err) => {
                log(
                    "error",
                    "cannot reach Valkey",
                    json!({ "addr": addr, "error": err.to_string() }),
                );
                std::process::exit(1);
            }
        }
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    log("info", "shutting down", json!({}));
}

#[tokio::main]
async fn main() {
    let port = env::var("PORT").unwrap_or_else(|_| "8080".to_string());

    let backend = match env::var("VALKEY_ADDR") {
        Ok(addr) if !addr.is_empty() => {
            let password = env::var("VALKEY_PASSWORD").unwrap_or_default();
            let days: i64 = env::var("CART_TTL_DAYS")
                .ok()
                .and_then(|d| d.parse().ok())
                .unwrap_or(30);
            let conn = connect_valkey(&addr, &password).await;
            log(
                "info",
                "storing carts in Valkey",
                json!({ "addr": addr, "ttlDays": days }),
            );
            Backend::Valkey {
                conn,
                ttl_seconds: days * 86_400,
                add: Arc::new(redis::Script::new(ADD_SCRIPT)),
            }
        }
        _ => {
            log(
                "warn",
                "VALKEY_ADDR is not set: carts are kept in memory and lost on restart",
                json!({}),
            );
            Backend::Memory(Arc::default())
        }
    };
    let state = AppState {
        backend,
        metrics: Metrics::new(),
    };

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{port}"))
        .await
        .expect("failed to bind port");
    log("info", "starting", json!({ "port": port }));

    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}

// ------------------------------------------------------------------ tests --

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn state_with(backend: Backend) -> AppState {
        AppState {
            backend,
            metrics: Metrics::new(),
        }
    }

    async fn call(
        router: &Router,
        method: &str,
        uri: &str,
        body: Option<serde_json::Value>,
    ) -> (StatusCode, String) {
        let mut req = axum::http::Request::builder().method(method).uri(uri);
        let body = match body {
            Some(v) => {
                req = req.header("content-type", "application/json");
                Body::from(v.to_string())
            }
            None => Body::empty(),
        };
        let resp = router
            .clone()
            .oneshot(req.body(body).unwrap())
            .await
            .unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8(bytes.to_vec()).unwrap())
    }

    async fn cart_flow(router: Router) {
        let user = format!("u-{}", std::process::id());
        let (s, _) = call(
            &router,
            "POST",
            &format!("/cart/{user}/items"),
            Some(json!({"productId": "p-1", "quantity": 2})),
        )
        .await;
        assert_eq!(s, StatusCode::CREATED);
        let (_, body) = call(
            &router,
            "POST",
            &format!("/cart/{user}/items"),
            Some(json!({"productId": "p-1", "quantity": 98})),
        )
        .await;
        let cart: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(cart["items"][0]["quantity"], 99, "quantity is capped at 99");

        call(
            &router,
            "POST",
            &format!("/cart/{user}/items"),
            Some(json!({"productId": "p-2", "quantity": 1})),
        )
        .await;
        let (_, body) = call(&router, "DELETE", &format!("/cart/{user}/items/p-1"), None).await;
        let cart: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(cart["totalItems"], 1);

        let (s, _) = call(&router, "DELETE", &format!("/cart/{user}"), None).await;
        assert_eq!(s, StatusCode::NO_CONTENT);
        let (_, body) = call(&router, "GET", &format!("/cart/{user}"), None).await;
        let cart: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(cart["totalItems"], 0);
    }

    #[tokio::test]
    async fn memory_cart_flow() {
        cart_flow(app(state_with(Backend::Memory(Arc::default())))).await;
    }

    #[tokio::test]
    async fn rejects_bad_quantity() {
        let router = app(state_with(Backend::Memory(Arc::default())));
        let (s, _) = call(
            &router,
            "POST",
            "/cart/u/items",
            Some(json!({"productId": "p-1", "quantity": 0})),
        )
        .await;
        assert_eq!(s, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn metrics_use_route_patterns() {
        let router = app(state_with(Backend::Memory(Arc::default())));
        call(&router, "GET", "/cart/alice", None).await;
        let (_, body) = call(&router, "GET", "/metrics", None).await;
        assert!(body.contains(r#"route="/cart/{user_id}""#), "{body}");
        assert!(!body.contains("alice"));
    }

    /// Runs only with TEST_VALKEY_ADDR set, e.g. TEST_VALKEY_ADDR=127.0.0.1:6379
    #[tokio::test]
    async fn valkey_cart_flow() {
        let Ok(addr) = env::var("TEST_VALKEY_ADDR") else {
            return;
        };
        let password = env::var("TEST_VALKEY_PASSWORD").unwrap_or_default();
        let conn = connect_valkey(&addr, &password).await;
        let backend = Backend::Valkey {
            conn: conn.clone(),
            ttl_seconds: 120,
            add: Arc::new(redis::Script::new(ADD_SCRIPT)),
        };
        cart_flow(app(state_with(backend.clone()))).await;

        // Concurrent adds must never lose an update
        let mut tasks = Vec::new();
        for _ in 0..20 {
            let b = backend.clone();
            tasks.push(tokio::spawn(async move {
                b.add("race", "p-9", 1).await.unwrap()
            }));
        }
        for t in tasks {
            t.await.unwrap();
        }
        assert_eq!(backend.get("race").await.unwrap()["p-9"], 20);
        let ttl: i64 = conn.clone().ttl("cart:race").await.unwrap();
        assert!(ttl > 0 && ttl <= 120, "carts must expire, ttl={ttl}");
        backend.clear("race").await.unwrap();
    }
}
