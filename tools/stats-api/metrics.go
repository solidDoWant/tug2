package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics bundles the Prometheus registry and the HTTP request instruments. It
// is served on its own port (see METRICS_ADDR) rather than on the API listener
// so operators can scrape it without it ever being reachable by API consumers or
// appearing in the generated OpenAPI spec.
type Metrics struct {
	registry *prometheus.Registry
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
	inflight prometheus.Gauge
}

// NewMetrics builds the registry, wiring in the default Go runtime/process
// collectors, the connection-pool collector, and the HTTP instruments.
//
// statFn is the pool-stats accessor (Store.Stat); passing the function rather
// than the pool keeps the pool owned by the store.
func NewMetrics(statFn func() *pgxpool.Stat) *Metrics {
	reg := prometheus.NewRegistry()

	// Go runtime + process collectors give operators GC, goroutine, fd, and
	// memory series for free.
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	// Pool saturation is the most likely failure mode for this read-only API,
	// so make pool_max_conns sizing observable.
	reg.MustRegister(newPoolCollector(statFn))

	m := &Metrics{
		registry: reg,
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total HTTP requests by matched route, method, and status code.",
		}, []string{"route", "method", "code"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds by matched route and method.",
			Buckets: prometheus.DefBuckets,
		}, []string{"route", "method"}),
		inflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "HTTP requests currently being served.",
		}),
	}
	reg.MustRegister(m.requests, m.duration, m.inflight)

	return m
}

// Handler builds the /metrics handler served on the metrics port.
func (m *Metrics) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{}))
	return mux
}

// Instrument wraps the API mux, recording request count and latency labelled by
// the matched route *pattern* (e.g. "GET /api/v1/players/{steam_id}") rather than
// the raw path, so high-cardinality path params like {steam_id} cannot explode
// the metric series.
//
// mux.Handler resolves the pattern for the label; the request is then served via
// mux.ServeHTTP so the standard-library router still populates path values for
// the huma handlers (calling the matched handler directly would skip that).
func (m *Metrics) Instrument(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, pattern := mux.Handler(r)
		if pattern == "" {
			pattern = "unmatched"
		}

		m.inflight.Inc()
		defer m.inflight.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		mux.ServeHTTP(rec, r)
		elapsed := time.Since(start).Seconds()

		m.requests.WithLabelValues(pattern, r.Method, strconv.Itoa(rec.status)).Inc()
		m.duration.WithLabelValues(pattern, r.Method).Observe(elapsed)
	})
}

// statusRecorder captures the response status code for the request metrics,
// defaulting to 200 for handlers that write a body without an explicit
// WriteHeader.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if !r.wroteHeader {
		r.status = code
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	r.wroteHeader = true
	return r.ResponseWriter.Write(b)
}

// poolCollector turns a pgxpool.Stat snapshot into Prometheus series, read lazily
// at scrape time so there is no overhead between scrapes.
type poolCollector struct {
	stat func() *pgxpool.Stat

	acquired        *prometheus.Desc
	idle            *prometheus.Desc
	total           *prometheus.Desc
	max             *prometheus.Desc
	acquireCount    *prometheus.Desc
	emptyAcquire    *prometheus.Desc
	canceledAcquire *prometheus.Desc
}

func newPoolCollector(stat func() *pgxpool.Stat) *poolCollector {
	return &poolCollector{
		stat:            stat,
		acquired:        prometheus.NewDesc("pgxpool_acquired_conns", "Connections currently acquired from the pool and in use.", nil, nil),
		idle:            prometheus.NewDesc("pgxpool_idle_conns", "Idle connections currently in the pool.", nil, nil),
		total:           prometheus.NewDesc("pgxpool_total_conns", "Total connections currently in the pool (acquired plus idle).", nil, nil),
		max:             prometheus.NewDesc("pgxpool_max_conns", "Maximum connections the pool is configured to hold (pool_max_conns).", nil, nil),
		acquireCount:    prometheus.NewDesc("pgxpool_acquire_total", "Cumulative count of successful connection acquisitions.", nil, nil),
		emptyAcquire:    prometheus.NewDesc("pgxpool_empty_acquire_total", "Cumulative acquisitions that had to wait because the pool was empty.", nil, nil),
		canceledAcquire: prometheus.NewDesc("pgxpool_canceled_acquire_total", "Cumulative acquisitions canceled by a context before completing.", nil, nil),
	}
}

func (c *poolCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- c.acquired
	ch <- c.idle
	ch <- c.total
	ch <- c.max
	ch <- c.acquireCount
	ch <- c.emptyAcquire
	ch <- c.canceledAcquire
}

func (c *poolCollector) Collect(ch chan<- prometheus.Metric) {
	s := c.stat()
	ch <- prometheus.MustNewConstMetric(c.acquired, prometheus.GaugeValue, float64(s.AcquiredConns()))
	ch <- prometheus.MustNewConstMetric(c.idle, prometheus.GaugeValue, float64(s.IdleConns()))
	ch <- prometheus.MustNewConstMetric(c.total, prometheus.GaugeValue, float64(s.TotalConns()))
	ch <- prometheus.MustNewConstMetric(c.max, prometheus.GaugeValue, float64(s.MaxConns()))
	ch <- prometheus.MustNewConstMetric(c.acquireCount, prometheus.CounterValue, float64(s.AcquireCount()))
	ch <- prometheus.MustNewConstMetric(c.emptyAcquire, prometheus.CounterValue, float64(s.EmptyAcquireCount()))
	ch <- prometheus.MustNewConstMetric(c.canceledAcquire, prometheus.CounterValue, float64(s.CanceledAcquireCount()))
}
