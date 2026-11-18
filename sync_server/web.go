package main

import (
	_ "embed"
	"net/http"
)

//go:embed web/index.html
var webConsoleHTML []byte

func (h *syncHandler) handleWebIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(webConsoleHTML)
}
