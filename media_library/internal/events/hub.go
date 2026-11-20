package events

import (
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Event represents one server-sent event delivered to a scoped client connection.
type Event struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Timestamp int64  `json:"timestamp"`
	Data      any    `json:"data,omitempty"`
}

type subscriber struct {
	householdID string
	memberID    string
	ch          chan Event
}

// Hub fans out tenant- and member-scoped real-time notifications without
// blocking producers when a client lags.
type Hub struct {
	mu      sync.RWMutex
	nextID  int64
	seq     atomic.Int64
	clients map[int64]subscriber
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[int64]subscriber),
	}
}

func (h *Hub) Subscribe(householdID, memberID string) (<-chan Event, func()) {
	ch := make(chan Event, 64)
	sub := subscriber{
		householdID: strings.TrimSpace(householdID),
		memberID:    strings.TrimSpace(memberID),
		ch:          ch,
	}

	h.mu.Lock()
	h.nextID++
	id := h.nextID
	h.clients[id] = sub
	h.mu.Unlock()

	unsubscribe := func() {
		h.mu.Lock()
		if c, ok := h.clients[id]; ok {
			delete(h.clients, id)
			close(c.ch)
		}
		h.mu.Unlock()
	}
	return ch, unsubscribe
}

// PublishToHousehold delivers an event to every subscriber in the given household.
func (h *Hub) PublishToHousehold(householdID, eventType string, data any) {
	hh := strings.TrimSpace(householdID)
	if hh == "" {
		return
	}
	h.publish(eventType, data, func(s subscriber) bool {
		return s.householdID == hh
	})
}

// PublishToMember delivers an event only to subscribers matching both householdID and memberID.
func (h *Hub) PublishToMember(householdID, memberID, eventType string, data any) {
	hh := strings.TrimSpace(householdID)
	mem := strings.TrimSpace(memberID)
	if hh == "" || mem == "" {
		return
	}
	h.publish(eventType, data, func(s subscriber) bool {
		return s.householdID == hh && s.memberID == mem
	})
}

func (h *Hub) publish(eventType string, data any, match func(subscriber) bool) {
	ev := Event{
		ID:        h.seq.Add(1),
		Type:      eventType,
		Timestamp: time.Now().UnixMilli(),
		Data:      data,
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, sub := range h.clients {
		if !match(sub) {
			continue
		}
		select {
		case sub.ch <- ev:
		default:
			// Drop oldest queued message to keep live updates fresh.
			select {
			case <-sub.ch:
			default:
			}
			select {
			case sub.ch <- ev:
			default:
			}
		}
	}
}
