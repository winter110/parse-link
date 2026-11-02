//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
)

// availableSpace mirrors the Windows helper's freeSpace request on Unix hosts.
func availableSpace(path string) (uint64, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return 0, err
	}
	for {
		if _, err := os.Stat(absolute); err == nil {
			break
		}
		parent := filepath.Dir(absolute)
		if parent == absolute {
			return 0, os.ErrNotExist
		}
		absolute = parent
	}
	var stat syscall.Statfs_t
	if err := syscall.Statfs(absolute, &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
