package service

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"devopslabs/internal/domain"
)

const (
	RiskOnTrack    = "on_track"
	RiskAtRisk     = "at_risk"
	RiskOverdue    = "overdue"
	RiskUnassigned = "unscheduled"
	RiskBlocked    = "blocked"
	RiskCompleted  = "completed"
)

const (
	DefaultStatus   = domain.StatusTodo
	DefaultPriority = domain.PriorityMedium
	MaxTags         = 8
	MaxTagLength    = 24
)

type Clock interface {
	Now() time.Time
}

type RealClock struct{}

func (RealClock) Now() time.Time {
	return time.Now().UTC()
}

type FixedClock struct {
	NowValue time.Time
}

func (c FixedClock) Now() time.Time {
	return c.NowValue
}

type SortOption struct {
	By    string
	Order string
}

type TaskMetrics struct {
	Risk       string   `json:"risk"`
	Score      float64  `json:"score"`
	AgeHours   float64  `json:"ageHours"`
	CycleHours *float64 `json:"cycleHours,omitempty"`
}

type Insights struct {
	Total             int            `json:"total"`
	ByStatus          map[string]int `json:"byStatus"`
	ByPriority        map[string]int `json:"byPriority"`
	Overdue           int            `json:"overdue"`
	AtRisk            int            `json:"atRisk"`
	Blocked           int            `json:"blocked"`
	Done              int            `json:"done"`
	AverageAgeHours   float64        `json:"averageAgeHours"`
	AverageCycleHours float64        `json:"averageCycleHours"`
	WorkloadHours     int            `json:"workloadHours"`
	FocusIndex        float64        `json:"focusIndex"`
}

func NormalizeStatus(input string) (string, error) {
	value := strings.TrimSpace(strings.ToLower(input))
	if value == "" {
		return DefaultStatus, nil
	}
	if !domain.AllowedStatuses[value] {
		return "", fmt.Errorf("некорректный статус: %s", value)
	}
	return value, nil
}

func NormalizePriority(input string) (string, error) {
	value := strings.TrimSpace(strings.ToLower(input))
	if value == "" {
		return DefaultPriority, nil
	}
	if !domain.AllowedPriorities[value] {
		return "", fmt.Errorf("некорректный приоритет: %s", value)
	}
	return value, nil
}

func NormalizeTags(tags []string) (domain.StringList, error) {
	if len(tags) == 0 {
		return domain.StringList{}, nil
	}

	unique := make(map[string]bool)
	result := make([]string, 0, len(tags))
	for _, tag := range tags {
		value := strings.TrimSpace(strings.ToLower(tag))
		if value == "" {
			continue
		}
		if len(value) > MaxTagLength {
			return nil, fmt.Errorf("слишком длинный тег: %s", value)
		}
		if !unique[value] {
			unique[value] = true
			result = append(result, value)
		}
	}

	if len(result) > MaxTags {
		return nil, fmt.Errorf("слишком много тегов: %d", len(result))
	}

	return domain.StringList(result), nil
}

func NormalizeSort(by string, order string) SortOption {
	value := strings.TrimSpace(strings.ToLower(by))
	if value == "" {
		value = "score"
	}

	switch value {
	case "score", "priority", "due_date", "created_at", "updated_at", "title":
		// allowed
	default:
		value = "score"
	}

	ord := strings.TrimSpace(strings.ToLower(order))
	if ord != "asc" && ord != "desc" {
		ord = "desc"
	}

	return SortOption{By: value, Order: ord}
}

func SortTasks(tasks []domain.Task, option SortOption, now time.Time) {
	if len(tasks) < 2 {
		return
	}

	desc := option.Order == "desc"

	switch option.By {
	case "score":
		scores := make(map[uint]float64, len(tasks))
		for _, task := range tasks {
			scores[task.ID] = ComputeScore(now, task)
		}
		sort.SliceStable(tasks, func(i, j int) bool {
			left := scores[tasks[i].ID]
			right := scores[tasks[j].ID]
			if left == right {
				return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
			}
			if desc {
				return left > right
			}
			return left < right
		})
	case "priority":
		sort.SliceStable(tasks, func(i, j int) bool {
			left := domain.PriorityWeights[tasks[i].Priority]
			right := domain.PriorityWeights[tasks[j].Priority]
			if left == right {
				return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
			}
			if desc {
				return left > right
			}
			return left < right
		})
	case "due_date":
		sort.SliceStable(tasks, func(i, j int) bool {
			left := tasks[i].DueDate
			right := tasks[j].DueDate
			if left == nil && right == nil {
				return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
			}
			if left == nil {
				return false
			}
			if right == nil {
				return true
			}
			if left.Equal(*right) {
				return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
			}
			if desc {
				return left.After(*right)
			}
			return left.Before(*right)
		})
	case "created_at":
		sort.SliceStable(tasks, func(i, j int) bool {
			return compareTime(tasks[i].CreatedAt, tasks[j].CreatedAt, desc)
		})
	case "updated_at":
		sort.SliceStable(tasks, func(i, j int) bool {
			return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
		})
	case "title":
		sort.SliceStable(tasks, func(i, j int) bool {
			left := strings.ToLower(tasks[i].Title)
			right := strings.ToLower(tasks[j].Title)
			if left == right {
				return compareTime(tasks[i].UpdatedAt, tasks[j].UpdatedAt, desc)
			}
			if desc {
				return left > right
			}
			return left < right
		})
	}
}

func compareTime(left, right time.Time, desc bool) bool {
	if left.Equal(right) {
		return false
	}
	if desc {
		return left.After(right)
	}
	return left.Before(right)
}

func ComputeMetrics(now time.Time, task domain.Task) TaskMetrics {
	age := 0.0
	if !task.CreatedAt.IsZero() {
		age = now.Sub(task.CreatedAt).Hours()
		if age < 0 {
			age = 0
		}
	}

	var cycle *float64
	if task.StartedAt != nil && task.CompletedAt != nil {
		value := task.CompletedAt.Sub(*task.StartedAt).Hours()
		if value < 0 {
			value = 0
		}
		cycle = &value
	}

	return TaskMetrics{
		Risk:       ComputeRisk(now, task),
		Score:      ComputeScore(now, task),
		AgeHours:   round2(age),
		CycleHours: cycle,
	}
}

func ComputeRisk(now time.Time, task domain.Task) string {
	switch task.Status {
	case domain.StatusDone:
		return RiskCompleted
	case domain.StatusBlocked:
		return RiskBlocked
	}

	if task.DueDate == nil {
		return RiskUnassigned
	}

	if task.DueDate.Before(now) {
		return RiskOverdue
	}

	if task.DueDate.Sub(now) <= 48*time.Hour {
		return RiskAtRisk
	}

	return RiskOnTrack
}

func ComputeScore(now time.Time, task domain.Task) float64 {
	priorityWeight := domain.PriorityWeights[task.Priority]
	score := float64(priorityWeight) * 10

	if task.DueDate != nil {
		hours := task.DueDate.Sub(now).Hours()
		switch {
		case hours <= 0:
			score += 20
		case hours <= 48:
			score += 10
		case hours <= 96:
			score += 5
		}
	}

	if task.Status == domain.StatusBlocked {
		score += 7
	}
	if task.Status == domain.StatusDone {
		score -= 5
	}

	score += float64(task.EffortHours) * 0.1
	return round1(score)
}

func ComputeInsights(now time.Time, tasks []domain.Task) Insights {
	insights := Insights{
		Total:      len(tasks),
		ByStatus:   make(map[string]int),
		ByPriority: make(map[string]int),
	}

	var ageSum float64
	var cycleSum float64
	var cycleCount int

	for _, task := range tasks {
		insights.ByStatus[task.Status]++
		insights.ByPriority[task.Priority]++

		metrics := ComputeMetrics(now, task)
		switch metrics.Risk {
		case RiskOverdue:
			insights.Overdue++
		case RiskAtRisk:
			insights.AtRisk++
		case RiskBlocked:
			insights.Blocked++
		case RiskCompleted:
			insights.Done++
		}

		ageSum += metrics.AgeHours
		if metrics.CycleHours != nil {
			cycleSum += *metrics.CycleHours
			cycleCount++
		}

		if task.Status != domain.StatusDone {
			insights.WorkloadHours += task.EffortHours
		}
	}

	if insights.Total > 0 {
		insights.AverageAgeHours = round2(ageSum / float64(insights.Total))
	}

	if cycleCount > 0 {
		insights.AverageCycleHours = round2(cycleSum / float64(cycleCount))
	}

	if insights.Total > 0 {
		insights.FocusIndex = round2(float64(insights.Done) / float64(insights.Total))
	}

	return insights
}

var allowedTransitions = map[string]map[string]bool{
	domain.StatusTodo: {
		domain.StatusInProgress: true,
		domain.StatusBlocked:    true,
	},
	domain.StatusInProgress: {
		domain.StatusBlocked: true,
		domain.StatusDone:    true,
	},
	domain.StatusBlocked: {
		domain.StatusInProgress: true,
		domain.StatusTodo:       true,
	},
	domain.StatusDone: {},
}

func ValidateTransition(from string, to string, force bool) error {
	if from == to {
		return nil
	}
	if force {
		return nil
	}
	allowed, ok := allowedTransitions[from]
	if !ok {
		return fmt.Errorf("неизвестный текущий статус: %s", from)
	}
	if !allowed[to] {
		return fmt.Errorf("переход недопустим: %s -> %s", from, to)
	}
	return nil
}

func ApplyStatusTransition(now time.Time, task *domain.Task, newStatus string, force bool) error {
	if task == nil {
		return errors.New("задача не задана")
	}

	status, err := NormalizeStatus(newStatus)
	if err != nil {
		return err
	}

	if task.Status != "" {
		if err := ValidateTransition(task.Status, status, force); err != nil {
			return err
		}
	}

	task.Status = status

	switch status {
	case domain.StatusInProgress:
		if task.StartedAt == nil {
			stamp := now
			task.StartedAt = &stamp
		}
		task.CompletedAt = nil
	case domain.StatusDone:
		if task.StartedAt == nil {
			stamp := now
			task.StartedAt = &stamp
		}
		if task.CompletedAt == nil {
			stamp := now
			task.CompletedAt = &stamp
		}
	case domain.StatusTodo:
		task.StartedAt = nil
		task.CompletedAt = nil
	case domain.StatusBlocked:
		task.CompletedAt = nil
	}

	return nil
}

func round1(value float64) float64 {
	return math.Round(value*10) / 10
}

func round2(value float64) float64 {
	return math.Round(value*100) / 100
}
