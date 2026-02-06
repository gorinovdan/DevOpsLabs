package database

import (
	"fmt"
	"os"
	"path/filepath"

	"gorm.io/driver/sqlite"
	"gorm.io/gorm"
)

var mkdirAll = os.MkdirAll
var openGorm = gorm.Open

func Connect(dbPath string) (*gorm.DB, error) {
	dir := filepath.Dir(dbPath)
	if dir != "." {
		if err := mkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("не удалось создать каталог базы данных: %w", err)
		}
	}

	db, err := openGorm(sqlite.Open(dbPath), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("не удалось открыть базу данных: %w", err)
	}

	return db, nil
}
