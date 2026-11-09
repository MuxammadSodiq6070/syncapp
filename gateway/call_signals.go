package main

// call_signals.go — WebRTC signaling relay for 1-to-1 P2P calls.
//
// Supported frame types (field "t"):
//   call_offer       — caller → callee   (SDP offer)
//   call_answer      — callee → caller   (SDP answer)
//   call_candidate   — either direction  (ICE candidate)
//   call_hangup      — either direction  (call ended / cancelled)
//   call_reject      — callee → caller   (declined)
//   call_busy        — callee → caller   (already in a call)
//
// Every frame MUST carry:
//   to         string — receiver's user ID
//   call_id    string — unique call ID
//   payload    any    — SDP / candidate / metadata

import (
	"encoding/json"
	"log"
)

// handleCallSignal is called by Conn.handle when it encounters a call_* frame.
// It validates, checks against sender spoofing, enriches with caller profile,
// and forwards to the receiver.
func (c *Conn) handleCallSignal(f *inFrame) {
	h := c.hub

	if !validUserID(f.To) {
		c.reply(f, map[string]any{"ok": false, "error": "bad_request"})
		return
	}

	// Sender spoofing rejection: verify frame-level sender identities match authenticated connection.
	if (f.ID != "" && f.ID != c.id) || (f.SenderID != "" && f.SenderID != c.id) {
		c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
		return
	}

	// Inspect payload if present for spoofed sender identifiers
	if len(f.Payload) > 0 {
		var pMap map[string]json.RawMessage
		if err := json.Unmarshal(f.Payload, &pMap); err == nil {
			if raw, ok := pMap["sender_id"]; ok {
				var sid string
				if err := json.Unmarshal(raw, &sid); err == nil && sid != "" && sid != c.id {
					c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
					return
				}
			}
			if raw, ok := pMap["from"]; ok {
				var from string
				if err := json.Unmarshal(raw, &from); err == nil && from != "" && from != c.id {
					c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
					return
				}
			}
		}
	}

	// Inspect blob if present for spoofed sender identifiers
	var blobExtra map[string]json.RawMessage
	if f.Blob != "" {
		if err := json.Unmarshal([]byte(f.Blob), &blobExtra); err == nil {
			if raw, ok := blobExtra["sender_id"]; ok {
				var sid string
				if err := json.Unmarshal(raw, &sid); err == nil && sid != "" && sid != c.id {
					c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
					return
				}
			}
			if raw, ok := blobExtra["from"]; ok {
				var from string
				if err := json.Unmarshal(raw, &from); err == nil && from != "" && from != c.id {
					c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
					return
				}
			}
			if raw, ok := blobExtra["id"]; ok {
				var id string
				if err := json.Unmarshal(raw, &id); err == nil && id != "" && id != c.id {
					c.reply(f, map[string]any{"ok": false, "error": "sender_spoofing"})
					return
				}
			}
		}
	}

	// Build enriched relay frame including caller display info.
	callerName := c.id
	callerAvatar := ""
	if h.store != nil {
		callerUser, err := h.store.User(c.id)
		if err == nil && callerUser != nil {
			if callerUser.DisplayName != "" {
				callerName = callerUser.DisplayName
			} else if callerUser.Username != "" {
				callerName = callerUser.Username
			}
		}
	}

	relay := map[string]any{
		"t":             f.T,
		"sender_id":     c.id,
		"sender_name":   callerName,
		"sender_avatar": callerAvatar,
		"receiver_id":   f.To,
	}

	if f.CallID != "" {
		relay["call_id"] = f.CallID
	}
	if len(f.Payload) > 0 {
		relay["payload"] = f.Payload
	}

	if f.Blob != "" {
		relay["blob"] = f.Blob
		if blobExtra != nil {
			for k, v := range blobExtra {
				switch k {
				case "t", "sender_id", "sender_name", "sender_avatar", "receiver_id":
					// Server-controlled fields; do not allow caller to overwrite
					continue
				default:
					relay[k] = v
				}
			}
			if _, hasPayload := relay["payload"]; !hasPayload {
				relay["payload"] = json.RawMessage(f.Blob)
			}
		}
	}

	relayBytes, err := json.Marshal(relay)
	if err != nil {
		log.Printf("call_signal: marshal error: %v", err)
		c.reply(f, map[string]any{"ok": false, "error": "server_error"})
		return
	}

	// Deliver in real-time if receiver is online.
	h.mu.RLock()
	target := h.conns[f.To]
	h.mu.RUnlock()

	if target != nil {
		select {
		case target.out <- relayBytes:
			c.reply(f, map[string]any{"ok": true, "delivered": true})
		default:
			// Buffer full — treat as offline for this signal.
			c.reply(f, map[string]any{"ok": false, "error": "receiver_busy"})
		}
		return
	}

	// Receiver offline: for call_offer, log notice (FCM push notification integration point).
	if f.T == "call_offer" {
		log.Printf("call_offer: receiver %s offline, FCM push not configured", f.To)
	}

	c.reply(f, map[string]any{"ok": true, "delivered": false})
}
