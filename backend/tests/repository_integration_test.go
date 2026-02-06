package tests

import (
	"context"
	"strings"
	"testing"

	"devopslabs/internal/domain"
	"devopslabs/internal/repository"
	"github.com/stretchr/testify/require"
	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

func TestRepositoryListWithFilters(t *testing.T) {
	db := setupStoreDB(t)
	store := repository.NewGormTaskStore(db)

	tasks := []domain.Task{
		{
			Title:       "Prepare CI",
			Description: "pipeline",
			Status:      domain.StatusTodo,
			Priority:    domain.PriorityHigh,
			Owner:       "anna",
			EffortHours: 5,
			Tags:        domain.StringList{"devops", "ci"},
		},
		{
			Title:       "Fix API",
			Description: "bug",
			Status:      domain.StatusInProgress,
			Priority:    domain.PriorityLow,
			Owner:       "ivan",
			EffortHours: 2,
			Tags:        domain.StringList{"backend"},
		},
	}

	for i := range tasks {
		require.NoError(t, store.Create(context.Background(), &tasks[i]))
	}

	task, err := store.Get(context.Background(), tasks[0].ID)
	require.NoError(t, err)
	require.Equal(t, "Prepare CI", task.Title)

	task.Title = "Prepare CI v2"
	require.NoError(t, store.Update(context.Background(), task))

	updated, err := store.Get(context.Background(), tasks[0].ID)
	require.NoError(t, err)
	require.Equal(t, "Prepare CI v2", updated.Title)

	filtered, err := store.List(context.Background(), repository.TaskFilter{Statuses: []string{domain.StatusTodo}})
	require.NoError(t, err)
	require.Len(t, filtered, 1)
	require.Equal(t, "Prepare CI v2", filtered[0].Title)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Priorities: []string{domain.PriorityLow}})
	require.NoError(t, err)
	require.Len(t, filtered, 1)
	require.Equal(t, "Fix API", filtered[0].Title)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Owner: "anna"})
	require.NoError(t, err)
	require.Len(t, filtered, 1)
	require.Equal(t, "Prepare CI v2", filtered[0].Title)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Query: "pipeline"})
	require.NoError(t, err)
	require.Len(t, filtered, 1)
	require.Equal(t, "Prepare CI v2", filtered[0].Title)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Tag: "devops"})
	require.NoError(t, err)
	require.Len(t, filtered, 1)
	require.Equal(t, "Prepare CI v2", filtered[0].Title)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Tag: " "})
	require.NoError(t, err)
	require.Len(t, filtered, 2)

	filtered, err = store.List(context.Background(), repository.TaskFilter{Tag: ""})
	require.NoError(t, err)
	require.Len(t, filtered, 2)

	require.NoError(t, store.Delete(context.Background(), tasks[1].ID))
	_, err = store.Get(context.Background(), tasks[1].ID)
	require.Error(t, err)
}

func TestRepositoryListReturnsErrorOnMissingTable(t *testing.T) {
	db := setupStoreDB(t)
	store := repository.NewGormTaskStore(db)

	require.NoError(t, db.Migrator().DropTable(&domain.Task{}))

	_, err := store.List(context.Background(), repository.TaskFilter{})
	require.Error(t, err)
}

func setupStoreDB(t *testing.T) *gorm.DB {
	t.Helper()

	dsn := "file:" + strings.ReplaceAll(t.Name(), "/", "_") + "?mode=memory&cache=shared"
	db, err := gorm.Open(sqlite.Open(dsn), &gorm.Config{})
	require.NoError(t, err)

	require.NoError(t, db.AutoMigrate(&domain.Task{}))
	return db
}
