// Package dnsgroup adds a multi-server DNS transport for Singlet.
//
// sing-box routes each query to a single server tag; this transport wraps
// several member servers and applies race / fallback / round-robin.
package dnsgroup

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/log"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
)

const Type = "singlet-group"

const (
	StrategyRace       = "race"
	StrategyFallback   = "fallback"
	StrategyRoundRobin = "round_robin"
)

// Options is the JSON body for type "singlet-group".
type Options struct {
	Servers  []string `json:"servers"`
	Strategy string   `json:"strategy,omitempty"`
}

func RegisterTransport(registry *dns.TransportRegistry) {
	dns.RegisterTransport[Options](registry, Type, New)
}

type Transport struct {
	dns.TransportAdapter
	ctx      context.Context
	logger   log.ContextLogger
	servers  []string
	strategy string
	rr       atomic.Uint64
	once     sync.Once
	manager  adapter.DNSTransportManager
}

func New(ctx context.Context, logger log.ContextLogger, tag string, options Options) (adapter.DNSTransport, error) {
	if len(options.Servers) == 0 {
		return nil, E.New("singlet-group: servers is empty")
	}
	strategy := options.Strategy
	if strategy == "" {
		strategy = StrategyRace
	}
	switch strategy {
	case StrategyRace, StrategyFallback, StrategyRoundRobin:
	default:
		return nil, E.New("singlet-group: unknown strategy: ", strategy)
	}
	deps := make([]string, 0, len(options.Servers))
	for _, s := range options.Servers {
		if s == "" || s == tag {
			continue
		}
		deps = append(deps, s)
	}
	if len(deps) == 0 {
		return nil, E.New("singlet-group: no valid member servers")
	}
	return &Transport{
		TransportAdapter: dns.NewTransportAdapter(Type, tag, deps),
		ctx:              ctx,
		logger:           logger,
		servers:          deps,
		strategy:         strategy,
	}, nil
}

func (t *Transport) Start(stage adapter.StartStage) error {
	if stage != adapter.StartStateStart {
		return nil
	}
	t.once.Do(func() {
		t.manager = service.FromContext[adapter.DNSTransportManager](t.ctx)
	})
	if t.manager == nil {
		return E.New("singlet-group: missing DNS transport manager")
	}
	return nil
}

func (t *Transport) Close() error { return nil }

func (t *Transport) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	members, err := t.members()
	if err != nil {
		return nil, err
	}
	if len(members) == 1 {
		return members[0].Exchange(ctx, message)
	}
	switch t.strategy {
	case StrategyFallback:
		return exchangeFallback(ctx, members, message)
	case StrategyRoundRobin:
		return exchangeRoundRobin(ctx, members, message, &t.rr)
	default:
		return exchangeRace(ctx, members, message)
	}
}

func (t *Transport) members() ([]adapter.DNSTransport, error) {
	if t.manager == nil {
		t.manager = service.FromContext[adapter.DNSTransportManager](t.ctx)
	}
	if t.manager == nil {
		return nil, E.New("singlet-group: DNS transport manager not ready")
	}
	out := make([]adapter.DNSTransport, 0, len(t.servers))
	for _, tag := range t.servers {
		tr, ok := t.manager.Transport(tag)
		if !ok {
			return nil, E.New("singlet-group: member not found: ", tag)
		}
		out = append(out, tr)
	}
	return out, nil
}

func exchangeFallback(ctx context.Context, members []adapter.DNSTransport, message *mDNS.Msg) (*mDNS.Msg, error) {
	var lastErr error
	for _, m := range members {
		resp, err := m.Exchange(ctx, message)
		if err != nil {
			lastErr = err
			continue
		}
		return resp, nil
	}
	if lastErr == nil {
		lastErr = E.New("singlet-group: all members failed")
	}
	return nil, lastErr
}

func exchangeRoundRobin(ctx context.Context, members []adapter.DNSTransport, message *mDNS.Msg, rr *atomic.Uint64) (*mDNS.Msg, error) {
	n := uint64(len(members))
	start := rr.Add(1) - 1
	var lastErr error
	for i := uint64(0); i < n; i++ {
		m := members[(start+i)%n]
		resp, err := m.Exchange(ctx, message)
		if err != nil {
			lastErr = err
			continue
		}
		return resp, nil
	}
	if lastErr == nil {
		lastErr = E.New("singlet-group: all members failed")
	}
	return nil, lastErr
}

func exchangeRace(ctx context.Context, members []adapter.DNSTransport, message *mDNS.Msg) (*mDNS.Msg, error) {
	type result struct {
		resp *mDNS.Msg
		err  error
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	ch := make(chan result, len(members))
	for _, m := range members {
		go func(tr adapter.DNSTransport) {
			resp, err := tr.Exchange(ctx, message)
			select {
			case ch <- result{resp, err}:
			case <-ctx.Done():
			}
		}(m)
	}

	var lastErr error
	for range members {
		select {
		case <-ctx.Done():
			if lastErr == nil {
				lastErr = ctx.Err()
			}
			return nil, lastErr
		case r := <-ch:
			if r.err != nil {
				lastErr = r.err
				continue
			}
			cancel()
			return r.resp, nil
		}
	}
	if lastErr == nil {
		lastErr = E.New("singlet-group: all members failed")
	}
	return nil, lastErr
}
