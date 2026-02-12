package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"devopslabs/internal/domain"
	"devopslabs/internal/repository"
	"devopslabs/internal/service"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

const (
	defaultOwner     = "unassigned"
	maxTitleLength   = 200
	maxEffortHours   = 200
	defaultEffortVal = 1
)

var applyStatusTransition = service.ApplyStatusTransition

type TaskHandler struct {
	store repository.TaskStore
	clock service.Clock
}

type TaskResponse struct {
	domain.Task
	Risk       string   `json:"risk"`
	Score      float64  `json:"score"`
	AgeHours   float64  `json:"ageHours"`
	CycleHours *float64 `json:"cycleHours,omitempty"`
}

type TaskCreateRequest struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Status      string   `json:"status"`
	Priority    string   `json:"priority"`
	Owner       string   `json:"owner"`
	EffortHours int      `json:"effortHours"`
	DueDate     *string  `json:"dueDate"`
	Tags        []string `json:"tags"`
}

type TaskUpdateRequest struct {
	Title       *string         `json:"title"`
	Description *string         `json:"description"`
	Status      *string         `json:"status"`
	Priority    *string         `json:"priority"`
	Owner       *string         `json:"owner"`
	EffortHours *int            `json:"effortHours"`
	DueDate     json.RawMessage `json:"dueDate"`
	Tags        json.RawMessage `json:"tags"`
}

type ListQuery struct {
	Statuses   []string
	Priorities []string
	Owner      string
	Tag        string
	Search     string
	Sort       service.SortOption
}

func NewTaskHandler(store repository.TaskStore, clock service.Clock) *TaskHandler {
	if clock == nil {
		clock = service.RealClock{}
	}
	return &TaskHandler{store: store, clock: clock}
}

func (h *TaskHandler) List(c *gin.Context) {
	filter, sortOption, err := parseListQuery(c)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	tasks, err := h.store.List(c.Request.Context(), repository.TaskFilter{
		Statuses:   filter.Statuses,
		Priorities: filter.Priorities,
		Owner:      filter.Owner,
		Query:      filter.Search,
		Tag:        filter.Tag,
	})
	if err != nil {
		respondError(c, http.StatusInternalServerError, "не удалось получить список задач")
		return
	}

	now := h.clock.Now()
	service.SortTasks(tasks, sortOption, now)

	response := make([]TaskResponse, 0, len(tasks))
	for _, task := range tasks {
		response = append(response, toTaskResponse(task, now))
	}

	c.JSON(http.StatusOK, response)
}

func (h *TaskHandler) Get(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}

	task, err := h.store.Get(c.Request.Context(), id)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			respondError(c, http.StatusNotFound, "задача не найдена")
			return
		}
		respondError(c, http.StatusInternalServerError, "не удалось получить задачу")
		return
	}

	c.JSON(http.StatusOK, toTaskResponse(*task, h.clock.Now()))
}

func (h *TaskHandler) Create(c *gin.Context) {
	var req TaskCreateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "некорректное тело запроса")
		return
	}

	title := strings.TrimSpace(req.Title)
	if title == "" {
		respondError(c, http.StatusBadRequest, "нужно указать название")
		return
	}
	if len(title) > maxTitleLength {
		respondError(c, http.StatusBadRequest, "слишком длинное название")
		return
	}

	status, err := service.NormalizeStatus(req.Status)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	priority, err := service.NormalizePriority(req.Priority)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	effortHours, err := normalizeEffort(req.EffortHours)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	tags, err := service.NormalizeTags(req.Tags)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	down := strings.TrimSpace(req.Owner)
	if down == "" {
		down = defaultOwner
	}

	dueDate, err := parseDueDate(req.DueDate)
	if err != nil {
		respondError(c, http.StatusBadRequest, "некорректная дата; используйте RFC3339")
		return
	}

	now := h.clock.Now()
	task := domain.Task{
		Title:       title,
		Description: strings.TrimSpace(req.Description),
		Status:      status,
		Priority:    priority,
		Owner:       down,
		EffortHours: effortHours,
		Tags:        tags,
		DueDate:     dueDate,
	}

	if err := applyStatusTransition(now, &task, status, true); err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	if err := h.store.Create(c.Request.Context(), &task); err != nil {
		respondError(c, http.StatusInternalServerError, "не удалось создать задачу")
		return
	}

	c.JSON(http.StatusCreated, toTaskResponse(task, now))
}

func (h *TaskHandler) Update(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}

	var req TaskUpdateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		respondError(c, http.StatusBadRequest, "некорректное тело запроса")
		return
	}

	task, err := h.store.Get(c.Request.Context(), id)
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			respondError(c, http.StatusNotFound, "задача не найдена")
			return
		}
		respondError(c, http.StatusInternalServerError, "не удалось загрузить задачу")
		return
	}

	if req.Title != nil {
		value := strings.TrimSpace(*req.Title)
		if value == "" {
			respondError(c, http.StatusBadRequest, "название не может быть пустым")
			return
		}
		if len(value) > maxTitleLength {
			respondError(c, http.StatusBadRequest, "слишком длинное название")
			return
		}
		task.Title = value
	}

	if req.Description != nil {
		task.Description = strings.TrimSpace(*req.Description)
	}

	if req.Priority != nil {
		value, err := service.NormalizePriority(*req.Priority)
		if err != nil {
			respondError(c, http.StatusBadRequest, err.Error())
			return
		}
		task.Priority = value
	}

	if req.Owner != nil {
		owner := strings.TrimSpace(*req.Owner)
		if owner == "" {
			owner = defaultOwner
		}
		task.Owner = owner
	}

	if req.EffortHours != nil {
		value, err := normalizeEffort(*req.EffortHours)
		if err != nil {
			respondError(c, http.StatusBadRequest, err.Error())
			return
		}
		task.EffortHours = value
	}

	if req.Status != nil {
		force := parseForce(c)
		if err := applyStatusTransition(h.clock.Now(), task, *req.Status, force); err != nil {
			respondError(c, http.StatusBadRequest, err.Error())
			return
		}
	}

	if len(req.DueDate) > 0 {
		set, value, err := parseDueDatePatch(req.DueDate)
		if err != nil {
			respondError(c, http.StatusBadRequest, "некорректная дата; используйте RFC3339 или null")
			return
		}
		if set {
			task.DueDate = value
		}
	}

	if len(req.Tags) > 0 {
		set, value, err := parseTagsPatch(req.Tags)
		if err != nil {
			respondError(c, http.StatusBadRequest, err.Error())
			return
		}
		if set {
			task.Tags = value
		}
	}

	if err := h.store.Update(c.Request.Context(), task); err != nil {
		respondError(c, http.StatusInternalServerError, "не удалось обновить задачу")
		return
	}

	c.JSON(http.StatusOK, toTaskResponse(*task, h.clock.Now()))
}

func (h *TaskHandler) Delete(c *gin.Context) {
	id, ok := parseID(c)
	if !ok {
		return
	}

	if err := h.store.Delete(c.Request.Context(), id); err != nil {
		respondError(c, http.StatusInternalServerError, "не удалось удалить задачу")
		return
	}

	c.Status(http.StatusNoContent)
}

func (h *TaskHandler) Insights(c *gin.Context) {
	filter, _, err := parseListQuery(c)
	if err != nil {
		respondError(c, http.StatusBadRequest, err.Error())
		return
	}

	tasks, err := h.store.List(c.Request.Context(), repository.TaskFilter{
		Statuses:   filter.Statuses,
		Priorities: filter.Priorities,
		Owner:      filter.Owner,
		Query:      filter.Search,
		Tag:        filter.Tag,
	})
	if err != nil {
		respondError(c, http.StatusInternalServerError, "не удалось получить метрики")
		return
	}

	insights := service.ComputeInsights(h.clock.Now(), tasks)
	c.JSON(http.StatusOK, insights)
}

func parseListQuery(c *gin.Context) (ListQuery, service.SortOption, error) {
	statuses, err := parseCSVEnum(c.Query("status"), service.NormalizeStatus)
	if err != nil {
		return ListQuery{}, service.SortOption{}, err
	}

	priorities, err := parseCSVEnum(c.Query("priority"), service.NormalizePriority)
	if err != nil {
		return ListQuery{}, service.SortOption{}, err
	}

	sortOption := service.NormalizeSort(c.Query("sort"), c.Query("order"))
	return ListQuery{
		Statuses:   statuses,
		Priorities: priorities,
		Owner:      strings.TrimSpace(c.Query("owner")),
		Tag:        strings.TrimSpace(c.Query("tag")),
		Search:     strings.TrimSpace(c.Query("q")),
		Sort:       sortOption,
	}, sortOption, nil
}

func parseCSVEnum(raw string, normalize func(string) (string, error)) ([]string, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}

	seen := make(map[string]bool)
	values := []string{}
	for _, entry := range strings.Split(raw, ",") {
		value := strings.TrimSpace(entry)
		if value == "" {
			continue
		}
		normalized, err := normalize(value)
		if err != nil {
			return nil, err
		}
		if !seen[normalized] {
			seen[normalized] = true
			values = append(values, normalized)
		}
	}
	return values, nil
}

func parseID(c *gin.Context) (uint, bool) {
	idParam := c.Param("id")
	id64, err := strconv.ParseUint(idParam, 10, 32)
	if err != nil {
		respondError(c, http.StatusBadRequest, "некорректный идентификатор")
		return 0, false
	}
	return uint(id64), true
}

func parseDueDate(raw *string) (*time.Time, error) {
	if raw == nil {
		return nil, nil
	}
	value := strings.TrimSpace(*raw)
	if value == "" {
		return nil, nil
	}
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return nil, err
	}
	return &parsed, nil
}

func parseDueDatePatch(raw json.RawMessage) (bool, *time.Time, error) {
	if len(raw) == 0 {
		return false, nil, nil
	}
	if strings.TrimSpace(string(raw)) == "null" {
		return true, nil, nil
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return true, nil, fmt.Errorf("некорректное значение даты")
	}
	parsed, err := time.Parse(time.RFC3339, strings.TrimSpace(value))
	if err != nil {
		return true, nil, err
	}
	return true, &parsed, nil
}

func parseTagsPatch(raw json.RawMessage) (bool, domain.StringList, error) {
	if len(raw) == 0 {
		return false, nil, nil
	}
	if strings.TrimSpace(string(raw)) == "null" {
		return true, domain.StringList{}, nil
	}
	var value []string
	if err := json.Unmarshal(raw, &value); err != nil {
		return true, nil, err
	}
	normalized, err := service.NormalizeTags(value)
	if err != nil {
		return true, nil, err
	}
	return true, normalized, nil
}

func normalizeEffort(value int) (int, error) {
	if value == 0 {
		return defaultEffortVal, nil
	}
	if value < 0 || value > maxEffortHours {
		return 0, fmt.Errorf("effortHours должен быть от 1 до %d", maxEffortHours)
	}
	return value, nil
}

func parseForce(c *gin.Context) bool {
	value := strings.ToLower(strings.TrimSpace(c.Query("force")))
	return value == "true" || value == "1" || value == "yes"
}

func toTaskResponse(task domain.Task, now time.Time) TaskResponse {
	metrics := service.ComputeMetrics(now, task)
	return TaskResponse{
		Task:       task,
		Risk:       metrics.Risk,
		Score:      metrics.Score,
		AgeHours:   metrics.AgeHours,
		CycleHours: metrics.CycleHours,
	}
}

func respondError(c *gin.Context, code int, message string) {
	c.JSON(code, gin.H{"error": message})
}
