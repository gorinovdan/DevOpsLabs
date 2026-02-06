package httpapi

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"devopslabs/internal/domain"
	"devopslabs/internal/repository"
	"devopslabs/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type stubStore struct {
	task      domain.Task
	listErr   error
	getErr    error
	createErr error
	updateErr error
	deleteErr error
}

func (s stubStore) List(ctx context.Context, filter repository.TaskFilter) ([]domain.Task, error) {
	if s.listErr != nil {
		return nil, s.listErr
	}
	return []domain.Task{s.task}, nil
}

func (s stubStore) Get(ctx context.Context, id uint) (*domain.Task, error) {
	if s.getErr != nil {
		return nil, s.getErr
	}
	return &s.task, nil
}

func (s stubStore) Create(ctx context.Context, task *domain.Task) error {
	return s.createErr
}

func (s stubStore) Update(ctx context.Context, task *domain.Task) error {
	return s.updateErr
}

func (s stubStore) Delete(ctx context.Context, id uint) error {
	return s.deleteErr
}

func TestNewTaskHandlerDefaultClock(t *testing.T) {
	h := NewTaskHandler(stubStore{}, nil)
	require.NotNil(t, h.clock)
	require.NotNil(t, h.clock.Now())
}

func TestHandlerStoreErrors(t *testing.T) {
	gin.SetMode(gin.TestMode)

	task := domain.Task{
		ID:          1,
		Title:       "Test",
		Status:      domain.StatusTodo,
		Priority:    domain.PriorityLow,
		EffortHours: 1,
		CreatedAt:   time.Now(),
	}
	clock := service.FixedClock{NowValue: time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)}

	listHandler := NewTaskHandler(stubStore{listErr: errors.New("fail")}, clock)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/tasks", nil)
	listHandler.List(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	getHandler := NewTaskHandler(stubStore{getErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/tasks/1", nil)
	c.Params = gin.Params{{Key: "id", Value: "1"}}
	getHandler.Get(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	createHandler := NewTaskHandler(stubStore{createErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewBufferString(`{"title":"A"}`))
	c.Request.Header.Set("Content-Type", "application/json")
	createHandler.Create(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	updateHandler := NewTaskHandler(stubStore{task: task, updateErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPut, "/api/tasks/1", bytes.NewBufferString(`{"description":"x"}`))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: "1"}}
	updateHandler.Update(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	updateGetHandler := NewTaskHandler(stubStore{getErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPut, "/api/tasks/1", bytes.NewBufferString(`{"description":"x"}`))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: "1"}}
	updateGetHandler.Update(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	deleteHandler := NewTaskHandler(stubStore{deleteErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodDelete, "/api/tasks/1", nil)
	c.Params = gin.Params{{Key: "id", Value: "1"}}
	deleteHandler.Delete(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)

	insightsHandler := NewTaskHandler(stubStore{listErr: errors.New("fail")}, clock)
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodGet, "/api/insights", nil)
	insightsHandler.Insights(c)
	require.Equal(t, http.StatusInternalServerError, w.Code)
}

func TestHandlerApplyStatusError(t *testing.T) {
	original := applyStatusTransition
	applyStatusTransition = func(now time.Time, task *domain.Task, newStatus string, force bool) error {
		return errors.New("apply failed")
	}
	t.Cleanup(func() { applyStatusTransition = original })

	clock := service.FixedClock{NowValue: time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)}
	handler := NewTaskHandler(stubStore{}, clock)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewBufferString(`{"title":"A"}`))
	c.Request.Header.Set("Content-Type", "application/json")

	handler.Create(c)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestHandlerHelpers(t *testing.T) {
	empty := ""
	nullRaw := []byte("null")

	date, err := parseDueDate(nil)
	require.NoError(t, err)
	require.Nil(t, date)

	date, err = parseDueDate(&empty)
	require.NoError(t, err)
	require.Nil(t, date)

	set, value, err := parseDueDatePatch([]byte{})
	require.NoError(t, err)
	require.False(t, set)
	require.Nil(t, value)

	set, value, err = parseDueDatePatch(nullRaw)
	require.NoError(t, err)
	require.True(t, set)
	require.Nil(t, value)

	set, value, err = parseDueDatePatch([]byte(`"2026-02-10T12:00:00Z"`))
	require.NoError(t, err)
	require.True(t, set)
	require.NotNil(t, value)

	set, _, err = parseDueDatePatch([]byte(`"bad"`))
	require.Error(t, err)
	require.True(t, set)

	set, _, err = parseDueDatePatch([]byte(`{`))
	require.Error(t, err)
	require.True(t, set)

	set, tags, err := parseTagsPatch([]byte{})
	require.NoError(t, err)
	require.False(t, set)
	require.Nil(t, tags)

	set, tags, err = parseTagsPatch(nullRaw)
	require.NoError(t, err)
	require.True(t, set)
	require.Len(t, tags, 0)

	set, tags, err = parseTagsPatch([]byte(`["ci"]`))
	require.NoError(t, err)
	require.True(t, set)
	require.Equal(t, domain.StringList{"ci"}, tags)

	set, _, err = parseTagsPatch([]byte(`{"bad":true}`))
	require.Error(t, err)
	require.True(t, set)

	set, _, err = parseTagsPatch([]byte(`["this-tag-name-is-way-too-long"]`))
	require.Error(t, err)
	require.True(t, set)

	_, err = normalizeEffort(-1)
	require.Error(t, err)

	effort, err := normalizeEffort(0)
	require.NoError(t, err)
	require.Equal(t, 1, effort)

	effort, err = normalizeEffort(5)
	require.NoError(t, err)
	require.Equal(t, 5, effort)

	_, err = normalizeEffort(999)
	require.Error(t, err)

	values, err := parseCSVEnum(" , ", service.NormalizeStatus)
	require.NoError(t, err)
	require.Len(t, values, 0)
}
