package main

// Runs only when TEST_DATABASE_URL points at a real PostgreSQL, e.g.
//   TEST_DATABASE_URL=postgres://postgres:pw@localhost:5432/catalog?sslmode=disable go test ./...

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
)

func TestPostgresStore(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	s, err := NewPostgresStore(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// A second start must not duplicate the seed data
	if _, err := NewPostgresStore(ctx, url); err != nil {
		t.Fatal(err)
	}
	products, err := s.List(ctx)
	if err != nil || len(products) != len(seedProducts) {
		t.Fatalf("expected %d products, got %d (%v)", len(seedProducts), len(products), err)
	}

	if _, err := s.Reserve(ctx, "nope", 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}

	// 20 shoppers race for the 15 lamps (p-1004): exactly 15 must succeed
	var ok atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Reserve(ctx, "p-1004", 1); err == nil {
				ok.Add(1)
			} else if !errors.Is(err, ErrInsufficientStock) {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if ok.Load() != 15 {
		t.Fatalf("expected 15 successful reservations, got %d", ok.Load())
	}
	if _, err := s.Release(ctx, "p-1004", 15); err != nil {
		t.Fatal(err)
	}
}
