package main

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestRunSuccess(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = originalConnect
	migrateDB = func(database *gorm.DB) error {
		return nil
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
	})

	require.NoError(t, run())
}

func TestRunStartError(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return errors.New("boom")
	}
	connectDB = originalConnect
	migrateDB = func(database *gorm.DB) error {
		return nil
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
	})

	require.Error(t, run())
}

func TestRunConnectError(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return nil, errors.New("connect fail")
	}
	migrateDB = func(database *gorm.DB) error {
		return nil
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
	})

	require.Error(t, run())
}

func TestRunMigrateError(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = originalConnect
	migrateDB = func(database *gorm.DB) error {
		return errors.New("migrate fail")
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
	})

	require.Error(t, run())
}

func TestMainExitOnError(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return errors.New("boom")
	}
	connectDB = originalConnect
	migrateDB = func(database *gorm.DB) error {
		return nil
	}
	originalExit := exit
	var code int
	exit = func(status int) {
		code = status
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
		exit = originalExit
	})

	main()
	require.Equal(t, 1, code)
}

func TestMainSuccess(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_PATH", filepath.Join(t.TempDir(), "app.db"))

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = originalConnect
	migrateDB = func(database *gorm.DB) error {
		return nil
	}
	originalExit := exit
	called := false
	exit = func(status int) {
		called = true
	}
	t.Cleanup(func() {
		startServer = originalStart
		connectDB = originalConnect
		migrateDB = originalMigrate
		exit = originalExit
	})

	main()
	require.False(t, called)
}
