package database

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestConnectCreatesDatabase(t *testing.T) {
	tmp := t.TempDir()
	path := filepath.Join(tmp, "nested", "app.db")

	database, err := Connect(path)
	require.NoError(t, err)
	require.NotNil(t, database)

	sqlDB, err := database.DB()
	require.NoError(t, err)

	err = sqlDB.Ping()
	require.NoError(t, err)
}

func TestConnectMkdirError(t *testing.T) {
	originalMkdir := mkdirAll
	mkdirAll = func(path string, perm os.FileMode) error {
		return errors.New("mkdir failed")
	}
	t.Cleanup(func() { mkdirAll = originalMkdir })

	_, err := Connect(filepath.Join(t.TempDir(), "nested", "app.db"))
	require.Error(t, err)
}

func TestConnectOpenError(t *testing.T) {
	originalOpen := openGorm
	openGorm = func(dialector gorm.Dialector, opts ...gorm.Option) (*gorm.DB, error) {
		return nil, errors.New("open failed")
	}
	t.Cleanup(func() { openGorm = originalOpen })

	_, err := Connect(filepath.Join(t.TempDir(), "app.db"))
	require.Error(t, err)
}
