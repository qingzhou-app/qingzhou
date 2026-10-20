package dispatcher

import (
	"context"
	"errors"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/transport"
	"sync"
	"testing"
	"time"
)

type qzTestReader struct{ closed, interrupted bool }

func (r *qzTestReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	b := buf.New()
	b.Write([]byte("upload"))
	return buf.MultiBuffer{b}, nil
}
func (r *qzTestReader) Close() error { r.closed = true; return nil }
func (r *qzTestReader) Interrupt()   { r.interrupted = true }

type qzTestWriter struct{ fail, closed, interrupted bool }

func (w *qzTestWriter) WriteMultiBuffer(m buf.MultiBuffer) error {
	buf.ReleaseMulti(m)
	if w.fail {
		return errors.New("write failed")
	}
	return nil
}
func (w *qzTestWriter) Close() error { w.closed = true; return nil }
func (w *qzTestWriter) Interrupt()   { w.interrupted = true }

func TestQingzhouDomainTrafficDirectionsAndLifecycle(t *testing.T) {
	c := newQZDomainCollector(2)
	r, w := &qzTestReader{}, &qzTestWriter{}
	link := &transport.Link{Reader: r, Writer: w}
	c.wrap(link, "tun-in", "proxy", "Example.COM.")
	m, _ := link.Reader.ReadMultiBuffer()
	buf.ReleaseMulti(m)
	b := buf.New()
	b.Write([]byte("download"))
	if err := link.Writer.WriteMultiBuffer(buf.MultiBuffer{b}); err != nil {
		t.Fatal(err)
	}
	rows := c.snapshot().Entries
	if len(rows) != 1 || rows[0].Domain != "example.com" || rows[0].Upload != 6 || rows[0].Download != 8 {
		t.Fatalf("unexpected: %+v", rows)
	}
	link.Reader.(*qzDomainReader).Close()
	link.Reader.(*qzDomainReader).Interrupt()
	link.Writer.(*qzDomainWriter).Close()
	link.Writer.(*qzDomainWriter).Interrupt()
	if !r.closed || !r.interrupted || !w.closed || !w.interrupted {
		t.Fatal("lifecycle not forwarded")
	}
}
func TestQingzhouDomainTrafficExcludesProbesAndFailedWrites(t *testing.T) {
	c := newQZDomainCollector(2)
	r := &qzTestReader{}
	probe := &transport.Link{Reader: r, Writer: &qzTestWriter{}}
	c.wrap(probe, "probe-in", "proxy", "secret.example")
	if probe.Reader != r || len(c.snapshot().Entries) != 0 {
		t.Fatal("probe included")
	}
	link := &transport.Link{Reader: r, Writer: &qzTestWriter{fail: true}}
	c.wrap(link, "tun-in", "direct", "test.example")
	b := buf.New()
	b.Write([]byte("failed"))
	_ = link.Writer.WriteMultiBuffer(buf.MultiBuffer{b})
	if c.snapshot().Entries[0].Download != 0 {
		t.Fatal("failed write counted")
	}
}
func TestQingzhouDomainTrafficCapPreservesTotalsAndUnknown(t *testing.T) {
	c := newQZDomainCollector(1)
	c.counter("one.example", "proxy").upload.Add(10)
	c.counter("two.example", "proxy").upload.Add(20)
	c.counter("1.2.3.4", "direct").download.Add(30)
	var up, down int64
	foundOther, foundUnknown := false, false
	for _, r := range c.snapshot().Entries {
		up += r.Upload
		down += r.Download
		foundOther = foundOther || r.Domain == "__other__"
		foundUnknown = foundUnknown || r.Domain == "__unknown__"
	}
	if up != 30 || down != 30 || !foundOther || !foundUnknown {
		t.Fatal("lost totals/buckets")
	}
}
func TestQingzhouDomainTrafficConcurrentSnapshots(t *testing.T) {
	c := newQZDomainCollector(2)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				c.counter("a.example", "proxy").upload.Add(1)
				_ = c.snapshot()
			}
		}()
	}
	wg.Wait()
	if c.snapshot().Entries[0].Upload != 800 {
		t.Fatal("lost concurrent count")
	}
}

// A timeout-capable reader must keep its fast path; fallback readers must remain usable.
type qzTestTimeoutReader struct {
	qzTestReader
	timeoutCalls int
}

func (r *qzTestTimeoutReader) ReadMultiBufferTimeout(d time.Duration) (buf.MultiBuffer, error) {
	r.timeoutCalls++
	return r.ReadMultiBuffer()
}
func TestQingzhouDomainTrafficTimeoutReader(t *testing.T) {
	c := newQZDomainCollector(2)
	r := &qzTestTimeoutReader{}
	link := &transport.Link{Reader: r, Writer: &qzTestWriter{}}
	c.wrap(link, "tun-in", "proxy", "timeout.example")
	m, err := link.Reader.(buf.TimeoutReader).ReadMultiBufferTimeout(time.Second)
	buf.ReleaseMulti(m)
	if err != nil || r.timeoutCalls != 1 || c.snapshot().Entries[0].Upload != 6 {
		t.Fatal("timeout path lost or miscounted")
	}
}
func TestQingzhouDomainTrafficRedispatchCountsOnce(t *testing.T) {
	link := &transport.Link{Reader: &qzTestReader{}, Writer: &qzTestWriter{}}
	ctx := qingzhouTrackDomain(context.Background(), link, "tun-in", "proxy", "redispatch.example")
	reader := link.Reader
	before := reader.(*qzDomainReader).counter.upload.Load()
	ctx = qingzhouTrackDomain(ctx, link, "tun-in", "proxy", "redispatch.example")
	if link.Reader != reader {
		t.Fatal("redispatch wrapped the same payload twice")
	}
	m, _ := link.Reader.ReadMultiBuffer()
	buf.ReleaseMulti(m)
	if reader.(*qzDomainReader).counter.upload.Load()-before != 6 {
		t.Fatal("redispatch miscounted")
	}
}
