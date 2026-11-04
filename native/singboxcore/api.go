package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"runtime"
	"unsafe"
)

func dupCString(s string) *C.char {
	return C.CString(s)
}

//export SingletVersion
func SingletVersion() *C.char {
	return dupCString(versionString)
}

//export SingletLastError
func SingletLastError() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return dupCString(lastError)
}

//export SingletFreeString
func SingletFreeString(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// SingletStart starts embedded sing-box with a JSON config path and optional Clash API base URL.
// Returns 0 on success, non-zero on failure (see SingletLastError).
//
//export SingletStart
func SingletStart(configPathC *C.char, clashAPIC *C.char) C.int {
	path := C.GoString(configPathC)
	api := C.GoString(clashAPIC)
	if err := startBox(path, api); err != nil {
		setErr(err)
		return 1
	}
	setErr(nil)
	return 0
}

//export SingletStop
func SingletStop() C.int {
	if err := stopBox(); err != nil {
		setErr(err)
		return 1
	}
	setErr(nil)
	return 0
}

//export SingletIsRunning
func SingletIsRunning() C.int {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return 1
	}
	return 0
}

//export SingletClashAPIBaseURL
func SingletClashAPIBaseURL() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return dupCString(clashAPIURL)
}

//export SingletStatusJSON
func SingletStatusJSON() *C.char {
	payload, _ := json.Marshal(statusSnapshot())
	return dupCString(string(payload))
}

// SingletMemoryJSON returns Go runtime memory stats for the embedded core process.
// Shape mirrors Clash Meta /memory enough for the dashboard: inuse + oslimit.
//
//export SingletMemoryJSON
func SingletMemoryJSON() *C.char {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	payload, _ := json.Marshal(map[string]any{
		"inuse":   ms.HeapInuse,
		"oslimit": ms.Sys,
		"sys":     ms.Sys,
		"alloc":   ms.Alloc,
		"source":  "runtime.MemStats",
	})
	return dupCString(string(payload))
}

func main() {}
