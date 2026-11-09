package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func setupTestHubAndConns(t *testing.T) (*Hub, *Conn, *Conn, string, string) {
	t.Helper()

	hub := &Hub{
		conns: make(map[string]*Conn),
	}

	callerID := strings.Repeat("a", 64)
	receiverID := strings.Repeat("b", 64)

	caller := &Conn{
		hub:  hub,
		id:   callerID,
		out:  make(chan []byte, 64),
		done: make(chan struct{}),
	}

	receiver := &Conn{
		hub:  hub,
		id:   receiverID,
		out:  make(chan []byte, 64),
		done: make(chan struct{}),
	}

	hub.conns[callerID] = caller
	hub.conns[receiverID] = receiver

	return hub, caller, receiver, callerID, receiverID
}

func readJSON(t *testing.T, ch <-chan []byte, timeout time.Duration) map[string]any {
	t.Helper()
	select {
	case data := <-ch:
		var m map[string]any
		if err := json.Unmarshal(data, &m); err != nil {
			t.Fatalf("failed to unmarshal JSON: %v, raw: %s", err, string(data))
		}
		return m
	case <-time.After(timeout):
		t.Fatal("timeout waiting for frame")
		return nil
	}
}

func assertNoMessage(t *testing.T, ch <-chan []byte, wait time.Duration) {
	t.Helper()
	select {
	case msg := <-ch:
		t.Fatalf("unexpected message received: %s", string(msg))
	case <-time.After(wait):
		// Expected: no message
	}
}

// TestCallSignalsRoutingAllTypes tests that all 6 WebRTC signaling frame types
// (call_offer, call_answer, call_candidate, call_hangup, call_reject, call_busy)
// are properly routed by Conn.handle to the receiver.
func TestCallSignalsRoutingAllTypes(t *testing.T) {
	signalTypes := []string{
		"call_offer",
		"call_answer",
		"call_candidate",
		"call_hangup",
		"call_reject",
		"call_busy",
	}

	for _, sigType := range signalTypes {
		t.Run(sigType, func(t *testing.T) {
			_, caller, receiver, callerID, receiverID := setupTestHubAndConns(t)

			req := &inFrame{
				T:       sigType,
				Rid:     "rid-" + sigType,
				To:      receiverID,
				CallID:  "call-xyz-123",
				Payload: json.RawMessage(`{"type":"video","sdp":"mock-sdp-data"}`),
			}

			// Route through Conn.handle
			caller.handle(req)

			// 1. Verify caller gets success reply
			res := readJSON(t, caller.out, 500*time.Millisecond)
			if res["t"] != "res" {
				t.Fatalf("expected res frame, got: %v", res["t"])
			}
			if res["rid"] != "rid-"+sigType {
				t.Fatalf("expected rid %q, got: %v", "rid-"+sigType, res["rid"])
			}
			if res["ok"] != true {
				t.Fatalf("expected ok=true, got: %v, err: %v", res["ok"], res["error"])
			}
			if res["delivered"] != true {
				t.Fatalf("expected delivered=true, got: %v", res["delivered"])
			}

			// 2. Verify receiver receives properly formatted signal frame
			routed := readJSON(t, receiver.out, 500*time.Millisecond)
			if routed["t"] != sigType {
				t.Fatalf("expected signal type %q, got: %v", sigType, routed["t"])
			}
			if routed["sender_id"] != callerID {
				t.Fatalf("expected sender_id %q, got: %v", callerID, routed["sender_id"])
			}
			if routed["receiver_id"] != receiverID {
				t.Fatalf("expected receiver_id %q, got: %v", receiverID, routed["receiver_id"])
			}
			if routed["call_id"] != "call-xyz-123" {
				t.Fatalf("expected call_id %q, got: %v", "call-xyz-123", routed["call_id"])
			}

			payload, ok := routed["payload"].(map[string]any)
			if !ok {
				t.Fatalf("expected payload map, got: %T (%v)", routed["payload"], routed["payload"])
			}
			if payload["sdp"] != "mock-sdp-data" {
				t.Fatalf("expected sdp %q, got: %v", "mock-sdp-data", payload["sdp"])
			}
		})
	}
}

// TestCallSignalsReceiverOnlineOffline tests handling when the receiver is online vs offline.
func TestCallSignalsReceiverOnlineOffline(t *testing.T) {
	hub, caller, receiver, _, receiverID := setupTestHubAndConns(t)

	// Subtest 1: Receiver is online -> delivered=true
	t.Run("Online", func(t *testing.T) {
		req := &inFrame{
			T:      "call_offer",
			Rid:    "rid-online",
			To:     receiverID,
			CallID: "call-online",
			Blob:   `{"call_id":"call-online","type":"audio"}`,
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != true || res["delivered"] != true {
			t.Fatalf("expected ok=true and delivered=true, got: %v", res)
		}

		delivered := readJSON(t, receiver.out, 500*time.Millisecond)
		if delivered["call_id"] != "call-online" {
			t.Fatalf("expected call_id call-online, got: %v", delivered["call_id"])
		}
	})

	// Subtest 2: Receiver goes offline (disconnected from hub) -> delivered=false
	t.Run("Offline", func(t *testing.T) {
		hub.mu.Lock()
		delete(hub.conns, receiverID)
		hub.mu.Unlock()

		req := &inFrame{
			T:      "call_offer",
			Rid:    "rid-offline",
			To:     receiverID,
			CallID: "call-offline",
			Blob:   `{"call_id":"call-offline","type":"video"}`,
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != true {
			t.Fatalf("expected ok=true, got: %v", res)
		}
		if res["delivered"] != false {
			t.Fatalf("expected delivered=false when offline, got: %v", res["delivered"])
		}

		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	// Subtest 3: Receiver buffer full (busy)
	t.Run("ReceiverBusy", func(t *testing.T) {
		// Create receiver with 1-slot buffer and fill it
		busyReceiver := &Conn{
			hub:  hub,
			id:   receiverID,
			out:  make(chan []byte, 1),
			done: make(chan struct{}),
		}
		busyReceiver.out <- []byte("already-full-slot")

		hub.mu.Lock()
		hub.conns[receiverID] = busyReceiver
		hub.mu.Unlock()

		req := &inFrame{
			T:      "call_candidate",
			Rid:    "rid-busy",
			To:     receiverID,
			CallID: "call-busy",
			Blob:   `{"candidate":"candidate:1"}`,
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false {
			t.Fatalf("expected ok=false for busy receiver, got: %v", res)
		}
		if res["error"] != "receiver_busy" {
			t.Fatalf("expected error='receiver_busy', got: %v", res["error"])
		}
	})
}

// TestCallSignalsInvalidReceiverID tests rejection of malformed receiver user IDs.
func TestCallSignalsInvalidReceiverID(t *testing.T) {
	_, caller, _, _, _ := setupTestHubAndConns(t)

	invalidIDs := []string{
		"",
		"short",
		"not-hex-characters-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
		strings.Repeat("A", 64), // uppercase not allowed
		strings.Repeat("1", 63), // 63 chars
		strings.Repeat("1", 65), // 65 chars
	}

	for _, badID := range invalidIDs {
		t.Run("bad_id_"+badID, func(t *testing.T) {
			req := &inFrame{
				T:   "call_offer",
				Rid: "rid-bad-id",
				To:  badID,
			}
			caller.handle(req)

			res := readJSON(t, caller.out, 500*time.Millisecond)
			if res["ok"] != false {
				t.Fatalf("expected ok=false for bad receiver ID, got: %v", res)
			}
			if res["error"] != "bad_request" {
				t.Fatalf("expected error='bad_request', got: %v", res["error"])
			}
		})
	}
}

// TestCallSignalsSenderSpoofingRejection tests that any attempt to impersonate another
// user in the signaling frame, payload, or blob is rejected.
func TestCallSignalsSenderSpoofingRejection(t *testing.T) {
	spoofedID := strings.Repeat("c", 64)

	t.Run("Spoofed_Frame_ID", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:      "call_offer",
			Rid:    "rid-spoof-1",
			To:     receiverID,
			ID:     spoofedID, // Attacker trying to claim caller identity is spoofedID
			CallID: "call-spoof-1",
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	t.Run("Spoofed_Frame_SenderID", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:        "call_offer",
			Rid:      "rid-spoof-2",
			To:       receiverID,
			SenderID: spoofedID,
			CallID:   "call-spoof-2",
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	t.Run("Spoofed_Blob_SenderID", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:      "call_offer",
			Rid:    "rid-spoof-3",
			To:     receiverID,
			CallID: "call-spoof-3",
			Blob:   `{"sender_id":"` + spoofedID + `","sdp":"spoofed"}`,
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	t.Run("Spoofed_Blob_From", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:      "call_offer",
			Rid:    "rid-spoof-4",
			To:     receiverID,
			CallID: "call-spoof-4",
			Blob:   `{"from":"` + spoofedID + `","sdp":"spoofed"}`,
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	t.Run("Spoofed_Payload_SenderID", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:       "call_offer",
			Rid:     "rid-spoof-5",
			To:      receiverID,
			CallID:  "call-spoof-5",
			Payload: json.RawMessage(`{"sender_id":"` + spoofedID + `"}`),
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})

	t.Run("Spoofed_Payload_From", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:       "call_offer",
			Rid:     "rid-spoof-6",
			To:      receiverID,
			CallID:  "call-spoof-6",
			Payload: json.RawMessage(`{"from":"` + spoofedID + `"}`),
		}
		caller.handle(req)

		res := readJSON(t, caller.out, 500*time.Millisecond)
		if res["ok"] != false || res["error"] != "sender_spoofing" {
			t.Fatalf("expected sender_spoofing rejection, got: %v", res)
		}
		assertNoMessage(t, receiver.out, 50*time.Millisecond)
	})
}

// TestCallSignalsFieldTamperingProtection tests that even if a caller includes fields like
// sender_name, sender_avatar, receiver_id, or t in blob, the gateway preserves authoritative
// values and does not allow client overwriting.
func TestCallSignalsFieldTamperingProtection(t *testing.T) {
	_, caller, receiver, callerID, receiverID := setupTestHubAndConns(t)

	spoofedVictim := strings.Repeat("f", 64)

	req := &inFrame{
		T:      "call_offer",
		Rid:    "rid-tamper",
		To:     receiverID,
		CallID: "call-tamper",
		Blob: `{
			"sender_id": "` + callerID + `",
			"sender_name": "Forged Admin",
			"sender_avatar": "https://evil.com/avatar.png",
			"receiver_id": "` + spoofedVictim + `",
			"t": "call_spoofed",
			"custom_data": "legitimate_extra_info"
		}`,
	}
	caller.handle(req)

	res := readJSON(t, caller.out, 500*time.Millisecond)
	if res["ok"] != true {
		t.Fatalf("expected ok=true, got: %v", res)
	}

	routed := readJSON(t, receiver.out, 500*time.Millisecond)

	// Server-managed fields MUST NOT be tampered with
	if routed["t"] != "call_offer" {
		t.Fatalf("expected t='call_offer', got: %v", routed["t"])
	}
	if routed["sender_id"] != callerID {
		t.Fatalf("expected sender_id=%q, got: %v", callerID, routed["sender_id"])
	}
	if routed["receiver_id"] != receiverID {
		t.Fatalf("expected receiver_id=%q, got: %v", receiverID, routed["receiver_id"])
	}
	// Legitimate extra data should be preserved
	if routed["custom_data"] != "legitimate_extra_info" {
		t.Fatalf("expected custom_data preserved, got: %v", routed["custom_data"])
	}
}

// TestCallSignalsPayloadFormats verifies handling of different client conventions:
// raw blob payload, nested payload inside blob, and top-level call_id.
func TestCallSignalsPayloadFormats(t *testing.T) {
	t.Run("FlatBlobPayload", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:   "call_offer",
			Rid: "rid-flat",
			To:  receiverID,
			Blob: `{
				"call_id": "call-flat-99",
				"type": "video",
				"sdp": "v=0\r\no=...",
				"sdp_type": "offer"
			}`,
		}
		caller.handle(req)

		_ = readJSON(t, caller.out, 500*time.Millisecond)
		routed := readJSON(t, receiver.out, 500*time.Millisecond)

		if routed["call_id"] != "call-flat-99" {
			t.Fatalf("expected call_id call-flat-99, got: %v", routed["call_id"])
		}
		// Check payload was extracted as map so Flutter CallController can read it
		payload, ok := routed["payload"].(map[string]any)
		if !ok {
			t.Fatalf("expected payload map, got: %T (%v)", routed["payload"], routed["payload"])
		}
		if payload["sdp_type"] != "offer" {
			t.Fatalf("expected sdp_type offer, got: %v", payload["sdp_type"])
		}
	})

	t.Run("NestedBlobPayload", func(t *testing.T) {
		_, caller, receiver, _, receiverID := setupTestHubAndConns(t)

		req := &inFrame{
			T:   "call_candidate",
			Rid: "rid-nested",
			To:  receiverID,
			Blob: `{
				"call_id": "call-nested-88",
				"payload": {
					"candidate": "candidate:12345 1 udp 2122260223 ...",
					"sdp_mid": "0",
					"sdp_m_line_index": 0
				}
			}`,
		}
		caller.handle(req)

		_ = readJSON(t, caller.out, 500*time.Millisecond)
		routed := readJSON(t, receiver.out, 500*time.Millisecond)

		if routed["call_id"] != "call-nested-88" {
			t.Fatalf("expected call_id call-nested-88, got: %v", routed["call_id"])
		}
		payload, ok := routed["payload"].(map[string]any)
		if !ok {
			t.Fatalf("expected nested payload map, got: %T (%v)", routed["payload"], routed["payload"])
		}
		if payload["sdp_mid"] != "0" {
			t.Fatalf("expected sdp_mid 0, got: %v", payload["sdp_mid"])
		}
	})
}
