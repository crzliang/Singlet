package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/experimental/deprecated"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	sjson "github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"

	"github.com/liang/singlet/native/singboxcore/dnsgroup"
)

const versionString = "singlet-singboxcore/0.2.0+sing-box-1.12.12"

var (
	mu          sync.Mutex
	instance    *box.Box
	cancelFn    context.CancelFunc
	running     bool
	configPath  string
	clashAPIURL string
	lastError   string
)

func setErr(err error) {
	if err == nil {
		lastError = ""
		return
	}
	lastError = err.Error()
}

func ensureClashAPI(opts *option.Options, clashBase string) (string, error) {
	base := strings.TrimSpace(clashBase)
	if base == "" {
		base = "http://127.0.0.1:9090"
	}
	u, err := url.Parse(base)
	if err != nil {
		return "", fmt.Errorf("parse clash api url: %w", err)
	}
	host := u.Host
	if host == "" {
		host = strings.TrimPrefix(base, "http://")
		host = strings.TrimPrefix(host, "https://")
	}
	if host == "" {
		return "", fmt.Errorf("empty clash api host")
	}
	if opts.Experimental == nil {
		opts.Experimental = &option.ExperimentalOptions{}
	}
	if opts.Experimental.ClashAPI == nil {
		opts.Experimental.ClashAPI = &option.ClashAPIOptions{}
	}
	if opts.Experimental.ClashAPI.ExternalController == "" {
		opts.Experimental.ClashAPI.ExternalController = host
	}
	scheme := u.Scheme
	if scheme == "" {
		scheme = "http"
	}
	return scheme + "://" + opts.Experimental.ClashAPI.ExternalController, nil
}

func startBox(path, clashBase string) error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return fmt.Errorf("already running")
	}
	if path == "" {
		return fmt.Errorf("config path is empty")
	}

	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}

	// Strip app-only metadata (e.g. legacy "_singlet_meta") so DisallowUnknownFields succeeds.
	cleaned, stripped, err := sanitizeSingBoxConfigJSON(content)
	if err != nil {
		return fmt.Errorf("sanitize config: %w", err)
	}
	if stripped {
		_ = os.WriteFile(path, cleaned, 0o644)
	}

	ctx := context.Background()
	ctx = service.ContextWith(ctx, deprecated.NewStderrManager(log.StdLogger()))
	// Custom registry so we can add singlet-group (multi-DNS race/fallback/rr).
	dnsRegistry := include.DNSTransportRegistry()
	dnsgroup.RegisterTransport(dnsRegistry)
	ctx = box.Context(
		ctx,
		include.InboundRegistry(),
		include.OutboundRegistry(),
		include.EndpointRegistry(),
		dnsRegistry,
		include.ServiceRegistry(),
	)

	opts, err := sjson.UnmarshalExtendedContext[option.Options](ctx, cleaned)
	if err != nil {
		return fmt.Errorf("decode config: %w", err)
	}

	resolvedAPI, err := ensureClashAPI(&opts, clashBase)
	if err != nil {
		return err
	}

	runCtx, cancel := context.WithCancel(ctx)
	inst, err := box.New(box.Options{
		Context: runCtx,
		Options: opts,
	})
	if err != nil {
		cancel()
		return fmt.Errorf("create box: %w", err)
	}
	if err := inst.Start(); err != nil {
		cancel()
		_ = inst.Close()
		return fmt.Errorf("start box: %w", err)
	}

	instance = inst
	cancelFn = cancel
	running = true
	configPath = path
	clashAPIURL = resolvedAPI
	lastError = ""
	return nil
}

func stopBox() error {
	mu.Lock()
	defer mu.Unlock()

	if !running || instance == nil {
		return fmt.Errorf("not running")
	}
	err := instance.Close()
	if cancelFn != nil {
		cancelFn()
	}
	instance = nil
	cancelFn = nil
	running = false
	if err != nil {
		lastError = err.Error()
		return err
	}
	lastError = ""
	return nil
}

func statusSnapshot() map[string]any {
	mu.Lock()
	defer mu.Unlock()
	return map[string]any{
		"running":      running,
		"configPath":   configPath,
		"clashApiBase": clashAPIURL,
		"version":      versionString,
		"stub":         false,
		"lastError":    lastError,
	}
}

// sanitizeSingBoxConfigJSON removes unknown top-level keys that sing-box rejects
// (DisallowUnknownFields), notably legacy "_singlet_meta" from older app drafts.
func sanitizeSingBoxConfigJSON(raw []byte) ([]byte, bool, error) {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(raw, &root); err != nil {
		return nil, false, err
	}
	allowed := map[string]struct{}{
		"$schema":      {},
		"log":          {},
		"dns":          {},
		"ntp":          {},
		"certificate":  {},
		"endpoints":    {},
		"inbounds":     {},
		"outbounds":    {},
		"route":        {},
		"services":     {},
		"experimental": {},
	}
	changed := false
	for k := range root {
		if _, ok := allowed[k]; ok {
			continue
		}
		// Drop underscore-prefixed app metadata and any other unknown top-level key.
		delete(root, k)
		changed = true
	}
	if !changed {
		return raw, false, nil
	}
	out, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return nil, false, err
	}
	return out, true, nil
}
