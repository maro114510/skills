package coord

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/maro114510/skills/oe/internal/exitcode"
)

// The permissions of the lock directory and file: this user's only.
const (
	lockDirPerm  = 0o700
	lockFilePerm = 0o600
)

// lock is the host-wide lock of one Epic, held for the life of one oe process. Two oe
// processes on one host never mutate the same Epic at once; a second one stops with exit 7.
type lock struct {
	f *os.File
}

// StateDir is where oe keeps what belongs to this host only: ${XDG_STATE_HOME:-$HOME/.local/state}/oe.
func StateDir(getenv func(string) string) (string, error) {
	if dir := getenv("XDG_STATE_HOME"); dir != "" {
		return filepath.Join(dir, "oe"), nil
	}
	home := getenv("HOME")
	if home == "" {
		return "", exitcode.New(exitcode.Refused, "neither XDG_STATE_HOME nor HOME is set, so oe has no place for its host-local state")
	}
	return filepath.Join(home, ".local", "state", "oe"), nil
}

// LockDir is the directory of the host-wide locks: <StateDir>/locks.
func LockDir(getenv func(string) string) (string, error) {
	dir, err := StateDir(getenv)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "locks"), nil
}

// LockPath is the lock file of one Epic: <owner>-<repo>-<epic>.lock.
func LockPath(dir, repo string, epic int) string {
	owner, name, _ := strings.Cut(repo, "/")
	return filepath.Join(dir, fmt.Sprintf("%s-%s-%d.lock", owner, name, epic))
}

// acquireLock takes the lock without waiting. Held by another process is exit 7.
func acquireLock(path string) (*lock, error) {
	if err := os.MkdirAll(filepath.Dir(path), lockDirPerm); err != nil {
		return nil, exitcode.Wrap(exitcode.Refused, err, "cannot create the Epic lock directory")
	}
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, lockFilePerm) //nolint:gosec // G304: the path is built from the resolved repository and Epic.
	if err != nil {
		return nil, exitcode.Wrap(exitcode.Refused, err, "cannot open the Epic lock")
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, exitcode.New(exitcode.Coordination, "another oe process on this host holds the Epic lock "+path+"; this one does not wait or take over")
		}
		return nil, exitcode.Wrap(exitcode.Coordination, err, "cannot take the Epic lock "+path)
	}
	// The pid is a note for a person looking at the file; the lock itself is the flock.
	if err := f.Truncate(0); err == nil {
		_, _ = f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0)
	}
	return &lock{f: f}, nil
}

// release drops the lock. Closing the file releases the flock even if the unlock fails.
func (l *lock) release() {
	if l == nil || l.f == nil {
		return
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
	l.f = nil
}

// processAlive reports whether a process with this pid runs on this host. A process owned by
// another user still runs.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
