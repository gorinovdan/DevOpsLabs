package httpapi

import (
	"net/http"

	"devopslabs/internal/repository"
	"devopslabs/internal/service"
	"github.com/gin-gonic/gin"
)

func NewRouter(taskStore repository.TaskStore) *gin.Engine {
	r := gin.New()
	r.Use(gin.Logger())
	r.Use(gin.Recovery())
	r.Use(corsMiddleware())

	r.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	h := NewTaskHandler(taskStore, service.RealClock{})

	api := r.Group("/api")
	{
		api.GET("/tasks", h.List)
		api.GET("/tasks/:id", h.Get)
		api.POST("/tasks", h.Create)
		api.PUT("/tasks/:id", h.Update)
		api.DELETE("/tasks/:id", h.Delete)
		api.GET("/insights", h.Insights)
	}

	return r
}

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}
