package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/redis/go-redis/v9"
)

// The whole catalog is cached as ONE Valkey key. Every product page and the
// category filter are served from it, and any stock change deletes it, so
// there is never more than one thing to invalidate.
const catalogCacheKey = "catalog:v1:products"

var cacheResults = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "catalog_cache_requests_total",
	Help: "Catalog cache lookups by result (hit, miss, error).",
}, []string{"result"})

// CachedStore wraps a Store with a Valkey read-through cache.
// Valkey being down never breaks the shop: reads fall back to PostgreSQL.
type CachedStore struct {
	Store
	rdb    *redis.Client
	ttl    time.Duration
	logger *slog.Logger
}

func NewCachedStore(s Store, rdb *redis.Client, ttl time.Duration, logger *slog.Logger) *CachedStore {
	return &CachedStore{Store: s, rdb: rdb, ttl: ttl, logger: logger}
}

func (c *CachedStore) List(ctx context.Context) ([]Product, error) {
	raw, err := c.rdb.Get(ctx, catalogCacheKey).Bytes()
	if err == nil {
		var products []Product
		if json.Unmarshal(raw, &products) == nil {
			cacheResults.WithLabelValues("hit").Inc()
			return products, nil
		}
	}
	if err == redis.Nil {
		cacheResults.WithLabelValues("miss").Inc()
	} else {
		cacheResults.WithLabelValues("error").Inc()
		c.logger.Warn("cache read failed", "error", err)
	}

	products, err := c.Store.List(ctx)
	if err != nil {
		return nil, err
	}
	if raw, err := json.Marshal(products); err == nil {
		if err := c.rdb.Set(ctx, catalogCacheKey, raw, c.ttl).Err(); err != nil {
			c.logger.Warn("cache write failed", "error", err)
		}
	}
	return products, nil
}

func (c *CachedStore) invalidate(ctx context.Context) {
	if err := c.rdb.Del(ctx, catalogCacheKey).Err(); err != nil {
		c.logger.Warn("cache invalidation failed", "error", err)
	}
}

func (c *CachedStore) Reserve(ctx context.Context, id string, q int) (Product, error) {
	p, err := c.Store.Reserve(ctx, id, q)
	if err == nil {
		c.invalidate(ctx)
	}
	return p, err
}

func (c *CachedStore) Release(ctx context.Context, id string, q int) (Product, error) {
	p, err := c.Store.Release(ctx, id, q)
	if err == nil {
		c.invalidate(ctx)
	}
	return p, err
}
