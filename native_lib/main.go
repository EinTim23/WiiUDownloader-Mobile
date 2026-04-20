package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	wiiudownloader "github.com/Xpl0itU/WiiUDownloader"
)

/*
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    const char* name;
    uint64_t title_id;
    uint8_t region;
    uint8_t key;
    uint8_t category;
} TitleEntry;

typedef struct {
    TitleEntry* data;
    int length;
} TitleEntryArray;

typedef void (*OnGameTitleFn)(const char*);
typedef void (*OnProgressFn)(int64_t, const char*);
typedef void (*OnDecryptionFn)(double);
typedef void (*OnSizeFn)(int64_t);
typedef void (*OnDoneFn)(const char*);

static inline void callOnGameTitle(OnGameTitleFn fn, const char* t) { fn(t); }
static inline void callOnProgress(OnProgressFn fn, int64_t d, const char* f) { fn(d, f); }
static inline void callOnDecryption(OnDecryptionFn fn, double p) { fn(p); }
static inline void callOnSize(OnSizeFn fn, int64_t s) { fn(s); }
static inline void callOnDone(OnDoneFn fn, const char* e) { fn(e); }
*/
import "C"

func normalizeFilename(filename string) string {
	var out strings.Builder
	shouldAppend := true
	firstChar := true

	for _, c := range filename {
		switch {
		case c == '_':
			if shouldAppend {
				out.WriteRune('_')
				shouldAppend = false
			}
			firstChar = false
		case c == ' ':
			if shouldAppend && !firstChar {
				out.WriteRune(' ')
				shouldAppend = false
			}
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'):
			out.WriteRune(c)
			shouldAppend = true
			firstChar = false
		}
	}

	result := out.String()
	if len(result) > 0 && result[len(result)-1] == '_' {
		result = result[:len(result)-1]
	}

	return result
}

//export SetTempDir
func SetTempDir(dir *C.char) {
	os.Setenv("TMPDIR", C.GoString(dir))
}

//export Search
func Search(query *C.char, category C.uint8_t, region C.uint8_t) C.TitleEntryArray {
	if category > 5 {
		return C.TitleEntryArray{data: nil, length: 0}
	}

	entries := wiiudownloader.GetTitleEntries(uint8(category))

	goQuery := strings.ToLower(C.GoString(query))
	regionFilter := uint8(region)

	if goQuery != "" || regionFilter != 0 {
		filtered := make([]wiiudownloader.TitleEntry, 0, len(entries))
		for _, e := range entries {
			if regionFilter != 0 && e.Region&regionFilter == 0 {
				continue
			}
			if goQuery != "" && !strings.Contains(strings.ToLower(e.Name), goQuery) {
				continue
			}
			filtered = append(filtered, e)
		}
		entries = filtered
	}

	n := len(entries)
	size := C.size_t(n) * C.size_t(unsafe.Sizeof(C.TitleEntry{}))
	ptr := C.malloc(size)

	slice := unsafe.Slice((*C.TitleEntry)(ptr), n)

	for i, te := range entries {
		cName := C.CString(te.Name)

		slice[i] = C.TitleEntry{
			name:     cName,
			title_id: C.uint64_t(te.TitleID),
			region:   C.uint8_t(te.Region),
			key:      C.uint8_t(te.Key),
			category: C.uint8_t(te.Category),
		}
	}

	return C.TitleEntryArray{
		data:   (*C.TitleEntry)(ptr),
		length: C.int(n),
	}
}

//export FreeTitleEntries
func FreeTitleEntries(arr C.TitleEntryArray) {
	if arr.data == nil || arr.length <= 0 {
		return
	}

	n := int(arr.length)

	slice := unsafe.Slice((*C.TitleEntry)(arr.data), n)

	for i := 0; i < n; i++ {
		if slice[i].name != nil {
			C.free(unsafe.Pointer(slice[i].name))
		}
	}

	C.free(unsafe.Pointer(arr.data))
}

type callbackReporter struct {
	onGameTitle     C.OnGameTitleFn
	onProgress      C.OnProgressFn
	onDecryption    C.OnDecryptionFn
	onSize          C.OnSizeFn
	cancelled       *C.int
	totalDownloaded int64
}

func (r *callbackReporter) SetGameTitle(title string) {
	C.callOnGameTitle(r.onGameTitle, C.CString(title))
}

func (r *callbackReporter) UpdateDownloadProgress(downloaded int64, filename string) {
	r.totalDownloaded += downloaded
	C.callOnProgress(r.onProgress, C.int64_t(r.totalDownloaded), C.CString(filename))
}

func (r *callbackReporter) UpdateDecryptionProgress(progress float64) {
	C.callOnDecryption(r.onDecryption, C.double(progress))
}

func (r *callbackReporter) Cancelled() bool {
	return *r.cancelled != 0
}

func (r *callbackReporter) SetCancelled() {
	*r.cancelled = 1
}

func (r *callbackReporter) SetDownloadSize(size int64) {
	C.callOnSize(r.onSize, C.int64_t(size))
}

func (r *callbackReporter) ResetTotals()                     {}
func (r *callbackReporter) MarkFileAsDone(filename string)   {}
func (r *callbackReporter) SetStartTime(startTime time.Time) {}

func (r *callbackReporter) SetTotalDownloadedForFile(filename string, downloaded int64) {
	r.totalDownloaded += downloaded
	C.callOnProgress(r.onProgress, C.int64_t(r.totalDownloaded), C.CString(filename))
}

//export DownloadTitle
func DownloadTitle(
	titleid *C.char,
	outputPath *C.char,
	onGameTitle C.OnGameTitleFn,
	onProgress C.OnProgressFn,
	onDecryption C.OnDecryptionFn,
	onSize C.OnSizeFn,
	cancelled *C.int,
	onDone C.OnDoneFn,
	doDecrypt C.int,
) {
	tid := C.GoString(titleid)
	out := C.GoString(outputPath)

	tid_int, err := strconv.ParseUint(tid, 16, 64)
	if err != nil {
		fmt.Println("conversion error:", err)
		return
	}

	title_entry := wiiudownloader.GetTitleEntryFromTid(tid_int)

	out = filepath.Join(out, fmt.Sprintf("%s [%s] [%s]", normalizeFilename(title_entry.Name), wiiudownloader.GetFormattedKind(title_entry.TitleID), tid))

	go func() {
		reporter := &callbackReporter{
			onGameTitle:  onGameTitle,
			onProgress:   onProgress,
			onDecryption: onDecryption,
			onSize:       onSize,
			cancelled:    cancelled,
		}
		client := &http.Client{}
		decrypt := doDecrypt != 0
		err := wiiudownloader.DownloadTitle(tid, out, decrypt, reporter, decrypt, client)
		if err != nil {
			C.callOnDone(onDone, C.CString(err.Error()))
		} else {
			C.callOnDone(onDone, nil)
		}
	}()
}

func main() {}
