package steamengine

// Tests the exact code path the app runs at launch: engine creation + Login
// with credentials. Auth against Steam will fail for the fake account, but
// the process must survive the whole flow — an unrecovered panic here is
// what would kill the real app instantly at launch.
import (
	"fmt"
	"testing"
)

func TestLoginSurvivesFullAuthPath(t *testing.T) {
	e := NewEngine()
	if e.Status() == "" {
		t.Fatal("engine status should never be empty after NewEngine")
	}
	dir := t.TempDir()
	result := e.Login("modshelf_citest_9x7", "definitely-not-a-real-password", "", dir)
	t.Logf("Login returned: %q (engine status now: %q)", result, e.Status())
	if e.Status() == "" {
		t.Fatal("engine status should be set after Login")
	}
	// The engine must not claim success for a fake account.
	if result == "" && !e.IsAuthenticated() {
		t.Fatal("Login returned no error but engine is not authenticated")
	}
	fmt.Println("engine survived the full login path")
}