package clock_test

import (
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
)

func TestFakeClockAdvance(t *testing.T) {
	start := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	var c clock.Clock = clocktest.NewFake(start)
	f := c.(*clocktest.Fake)
	if !c.Now().Equal(start) {
		t.Fatalf("now = %v", c.Now())
	}
	f.Advance(90 * time.Second)
	if want := start.Add(90 * time.Second); !c.Now().Equal(want) {
		t.Fatalf("now = %v want %v", c.Now(), want)
	}
	f.Set(start)
	if !c.Now().Equal(start) || c.Now().Location() != time.UTC {
		t.Fatalf("set failed: %v", c.Now())
	}
	if (clock.Real{}).Now().Location() != time.UTC {
		t.Fatal("real clock not UTC")
	}
}
