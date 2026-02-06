package service

import (
	"testing"
	"time"

	"devopslabs/internal/domain"
	"github.com/stretchr/testify/require"
)

func TestNormalizeStatusPriorityTags(t *testing.T) {
	status, err := NormalizeStatus("")
	require.NoError(t, err)
	require.Equal(t, domain.StatusTodo, status)

	status, err = NormalizeStatus("DONE")
	require.NoError(t, err)
	require.Equal(t, domain.StatusDone, status)

	_, err = NormalizeStatus("unknown")
	require.Error(t, err)

	priority, err := NormalizePriority("")
	require.NoError(t, err)
	require.Equal(t, domain.PriorityMedium, priority)

	priority, err = NormalizePriority("High")
	require.NoError(t, err)
	require.Equal(t, domain.PriorityHigh, priority)

	_, err = NormalizePriority("p0")
	require.Error(t, err)

	tags, err := NormalizeTags([]string{" DevOps ", "devops", ""})
	require.NoError(t, err)
	require.Equal(t, domain.StringList{"devops"}, tags)

	tags, err = NormalizeTags(nil)
	require.NoError(t, err)
	require.Equal(t, domain.StringList{}, tags)

	_, err = NormalizeTags([]string{"this-tag-name-is-way-too-long"})
	require.Error(t, err)

	_, err = NormalizeTags([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i"})
	require.Error(t, err)
}

func TestNormalizeSort(t *testing.T) {
	option := NormalizeSort("", "")
	require.Equal(t, "score", option.By)
	require.Equal(t, "desc", option.Order)

	option = NormalizeSort("title", "asc")
	require.Equal(t, "title", option.By)
	require.Equal(t, "asc", option.Order)

	option = NormalizeSort("unknown", "maybe")
	require.Equal(t, "score", option.By)
	require.Equal(t, "desc", option.Order)
}

func TestClockNow(t *testing.T) {
	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	fixed := FixedClock{NowValue: now}
	require.Equal(t, now, fixed.Now())

	real := RealClock{}
	require.WithinDuration(t, time.Now().UTC(), real.Now(), time.Second)
}

func TestComputeRiskScoreAndMetrics(t *testing.T) {
	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	base := domain.Task{
		ID:          1,
		Title:       "Task",
		Status:      domain.StatusTodo,
		Priority:    domain.PriorityMedium,
		EffortHours: 8,
		CreatedAt:   now.Add(-4 * time.Hour),
	}

	unscheduled := base
	unscheduled.DueDate = nil
	require.Equal(t, RiskUnassigned, ComputeRisk(now, unscheduled))

	overdue := base
	overdue.DueDate = ptrTime(now.Add(-2 * time.Hour))
	require.Equal(t, RiskOverdue, ComputeRisk(now, overdue))
	require.Equal(t, 40.8, ComputeScore(now, overdue))

	atRisk := base
	atRisk.DueDate = ptrTime(now.Add(24 * time.Hour))
	require.Equal(t, RiskAtRisk, ComputeRisk(now, atRisk))

	onTrack := base
	onTrack.DueDate = ptrTime(now.Add(7 * 24 * time.Hour))
	require.Equal(t, RiskOnTrack, ComputeRisk(now, onTrack))

	blocked := base
	blocked.Status = domain.StatusBlocked
	require.Equal(t, RiskBlocked, ComputeRisk(now, blocked))
	require.Greater(t, ComputeScore(now, blocked), 0.0)

	done := base
	done.Status = domain.StatusDone
	require.Equal(t, RiskCompleted, ComputeRisk(now, done))
	require.Greater(t, ComputeScore(now, done), 0.0)

	soon := base
	soon.DueDate = ptrTime(now.Add(24 * time.Hour))
	require.Greater(t, ComputeScore(now, soon), 0.0)

	mid := base
	mid.DueDate = ptrTime(now.Add(72 * time.Hour))
	require.Greater(t, ComputeScore(now, mid), 0.0)

	started := now.Add(-5 * time.Hour)
	completed := now.Add(-2 * time.Hour)
	cycle := base
	cycle.StartedAt = &started
	cycle.CompletedAt = &completed
	metrics := ComputeMetrics(now, cycle)
	require.Equal(t, 4.0, metrics.AgeHours)
	require.NotNil(t, metrics.CycleHours)
	require.Equal(t, 3.0, *metrics.CycleHours)

	negative := base
	negative.CreatedAt = now.Add(2 * time.Hour)
	negative.StartedAt = ptrTime(now.Add(2 * time.Hour))
	negative.CompletedAt = ptrTime(now.Add(1 * time.Hour))
	metrics = ComputeMetrics(now, negative)
	require.Equal(t, 0.0, metrics.AgeHours)
	require.NotNil(t, metrics.CycleHours)
	require.Equal(t, 0.0, *metrics.CycleHours)
}

func TestComputeInsights(t *testing.T) {
	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	tasks := []domain.Task{
		{
			ID:          1,
			Title:       "A",
			Status:      domain.StatusTodo,
			Priority:    domain.PriorityLow,
			EffortHours: 2,
			CreatedAt:   now.Add(-2 * time.Hour),
		},
		{
			ID:          2,
			Title:       "B",
			Status:      domain.StatusInProgress,
			Priority:    domain.PriorityHigh,
			EffortHours: 5,
			CreatedAt:   now.Add(-4 * time.Hour),
			DueDate:     ptrTime(now.Add(-1 * time.Hour)),
		},
		{
			ID:          3,
			Title:       "C",
			Status:      domain.StatusDone,
			Priority:    domain.PriorityMedium,
			EffortHours: 3,
			CreatedAt:   now.Add(-10 * time.Hour),
			StartedAt:   ptrTime(now.Add(-9 * time.Hour)),
			CompletedAt: ptrTime(now.Add(-6 * time.Hour)),
		},
		{
			ID:          4,
			Title:       "D",
			Status:      domain.StatusBlocked,
			Priority:    domain.PriorityCritical,
			EffortHours: 4,
			CreatedAt:   now.Add(-3 * time.Hour),
		},
		{
			ID:          5,
			Title:       "E",
			Status:      domain.StatusTodo,
			Priority:    domain.PriorityMedium,
			EffortHours: 1,
			CreatedAt:   now.Add(-1 * time.Hour),
			DueDate:     ptrTime(now.Add(24 * time.Hour)),
		},
	}

	insights := ComputeInsights(now, tasks)
	require.Equal(t, 5, insights.Total)
	require.Equal(t, 2, insights.ByStatus[domain.StatusTodo])
	require.Equal(t, 1, insights.ByStatus[domain.StatusInProgress])
	require.Equal(t, 1, insights.ByStatus[domain.StatusDone])
	require.Equal(t, 1, insights.ByStatus[domain.StatusBlocked])
	require.Equal(t, 1, insights.Overdue)
	require.Equal(t, 1, insights.AtRisk)
	require.Equal(t, 1, insights.Blocked)
	require.Equal(t, 1, insights.Done)
	require.Equal(t, 12, insights.WorkloadHours)
	require.Greater(t, insights.AverageAgeHours, 0.0)
	require.Greater(t, insights.AverageCycleHours, 0.0)
	require.Equal(t, 0.2, insights.FocusIndex)
}

func TestValidateAndApplyTransition(t *testing.T) {
	err := ValidateTransition(domain.StatusTodo, domain.StatusInProgress, false)
	require.NoError(t, err)

	err = ValidateTransition(domain.StatusDone, domain.StatusTodo, false)
	require.Error(t, err)

	err = ValidateTransition(domain.StatusDone, domain.StatusTodo, true)
	require.NoError(t, err)

	err = ValidateTransition("mystery", domain.StatusTodo, false)
	require.Error(t, err)

	err = ValidateTransition(domain.StatusTodo, domain.StatusTodo, false)
	require.NoError(t, err)

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	task := &domain.Task{Status: domain.StatusTodo}
	require.NoError(t, ApplyStatusTransition(now, task, domain.StatusInProgress, false))
	require.Equal(t, domain.StatusInProgress, task.Status)
	require.NotNil(t, task.StartedAt)
	require.Nil(t, task.CompletedAt)

	require.NoError(t, ApplyStatusTransition(now, task, domain.StatusDone, false))
	require.Equal(t, domain.StatusDone, task.Status)
	require.NotNil(t, task.CompletedAt)

	require.NoError(t, ApplyStatusTransition(now, task, domain.StatusTodo, true))
	require.Nil(t, task.StartedAt)
	require.Nil(t, task.CompletedAt)

	require.NoError(t, ApplyStatusTransition(now, task, domain.StatusBlocked, false))
	require.Equal(t, domain.StatusBlocked, task.Status)
	require.Nil(t, task.CompletedAt)

	require.Error(t, ApplyStatusTransition(now, task, "invalid", false))

	invalidTransition := &domain.Task{Status: domain.StatusDone}
	require.Error(t, ApplyStatusTransition(now, invalidTransition, domain.StatusTodo, false))

	newTask := &domain.Task{}
	require.NoError(t, ApplyStatusTransition(now, newTask, domain.StatusTodo, false))

	doneFromTodo := &domain.Task{Status: domain.StatusTodo}
	require.NoError(t, ApplyStatusTransition(now, doneFromTodo, domain.StatusDone, true))
	require.NotNil(t, doneFromTodo.StartedAt)
	require.NotNil(t, doneFromTodo.CompletedAt)

	require.Error(t, ApplyStatusTransition(now, nil, domain.StatusTodo, false))
}

func TestSortTasks(t *testing.T) {
	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

	tasks := []domain.Task{
		{ID: 1, Title: "Beta", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now.Add(-1 * time.Hour), CreatedAt: now.Add(-2 * time.Hour)},
		{ID: 2, Title: "Alpha", Priority: domain.PriorityCritical, Status: domain.StatusBlocked, UpdatedAt: now.Add(-2 * time.Hour), CreatedAt: now.Add(-4 * time.Hour), DueDate: ptrTime(now.Add(48 * time.Hour))},
		{ID: 3, Title: "Gamma", Priority: domain.PriorityMedium, Status: domain.StatusInProgress, UpdatedAt: now.Add(-3 * time.Hour), CreatedAt: now.Add(-1 * time.Hour), DueDate: ptrTime(now.Add(2 * time.Hour))},
		{ID: 4, Title: "Delta", Priority: domain.PriorityMedium, Status: domain.StatusTodo, UpdatedAt: now.Add(-3 * time.Hour), CreatedAt: now.Add(-3 * time.Hour)},
	}

	SortTasks(tasks, SortOption{By: "title", Order: "asc"}, now)
	require.Equal(t, uint(2), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "priority", Order: "desc"}, now)
	require.Equal(t, uint(2), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "priority", Order: "asc"}, now)
	require.Equal(t, uint(1), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "due_date", Order: "asc"}, now)
	require.Equal(t, uint(3), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "due_date", Order: "desc"}, now)
	require.Equal(t, uint(2), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "score", Order: "desc"}, now)
	require.Equal(t, uint(2), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "score", Order: "asc"}, now)
	require.Equal(t, uint(1), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "created_at", Order: "desc"}, now)
	require.Equal(t, uint(3), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "updated_at", Order: "asc"}, now)
	require.Equal(t, uint(3), tasks[0].ID)

	SortTasks(tasks, SortOption{By: "title", Order: "desc"}, now)
	require.Equal(t, uint(3), tasks[0].ID)

	SortTasks(tasks[:1], SortOption{By: "score", Order: "desc"}, now)

	tie := []domain.Task{
		{ID: 5, Title: "Echo", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now},
		{ID: 6, Title: "Foxtrot", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now.Add(-1 * time.Hour)},
	}
	SortTasks(tie, SortOption{By: "score", Order: "desc"}, now)
	require.Equal(t, uint(5), tie[0].ID)

	tiePriority := []domain.Task{
		{ID: 7, Title: "Alpha", Priority: domain.PriorityHigh, Status: domain.StatusTodo, UpdatedAt: now},
		{ID: 8, Title: "Beta", Priority: domain.PriorityHigh, Status: domain.StatusTodo, UpdatedAt: now.Add(-1 * time.Hour)},
	}
	SortTasks(tiePriority, SortOption{By: "priority", Order: "desc"}, now)
	require.Equal(t, uint(7), tiePriority[0].ID)

	tieDue := []domain.Task{
		{ID: 9, Title: "X", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now, DueDate: ptrTime(now.Add(24 * time.Hour))},
		{ID: 10, Title: "Y", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now.Add(-1 * time.Hour), DueDate: ptrTime(now.Add(24 * time.Hour))},
	}
	SortTasks(tieDue, SortOption{By: "due_date", Order: "asc"}, now)
	require.Equal(t, uint(10), tieDue[0].ID)

	tieTitle := []domain.Task{
		{ID: 11, Title: "Same", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now},
		{ID: 12, Title: "Same", Priority: domain.PriorityLow, Status: domain.StatusTodo, UpdatedAt: now.Add(-1 * time.Hour)},
	}
	SortTasks(tieTitle, SortOption{By: "title", Order: "asc"}, now)
	require.Equal(t, uint(12), tieTitle[0].ID)
}

func ptrTime(value time.Time) *time.Time {
	return &value
}
