package observability

import (
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	registerMetricsOnce sync.Once

	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "flowboard",
			Subsystem: "http",
			Name:      "requests_total",
			Help:      "Total number of HTTP requests handled by the backend.",
		},
		[]string{"method", "route", "status"},
	)
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Namespace: "flowboard",
			Subsystem: "http",
			Name:      "request_duration_seconds",
			Help:      "Latency of HTTP requests handled by the backend.",
			Buckets:   prometheus.DefBuckets,
		},
		[]string{"method", "route", "status"},
	)
	httpInflightRequests = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Namespace: "flowboard",
			Subsystem: "http",
			Name:      "inflight_requests",
			Help:      "Current number of HTTP requests being processed by the backend.",
		},
	)
)

func Register() {
	registerMetricsOnce.Do(func() {
		prometheus.MustRegister(httpRequestsTotal, httpRequestDuration, httpInflightRequests)
	})
}

func Middleware() gin.HandlerFunc {
	Register()

	return func(c *gin.Context) {
		startedAt := time.Now()
		httpInflightRequests.Inc()
		defer httpInflightRequests.Dec()

		c.Next()

		route := c.FullPath()
		if route == "" {
			route = "unmatched"
		}

		status := strconv.Itoa(c.Writer.Status())
		httpRequestsTotal.WithLabelValues(c.Request.Method, route, status).Inc()
		httpRequestDuration.WithLabelValues(c.Request.Method, route, status).Observe(time.Since(startedAt).Seconds())
	}
}

func Handler() gin.HandlerFunc {
	Register()
	return gin.WrapH(promhttp.Handler())
}
