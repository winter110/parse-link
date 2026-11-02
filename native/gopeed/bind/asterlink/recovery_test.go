package gopeed

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GopeedLab/gopeed/pkg/download"
)

func TestMissingAndTruncatedCacheRestartFromZero(t *testing.T) {
	for _, damage := range []string{"missing", "truncated"} {
		t.Run(damage, func(t *testing.T) {
			_, payload, _ := openTestCore(t)
			f := serveFile(t, 1024*1024, 0)
			startFile(t, "cache", f.server.URL+"/file", 8, 512*1024)
			state := waitState(t, "cache", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
			if err := Pause("cache"); err != nil {
				t.Fatal(err)
			}
			oldID := taskIDs["cache"]
			var err error
			if damage == "missing" {
				err = os.Remove(state.Path)
			} else {
				err = os.Truncate(state.Path, 10)
			}
			if err != nil {
				t.Fatal(err)
			}
			startFile(t, "cache", f.server.URL+"/file", 8, 0)
			if taskIDs["cache"] == oldID {
				t.Fatal("checkpoint retained for a damaged payload")
			}
			result := waitState(t, "cache", func(s snapshot) bool { return s.Status == "done" })
			assertPayload(t, result, f.data)
			if filepath.Clean(result.Path) != filepath.Join(payload, "cache", "payload.gopeed") {
				t.Fatal("orphan file forced a renamed payload")
			}
		})
	}
}

func TestCompletedPayloadEvictionRestarts(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 8192, 0)
	startFile(t, "done", f.server.URL+"/file", 4, 0)
	state := waitState(t, "done", func(s snapshot) bool { return s.Status == "done" })
	if err := os.Remove(state.Path); err != nil {
		t.Fatal(err)
	}
	startFile(t, "done", f.server.URL+"/file", 4, 0)
	assertPayload(t, waitState(t, "done", func(s snapshot) bool { return s.Status == "done" }), f.data)
}

func TestLegacyCacheIsRebuiltWithoutTouchingOtherTasks(t *testing.T) {
	_, payload, _ := openTestCore(t)
	dir := filepath.Join(payload, "legacy")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"payload.part", "ranges.state", "single.part", "payload.gopeed"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("old Kotlin payload"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	other := filepath.Join(payload, "other-task")
	if err := os.WriteFile(other, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	f := serveFile(t, 8192, 0)
	startFile(t, "legacy", f.server.URL+"/file", 4, 0)
	state := waitState(t, "legacy", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, f.data)
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 1 || entries[0].Name() != "payload.gopeed" {
		t.Fatal("legacy cache not cleared")
	}
	if got, err := os.ReadFile(other); err != nil || string(got) != "keep" {
		t.Fatal("unrelated cache modified")
	}
}

func TestRetrySettingControlsEveryConnection(t *testing.T) {
	for _, retries := range []int{0, 2, 3, 64} {
		t.Run(fmt.Sprint(retries), func(t *testing.T) {
			openTestCore(t)
			var attempts atomic.Int32
			// Exercise the 64-retry bridge setting without waiting ten minutes
			// for every backoff; ten real retries also exceeds the former cap.
			failures := int32(min(10, max(3, retries)))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Range") == "bytes=0-0" {
					w.Header().Set("Content-Range", "bytes 0-0/8")
					w.WriteHeader(206)
					w.Write([]byte("a"))
					return
				}
				if attempts.Add(1) <= failures {
					w.WriteHeader(503)
					return
				}
				w.Header().Set("Content-Range", "bytes 0-7/8")
				w.WriteHeader(206)
				w.Write([]byte("abcdefgh"))
			}))
			t.Cleanup(server.Close)
			raw, _ := json.Marshal(request{ID: "retry", URL: server.URL, Connections: 1, Retries: retries})
			if err := Begin(string(raw)); err != nil {
				t.Fatal(err)
			}
			// The backoff between attempts, not the configured ceiling, decides
			// how long this can take, so the deadline follows the attempts that
			// can really happen (at most failures) rather than the raw setting.
			state := waitState(t, "retry", func(s snapshot) bool { return s.Status == "done" || s.Status == "error" }, 45*time.Second+time.Duration(failures)*30*time.Second)
			wantAttempts := int32(retries + 1)
			if int32(retries) >= failures {
				wantAttempts = failures + 1
				if state.Status != "done" {
					t.Fatal("configured retries were cut short")
				}
				assertPayload(t, state, []byte("abcdefgh"))
			} else if state.HTTPCode != 503 {
				t.Fatalf("expected 503, got %+v", state)
			}
			if attempts.Load() != wantAttempts {
				t.Fatalf("want %d attempts, got %d", wantAttempts, attempts.Load())
			}
		})
	}
}

func TestImmediatePauseAndReplacementCannotReceiveOldEvents(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 32768, 5*time.Millisecond)
	for i := 0; i < 12; i++ {
		startFile(t, "rapid", f.server.URL+"/file", 8, 0)
		if err := Pause("rapid"); err != nil {
			t.Fatal(err)
		}
		oldTask := core.GetTask(taskIDs["rapid"])
		if err := Remove("rapid"); err != nil {
			t.Fatal(err)
		}
		startFile(t, "rapid", f.server.URL+"/file", 8, 0)
		remember(&download.Event{Task: oldTask})
		assertPayload(t, waitState(t, "rapid", func(s snapshot) bool { return s.Status == "done" }), f.data)
		if err := Remove("rapid"); err != nil {
			t.Fatal(err)
		}
	}
}

func TestNonRangeRetryDoesNotInflateProgress(t *testing.T) {
	openTestCore(t)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "8")
		if requests.Add(1) == 2 {
			w.Write([]byte("abcd"))
			return
		}
		w.Write([]byte("abcdefgh"))
	}))
	t.Cleanup(server.Close)
	raw, _ := json.Marshal(request{ID: "single", URL: server.URL, Connections: 64, Retries: 3})
	if err := Begin(string(raw)); err != nil {
		t.Fatal(err)
	}
	state := waitState(t, "single", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, []byte("abcdefgh"))
	if state.Downloaded != 8 {
		t.Fatalf("progress includes discarded attempt: %d", state.Downloaded)
	}
}

func TestRepeatedPauseResumeKeepsNativeCheckpoint(t *testing.T) {
	openTestCore(t)
	f := serveFile(t, 2*1024*1024, 0)
	startFile(t, "repeat", f.server.URL+"/file", 16, 512*1024)
	var previous int64
	for i := 0; i < 4; i++ {
		waitState(t, "repeat", func(s snapshot) bool { return s.Downloaded > previous && s.Status != "done" })
		if err := Pause("repeat"); err != nil {
			t.Fatal(err)
		}
		paused := waitState(t, "repeat", func(s snapshot) bool { return s.Status == "pause" })
		previous = paused.Downloaded
		oldID := taskIDs["repeat"]
		startFile(t, "repeat", f.server.URL+"/refreshed", 16, 512*1024)
		if taskIDs["repeat"] != oldID {
			t.Fatal("valid checkpoint was discarded")
		}
	}
	assertPayload(t, waitState(t, "repeat", func(s snapshot) bool { return s.Status == "done" }), f.data)
}

func TestUcCookieResumeAfterRestartUsesFreshHeadersAndSavedRanges(t *testing.T) {
	storage, payload, key := openTestCore(t)
	data := make([]byte, 2*1024*1024)
	for i := range data {
		data[i] = byte((i*37 + i/101) % 251)
	}
	var fresh, rejected, resumed atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie := "__pus=fixture; __puus=before"
		if fresh.Load() != 0 {
			cookie = "__pus=fixture; __puus=after"
		}
		if r.Header.Get("Cookie") != cookie {
			rejected.Add(1)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var begin, end int
		if _, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &begin, &end); err != nil || begin < 0 || end < begin || end >= len(data) {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if fresh.Load() != 0 && begin > 0 {
			resumed.Add(1)
		}
		w.Header().Set("ETag", `"uc-original"`)
		w.Header().Set("Content-Length", fmt.Sprint(end-begin+1))
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", begin, end, len(data)))
		w.WriteHeader(http.StatusPartialContent)
		w.Write(data[begin : end+1])
	}))
	t.Cleanup(server.Close)
	start := func(cookie string) {
		t.Helper()
		raw, err := json.Marshal(request{
			ID: "uc-cookie-resume", URL: server.URL + "/file",
			Headers:     map[string]string{"Cookie": cookie, "If-Range": `"uc-original"`},
			Connections: 1, ConnectionProfile: "uc", Retries: 0, SpeedLimit: 512 * 1024,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := Begin(string(raw)); err != nil {
			t.Fatal(err)
		}
	}
	start("__pus=fixture; __puus=before")
	waitState(t, "uc-cookie-resume", func(s snapshot) bool { return s.Downloaded > 0 && s.Status != "done" })
	if err := Pause("uc-cookie-resume"); err != nil {
		t.Fatal(err)
	}
	paused := waitState(t, "uc-cookie-resume", func(s snapshot) bool { return s.Status == "pause" })
	previousID := taskIDs["uc-cookie-resume"]
	if err := Close(); err != nil {
		t.Fatal(err)
	}
	fresh.Store(1)
	if err := Open(storage, payload, key); err != nil {
		t.Fatal(err)
	}
	start("__pus=fixture; __puus=after")
	if taskIDs["uc-cookie-resume"] != previousID {
		t.Fatal("saved UC task was replaced instead of resumed")
	}
	state := waitState(t, "uc-cookie-resume", func(s snapshot) bool { return s.Status == "done" })
	assertPayload(t, state, data)
	if paused.Downloaded <= 0 || resumed.Load() == 0 || rejected.Load() != 0 {
		t.Fatalf("progress=%d resumed=%d rejected=%d", paused.Downloaded, resumed.Load(), rejected.Load())
	}
}

func TestUnknownLengthAndEmptyFiles(t *testing.T) {
	for _, contents := range []string{"", "unknown-length-payload"} {
		t.Run(fmt.Sprint(len(contents)), func(t *testing.T) {
			openTestCore(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Range") != "" {
					if contents == "" {
						w.Header().Set("Content-Range", "bytes */0")
						w.WriteHeader(416)
					} else {
						w.Header().Set("Content-Range", "bytes 0-0/*")
						w.WriteHeader(206)
						w.Write([]byte(contents[:1]))
					}
					return
				}
				w.(http.Flusher).Flush() // Chunked response without Content-Length.
				w.Write([]byte(contents))
			}))
			t.Cleanup(server.Close)
			raw, _ := json.Marshal(request{ID: "unknown", URL: server.URL, Connections: 64, Retries: 1})
			if err := Begin(string(raw)); err != nil {
				t.Fatal(err)
			}
			state := waitState(t, "unknown", func(s snapshot) bool { return s.Status == "done" })
			assertPayload(t, state, []byte(contents))
			if state.Downloaded != int64(len(contents)) {
				t.Fatal("incorrect stream length")
			}
		})
	}
}
