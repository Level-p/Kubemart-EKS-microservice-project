package main

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

// countingStore counts how often the database is read.
type countingStore struct {
	*MemoryStore
	lists int
}

func (c *countingStore) List(ctx context.Context) ([]Product, error) {
	c.lists++
	return c.MemoryStore.List(ctx)
}

func TestCacheServesReadsAndIsClearedOnStockChange(t *testing.T) {
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	db := &countingStore{MemoryStore: NewMemoryStore()}
	s := NewCachedStore(db, rdb, time.Minute, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	ctx := context.Background()

	for range 3 {
		if _, err := s.List(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if db.lists != 1 {
		t.Fatalf("expected 1 database read for 3 requests, got %d", db.lists)
	}

	if _, err := s.Reserve(ctx, "p-1001", 1); err != nil {
		t.Fatal(err)
	}
	if mr.Exists(catalogCacheKey) {
		t.Fatal("a stock change must clear the cache")
	}
	products, _ := s.List(ctx)
	if db.lists != 2 || products[0].Stock != 39 {
		t.Fatalf("expected a fresh read showing stock 39, got reads=%d stock=%d", db.lists, products[0].Stock)
	}
}

func TestCacheDownFallsBackToDatabase(t *testing.T) {
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr(), MaxRetries: -1})
	s := NewCachedStore(NewMemoryStore(), rdb, time.Minute, slog.New(slog.NewJSONHandler(io.Discard, nil)))
	mr.Close() // Valkey is gone

	products, err := s.List(context.Background())
	if err != nil || len(products) != len(seedProducts) {
		t.Fatalf("expected the catalog from the database, got %d products (%v)", len(products), err)
	}
}
