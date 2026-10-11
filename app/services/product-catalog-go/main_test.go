package main

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() http.Handler {
	a := &api{store: NewMemoryStore(), logger: slog.New(slog.NewJSONHandler(io.Discard, nil))}
	return a.routes()
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
	return rec
}

func TestListProducts(t *testing.T) {
	rec := do(t, newTestServer(), http.MethodGet, "/products", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var got []Product
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != len(seedProducts) {
		t.Fatalf("expected %d products, got %d", len(seedProducts), len(got))
	}
}

func TestFilterByCategory(t *testing.T) {
	rec := do(t, newTestServer(), http.MethodGet, "/products?category=electronics", "")
	var got []Product
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if len(got) == 0 {
		t.Fatal("expected electronics products")
	}
	for _, p := range got {
		if p.Category != "electronics" {
			t.Fatalf("unexpected category %q", p.Category)
		}
	}
}

func TestGetProductNotFound(t *testing.T) {
	rec := do(t, newTestServer(), http.MethodGet, "/products/nope", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestReserveAndRelease(t *testing.T) {
	h := newTestServer()
	// p-1007 starts with 10 in stock
	rec := do(t, h, http.MethodPost, "/products/p-1007/reserve", `{"quantity": 4}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("reserve: expected 200, got %d: %s", rec.Code, rec.Body)
	}
	var p Product
	_ = json.Unmarshal(rec.Body.Bytes(), &p)
	if p.Stock != 6 {
		t.Fatalf("expected stock 6, got %d", p.Stock)
	}

	if rec := do(t, h, http.MethodPost, "/products/p-1007/reserve", `{"quantity": 7}`); rec.Code != http.StatusConflict {
		t.Fatalf("over-reserve: expected 409, got %d", rec.Code)
	}

	rec = do(t, h, http.MethodPost, "/products/p-1007/release", `{"quantity": 4}`)
	_ = json.Unmarshal(rec.Body.Bytes(), &p)
	if p.Stock != 10 {
		t.Fatalf("expected stock back to 10, got %d", p.Stock)
	}
}

func TestReserveValidation(t *testing.T) {
	h := newTestServer()
	if rec := do(t, h, http.MethodPost, "/products/p-1001/reserve", `{"quantity": 0}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if rec := do(t, h, http.MethodPost, "/products/nope/reserve", `{"quantity": 1}`); rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rec.Code)
	}
}

func TestMetricsUseRoutePatterns(t *testing.T) {
	h := newTestServer()
	do(t, h, http.MethodGet, "/products/p-1001", "")
	body := do(t, h, http.MethodGet, "/metrics", "").Body.String()
	if !strings.Contains(body, `route="/products/{id}"`) {
		t.Fatal("expected the route pattern as a metric label")
	}
	if strings.Contains(body, `route="/products/p-1001"`) {
		t.Fatal("raw paths must not become metric labels")
	}
}
