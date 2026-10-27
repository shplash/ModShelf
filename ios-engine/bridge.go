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
	mu            sync.RWMutex
	loginMu       sync.Mutex
	client        *steam.Client
	status        string
	lastError     string
	currentFile   string
	progress      float64
	authenticated bool
	cancel        context.CancelFunc
	guardCh       chan string
	guardPending  bool
}

func NewEngine() *Engine { return &Engine{status: "Not connected"} }

// SubmitGuardCode delivers the code the user typed to a sign-in that is waiting for it.
// It does not start a new login, so Steam sends only one Steam Guard prompt.
func (e *Engine) SubmitGuardCode(code string) {
	code = strings.TrimSpace(code)
	e.mu.Lock()
	ch := e.guardCh
	e.guardCh = nil
	e.guardPending = false
	e.mu.Unlock()
	if ch == nil {
		return
	}
	select {
	case ch <- code:
	default:
		// The callback may already have exited because the login context timed out.
		// In that case, there is no one left waiting on the channel.
	}
}

func (e *Engine) Status() string      { e.mu.RLock(); defer e.mu.RUnlock(); return e.status }
func (e *Engine) LastError() string   { e.mu.RLock(); defer e.mu.RUnlock(); return e.lastError }
func (e *Engine) Progress() float64   { e.mu.RLock(); defer e.mu.RUnlock(); return e.progress }
func (e *Engine) CurrentFile() string { e.mu.RLock(); defer e.mu.RUnlock(); return e.currentFile }
func (e *Engine) IsAuthenticated() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.authenticated && e.client != nil
}

func (e *Engine) Login(username, password, guardCode, cachePath string) string {
	e.loginMu.Lock()
	defer e.loginMu.Unlock()
	username = strings.TrimSpace(username)
	if username == "" || password == "" {
		return "Enter your Steam username and password."
	}
	if strings.TrimSpace(cachePath) == "" {
		return "The app could not access its private storage directory."
	}
	if err := os.MkdirAll(cachePath, 0700); err != nil {
		return fmt.Sprintf("Cannot create private Steam cache: %v", err)
	}
	e.mu.Lock()
	if e.cancel != nil {
		e.mu.Unlock()
		return "Wait for the current download to finish or cancel it before signing in again."
	}
	// If a guard prompt is already pending, do not restart the same login flow.
	if e.guardPending {
		e.mu.Unlock()
		return "Steam is waiting for the current Guard prompt to finish."
	}
	e.status, e.lastError = "Connecting to Steam…", ""
	e.guardCh = nil
	e.guardPending = false
	e.mu.Unlock()

	// Keep the constructor context alive through connection establishment only; the client
	// implementation owns its background work after New returns.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	code := strings.TrimSpace(guardCode)
	client, err := steam.New(ctx, steam.Config{
		Username: username, Password: password,
		CachePath:         filepath.Join(cachePath, "steam-session"),
		MaxParallelChunks: 4,
		SteamGuardCallback: func() (string, error) {
			if code != "" {
				return code, nil
			}

			e.mu.Lock()
			if e.guardPending {
				ch := e.guardCh
				e.mu.Unlock()
				if ch == nil {
					return "", fmt.Errorf("The Steam Guard request was cancelled. Please try signing in again.")
				}
				select {
				case c := <-ch:
					if c == "" {
						return "", fmt.Errorf("The Steam Guard code was empty.")
					}
					return c, nil
				case <-ctx.Done():
					e.mu.Lock()
					e.guardCh = nil
					e.guardPending = false
					e.mu.Unlock()
					return "", fmt.Errorf("The Steam Guard code was not entered in time. Try signing in again.")
				}
			}

			// The user can satisfy the same prompt either by approving the sign-in in the Steam app
			// or by entering the Guard code. We only allow one outstanding request so a second prompt
			// is not started while the original login attempt is still waiting.
			ch := make(chan string, 1)
			e.guardCh = ch
			e.guardPending = true
			e.status = "Steam Guard code required"
			e.lastError = "Approve the sign-in in the Steam app or enter the Guard code."
			e.mu.Unlock()

			select {
			case c := <-ch:
				e.mu.Lock()
				e.guardCh = nil
				e.guardPending = false
				e.mu.Unlock()
				if c == "" {
					return "", fmt.Errorf("The Steam Guard code was empty.")
				}
				return c, nil
			case <-ctx.Done():
				e.mu.Lock()
				e.guardCh = nil
				e.guardPending = false
				e.mu.Unlock()
				return "", fmt.Errorf("The Steam Guard code was not entered in time. Try signing in again.")
			}
		},
	})
	if err != nil {
		e.mu.Lock()
		e.status = "Sign-in failed"
		e.lastError = err.Error()
		e.guardCh = nil
		e.guardPending = false
		e.mu.Unlock()
		return err.Error()
	}
	e.mu.Lock()
	oldClient := e.client
	e.client, e.authenticated = client, true
	e.guardCh = nil
	e.guardPending = false
	e.status, e.lastError = "Connected to Steam", ""
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
	if strings.TrimSpace(targetDir) == "" {
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
	e.status, e.lastError = "Preparing Workshop download…", ""
	e.progress, e.currentFile = 0, ""
	e.mu.Unlock()

	go func() {
		defer func() { e.mu.Lock(); e.cancel = nil; e.mu.Unlock() }()
		fail := func(err error) {
			e.mu.Lock()
			e.status = "Download failed"
			e.lastError = err.Error()
			e.mu.Unlock()
		}
		if err := os.MkdirAll(targetDir, 0700); err != nil {
			fail(err)
			return
		}
		ch, err := client.DownloadWorkshopItem(ctx, steam.WorkshopDownloadRequest{ItemID: id, TargetDir: targetDir})
		if err != nil {
			fail(err)
			return
		}
		failed := false
		for p := range ch {
			e.mu.Lock()
			// The library reports whole chunks completed, not bytes written, so the chunk count is
			// the only progress it actually gives us.
			if p.TotalBytes > 0 && p.DoneBytes > 0 {
				e.progress = float64(p.DoneBytes) / float64(p.TotalBytes)
			} else if p.TotalChunks > 0 {
				e.progress = float64(p.DoneChunks) / float64(p.TotalChunks)
			}
			if e.progress > 1 {
				e.progress = 1
			}
			if p.CurrentFile != "" {
				e.currentFile = p.CurrentFile
			}
			if p.Err != nil {
				failed = true
				e.status = "Download failed"
				e.lastError = p.Err.Error()
			} else if !failed && p.Phase == steam.PhaseComplete {
				e.progress = 1
				e.status = "Download complete"
			} else if !failed && ctx.Err() == nil {
				switch p.Phase {
				case steam.PhaseResolving:
					e.status = "Preparing download…"
				case steam.PhaseManifest:
					e.status = "Fetching Steam manifest…"
				case steam.PhaseDiffing:
					e.status = "Checking files already here…"
				default:
					e.status = "Downloading"
				}
			}
			e.mu.Unlock()
		}
		e.mu.Lock()
		switch {
		case ctx.Err() != nil:
			e.status = "Download cancelled"
			e.lastError = "Download was cancelled."
		case failed:
			// Keep the failure status and error; later progress events must not erase them.
		case e.status == "Download complete":
			e.progress = 1
		default:
			e.status = "Download failed"
			e.lastError = "The download ended without a completion event."
		}
		e.mu.Unlock()
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
	cancel, client := e.cancel, e.client
	if cancel != nil {
		cancel()
	}
	e.client, e.authenticated = nil, false
	e.status, e.lastError = "Not connected", ""
	e.guardCh = nil
	e.guardPending = false
	e.mu.Unlock()
	if client != nil {
		client.Close()
	}
}
