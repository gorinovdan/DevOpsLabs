package database

import (
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	"gorm.io/gorm"
)

func TestConnectSuccess(t *testing.T) {
	originalOpen := openGorm
	originalPing := pingDB
	openGorm = func(dialector gorm.Dialector, opts ...gorm.Option) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
	pingDB = func(database *gorm.DB) error {
		return nil
	}
	t.Cleanup(func() {
		openGorm = originalOpen
		pingDB = originalPing
	})

	database, err := Connect("host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")
	require.NoError(t, err)
	require.NotNil(t, database)
}

func TestConnectEmptyDSN(t *testing.T) {
	_, err := Connect("   ")
	require.Error(t, err)
}

func TestConnectPingError(t *testing.T) {
	originalOpen := openGorm
	originalPing := pingDB
	openGorm = func(dialector gorm.Dialector, opts ...gorm.Option) (*gorm.DB, error) {
		return &gorm.DB{}, nil
	}
	pingDB = func(database *gorm.DB) error {
		return errors.New("ping failed")
	}
	t.Cleanup(func() {
		openGorm = originalOpen
		pingDB = originalPing
	})

	_, err := Connect("host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")
	require.Error(t, err)
}

func TestConnectOpenError(t *testing.T) {
	originalOpen := openGorm
	openGorm = func(dialector gorm.Dialector, opts ...gorm.Option) (*gorm.DB, error) {
		return nil, errors.New("open failed")
	}
	t.Cleanup(func() { openGorm = originalOpen })

	_, err := Connect("host=db user=demo password=secret dbname=demo port=5432 sslmode=disable")
	require.Error(t, err)
}
