package events

import (
	"testing"
	"time"
)

func expectNoEvent(t *testing.T, ch <-chan Event, label string) {
	t.Helper()
	select {
	case ev, ok := <-ch:
		if ok {
			t.Fatalf("%s received unexpected event: %+v", label, ev)
		}
	case <-time.After(30 * time.Millisecond):
	}
}

func expectEvent(t *testing.T, ch <-chan Event, wantType string, label string) Event {
	t.Helper()
	select {
	case ev, ok := <-ch:
		if !ok {
			t.Fatalf("%s channel unexpectedly closed", label)
		}
		if ev.Type != wantType {
			t.Fatalf("%s got event type %q, want %q", label, ev.Type, wantType)
		}
		return ev
	case <-time.After(time.Second):
		t.Fatalf("%s timed out waiting for event %q", label, wantType)
		return Event{}
	}
}

func TestHubTenantAndMemberIsolation(t *testing.T) {
	h := NewHub()

	chA1, unsubA1 := h.Subscribe("hhA", "mem1")
	defer unsubA1()
	chA2, unsubA2 := h.Subscribe("hhA", "mem2")
	defer unsubA2()
	chB1, unsubB1 := h.Subscribe("hhB", "mem1")
	defer unsubB1()

	// Household broadcast reaches all members in hhA, never hhB.
	h.PublishToHousehold("hhA", "library.changed", map[string]any{"seq": 10})
	expectEvent(t, chA1, "library.changed", "hhA/mem1")
	expectEvent(t, chA2, "library.changed", "hhA/mem2")
	expectNoEvent(t, chB1, "hhB/mem1")

	// Member broadcast reaches only hhA/mem1, never hhA/mem2 or hhB/mem1.
	h.PublishToMember("hhA", "mem1", "progress.changed", map[string]any{"pos": 42})
	expectEvent(t, chA1, "progress.changed", "hhA/mem1")
	expectNoEvent(t, chA2, "hhA/mem2")
	expectNoEvent(t, chB1, "hhB/mem1")

	// Empty household or member ID must be safely ignored.
	h.PublishToHousehold("", "library.changed", nil)
	h.PublishToMember("hhA", "", "progress.changed", nil)
	expectNoEvent(t, chA1, "hhA/mem1 after empty publish")
	expectNoEvent(t, chA2, "hhA/mem2 after empty publish")
	expectNoEvent(t, chB1, "hhB/mem1 after empty publish")
}
