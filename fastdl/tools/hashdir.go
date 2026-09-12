package main

// hashdir prints <prefix>_<hash12> for a directory's contents.
//
// Hashes the sorted (relative path, bytes) of every file, so a rename counts as a change too. This
// is what puts content at a path no client has ever requested.

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func groupHash(root string) (string, int, error) {
	var rels []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			r, err := filepath.Rel(root, p)
			if err != nil {
				return err
			}
			rels = append(rels, filepath.ToSlash(r))
		}
		return nil
	})
	if err != nil {
		return "", 0, err
	}
	sort.Strings(rels)

	h := sha256.New()
	for _, r := range rels {
		h.Write([]byte(r))
		h.Write([]byte{0})
		f, err := os.Open(filepath.Join(root, filepath.FromSlash(r)))
		if err != nil {
			return "", 0, err
		}
		if _, err := io.Copy(h, f); err != nil {
			f.Close()
			return "", 0, err
		}
		f.Close()
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:12], len(rels), nil
}

func cmdHashdir(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: hashdir <prefix> <dir>")
	}
	prefix, root := args[0], args[1]
	st, err := os.Stat(root)
	if err != nil || !st.IsDir() {
		return fmt.Errorf("hashdir: no such directory %s", root)
	}
	sum, n, err := groupHash(root)
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("hashdir: %s is empty", root)
	}
	fmt.Println(strings.Join([]string{prefix, sum}, "_"))
	return nil
}
