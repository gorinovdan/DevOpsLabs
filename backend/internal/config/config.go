package config

import "os"

type Config struct {
	Port  string
	DBDSN string
}

func Load() Config {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	dbDSN := os.Getenv("DB_DSN")
	if dbDSN == "" {
		dbDSN = "host=localhost user=postgres password=postgres dbname=flowboard port=5432 sslmode=disable TimeZone=UTC"
	}

	return Config{
		Port:  port,
		DBDSN: dbDSN,
	}
}
