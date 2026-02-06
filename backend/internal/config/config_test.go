package config

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("PORT", "")
	t.Setenv("DB_PATH", "")

	cfg := Load()
	require.Equal(t, "8080", cfg.Port)
	require.Equal(t, "data/app.db", cfg.DBPath)
}

func TestLoadCustom(t *testing.T) {
	require.NoError(t, os.Setenv("PORT", "9090"))
	require.NoError(t, os.Setenv("DB_PATH", "custom.db"))
	defer func() {
		_ = os.Unsetenv("PORT")
		_ = os.Unsetenv("DB_PATH")
	}()

	cfg := Load()
	require.Equal(t, "9090", cfg.Port)
	require.Equal(t, "custom.db", cfg.DBPath)
}
