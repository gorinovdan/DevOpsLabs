package httpapi

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"devopslabs/internal/domain"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestRouterExposesPrometheusMetrics(t *testing.T) {
	gin.SetMode(gin.TestMode)

	router := NewRouter(stubStore{
		task: domain.Task{
			ID:          1,
			Title:       "Demo",
			Status:      domain.StatusTodo,
			Priority:    domain.PriorityLow,
			EffortHours: 1,
			CreatedAt:   time.Now().UTC(),
			UpdatedAt:   time.Now().UTC(),
		},
	})

	requestRecorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/tasks", nil)
	router.ServeHTTP(requestRecorder, request)
	require.Equal(t, http.StatusOK, requestRecorder.Code)

	metricsRecorder := httptest.NewRecorder()
	metricsRequest := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	router.ServeHTTP(metricsRecorder, metricsRequest)

	require.Equal(t, http.StatusOK, metricsRecorder.Code)
	require.Contains(t, metricsRecorder.Body.String(), "flowboard_http_requests_total")
	require.Contains(t, metricsRecorder.Body.String(), `route="/api/tasks"`)
}
