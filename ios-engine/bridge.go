package steamengine

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	steam "github.com/BirknerAlex/go-steam"
)

// Engine exposes a small, mobile-bindable API to the native iOS app.
type Engine struct {
	mu sync.RWMutex
	client *steam.Client
	status string
	lastError string
	currentFile string
	progress float64
	authenticated bool
	cancel context.CancelFunc
}

func NewEngine() *Engine {
	return &Engine{status: "Not connected"}
}

func (e *Engine) Status() string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.status
}

func (e *Engine) LastError() string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.lastError
}

func (e *Engine) Progress() float64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.progress
}

func (e *Engine) CurrentFile() string {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.currentFile
}

func (e *Engine) IsAuthenticated() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.authenticated && e.client != nil
}

func (e *Engine) Login(username, password, guardCode, cachePath string) string {
	username = strings.TrimSpace(username)
	if username == "" || password == "" {
		return "Enter your Steam username and password."
	}
	if cachePath == "" {
		return "The app could not access its private storage directory."
	}
	if err := os.MkdirAll(cachePath, 0700); err != nil {
		return fmt.Sprintf("Cannot create private Steam cache: %v", err)
	}
	e.mu.Lock()
	e.status = "Connecting to Steam…"
	e.lastError = ""
	e.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	code := strings.TrimSpace(guardCode)
	client, err := steam.New(ctx, steam.Config{
		Username: username,
		Password: password,
		CachePath: filepath.Join(cachePath, "steam-session"),
		MaxParallelChunks: 4,
		SteamGuardCallback: func() (string, error) {
			if code == "" {
				return "", fmt.Errorf("Steam Guard code required; enter it and retry sign-in")
			}
			return code, nil
		},
	})
	if err != nil {
		e.mu.Lock()
		e.status = "Sign-in failed"
		e.lastError = err.Error()
		e.authenticated = false
		e.mu.Unlock()
		return err.Error()
	}

	e.mu.Lock()
	oldClient := e.client
	e.client = client
	e.authenticated = true
	e.status = "Connected to Steam"
	e.lastError = ""
	e.mu.Unlock()
	if oldClient != nil {
		oldClient.Close()
	}
	return ""
}

func (e *Engine) DownloadWorkshopItem(itemID, targetDir string) string {
	id, err := strconv.ParseUint(strings.TrimSpace(itemID), 10, 64)
	if err != nil || id == 0 {
		return "That does not look like a valid Workshop item ID."
	}
	if targetDir == "" {
		return "The app could not access its download directory."
	}
	e.mu.Lock()
	if !e.authenticated || e.client == nil {
		e.mu.Unlock()
		return "Sign in to Steam before downloading Workshop items."
	}
	if e.cancel != nil {
		e.mu.Unlock()
		return "A download is already running."
	}
	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	client := e.client
	e.status = "Preparing Workshop download…"
	e.progress = 0
	e.currentFile = ""
	e.lastError = ""
	e.mu.Unlock()

	go func() {
		defer func() {
			e.mu.Lock()
			e.cancel = nil
			e.mu.Unlock()
		}()
		if err := os.MkdirAll(targetDir, 0700); err != nil {
			e.mu.Lock()
			e.status = "Download failed"
			e.lastError = err.Error()
			e.mu.Unlock()
			return
		}
		ch, err := client.DownloadWorkshopItem(ctx, steam.WorkshopDownloadRequest{
			ItemID: id,
			TargetDir: targetDir,
		})
		if err != nil {
			e.mu.Lock()
			e.status = "Download failed"
			e.lastError = err.Error()
			e.mu.Unlock()
			return
		}
		failed := false
		for p := range ch {
			e.mu.Lock()
			if p.TotalBytes > 0 {
				e.progress = float64(p.DoneBytes) / float64(p.TotalBytes)
			}
			if p.CurrentFile != "" {
				e.currentFile = p.CurrentFile
			}
			if p.Err != nil {
				e.status = "Download failed"
				e.lastError = p.Err.Error()
				failed = true
			} else if p.Phase == steam.PhaseComplete {
				e.progress = 1
				e.status = "Download complete"
			} else {
				e.status = p.Phase.String()
			}
			e.mu.Unlock()
		}
		if ctx.Err() != nil {
			e.mu.Lock()
			e.status = "Download cancelled"
			e.mu.Unlock()
		} else if !failed {
			e.mu.Lock()
			e.progress = 1
			e.status = "Download complete"
			e.mu.Unlock()
		}
	}()
	return ""
}

func (e *Engine) CancelDownload() {
	e.mu.Lock()
	cancel := e.cancel
	e.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (e *Engine) Logout() {
	e.mu.Lock()
	client := e.client
	e.client = nil
	e.authenticated = false
	e.status = "Not connected"
	e.lastError = ""
	e.mu.Unlock()
	if client != nil {
		client.Close()
	}
}
