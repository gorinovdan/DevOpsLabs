package main

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestRunSuccess(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
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
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return errors.New("boom")
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return &gorm.DB{}, nil
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

func TestRunConnectError(t *testing.T) {
	t.Setenv("PORT", "0")
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

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
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
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
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return errors.New("boom")
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
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
	t.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")

	originalStart := startServer
	originalConnect := connectDB
	originalMigrate := migrateDB
	startServer = func(addr string, router Router) error {
		return nil
	}
	connectDB = func(path string) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
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
