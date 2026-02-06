package domain

import "time"

const (
	StatusTodo       = "todo"
	StatusInProgress = "in_progress"
	StatusBlocked    = "blocked"
	StatusDone       = "done"
)

const (
	PriorityLow      = "low"
	PriorityMedium   = "medium"
	PriorityHigh     = "high"
	PriorityCritical = "critical"
)

var AllowedStatuses = map[string]bool{
	StatusTodo:       true,
	StatusInProgress: true,
	StatusBlocked:    true,
	StatusDone:       true,
}

var AllowedPriorities = map[string]bool{
	PriorityLow:      true,
	PriorityMedium:   true,
	PriorityHigh:     true,
	PriorityCritical: true,
}

var PriorityWeights = map[string]int{
	PriorityLow:      1,
	PriorityMedium:   2,
	PriorityHigh:     3,
	PriorityCritical: 4,
}

type Task struct {
	ID          uint       `json:"id" gorm:"primaryKey"`
	Title       string     `json:"title" gorm:"size:200;not null"`
	Description string     `json:"description" gorm:"type:text"`
	Status      string     `json:"status" gorm:"size:32;not null"`
	Priority    string     `json:"priority" gorm:"size:16;not null"`
	Owner       string     `json:"owner" gorm:"size:80"`
	EffortHours int        `json:"effortHours" gorm:"not null;default:1"`
	Tags        StringList `json:"tags" gorm:"type:text"`
	DueDate     *time.Time `json:"dueDate,omitempty"`
	StartedAt   *time.Time `json:"startedAt,omitempty"`
	CompletedAt *time.Time `json:"completedAt,omitempty"`
	CreatedAt   time.Time  `json:"createdAt"`
	UpdatedAt   time.Time  `json:"updatedAt"`
}
