package dispatcher

// Qingzhou: bounded user-payload observations after routing/sniffing. Not billing counters.
// No paths, credentials, source IPs, or raw connection records are retained.
import (
	"context"
	"expvar"
	"fmt"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/buf"
	"github.com/xtls/xray-core/transport"
	"net"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type qzDomainCounter struct{ upload, download atomic.Int64 }
type qzDomainKey struct{ domain, route string }
type qzDomainEntry struct {
	Domain   string `json:"domain"`
	Route    string `json:"route"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
}
type qzDomainSnapshot struct {
	Session string          `json:"session"`
	Entries []qzDomainEntry `json:"entries"`
}
type qzDomainCollector struct {
	mu                sync.Mutex
	limit, namedCount int
	session           string
	counters          map[qzDomainKey]*qzDomainCounter
}

func newQZDomainCollector(limit int) *qzDomainCollector {
	return &qzDomainCollector{limit: limit, session: fmt.Sprintf("%d", time.Now().UnixNano()), counters: make(map[qzDomainKey]*qzDomainCounter)}
}

var qzDomainTraffic = newQZDomainCollector(512)

func init() {
	expvar.Publish("qingzhouDomainTraffic", expvar.Func(func() any { return qzDomainTraffic.snapshot() }))
}

func (c *qzDomainCollector) counter(domain, route string) *qzDomainCounter {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	if domain == "" || net.ParseIP(strings.Trim(domain, "[]")) != nil || len(domain) > 253 {
		domain = "__unknown__"
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	key := qzDomainKey{domain, route}
	if found := c.counters[key]; found != nil {
		return found
	}
	if domain != "__unknown__" {
		if c.namedCount >= c.limit {
			key.domain = "__other__"
		} else {
			c.namedCount++
		}
	}
	if found := c.counters[key]; found != nil {
		return found
	}
	result := &qzDomainCounter{}
	c.counters[key] = result
	return result
}
func (c *qzDomainCollector) snapshot() qzDomainSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	result := qzDomainSnapshot{Session: c.session, Entries: make([]qzDomainEntry, 0, len(c.counters))}
	for k, v := range c.counters {
		result.Entries = append(result.Entries, qzDomainEntry{k.domain, k.route, v.upload.Load(), v.download.Load()})
	}
	sort.Slice(result.Entries, func(i, j int) bool {
		a, b := result.Entries[i], result.Entries[j]
		if a.Domain == b.Domain {
			return a.Route < b.Route
		}
		return a.Domain < b.Domain
	})
	return result
}

func (c *qzDomainCollector) wrap(link *transport.Link, inbound, route, domain string) {
	if inbound != "tun-in" || (route != "proxy" && route != "direct") {
		return
	}
	counter := c.counter(domain, route)
	reader, ok := link.Reader.(buf.TimeoutReader)
	if !ok {
		reader = &buf.TimeoutWrapperReader{Reader: link.Reader}
	}
	link.Reader = &qzDomainReader{reader: reader, original: link.Reader, counter: counter}
	link.Writer = &qzDomainWriter{writer: link.Writer, counter: counter}
}

type qzTrafficContextKey struct{}

func qingzhouTrackDomain(ctx context.Context, link *transport.Link, inbound, route, domain string) context.Context {
	if ctx.Value(qzTrafficContextKey{}) != nil || inbound != "tun-in" || (route != "proxy" && route != "direct") {
		return ctx
	}
	qzDomainTraffic.wrap(link, inbound, route, domain)
	return context.WithValue(ctx, qzTrafficContextKey{}, true)
}

type qzDomainReader struct {
	reader   buf.TimeoutReader
	original buf.Reader
	counter  *qzDomainCounter
}

func (r *qzDomainReader) ReadMultiBuffer() (buf.MultiBuffer, error) {
	m, e := r.reader.ReadMultiBuffer()
	r.counter.upload.Add(int64(m.Len()))
	return m, e
}
func (r *qzDomainReader) ReadMultiBufferTimeout(d time.Duration) (buf.MultiBuffer, error) {
	m, e := r.reader.ReadMultiBufferTimeout(d)
	r.counter.upload.Add(int64(m.Len()))
	return m, e
}
func (r *qzDomainReader) Close() error { return common.Close(r.original) }
func (r *qzDomainReader) Interrupt()   { common.Interrupt(r.original) }

type qzDomainWriter struct {
	writer  buf.Writer
	counter *qzDomainCounter
}

func (w *qzDomainWriter) WriteMultiBuffer(m buf.MultiBuffer) error {
	n := int64(m.Len())
	err := w.writer.WriteMultiBuffer(m)
	if err == nil {
		w.counter.download.Add(n)
	}
	return err
}
func (w *qzDomainWriter) Close() error { return common.Close(w.writer) }
func (w *qzDomainWriter) Interrupt()   { common.Interrupt(w.writer) }
