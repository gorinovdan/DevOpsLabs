package tests

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"devopslabs/internal/domain"
	"devopslabs/internal/repository"
	"devopslabs/internal/service"
	"devopslabs/internal/transport/httpapi"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

const defaultOwner = "unassigned"

type taskResponse struct {
	ID          uint       `json:"id"`
	Title       string     `json:"title"`
	Description string     `json:"description"`
	Status      string     `json:"status"`
	Priority    string     `json:"priority"`
	Owner       string     `json:"owner"`
	EffortHours int        `json:"effortHours"`
	Tags        []string   `json:"tags"`
	DueDate     *time.Time `json:"dueDate"`
	StartedAt   *time.Time `json:"startedAt"`
	CompletedAt *time.Time `json:"completedAt"`
	Risk        string     `json:"risk"`
	Score       float64    `json:"score"`
}

func setupTestRouter(t *testing.T) (*gin.Engine, service.FixedClock) {
	t.Helper()
	gin.SetMode(gin.TestMode)

	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)

	require.NoError(t, db.AutoMigrate(&domain.Task{}))

	clock := service.FixedClock{NowValue: time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)}
	taskStore := repository.NewGormTaskStore(db)
	h := httpapi.NewTaskHandler(taskStore, clock)

	r := gin.New()
	r.Use(gin.Recovery())

	api := r.Group("/api")
	{
		api.GET("/tasks", h.List)
		api.GET("/tasks/:id", h.Get)
		api.POST("/tasks", h.Create)
		api.PUT("/tasks/:id", h.Update)
		api.DELETE("/tasks/:id", h.Delete)
		api.GET("/insights", h.Insights)
	}

	return r, clock
}

func performRequest(router *gin.Engine, method, path string, body []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	return w
}

func TestTaskCRUDFlow(t *testing.T) {
	router, clock := setupTestRouter(t)

	createBody := []byte(`{"title":"Write report","description":"Finish the DevOps report","status":"in_progress","priority":"high","owner":"","effortHours":0,"dueDate":"2026-02-10T12:00:00Z","tags":["DevOps","CI"]}`)
	createResp := performRequest(router, http.MethodPost, "/api/tasks", createBody)
	require.Equal(t, http.StatusCreated, createResp.Code)

	var created taskResponse
	require.NoError(t, json.Unmarshal(createResp.Body.Bytes(), &created))
	require.NotZero(t, created.ID)
	require.Equal(t, "Write report", created.Title)
	require.Equal(t, domain.StatusInProgress, created.Status)
	require.Equal(t, domain.PriorityHigh, created.Priority)
	require.Equal(t, defaultOwner, created.Owner)
	require.Equal(t, 1, created.EffortHours)
	require.NotNil(t, created.StartedAt)
	require.Equal(t, service.RiskOnTrack, created.Risk)
	require.InDelta(t, 35.1, created.Score, 0.01)
	require.ElementsMatch(t, []string{"devops", "ci"}, created.Tags)

	listResp := performRequest(router, http.MethodGet, "/api/tasks?status=in_progress&sort=score", nil)
	require.Equal(t, http.StatusOK, listResp.Code)

	var list []taskResponse
	require.NoError(t, json.Unmarshal(listResp.Body.Bytes(), &list))
	require.Len(t, list, 1)

	getResp := performRequest(router, http.MethodGet, "/api/tasks/"+itoa(created.ID), nil)
	require.Equal(t, http.StatusOK, getResp.Code)

	patchBody := []byte(`{"title":"Write report v2","owner":"","effortHours":5,"priority":"critical","dueDate":"2026-02-11T12:00:00Z"}`)
	patchResp := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), patchBody)
	require.Equal(t, http.StatusOK, patchResp.Code)

	var patched taskResponse
	require.NoError(t, json.Unmarshal(patchResp.Body.Bytes(), &patched))
	require.Equal(t, "Write report v2", patched.Title)
	require.Equal(t, defaultOwner, patched.Owner)
	require.Equal(t, 5, patched.EffortHours)
	require.Equal(t, domain.PriorityCritical, patched.Priority)
	require.NotNil(t, patched.DueDate)

	updateBody := []byte(`{"status":"done","dueDate":null,"tags":["release"]}`)
	updateResp := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), updateBody)
	require.Equal(t, http.StatusOK, updateResp.Code)

	var updated taskResponse
	require.NoError(t, json.Unmarshal(updateResp.Body.Bytes(), &updated))
	require.Equal(t, domain.StatusDone, updated.Status)
	require.Nil(t, updated.DueDate)
	require.NotNil(t, updated.CompletedAt)
	require.ElementsMatch(t, []string{"release"}, updated.Tags)
	require.Equal(t, service.RiskCompleted, updated.Risk)
	require.WithinDuration(t, clock.NowValue, *updated.CompletedAt, 0)

	forceUpdate := []byte(`{"status":"todo"}`)
	forceResp := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID)+"?force=true", forceUpdate)
	require.Equal(t, http.StatusOK, forceResp.Code)

	var forced taskResponse
	require.NoError(t, json.Unmarshal(forceResp.Body.Bytes(), &forced))
	require.Equal(t, domain.StatusTodo, forced.Status)
	require.Nil(t, forced.StartedAt)
	require.Nil(t, forced.CompletedAt)

	insightsResp := performRequest(router, http.MethodGet, "/api/insights", nil)
	require.Equal(t, http.StatusOK, insightsResp.Code)

	var insights service.Insights
	require.NoError(t, json.Unmarshal(insightsResp.Body.Bytes(), &insights))
	require.Equal(t, 1, insights.Total)

	deleteResp := performRequest(router, http.MethodDelete, "/api/tasks/"+itoa(created.ID), nil)
	require.Equal(t, http.StatusNoContent, deleteResp.Code)

	getResp = performRequest(router, http.MethodGet, "/api/tasks/"+itoa(created.ID), nil)
	require.Equal(t, http.StatusNotFound, getResp.Code)
}

func TestTaskHandlerErrors(t *testing.T) {
	router, _ := setupTestRouter(t)

	badCreate := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":""}`))
	require.Equal(t, http.StatusBadRequest, badCreate.Code)

	badJSON := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{`))
	require.Equal(t, http.StatusBadRequest, badJSON.Code)

	badPriority := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"X","priority":"p0"}`))
	require.Equal(t, http.StatusBadRequest, badPriority.Code)

	badEffort := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"X","effortHours":300}`))
	require.Equal(t, http.StatusBadRequest, badEffort.Code)

	badDue := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"X","dueDate":"nope"}`))
	require.Equal(t, http.StatusBadRequest, badDue.Code)

	badTags := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"X","tags":["this-tag-name-is-way-too-long"]}`))
	require.Equal(t, http.StatusBadRequest, badTags.Code)

	longTitle := strings.Repeat("a", 201)
	badTitle := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"`+longTitle+`"}`))
	require.Equal(t, http.StatusBadRequest, badTitle.Code)

	badStatus := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"X","status":"weird"}`))
	require.Equal(t, http.StatusBadRequest, badStatus.Code)

	invalidStatusList := performRequest(router, http.MethodGet, "/api/tasks?status=unknown", nil)
	require.Equal(t, http.StatusBadRequest, invalidStatusList.Code)

	invalidPriorityList := performRequest(router, http.MethodGet, "/api/tasks?priority=unknown", nil)
	require.Equal(t, http.StatusBadRequest, invalidPriorityList.Code)

	invalidInsights := performRequest(router, http.MethodGet, "/api/insights?priority=unknown", nil)
	require.Equal(t, http.StatusBadRequest, invalidInsights.Code)

	invalidID := performRequest(router, http.MethodGet, "/api/tasks/abc", nil)
	require.Equal(t, http.StatusBadRequest, invalidID.Code)

	invalidDelete := performRequest(router, http.MethodDelete, "/api/tasks/abc", nil)
	require.Equal(t, http.StatusBadRequest, invalidDelete.Code)

	create := performRequest(router, http.MethodPost, "/api/tasks", []byte(`{"title":"Deploy","status":"todo","priority":"low"}`))
	require.Equal(t, http.StatusCreated, create.Code)

	var created taskResponse
	require.NoError(t, json.Unmarshal(create.Body.Bytes(), &created))

	invalidTransition := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"status":"done"}`))
	require.Equal(t, http.StatusBadRequest, invalidTransition.Code)

	badUpdateJSON := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{`))
	require.Equal(t, http.StatusBadRequest, badUpdateJSON.Code)

	invalidUpdateID := performRequest(router, http.MethodPut, "/api/tasks/abc", []byte(`{"description":"x"}`))
	require.Equal(t, http.StatusBadRequest, invalidUpdateID.Code)

	emptyTitleUpdate := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"title":""}`))
	require.Equal(t, http.StatusBadRequest, emptyTitleUpdate.Code)

	badUpdateStatus := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"status":"invalid"}`))
	require.Equal(t, http.StatusBadRequest, badUpdateStatus.Code)

	badUpdatePriority := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"priority":"invalid"}`))
	require.Equal(t, http.StatusBadRequest, badUpdatePriority.Code)

	badUpdateEffort := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"effortHours":-2}`))
	require.Equal(t, http.StatusBadRequest, badUpdateEffort.Code)

	badUpdateTitle := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"title":"`+longTitle+`"}`))
	require.Equal(t, http.StatusBadRequest, badUpdateTitle.Code)

	badUpdateDate := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"dueDate":"bad"}`))
	require.Equal(t, http.StatusBadRequest, badUpdateDate.Code)

	badUpdateTags := performRequest(router, http.MethodPut, "/api/tasks/"+itoa(created.ID), []byte(`{"tags":"oops"}`))
	require.Equal(t, http.StatusBadRequest, badUpdateTags.Code)

	updateMissing := performRequest(router, http.MethodPut, "/api/tasks/999", []byte(`{"description":"x"}`))
	require.Equal(t, http.StatusNotFound, updateMissing.Code)
}

func TestRouterHealthAndCORS(t *testing.T) {
	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)
	require.NoError(t, db.AutoMigrate(&domain.Task{}))

	taskStore := repository.NewGormTaskStore(db)
	router := httpapi.NewRouter(taskStore)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	resp := httptest.NewRecorder()
	router.ServeHTTP(resp, req)
	require.Equal(t, http.StatusOK, resp.Code)
	require.Contains(t, resp.Body.String(), "ok")

	opts := httptest.NewRequest(http.MethodOptions, "/api/tasks", nil)
	optResp := httptest.NewRecorder()
	router.ServeHTTP(optResp, opts)
	require.Equal(t, http.StatusNoContent, optResp.Code)
	require.Equal(t, "*", optResp.Header().Get("Access-Control-Allow-Origin"))
}

func itoa(id uint) string {
	return strconv.FormatUint(uint64(id), 10)
}
