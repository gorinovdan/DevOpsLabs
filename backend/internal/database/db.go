package database

import (
	"fmt"
	"strings"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

var openGorm = gorm.Open
var pingDB = func(database *gorm.DB) error {
	sqlDB, err := database.DB()
	if err != nil {
		return err
	}
	return sqlDB.Ping()
}

func Connect(dbDSN string) (*gorm.DB, error) {
	dsn := strings.TrimSpace(dbDSN)
	if dsn == "" {
		return nil, fmt.Errorf("не задан DSN базы данных")
	}

	db, err := openGorm(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("не удалось открыть базу данных: %w", err)
	}

	if err := pingDB(db); err != nil {
		return nil, fmt.Errorf("не удалось проверить соединение с базой данных: %w", err)
	}

	return db, nil
}
