package main

// vtfc compiles texture sources into VTFs.
//
//	foo.png + foo.png.txt   compiled using the settings in the sidecar
//	foo.vtf                 copied through byte-for-byte
//
// Pass-through matters: re-encoding a DXT texture you did not edit costs a second generation of block
// artifacts for nothing, and on normal maps that is visible. Only ship a .png for maps you edit.
//
// Sidecar keys are vtex-flavoured: format, normal, clamps, clampt, nomip, nolod, bumpscale, version.

import (
	"bufio"
	"fmt"
	"image"
	"image/draw"
	_ "image/png"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

var sidecarRE = regexp.MustCompile(`^"?([A-Za-z_]+)"?\s+"?([^"\s]+)"?`)

var sidecarFlags = map[string]string{
	"normal": "NORMALMAP", "clamps": "CLAMPS", "clampt": "CLAMPT",
	"nomip": "NOMIP", "nolod": "NOLOD", "pointsample": "POINTSAMPLE",
	"trilinear": "TRILINEAR", "anisotropic": "ANISOTROPIC", "srgb": "SRGB",
	"envmap": "ENVMAP", "ssbump": "SSBUMP",
}

func readSidecar(path string) (map[string]string, error) {
	cfg := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		if m := sidecarRE.FindStringSubmatch(strings.TrimSpace(line)); m != nil {
			cfg[strings.ToLower(m[1])] = m[2]
		}
	}
	return cfg, sc.Err()
}

func truthy(s string) bool {
	switch strings.ToLower(s) {
	case "1", "true", "yes":
		return true
	}
	return false
}

// loadNRGBA decodes an image and normalises it to NRGBA, which keeps colour channels
// un-premultiplied - premultiplying would darken every pixel under a partial alpha.
func loadNRGBA(path string) (*image.NRGBA, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	src, _, err := image.Decode(f)
	if err != nil {
		return nil, err
	}
	if n, ok := src.(*image.NRGBA); ok {
		return n, nil
	}
	b := src.Bounds()
	dst := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(dst, dst.Bounds(), src, b.Min, draw.Src)
	return dst, nil
}

func compilePNG(src, dst string, cfg map[string]string) (string, error) {
	img, err := loadNRGBA(src)
	if err != nil {
		return "", err
	}
	w, h := img.Bounds().Dx(), img.Bounds().Dy()

	fname := strings.ToUpper(cfg["format"])
	if fname == "" {
		fname = "DXT5"
	}
	format, ok := formatByName[fname]
	if !ok {
		return "", fmt.Errorf("%s: unknown format %s", src, fname)
	}
	if blockBytes(format) != 0 && (w%4 != 0 || h%4 != 0) {
		return "", fmt.Errorf("%s: %dx%d is not a multiple of 4, required for %s", src, w, h, fname)
	}

	var flags uint32
	for key, name := range sidecarFlags {
		if truthy(cfg[key]) {
			flags |= flagByName[name]
		}
	}
	// DXT5 carries a full alpha channel; say so, the way the shipped textures do.
	if format == fmtDXT5 {
		flags |= flagByName["EIGHTBITALPHA"]
	}

	major, minor := uint32(7), uint32(2)
	if v := cfg["version"]; v != "" {
		a, b, _ := strings.Cut(v, ".")
		if x, err := strconv.Atoi(a); err == nil {
			major = uint32(x)
		}
		if y, err := strconv.Atoi(b); err == nil {
			minor = uint32(y)
		}
	}
	bump := float32(1.0)
	if b := cfg["bumpscale"]; b != "" {
		if f, err := strconv.ParseFloat(b, 32); err == nil {
			bump = float32(f)
		}
	}
	mip := !truthy(cfg["nomip"])

	size, err := writeVTF(dst, img, format, flags, bump, major, minor, mip)
	if err != nil {
		return "", err
	}
	kind := "mips"
	if !mip {
		kind = "nomip"
	}
	return fmt.Sprintf("%s %dx%d %s %d B", fname, w, h, kind, size), nil
}

func cmdVtfc(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: vtfc <source-dir> <out-dir>")
	}
	srcRoot, outRoot := args[0], args[1]
	made := 0
	err := filepath.WalkDir(srcRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(srcRoot, filepath.Dir(p))
		if err != nil {
			return err
		}
		outDir := filepath.Join(outRoot, rel)
		lower := strings.ToLower(d.Name())
		switch {
		case strings.HasSuffix(lower, ".vtf"):
			if err := os.MkdirAll(outDir, 0o755); err != nil {
				return err
			}
			raw, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(outDir, d.Name()), raw, 0o644); err != nil {
				return err
			}
			fmt.Printf("  copy    %s\n", filepath.Join(rel, d.Name()))
			made++
		case strings.HasSuffix(lower, ".png"):
			if err := os.MkdirAll(outDir, 0o755); err != nil {
				return err
			}
			cfg, err := readSidecar(p + ".txt")
			if err != nil {
				return err
			}
			out := filepath.Join(outDir, d.Name()[:len(d.Name())-4]+".vtf")
			info, err := compilePNG(p, out, cfg)
			if err != nil {
				return err
			}
			fmt.Printf("  compile %s.vtf  [%s]\n", filepath.Join(rel, d.Name()[:len(d.Name())-4]), info)
			made++
		}
		return nil
	})
	if err != nil {
		return err
	}
	if made == 0 {
		return fmt.Errorf("vtfc: no .png or .vtf sources under %s", srcRoot)
	}
	fmt.Printf("vtfc: %d texture(s)\n", made)
	return nil
}
