package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

const (
	listingTTL       = 30 * 24 * time.Hour
	maxSellerListing = 20
	maxListingsTotal = 50000
	maxListingsShown = 100
)

var (
	errTooManyListing = errors.New("too_many_listings")
	errMarketFull     = errors.New("marketplace_full")
)

// Listing is public by design: unlike chats, Marketplace posts are not encrypted.
type Listing struct {
	ID          string `json:"id"`
	Seller      string `json:"seller"`
	SellerName  string `json:"seller_name"`
	Title       string `json:"title"`
	Price       string `json:"price"`
	Description string `json:"description"`
	Category    string `json:"category"`
	CreatedAt   int64  `json:"created_at"`
}

func (s *Store) PostListing(l *Listing) error {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return err
	}
	l.ID = hex.EncodeToString(raw)
	l.CreatedAt = time.Now().UnixMilli()
	ctx, cancel := ctxDB()
	defer cancel()
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		// Serializes one seller's posts so concurrent ones cannot pass the cap together.
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, l.Seller); err != nil {
			return err
		}
		var mine int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.market WHERE seller = $1`, l.Seller).Scan(&mine); err != nil {
			return err
		}
		if mine >= maxSellerListing {
			return errTooManyListing
		}
		var total int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM sync_gateway.market`).Scan(&total); err != nil {
			return err
		}
		if total >= maxListingsTotal {
			return errMarketFull
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO sync_gateway.market (id, seller, seller_name, title, price, description, category, created_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
			l.ID, l.Seller, l.SellerName, l.Title, l.Price, l.Description, l.Category, l.CreatedAt)
		return err
	})
}

// DeleteListing removes the listing only if owner posted it.
func (s *Store) DeleteListing(id, owner string) (bool, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	tag, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.market WHERE id = $1 AND seller = $2`, id, owner)
	return tag.RowsAffected() > 0, err
}

// Listings returns live listings, newest first, matching q in title or description.
func (s *Store) Listings(q string, now time.Time) ([]Listing, error) {
	ctx, cancel := ctxDB()
	defer cancel()
	cutoff := now.Add(-listingTTL).UnixMilli()
	pattern := "%" + escapeLike(strings.ToLower(strings.TrimSpace(q))) + "%"
	rows, err := s.db.Query(ctx, `
		SELECT id, seller, seller_name, title, price, description, category, created_at
		FROM sync_gateway.market
		WHERE created_at >= $1 AND ($2 = '%%' OR lower(title || ' ' || description) LIKE $2)
		ORDER BY created_at DESC LIMIT $3`, cutoff, pattern, maxListingsShown)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Listing{}
	for rows.Next() {
		var l Listing
		if err := rows.Scan(&l.ID, &l.Seller, &l.SellerName, &l.Title, &l.Price, &l.Description, &l.Category, &l.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

func (s *Store) SweepListings(ctx context.Context, now time.Time) error {
	_, err := s.db.Exec(ctx, `DELETE FROM sync_gateway.market WHERE created_at < $1`, now.Add(-listingTTL).UnixMilli())
	return err
}

func (c *Conn) handleMarket(f *inFrame) {
	h := c.hub
	switch f.T {
	case "market_list":
		items, err := h.store.Listings(f.Q, time.Now())
		if err != nil {
			log.Printf("listings: %v", err)
			c.reply(f, map[string]any{"ok": false, "error": "server_error"})
			return
		}
		c.reply(f, map[string]any{"ok": true, "items": items})
	case "market_post":
		title, price := strings.TrimSpace(f.Title), strings.TrimSpace(f.Price)
		if title == "" || price == "" || utf8.RuneCountInString(title) > 80 ||
			utf8.RuneCountInString(price) > 32 || utf8.RuneCountInString(f.Description) > 2000 ||
			utf8.RuneCountInString(f.Category) > 32 {
			c.reply(f, map[string]any{"ok": false, "error": "bad_request"})
			return
		}
		seller, err := h.store.User(c.id)
		if err != nil || seller == nil {
			c.reply(f, map[string]any{"ok": false, "error": "server_error"})
			return
		}
		l := Listing{Seller: c.id, SellerName: seller.DisplayName, Title: title, Price: price,
			Description: f.Description, Category: f.Category}
		if err := h.store.PostListing(&l); err != nil {
			if errors.Is(err, errTooManyListing) || errors.Is(err, errMarketFull) {
				c.reply(f, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			log.Printf("post listing: %v", err)
			c.reply(f, map[string]any{"ok": false, "error": "server_error"})
			return
		}
		c.reply(f, map[string]any{"ok": true, "item": l})
	case "market_delete":
		ok, err := h.store.DeleteListing(f.ID, c.id)
		if err != nil {
			log.Printf("delete listing: %v", err)
			c.reply(f, map[string]any{"ok": false, "error": "server_error"})
			return
		}
		if !ok {
			c.reply(f, map[string]any{"ok": false, "error": "not_found"})
			return
		}
		c.reply(f, map[string]any{"ok": true})
	}
}
