package conformance

import "io"

type counterReader struct {
	pos, end, seed int64
}

// CounterReader streams bytes [start, end) of the counter pattern described by g.
// Positions are absolute, so a range equals the same slice of the full stream.
func CounterReader(g Generate, start, end int64) io.Reader {
	return &counterReader{pos: start, end: end, seed: int64(g.Seed)}
}

func (c *counterReader) Read(p []byte) (int, error) {
	if c.pos >= c.end {
		return 0, io.EOF
	}
	n := int64(len(p))
	if rem := c.end - c.pos; rem < n {
		n = rem
	}
	for i := int64(0); i < n; i++ {
		p[i] = byte((c.pos + i + c.seed) % 256)
	}
	c.pos += n
	return int(n), nil
}
