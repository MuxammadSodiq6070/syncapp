package main

import (
	"context"
	"errors"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/anthropics/anthropic-sdk-go/v2/option"
	"github.com/anthropics/anthropic-sdk-go/v2/shared/constant"
)

const (
	aiMaxTurns      = 40
	aiMaxChars      = 20000
	aiMaxSystem     = 4000
	aiPerUserMinute = 20
	aiConcurrency   = 16
	aiPerUserActive = 2
	aiMaxTokens     = 4096 // a spend cap, and plenty for a chat reply
	aiTimeout       = 2 * time.Minute
	aiBaseSystem    = "You are an assistant inside the Sync messenger. Keep replies conversational and reasonably short. Reply in the language the user writes in."
)

var errAINotConfigured = errors.New("ai_not_configured")

type AITurn struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

// AIService is the optional assistant. Unlike chats, these conversations are not
// end-to-end encrypted: the gateway and the model provider see them.
type AIService struct {
	client anthropic.Client
	model  string
	slots  chan struct{}

	maxPerMinute int
	maxPerDay    int

	mu       sync.Mutex
	hits     map[string][]time.Time
	active   map[string]int
	minute   []time.Time
	dayStart time.Time
	dayCount int
}

func envInt(key string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return fallback
}

// NewAIService returns nil when no API key is configured; the feature then reports
// ai_not_configured to clients instead of failing on each request.
func NewAIService(opts ...option.RequestOption) *AIService {
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		return nil
	}
	model := os.Getenv("SYNC_AI_MODEL")
	if model == "" {
		model = "claude-opus-5-5"
	}
	return &AIService{
		client: anthropic.NewClient(opts...),
		model:  model,
		slots:  make(chan struct{}, aiConcurrency),
		hits:   map[string][]time.Time{},
		active: map[string]int{},

		maxPerMinute: envInt("SYNC_AI_MAX_PER_MINUTE", 60),
		maxPerDay:    envInt("SYNC_AI_MAX_PER_DAY", 2000),
	}
}

// allow admits one call. Keys are free, so the service-wide budgets are what actually
// bound spend; the per-user limits only keep one person from using all of it.
func (a *AIService) allow(user string, now time.Time) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	cutoff := now.Add(-time.Minute)
	if now.Sub(a.dayStart) >= 24*time.Hour {
		a.dayStart, a.dayCount = now, 0
	}
	if a.dayCount >= a.maxPerDay {
		return errors.New("ai_busy")
	}
	minute := a.minute[:0]
	for _, t := range a.minute {
		if t.After(cutoff) {
			minute = append(minute, t)
		}
	}
	a.minute = minute
	if len(a.minute) >= a.maxPerMinute {
		return errors.New("ai_busy")
	}
	if a.active[user] >= aiPerUserActive {
		return errors.New("rate_limited")
	}
	recent := a.hits[user][:0]
	for _, t := range a.hits[user] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}
	if len(recent) >= aiPerUserMinute {
		a.hits[user] = recent
		return errors.New("rate_limited")
	}
	a.hits[user] = append(recent, now)
	a.minute = append(a.minute, now)
	a.dayCount++
	a.active[user]++
	if len(a.hits) > 10000 { // memory bound
		for k, v := range a.hits {
			if len(v) == 0 || v[len(v)-1].Before(cutoff) {
				delete(a.hits, k)
			}
		}
	}
	return nil
}

func (a *AIService) finished(user string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.active[user]--; a.active[user] <= 0 {
		delete(a.active, user)
	}
}

func validateTurns(turns []AITurn, system string) bool {
	if len(turns) == 0 || len(turns) > aiMaxTurns || utf8.RuneCountInString(system) > aiMaxSystem {
		return false
	}
	total := 0
	for i, t := range turns {
		want := "user"
		if i%2 == 1 {
			want = "assistant"
		}
		if t.Role != want || strings.TrimSpace(t.Text) == "" {
			return false
		}
		total += utf8.RuneCountInString(t.Text)
	}
	return total <= aiMaxChars && turns[len(turns)-1].Role == "user"
}

// Reply returns the assistant's text, or an error code suitable for the client.
func (a *AIService) Reply(ctx context.Context, persona string, turns []AITurn) (string, error) {
	msgs := make([]anthropic.BetaMessageParam, 0, len(turns))
	for _, t := range turns {
		block := anthropic.NewBetaTextBlock(t.Text)
		if t.Role == "user" {
			msgs = append(msgs, anthropic.NewBetaUserMessage(block))
		} else {
			msgs = append(msgs, anthropic.BetaMessageParam{OfAssistant: &anthropic.BetaAssistantMessageParam{
				Content: []anthropic.BetaContentBlockParamUnion{block},
			}})
		}
	}
	system := aiBaseSystem
	if strings.TrimSpace(persona) != "" {
		system += "\n\nThe user configured this persona for you:\n" + persona
	}

	select {
	case a.slots <- struct{}{}:
		defer func() { <-a.slots }()
	case <-ctx.Done():
		return "", errors.New("ai_busy")
	}

	resp, err := a.client.Beta.Messages.New(ctx, anthropic.BetaMessageNewParams{
		Model:        a.model,
		MaxTokens:    aiMaxTokens,
		System:       []anthropic.BetaTextBlockParam{{Text: system}},
		Messages:     msgs,
		OutputConfig: anthropic.BetaOutputConfigParam{Effort: anthropic.BetaOutputConfigEffortLow},
		Fallbacks:    anthropic.BetaFallbacksParamUnion{OfDefault: constant.ValueOf[constant.Default]()},
		Betas:        []anthropic.AnthropicBeta{anthropic.AnthropicBetaServerSideFallback2026_07_01},
	})
	if err != nil {
		var apiErr *anthropic.Error
		if errors.As(err, &apiErr) {
			log.Printf("ai request failed with status %d", apiErr.StatusCode)
			if apiErr.StatusCode == 429 || apiErr.StatusCode == 529 {
				return "", errors.New("ai_busy")
			}
		} else {
			log.Printf("ai request failed: %v", err)
		}
		return "", errors.New("ai_failed")
	}
	if resp.StopReason == anthropic.BetaStopReasonRefusal {
		return "", errors.New("ai_refused")
	}
	var out strings.Builder
	for _, block := range resp.Content {
		if b, ok := block.AsAny().(anthropic.BetaTextBlock); ok {
			out.WriteString(b.Text)
		}
	}
	if out.Len() == 0 {
		return "", errors.New("ai_failed")
	}
	return out.String(), nil
}

func (c *Conn) handleAI(f *inFrame) {
	ai := c.hub.ai
	if ai == nil {
		c.reply(f, map[string]any{"ok": false, "error": errAINotConfigured.Error()})
		return
	}
	if !validateTurns(f.Turns, f.System) {
		c.reply(f, map[string]any{"ok": false, "error": "bad_request"})
		return
	}
	if err := ai.allow(c.id, time.Now()); err != nil {
		c.reply(f, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	// Off the read loop: a slow model reply must not stall message delivery.
	frame := *f
	go func() {
		defer ai.finished(c.id)
		// Tied to the connection: nobody is left paying for a reply no one will read.
		ctx, cancel := context.WithTimeout(c.ctx, aiTimeout)
		defer cancel()
		text, err := ai.Reply(ctx, frame.System, frame.Turns)
		if err != nil {
			c.reply(&frame, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		c.reply(&frame, map[string]any{"ok": true, "text": text})
	}()
}
