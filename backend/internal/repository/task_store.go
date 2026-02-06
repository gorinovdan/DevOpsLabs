package repository

import (
	"context"
	"strings"

	"devopslabs/internal/domain"
	"gorm.io/gorm"
)

type TaskFilter struct {
	Statuses   []string
	Priorities []string
	Owner      string
	Query      string
	Tag        string
}

type TaskStore interface {
	List(ctx context.Context, filter TaskFilter) ([]domain.Task, error)
	Get(ctx context.Context, id uint) (*domain.Task, error)
	Create(ctx context.Context, task *domain.Task) error
	Update(ctx context.Context, task *domain.Task) error
	Delete(ctx context.Context, id uint) error
}

type GormTaskStore struct {
	db *gorm.DB
}

func NewGormTaskStore(db *gorm.DB) *GormTaskStore {
	return &GormTaskStore{db: db}
}

func (s *GormTaskStore) List(ctx context.Context, filter TaskFilter) ([]domain.Task, error) {
	query := s.db.WithContext(ctx)
	if len(filter.Statuses) > 0 {
		query = query.Where("status IN ?", filter.Statuses)
	}
	if len(filter.Priorities) > 0 {
		query = query.Where("priority IN ?", filter.Priorities)
	}
	if filter.Owner != "" {
		query = query.Where("owner = ?", filter.Owner)
	}
	if filter.Query != "" {
		like := "%" + filter.Query + "%"
		query = query.Where("title LIKE ? OR description LIKE ?", like, like)
	}

	var tasks []domain.Task
	if err := query.Find(&tasks).Error; err != nil {
		return nil, err
	}

	if filter.Tag == "" {
		return tasks, nil
	}

	tag := strings.ToLower(strings.TrimSpace(filter.Tag))
	if tag == "" {
		return tasks, nil
	}

	filtered := make([]domain.Task, 0, len(tasks))
	for _, task := range tasks {
		if containsTag(task.Tags, tag) {
			filtered = append(filtered, task)
		}
	}

	return filtered, nil
}

func (s *GormTaskStore) Get(ctx context.Context, id uint) (*domain.Task, error) {
	var task domain.Task
	if err := s.db.WithContext(ctx).First(&task, id).Error; err != nil {
		return nil, err
	}
	return &task, nil
}

func (s *GormTaskStore) Create(ctx context.Context, task *domain.Task) error {
	return s.db.WithContext(ctx).Create(task).Error
}

func (s *GormTaskStore) Update(ctx context.Context, task *domain.Task) error {
	return s.db.WithContext(ctx).Save(task).Error
}

func (s *GormTaskStore) Delete(ctx context.Context, id uint) error {
	return s.db.WithContext(ctx).Delete(&domain.Task{}, id).Error
}

func containsTag(tags domain.StringList, tag string) bool {
	for _, value := range tags {
		if strings.ToLower(value) == tag {
			return true
		}
	}
	return false
}
