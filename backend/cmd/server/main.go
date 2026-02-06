package main

import (
	"log"
	"os"

	"devopslabs/internal/config"
	"devopslabs/internal/database"
	"devopslabs/internal/domain"
	"devopslabs/internal/repository"
	"devopslabs/internal/transport/httpapi"
	"gorm.io/gorm"
)

type Router interface {
	Run(addr ...string) error
}

var startServer = func(addr string, router Router) error {
	return router.Run(addr)
}

var exit = os.Exit
var connectDB = database.Connect
var migrateDB = func(database *gorm.DB) error {
	return database.AutoMigrate(&domain.Task{})
}

func main() {
	if err := run(); err != nil {
		log.Printf("ошибка сервера: %v", err)
		exit(1)
	}
}

func run() error {
	cfg := config.Load()

	database, err := connectDB(cfg.DBPath)
	if err != nil {
		return err
	}

	if err := migrateDB(database); err != nil {
		return err
	}

	taskStore := repository.NewGormTaskStore(database)
	router := httpapi.NewRouter(taskStore)

	if err := startServer(":"+cfg.Port, router); err != nil {
		return err
	}

	return nil
}
