package dnsgroup

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"

	mDNS "github.com/miekg/dns"
)

type stubTransport struct {
	tag     string
	delay   time.Duration
	err     error
	calls   atomic.Int32
	onStart chan struct{}
}

func (s *stubTransport) Type() string                       { return "stub" }
func (s *stubTransport) Tag() string                        { return s.tag }
func (s *stubTransport) Dependencies() []string             { return nil }
func (s *stubTransport) Start(adapter.StartStage) error     { return nil }
func (s *stubTransport) Close() error                       { return nil }
func (s *stubTransport) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	s.calls.Add(1)
	if s.onStart != nil {
		select {
		case s.onStart <- struct{}{}:
		default:
		}
	}
	if s.delay > 0 {
		select {
		case <-time.After(s.delay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if s.err != nil {
		return nil, s.err
	}
	return &mDNS.Msg{MsgHdr: mDNS.MsgHdr{Id: message.Id, Response: true, Rcode: mDNS.RcodeSuccess}}, nil
}

func TestExchangeRaceTakesFastest(t *testing.T) {
	fast := &stubTransport{tag: "fast", delay: 10 * time.Millisecond}
	slow := &stubTransport{tag: "slow", delay: 200 * time.Millisecond}
	msg := new(mDNS.Msg)
	msg.SetQuestion("example.com.", mDNS.TypeA)

	start := time.Now()
	resp, err := exchangeRace(context.Background(), []adapter.DNSTransport{slow, fast}, msg)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatal(err)
	}
	if resp == nil {
		t.Fatal("nil response")
	}
	if elapsed > 100*time.Millisecond {
		t.Fatalf("race too slow: %s", elapsed)
	}
}

func TestExchangeFallbackOrder(t *testing.T) {
	fail := &stubTransport{tag: "fail", err: errors.New("down")}
	ok := &stubTransport{tag: "ok"}
	msg := new(mDNS.Msg)
	msg.SetQuestion("example.com.", mDNS.TypeA)

	resp, err := exchangeFallback(context.Background(), []adapter.DNSTransport{fail, ok}, msg)
	if err != nil {
		t.Fatal(err)
	}
	if resp == nil {
		t.Fatal("nil response")
	}
	if fail.calls.Load() != 1 || ok.calls.Load() != 1 {
		t.Fatalf("calls fail=%d ok=%d", fail.calls.Load(), ok.calls.Load())
	}
}

func TestExchangeRoundRobinRotates(t *testing.T) {
	a := &stubTransport{tag: "a"}
	b := &stubTransport{tag: "b"}
	msg := new(mDNS.Msg)
	msg.SetQuestion("example.com.", mDNS.TypeA)
	var rr atomic.Uint64

	_, _ = exchangeRoundRobin(context.Background(), []adapter.DNSTransport{a, b}, msg, &rr)
	_, _ = exchangeRoundRobin(context.Background(), []adapter.DNSTransport{a, b}, msg, &rr)
	if a.calls.Load() != 1 || b.calls.Load() != 1 {
		t.Fatalf("expected 1/1 calls, got a=%d b=%d", a.calls.Load(), b.calls.Load())
	}
}
