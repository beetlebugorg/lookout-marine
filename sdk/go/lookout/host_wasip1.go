//go:build wasip1

// The host boundary: the API's imports on one side, the five exports on the
// other, and nothing above them. Every other file in this package is portable
// Go that calls the host* wrappers at the bottom of this file, which is what
// lets the package build and its tests run on a development machine.

package lookout

import "unsafe"

// ---------------------------------------------------------------------------
// The host imports, exactly as the API freezes them
// ---------------------------------------------------------------------------

//go:wasmimport lookout log
func wasmLog(level uint32, ptr unsafe.Pointer, n uint32)

//go:wasmimport lookout now_ms
func wasmNowMs() int64

//go:wasmimport lookout mono_ms
func wasmMonoMs() int64

//go:wasmimport lookout publish
func wasmPublish(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout ais_upsert
func wasmAISUpsert(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout overlay
func wasmOverlay(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout chrome_status
func wasmChromeStatus(ptr unsafe.Pointer, n uint32)

//go:wasmimport lookout alert
func wasmAlert(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout tcp_connect
func wasmTCPConnect(hostPtr unsafe.Pointer, hostLen uint32, port uint32) int64

//go:wasmimport lookout tcp_send
func wasmTCPSend(id int64, ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout tcp_close
func wasmTCPClose(id int64)

//go:wasmimport lookout timer_set
func wasmTimerSet(delayMs int64, periodic uint32) int64

//go:wasmimport lookout timer_cancel
func wasmTimerCancel(id int64)

//go:wasmimport lookout subscribe
func wasmSubscribe(ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout ais_subscribe
func wasmAISSubscribe() int32

//go:wasmimport lookout udp_open
func wasmUDPOpen(port uint32) int64

//go:wasmimport lookout udp_send
func wasmUDPSend(id int64, ptr unsafe.Pointer, n uint32, hostPtr unsafe.Pointer, hostLen uint32, port uint32) int32

//go:wasmimport lookout udp_close
func wasmUDPClose(id int64)

//go:wasmimport lookout http_fetch
func wasmHTTPFetch(ptr unsafe.Pointer, n uint32) int64

//go:wasmimport lookout ws_connect
func wasmWSConnect(ptr unsafe.Pointer, n uint32) int64

//go:wasmimport lookout ws_send
func wasmWSSend(id int64, ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout ws_close
func wasmWSClose(id int64)

//go:wasmimport lookout storage_get
func wasmStorageGet(kptr unsafe.Pointer, klen uint32, vptr unsafe.Pointer, vcap uint32) int32

//go:wasmimport lookout storage_put
func wasmStoragePut(kptr unsafe.Pointer, klen uint32, vptr unsafe.Pointer, vlen uint32) int32

//go:wasmimport lookout file_read
func wasmFileRead(handle int64, offset int64, ptr unsafe.Pointer, cap uint32) int32

//go:wasmimport lookout file_write
func wasmFileWrite(handle int64, ptr unsafe.Pointer, n uint32) int32

//go:wasmimport lookout file_close
func wasmFileClose(handle int64)

// bytesOf is the (pointer, length) pair every import above takes. The slice
// must stay reachable until the call returns, which it does: it is an argument
// here and Go's collector does not move heap objects.
func bytesOf(b []byte) (unsafe.Pointer, uint32) {
	if len(b) == 0 {
		return unsafe.Pointer(&zeroByte), 0
	}
	return unsafe.Pointer(unsafe.SliceData(b)), uint32(len(b))
}

func stringOf(s string) (unsafe.Pointer, uint32) {
	if len(s) == 0 {
		return unsafe.Pointer(&zeroByte), 0
	}
	return unsafe.Pointer(unsafe.StringData(s)), uint32(len(s))
}

// A real address for an empty range. A wasm address of 0 is a valid offset the
// host would bounds-check, and passing the address of nothing is clearer than
// passing null.
var zeroByte byte

// ---------------------------------------------------------------------------
// What the rest of the package calls
// ---------------------------------------------------------------------------

func hostLog(level Level, msg string) { p, n := stringOf(msg); wasmLog(uint32(level), p, n) }

func hostNow() int64  { return wasmNowMs() }
func hostMono() int64 { return wasmMonoMs() }

func hostPublish(b []byte) int32   { p, n := bytesOf(b); return wasmPublish(p, n) }
func hostAISUpsert(b []byte) int32 { p, n := bytesOf(b); return wasmAISUpsert(p, n) }
func hostOverlay(b []byte) int32   { p, n := bytesOf(b); return wasmOverlay(p, n) }
func hostStatus(b []byte)          { p, n := bytesOf(b); wasmChromeStatus(p, n) }
func hostAlert(b []byte) int32     { p, n := bytesOf(b); return wasmAlert(p, n) }
func hostSubscribe(b []byte) int32 { p, n := bytesOf(b); return wasmSubscribe(p, n) }
func hostAISSubscribe() int32      { return wasmAISSubscribe() }

func hostTimerSet(delayMs int64, periodic bool) int64 {
	var p uint32
	if periodic {
		p = 1
	}
	return wasmTimerSet(delayMs, p)
}

func hostTimerCancel(id int64) { wasmTimerCancel(id) }

func hostTCPConnect(addr string, port uint16) int64 {
	p, n := stringOf(addr)
	return wasmTCPConnect(p, n, uint32(port))
}

func hostTCPSend(id int64, b []byte) int32 { p, n := bytesOf(b); return wasmTCPSend(id, p, n) }
func hostTCPClose(id int64)                { wasmTCPClose(id) }

func hostWSConnect(req []byte) int64      { p, n := bytesOf(req); return wasmWSConnect(p, n) }
func hostWSSend(id int64, b []byte) int32 { p, n := bytesOf(b); return wasmWSSend(id, p, n) }
func hostWSClose(id int64)                { wasmWSClose(id) }

func hostUDPOpen(port uint16) int64 { return wasmUDPOpen(uint32(port)) }

func hostUDPSend(id int64, b []byte, addr string, port uint16) int32 {
	p, n := bytesOf(b)
	hp, hn := stringOf(addr)
	return wasmUDPSend(id, p, n, hp, hn, uint32(port))
}

func hostUDPClose(id int64) { wasmUDPClose(id) }

func hostHTTPFetch(req []byte) int64 { p, n := bytesOf(req); return wasmHTTPFetch(p, n) }

func hostStorageGet(key string, out []byte) int32 {
	kp, kn := stringOf(key)
	vp, vn := bytesOf(out)
	return wasmStorageGet(kp, kn, vp, vn)
}

func hostStoragePut(key string, value []byte) int32 {
	kp, kn := stringOf(key)
	vp, vn := bytesOf(value)
	return wasmStoragePut(kp, kn, vp, vn)
}

func hostFileRead(handle, offset int64, out []byte) int32 {
	p, n := bytesOf(out)
	return wasmFileRead(handle, offset, p, n)
}

func hostFileWrite(handle int64, b []byte) int32 {
	p, n := bytesOf(b)
	return wasmFileWrite(handle, p, n)
}

func hostFileClose(handle int64) { wasmFileClose(handle) }

// ---------------------------------------------------------------------------
// The five exports
// ---------------------------------------------------------------------------

// Buffers the host owns while it hands us a payload. The key is the wasm
// address lk_alloc returned; the value keeps the slice reachable so the
// collector leaves it alone until lk_free. A plugin has one or two of these
// live at a time, never more.
var allocs = map[uint32][]byte{}

//go:wasmexport lk_abi
func lkAPI() uint32 { return APIVersion }

//go:wasmexport lk_alloc
func lkAlloc(n uint32) uint32 {
	if n == 0 {
		n = 1
	}
	b := make([]byte, n)
	addr := uint32(uintptr(unsafe.Pointer(unsafe.SliceData(b))))
	if addr == 0 {
		// The host reads 0 as "the plugin is out of memory", so an allocation
		// that landed on address zero has to be refused rather than reported.
		return 0
	}
	allocs[addr] = b
	return addr
}

//go:wasmexport lk_free
func lkFree(addr uint32, n uint32) {
	_ = n
	delete(allocs, addr)
}

// payload finds the host's bytes without turning an integer back into a
// pointer. The host always writes into a buffer lk_alloc handed it, so the
// address is either a key of allocs or inside one of its buffers.
func payload(addr, n uint32) []byte {
	if n == 0 {
		return nil
	}
	if b, ok := allocs[addr]; ok && uint32(len(b)) >= n {
		return b[:n]
	}
	for base, b := range allocs {
		end := uint64(base) + uint64(len(b))
		if addr >= base && uint64(addr)+uint64(n) <= end {
			off := addr - base
			return b[off : off+n]
		}
	}
	hostLog(Error, "lk_event: payload is not in a buffer this plugin allocated")
	return nil
}

//go:wasmexport lk_start
func lkStart(addr uint32, n uint32) int32 {
	return dispatchStart(payload(addr, n))
}

//go:wasmexport lk_event
func lkEvent(kind uint32, handle uint64, addr uint32, n uint32) int32 {
	return dispatchEvent(Kind(kind), int64(handle), payload(addr, n))
}
