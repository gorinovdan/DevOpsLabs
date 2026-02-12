package config

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("PORT", "")
	t.Setenv("DB_DSN", "")

	cfg := Load()
	require.Equal(t, "8080", cfg.Port)
	require.Equal(t, "host=localhost user=postgres password=postgres dbname=flowboard port=5432 sslmode=disable TimeZone=UTC", cfg.DBDSN)
}

func TestLoadCustom(t *testing.T) {
	require.NoError(t, os.Setenv("PORT", "9090"))
	require.NoError(t, os.Setenv("DB_DSN", "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable"))
	defer func() {
		_ = os.Unsetenv("PORT")
		_ = os.Unsetenv("DB_DSN")
	}()

	cfg := Load()
	require.Equal(t, "9090", cfg.Port)
	require.Equal(t, "host=db user=demo password=secret dbname=demo port=5432 sslmode=disable", cfg.DBDSN)
}
