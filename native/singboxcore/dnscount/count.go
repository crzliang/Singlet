// Package dnscount counts DNS queries handled by the embedded sing-box core.
//
// Clash API /connections filters OutboundType DNS, so the dashboard cannot use
// connection snapshots. Cache hits also skip DNS transports — we therefore count
// at the DNSRouter.Exchange / Lookup entrypoints (including cached answers).
package dnscount

import (
	"context"
	"net/netip"
	"reflect"
	"sync/atomic"
	"unsafe"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	mDNS "github.com/miekg/dns"
)

// QueryTotal is the number of DNS queries since the last Reset
// (hijack-dns + internal lookups, including cache hits).
var QueryTotal atomic.Uint64

// Reset clears the counter (call on core start/stop).
func Reset() { QueryTotal.Store(0) }

type ctxKey struct{}

// Registry wraps an existing DNS transport registry (kept for future hooks).
type Registry struct {
	inner adapter.DNSTransportRegistry
}

func WrapRegistry(inner adapter.DNSTransportRegistry) *Registry {
	return &Registry{inner: inner}
}

func (r *Registry) CreateOptions(transportType string) (any, bool) {
	return r.inner.CreateOptions(transportType)
}

func (r *Registry) CreateDNSTransport(
	ctx context.Context,
	logger log.ContextLogger,
	tag string,
	transportType string,
	options any,
) (adapter.DNSTransport, error) {
	return r.inner.CreateDNSTransport(ctx, logger, tag, transportType, options)
}

type countingRouter struct {
	adapter.DNSRouter
}

// WrapRouter counts every Exchange/Lookup (cache hits included).
func WrapRouter(inner adapter.DNSRouter) adapter.DNSRouter {
	if inner == nil {
		return nil
	}
	if _, ok := inner.(*countingRouter); ok {
		return inner
	}
	return &countingRouter{DNSRouter: inner}
}

func (r *countingRouter) Exchange(
	ctx context.Context,
	message *mDNS.Msg,
	options adapter.DNSQueryOptions,
) (*mDNS.Msg, error) {
	if ctx.Value(ctxKey{}) == nil {
		QueryTotal.Add(1)
		ctx = context.WithValue(ctx, ctxKey{}, true)
	}
	return r.DNSRouter.Exchange(ctx, message, options)
}

func (r *countingRouter) Lookup(
	ctx context.Context,
	domain string,
	options adapter.DNSQueryOptions,
) ([]netip.Addr, error) {
	if ctx.Value(ctxKey{}) == nil {
		QueryTotal.Add(1)
		ctx = context.WithValue(ctx, ctxKey{}, true)
	}
	return r.DNSRouter.Lookup(ctx, domain, options)
}

// PatchBox replaces route.Router.dns inside *box.Box with a counting wrapper.
// Must run after box.New (which wires the concrete DNS router into the route).
func PatchBox(instance any) {
	if instance == nil {
		return
	}
	v := reflect.ValueOf(instance)
	if v.Kind() != reflect.Pointer || v.IsNil() {
		return
	}
	elem := v.Elem()
	routerField := elem.FieldByName("router")
	if !routerField.IsValid() || routerField.IsNil() {
		return
	}
	// Unexported *route.Router from another package.
	routerVal := reflect.NewAt(
		routerField.Type(),
		unsafe.Pointer(routerField.UnsafeAddr()),
	).Elem()
	if routerVal.IsNil() {
		return
	}
	routerElem := routerVal.Elem()
	dnsField := routerElem.FieldByName("dns")
	if !dnsField.IsValid() {
		return
	}
	dnsVal := reflect.NewAt(
		dnsField.Type(),
		unsafe.Pointer(dnsField.UnsafeAddr()),
	).Elem()
	current, ok := dnsVal.Interface().(adapter.DNSRouter)
	if !ok || current == nil {
		return
	}
	dnsVal.Set(reflect.ValueOf(WrapRouter(current)))
}
