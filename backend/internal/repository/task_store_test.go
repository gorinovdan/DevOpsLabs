package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"devopslabs/internal/domain"
	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

var taskColumns = []string{
	"id",
	"title",
	"description",
	"status",
	"priority",
	"owner",
	"effort_hours",
	"tags",
	"due_date",
	"started_at",
	"completed_at",
	"created_at",
	"updated_at",
}

func setupStoreDB(t *testing.T) (*GormTaskStore, sqlmock.Sqlmock) {
	t.Helper()

	sqlDB, mock, err := sqlmock.New()
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, mock.ExpectationsWereMet())
	})

	dialector := postgres.New(postgres.Config{Conn: sqlDB, PreferSimpleProtocol: true})
	db, err := gorm.Open(dialector, &gorm.Config{})
	require.NoError(t, err)

	return NewGormTaskStore(db), mock
}

func TestRepositoryCRUD(t *testing.T) {
	store, mock := setupStoreDB(t)

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	createTask := &domain.Task{
		Title:       "Prepare CI",
		Description: "pipeline",
		Status:      domain.StatusTodo,
		Priority:    domain.PriorityHigh,
		Owner:       "anna",
		EffortHours: 5,
		Tags:        domain.StringList{"devops", "ci"},
		CreatedAt:   now,
		UpdatedAt:   now,
	}

	mock.ExpectBegin()
	mock.ExpectQuery(`INSERT INTO "tasks"`).WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(1))
	mock.ExpectCommit()
	require.NoError(t, store.Create(context.Background(), createTask))
	require.Equal(t, uint(1), createTask.ID)

	mock.ExpectQuery(`SELECT .* FROM "tasks"`).WillReturnRows(
		sqlmock.NewRows(taskColumns).AddRow(
			1,
			"Prepare CI",
			"pipeline",
			domain.StatusTodo,
			domain.PriorityHigh,
			"anna",
			5,
			`["devops","ci"]`,
			nil,
			nil,
			nil,
			now,
			now,
		),
	)

	stored, err := store.Get(context.Background(), 1)
	require.NoError(t, err)
	require.Equal(t, "Prepare CI", stored.Title)

	stored.Title = "Prepare CI v2"
	stored.UpdatedAt = now.Add(5 * time.Minute)

	mock.ExpectBegin()
	mock.ExpectExec(`UPDATE "tasks"`).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	require.NoError(t, store.Update(context.Background(), stored))

	mock.ExpectBegin()
	mock.ExpectExec(`DELETE FROM "tasks"`).WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	require.NoError(t, store.Delete(context.Background(), 1))
}

func TestRepositoryListWithFiltersAndTags(t *testing.T) {
	store, mock := setupStoreDB(t)

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	rows := sqlmock.NewRows(taskColumns).
		AddRow(
			1,
			"Prepare CI",
			"pipeline",
			domain.StatusTodo,
			domain.PriorityHigh,
			"anna",
			5,
			`["devops","ci"]`,
			nil,
			nil,
			nil,
			now,
			now,
		).
		AddRow(
			2,
			"Fix API",
			"bug",
			domain.StatusInProgress,
			domain.PriorityLow,
			"ivan",
			2,
			`["backend"]`,
			nil,
			nil,
			nil,
			now,
			now,
		)

	mock.ExpectQuery(`SELECT .* FROM "tasks"`).WillReturnRows(rows)
	tasks, err := store.List(context.Background(), TaskFilter{
		Statuses:   []string{domain.StatusTodo, domain.StatusInProgress},
		Priorities: []string{domain.PriorityHigh, domain.PriorityLow},
		Owner:      "anna",
		Query:      "pipe",
		Tag:        "DEVOPS",
	})
	require.NoError(t, err)
	require.Len(t, tasks, 1)
	require.Equal(t, "Prepare CI", tasks[0].Title)
}

func TestRepositoryGetNotFound(t *testing.T) {
	store, mock := setupStoreDB(t)

	mock.ExpectQuery(`SELECT .* FROM "tasks"`).WillReturnRows(sqlmock.NewRows(taskColumns))

	_, err := store.Get(context.Background(), 999)
	require.ErrorIs(t, err, gorm.ErrRecordNotFound)
}

func TestRepositoryListReturnsErrorOnQueryFailure(t *testing.T) {
	store, mock := setupStoreDB(t)

	mock.ExpectQuery(`SELECT .* FROM "tasks"`).WillReturnError(errors.New("query failed"))

	_, err := store.List(context.Background(), TaskFilter{})
	require.Error(t, err)
}
