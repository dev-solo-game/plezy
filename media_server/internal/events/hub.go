package events

import (
	"sync"
	"sync/atomic"
	"time"
)

// Event represents one server-sent event broadcast to connected Web clients.
type Event struct {
	ID        int64  `json:"id"`
	Type      string `json:"type"`
	Timestamp int64  `json:"timestamp"`
	Data      any    `json:"data,omitempty"`
}

// Hub fans out real-time scan, scrape, mount and library change notifications
// without blocking producers when a client lags.
type Hub struct {
	mu      sync.RWMutex
	nextID  int64
	seq     atomic.Int64
	clients map[int64]chan Event
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[int64]chan Event),
	}
}

func (h *Hub) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 64)
	h.mu.Lock()
	h.nextID++
	id := h.nextID
	h.clients[id] = ch
	h.mu.Unlock()

	unsubscribe := func() {
		h.mu.Lock()
		if c, ok := h.clients[id]; ok {
			delete(h.clients, id)
			close(c)
		}
		h.mu.Unlock()
	}
	return ch, unsubscribe
}

func (h *Hub) Publish(eventType string, data any) {
	ev := Event{
		ID:        h.seq.Add(1),
		Type:      eventType,
		Timestamp: time.Now().UnixMilli(),
		Data:      data,
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, ch := range h.clients {
		select {
		case ch <- ev:
		default:
			// Drop oldest queued message to keep live updates fresh.
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- ev:
			default:
			}
		}
	}
}
