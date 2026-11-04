package main

import (
	"encoding/json"
	"testing"
)

func TestSanitizeStripsSingletMeta(t *testing.T) {
	in := []byte(`{"log":{"level":"info"},"_singlet_meta":{"x":1},"outbounds":[],"inbounds":[],"route":{},"experimental":{}}`)
	out, changed, err := sanitizeSingBoxConfigJSON(in)
	if err != nil {
		t.Fatal(err)
	}
	if !changed {
		t.Fatal("expected changed")
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	if _, ok := m["_singlet_meta"]; ok {
		t.Fatal("_singlet_meta still present")
	}
	for _, k := range []string{"log", "outbounds", "inbounds", "route", "experimental"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("missing %s", k)
		}
	}
}
