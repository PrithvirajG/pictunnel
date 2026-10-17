package probe

import (
	"encoding/binary"
	"io"
	"time"
)

// mp4Epoch is the ISO-BMFF / QuickTime time origin.
var mp4Epoch = time.Date(1904, 1, 1, 0, 0, 0, 0, time.UTC)

// maxBoxDepth bounds nesting so crafted input cannot recurse deeply.
const maxBoxDepth = 4

// mvhdDate finds moov/mvhd within the first limit bytes and returns its
// creation time. A zero creation time is reported as unknown.
func mvhdDate(r io.ReaderAt, limit int64) (DateResult, bool) {
	start, end, ok := findBox(r, 0, limit, "moov", 0)
	if !ok {
		return DateResult{}, false
	}
	mStart, mEnd, ok := findBox(r, start, end, "mvhd", 1)
	if !ok {
		return DateResult{}, false
	}
	var hdr [12]byte
	if mEnd-mStart < 8 {
		return DateResult{}, false
	}
	n := min(mEnd-mStart, int64(len(hdr)))
	if _, err := r.ReadAt(hdr[:n], mStart); err != nil && err != io.EOF {
		return DateResult{}, false
	}
	var secs uint64
	switch hdr[0] {
	case 0:
		secs = uint64(binary.BigEndian.Uint32(hdr[4:8]))
	case 1:
		if n < 12 {
			return DateResult{}, false
		}
		secs = binary.BigEndian.Uint64(hdr[4:12])
	default:
		return DateResult{}, false
	}
	if secs == 0 || secs > uint64((maxYear-1904)*366*24*3600) {
		return DateResult{}, false
	}
	t := mp4Epoch.Add(time.Duration(secs) * time.Second)
	if !plausible(t) {
		return DateResult{}, false
	}
	return DateResult{Time: t, Source: SourceContainer}, true
}

// findBox scans sibling boxes in [off, end) for typ and returns its payload
// range, clipped to end. depth is only used to bound recursion by callers.
func findBox(r io.ReaderAt, off, end int64, typ string, depth int) (int64, int64, bool) {
	if depth > maxBoxDepth {
		return 0, 0, false
	}
	var h [16]byte
	for off+8 <= end {
		if _, err := r.ReadAt(h[:8], off); err != nil {
			return 0, 0, false
		}
		size := int64(binary.BigEndian.Uint32(h[:4]))
		hdrLen := int64(8)
		switch size {
		case 0: // extends to end of file
			size = end - off
		case 1: // 64-bit largesize follows
			if off+16 > end {
				return 0, 0, false
			}
			if _, err := r.ReadAt(h[8:16], off+8); err != nil {
				return 0, 0, false
			}
			ls := binary.BigEndian.Uint64(h[8:16])
			if ls > uint64(1<<62) {
				return 0, 0, false
			}
			size, hdrLen = int64(ls), 16
		}
		if size < hdrLen {
			return 0, 0, false
		}
		if string(h[4:8]) == typ {
			payloadEnd := off + size
			if payloadEnd > end || payloadEnd < off {
				payloadEnd = end
			}
			return off + hdrLen, payloadEnd, true
		}
		if size > end-off {
			return 0, 0, false
		}
		off += size
	}
	return 0, 0, false
}
