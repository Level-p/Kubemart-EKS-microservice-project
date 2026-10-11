package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Product is the JSON contract shared with cart, orders and frontend.
type Product struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Category    string `json:"category"`
	PriceCents  int64  `json:"priceCents"`
	Currency    string `json:"currency"`
	ImageURL    string `json:"imageUrl"`
	Stock       int    `json:"stock"`
}

var (
	ErrNotFound          = errors.New("product not found")
	ErrInsufficientStock = errors.New("not enough stock")
)

// Store is where products live: PostgreSQL in Kubernetes, memory in tests.
type Store interface {
	List(ctx context.Context) ([]Product, error)
	// Reserve takes quantity items out of stock, all or nothing.
	Reserve(ctx context.Context, id string, quantity int) (Product, error)
	// Release puts quantity items back (an order was not paid).
	Release(ctx context.Context, id string, quantity int) (Product, error)
	Ping(ctx context.Context) error
}

// seedProducts fills an empty catalog on first start.
var seedProducts = []Product{
	{"p-1001", "Cloud Hoodie", "Warm hoodie for long deploy nights.", "clothing", 4500, "GBP", "https://picsum.photos/seed/hoodie/400/300", 40},
	{"p-1002", "Container Mug", "Holds 350 ml of coffee. Immutable.", "kitchen", 1200, "GBP", "https://picsum.photos/seed/mug/400/300", 120},
	{"p-1003", "Pod Sticker Pack", "Ten vinyl stickers for your laptop.", "accessories", 600, "GBP", "https://picsum.photos/seed/stickers/400/300", 300},
	{"p-1004", "Helm Wheel Lamp", "Desk lamp shaped like a ship's wheel.", "home", 3900, "GBP", "https://picsum.photos/seed/lamp/400/300", 15},
	{"p-1005", "GitOps Notebook", "A5 dotted notebook, 120 pages.", "stationery", 900, "GBP", "https://picsum.photos/seed/notebook/400/300", 80},
	{"p-1006", "Mechanical Keyboard", "Tactile switches, made for YAML.", "electronics", 8900, "GBP", "https://picsum.photos/seed/keyboard/400/300", 25},
	{"p-1007", "Noise-cancelling Headphones", "Silence the pager. Briefly.", "electronics", 15900, "GBP", "https://picsum.photos/seed/headphones/400/300", 10},
	{"p-1008", "Cluster Backpack", "Fits a laptop and three node pools.", "accessories", 6400, "GBP", "https://picsum.photos/seed/backpack/400/300", 30},
}

// ---- Memory store (tests and "go run" without a database) ----

type MemoryStore struct {
	mu       sync.Mutex
	products []Product
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{products: slices.Clone(seedProducts)}
}

func (m *MemoryStore) List(context.Context) ([]Product, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return slices.Clone(m.products), nil
}

func (m *MemoryStore) change(id string, delta int) (Product, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.products {
		if m.products[i].ID == id {
			if m.products[i].Stock+delta < 0 {
				return m.products[i], ErrInsufficientStock
			}
			m.products[i].Stock += delta
			return m.products[i], nil
		}
	}
	return Product{}, ErrNotFound
}

func (m *MemoryStore) Reserve(_ context.Context, id string, q int) (Product, error) {
	return m.change(id, -q)
}

func (m *MemoryStore) Release(_ context.Context, id string, q int) (Product, error) {
	return m.change(id, q)
}

func (m *MemoryStore) Ping(context.Context) error { return nil }

// ---- PostgreSQL store ----

type PostgresStore struct {
	pool *pgxpool.Pool
}

const schema = `
CREATE TABLE IF NOT EXISTS products (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    category    TEXT NOT NULL,
    price_cents BIGINT NOT NULL CHECK (price_cents >= 0),
    currency    TEXT NOT NULL DEFAULT 'GBP',
    image_url   TEXT NOT NULL DEFAULT '',
    stock       INTEGER NOT NULL CHECK (stock >= 0),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS products_category_idx ON products (category);`

// NewPostgresStore connects, creates the table and seeds an empty catalog.
// It retries for up to a minute: after a failover, or when the database starts
// after the app, the primary may not accept connections yet.
func NewPostgresStore(ctx context.Context, url string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	s := &PostgresStore{pool: pool}

	deadline := time.Now().Add(60 * time.Second)
	for {
		err = s.migrate(ctx)
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(3 * time.Second)
	}
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("prepare database: %w", err)
	}
	return s, nil
}

func (s *PostgresStore) migrate(ctx context.Context) error {
	if _, err := s.pool.Exec(ctx, schema); err != nil {
		return err
	}
	// ON CONFLICT DO NOTHING: several pods may start at the same time
	batch := &pgx.Batch{}
	for _, p := range seedProducts {
		batch.Queue(`INSERT INTO products (id, name, description, category, price_cents, currency, image_url, stock)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (id) DO NOTHING`,
			p.ID, p.Name, p.Description, p.Category, p.PriceCents, p.Currency, p.ImageURL, p.Stock)
	}
	return s.pool.SendBatch(ctx, batch).Close()
}

func (s *PostgresStore) List(ctx context.Context) ([]Product, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, description, category, price_cents, currency, image_url, stock
		FROM products ORDER BY id`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Product, error) {
		var p Product
		err := r.Scan(&p.ID, &p.Name, &p.Description, &p.Category, &p.PriceCents, &p.Currency, &p.ImageURL, &p.Stock)
		return p, err
	})
}

func (s *PostgresStore) change(ctx context.Context, id string, delta int) (Product, error) {
	// One statement, so two shoppers can never buy the last item twice:
	// the row is locked and the WHERE clause re-checked by PostgreSQL.
	var p Product
	err := s.pool.QueryRow(ctx, `UPDATE products SET stock = stock + $2, updated_at = now()
		WHERE id = $1 AND stock + $2 >= 0
		RETURNING id, name, description, category, price_cents, currency, image_url, stock`, id, delta).
		Scan(&p.ID, &p.Name, &p.Description, &p.Category, &p.PriceCents, &p.Currency, &p.ImageURL, &p.Stock)
	if errors.Is(err, pgx.ErrNoRows) {
		var exists bool
		if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM products WHERE id = $1)`, id).Scan(&exists); err != nil {
			return Product{}, err
		}
		if exists {
			return Product{}, ErrInsufficientStock
		}
		return Product{}, ErrNotFound
	}
	return p, err
}

func (s *PostgresStore) Reserve(ctx context.Context, id string, q int) (Product, error) {
	return s.change(ctx, id, -q)
}

func (s *PostgresStore) Release(ctx context.Context, id string, q int) (Product, error) {
	return s.change(ctx, id, q)
}

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *PostgresStore) Close() { s.pool.Close() }
