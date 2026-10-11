// KubeMart product-catalog service (Go).
//
// GET  /health                  liveness/readiness (the process is up)
// GET  /products                list products (optional ?category=)
// GET  /products/{id}           one product
// POST /products/{id}/reserve   {"quantity": 2} take items out of stock (409 if not enough)
// POST /products/{id}/release   {"quantity": 2} put items back (order not paid)
// GET  /metrics                 Prometheus metrics
//
// Products and stock live in PostgreSQL (database "catalog" on the kubemart-db
// cluster). The product list is cached in Valkey. Without DB_HOST the service
// keeps the catalog in memory, which is only meant for tests and quick demos.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests by method, route and status code.",
	}, []string{"method", "route", "status"})
	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request duration by method and route.",
		Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
	}, []string{"method", "route"})
	reservations = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "catalog_stock_reservations_total",
		Help: "Stock reservations and releases by result.",
	}, []string{"action", "result"})
)

type api struct {
	store  Store
	logger *slog.Logger
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (a *api) storeError(w http.ResponseWriter, err error) {
	a.logger.Error("database error", "error", err)
	writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "catalog temporarily unavailable"})
}

func (a *api) listProducts(w http.ResponseWriter, r *http.Request) {
	products, err := a.store.List(r.Context())
	if err != nil {
		a.storeError(w, err)
		return
	}
	category := strings.ToLower(r.URL.Query().Get("category"))
	result := make([]Product, 0, len(products))
	for _, p := range products {
		if category == "" || p.Category == category {
			result = append(result, p)
		}
	}
	writeJSON(w, http.StatusOK, result)
}

func (a *api) getProduct(w http.ResponseWriter, r *http.Request) {
	products, err := a.store.List(r.Context())
	if err != nil {
		a.storeError(w, err)
		return
	}
	id := r.PathValue("id")
	for _, p := range products {
		if p.ID == id {
			writeJSON(w, http.StatusOK, p)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "product not found", "id": id})
}

// changeStock handles both /reserve and /release.
func (a *api) changeStock(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Quantity int `json:"quantity"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Quantity < 1 || body.Quantity > 99 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "quantity must be between 1 and 99"})
			return
		}
		id := r.PathValue("id")
		var p Product
		var err error
		if action == "reserve" {
			p, err = a.store.Reserve(r.Context(), id, body.Quantity)
		} else {
			p, err = a.store.Release(r.Context(), id, body.Quantity)
		}
		switch {
		case errors.Is(err, ErrNotFound):
			reservations.WithLabelValues(action, "not_found").Inc()
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "product not found", "id": id})
		case errors.Is(err, ErrInsufficientStock):
			reservations.WithLabelValues(action, "insufficient_stock").Inc()
			writeJSON(w, http.StatusConflict, map[string]string{"error": "not enough stock", "id": id})
		case err != nil:
			reservations.WithLabelValues(action, "error").Inc()
			a.storeError(w, err)
		default:
			reservations.WithLabelValues(action, "ok").Inc()
			a.logger.Info("stock "+action+"d", "productId", id, "quantity", body.Quantity, "stock", p.Stock)
			writeJSON(w, http.StatusOK, p)
		}
	}
}

func (a *api) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": "product-catalog"})
	})
	mux.HandleFunc("GET /products", a.listProducts)
	mux.HandleFunc("GET /products/{id}", a.getProduct)
	mux.HandleFunc("POST /products/{id}/reserve", a.changeStock("reserve"))
	mux.HandleFunc("POST /products/{id}/release", a.changeStock("release"))
	mux.Handle("GET /metrics", promhttp.Handler())
	return a.instrument(mux)
}

// instrument records metrics and writes one JSON log line per request
// (shipped to Elasticsearch by Fluent Bit).
func (a *api) instrument(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		mux.ServeHTTP(rec, r)

		// The route pattern ("/products/{id}"), never the raw path, keeps the
		// number of metric series small.
		_, route := mux.Handler(r)
		route = strings.TrimPrefix(strings.TrimPrefix(route, r.Method+" "), "GET ")
		if route == "" {
			route = "unmatched"
		}
		elapsed := time.Since(start)
		httpRequests.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
		httpDuration.WithLabelValues(r.Method, route).Observe(elapsed.Seconds())
		if route != "/health" && route != "/metrics" {
			a.logger.Info("request",
				"http.method", r.Method, "url.path", r.URL.Path, "http.status_code", rec.status,
				"duration_ms", elapsed.Milliseconds())
		}
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// databaseURL builds the connection string from the Secret the postgres-operator
// creates (DB_USER, DB_PASSWORD). The database only accepts TLS connections.
func databaseURL() string {
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(os.Getenv("DB_USER"), os.Getenv("DB_PASSWORD")),
		Host:     os.Getenv("DB_HOST") + ":" + getenv("DB_PORT", "5432"),
		Path:     getenv("DB_NAME", "catalog"),
		RawQuery: "sslmode=" + getenv("DB_SSLMODE", "require"),
	}
	return u.String()
}

func main() {
	// ECS-style field names so every service's logs share one Elasticsearch mapping
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.MessageKey:
				a.Key = "message"
			case slog.LevelKey:
				a.Key = "log.level"
				a.Value = slog.StringValue(strings.ToLower(a.Value.String()))
			}
			return a
		},
	})
	logger := slog.New(handler).With("service.name", "product-catalog")
	if err := run(logger); err != nil {
		logger.Error("startup failed", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx := context.Background()
	port := getenv("PORT", "8080")

	var store Store
	if os.Getenv("DB_HOST") == "" {
		logger.Warn("DB_HOST is not set: using an in-memory catalog (data is lost on restart)")
		store = NewMemoryStore()
	} else {
		pg, err := NewPostgresStore(ctx, databaseURL())
		if err != nil {
			return err
		}
		defer pg.Close()
		store = pg
		logger.Info("connected to PostgreSQL", "host", os.Getenv("DB_HOST"), "database", getenv("DB_NAME", "catalog"))
	}

	if addr := os.Getenv("VALKEY_ADDR"); addr != "" {
		rdb := redis.NewClient(&redis.Options{
			Addr:         addr,
			Password:     os.Getenv("VALKEY_PASSWORD"),
			DialTimeout:  2 * time.Second,
			ReadTimeout:  500 * time.Millisecond,
			WriteTimeout: 500 * time.Millisecond,
		})
		defer rdb.Close()
		ttl, err := time.ParseDuration(getenv("CACHE_TTL", "60s"))
		if err != nil {
			return fmt.Errorf("CACHE_TTL: %w", err)
		}
		store = NewCachedStore(store, rdb, ttl, logger)
		logger.Info("caching products in Valkey", "addr", addr, "ttl", ttl.String())
	}

	a := &api{store: store, logger: logger}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("starting", "port", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown when Kubernetes sends SIGTERM
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	shutdownCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	logger.Info("stopped")
	return nil
}
