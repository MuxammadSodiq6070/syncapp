package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const telegramGatewayBase = "https://gatewayapi.telegram.org"

// errNoTelegram means this number cannot be reached on Telegram, so no code was sent
// and nothing was charged. The person is told to try another number.
var errNoTelegram = errors.New("no_telegram")

// TelegramSender delivers codes through Telegram's own verification platform. The
// person needs no bot and takes no action: the code appears in Telegram's built-in
// "Verification Codes" chat.
//
// One delivery is two calls. checkSendAbility says whether the number is on Telegram,
// and is free when it is not, so a number without Telegram costs nothing at all.
// Handing its request_id to sendVerificationMessage makes that second call free, so a
// delivered code is charged exactly once.
type TelegramSender struct {
	base, token string
	http        *http.Client
}

func NewTelegramSender(token string) *TelegramSender {
	return &TelegramSender{
		base:  telegramGatewayBase,
		token: token,
		http:  &http.Client{Timeout: 20 * time.Second},
	}
}

// telegramUnreachable lists the errors that mean "this number, not our account".
// Telegram does not publish the full set, so anything unrecognised is treated as our
// problem instead: a wrong token or an empty balance must surface in the log, never as
// "your number has no Telegram".
var telegramUnreachable = map[string]bool{
	"SEND_ABILITY_CHECK_FAILED": true,
	"PHONE_NUMBER_INVALID":      true,
	"PHONE_NUMBER_NOT_FOUND":    true,
	"USER_NOT_FOUND":            true,
}

type telegramReply struct {
	OK     bool   `json:"ok"`
	Error  string `json:"error"`
	Result struct {
		RequestID string `json:"request_id"`
	} `json:"result"`
}

func (t *TelegramSender) call(ctx context.Context, method string, form url.Values) (*telegramReply, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.base+"/"+method,
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Authorization", "Bearer "+t.token)
	resp, err := t.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("telegram %s: %w", method, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	var out telegramReply
	if json.Unmarshal(body, &out) != nil {
		return nil, fmt.Errorf("telegram %s: %d %s", method, resp.StatusCode,
			strings.TrimSpace(string(body)))
	}
	return &out, nil
}

func (t *TelegramSender) Via() string { return "telegram" }

// Send shows the code to whoever owns the number.
func (t *TelegramSender) Send(ctx context.Context, phone, code string) error {
	able, err := t.call(ctx, "checkSendAbility", url.Values{"phone_number": {phone}})
	if err != nil {
		return err
	}
	if !able.OK || able.Result.RequestID == "" {
		if telegramUnreachable[able.Error] {
			return fmt.Errorf("%w: %s", errNoTelegram, able.Error)
		}
		return fmt.Errorf("telegram checkSendAbility: %s", able.Error)
	}
	sent, err := t.call(ctx, "sendVerificationMessage", url.Values{
		"phone_number": {phone},
		"request_id":   {able.Result.RequestID},
		"code":         {code},
		// Telegram refunds a code it could not deliver in time, and there is no
		// point outliving the code we stored.
		"ttl": {strconv.Itoa(int(codeTTL.Seconds()))},
	})
	if err != nil {
		return err
	}
	if !sent.OK {
		if telegramUnreachable[sent.Error] {
			return fmt.Errorf("%w: %s", errNoTelegram, sent.Error)
		}
		return fmt.Errorf("telegram sendVerificationMessage: %s", sent.Error)
	}
	return nil
}
