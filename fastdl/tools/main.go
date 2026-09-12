package main

// Build tooling for the fast-download content image. One binary, several subcommands, driven by
// tools/build.sh - see fastdl/README.md.

import (
	"fmt"
	"image/png"
	"os"
)

func cmdVtf2png(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: vtf2png <in.vtf> <out.png>")
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	h, err := readVTFHeader(raw)
	if err != nil {
		return err
	}
	w, ht := int(h.width), int(h.height)
	top := mipSize(h.format, w, ht)
	if len(raw) < top {
		return fmt.Errorf("%s: truncated", args[0])
	}
	// VTF stores mipmaps smallest first, so the full-size image is the last chunk.
	data := raw[len(raw)-top:]
	if blockBytes(h.format) == 0 {
		return fmt.Errorf("%s: decode of %s not supported", args[0], formatName[h.format])
	}
	img := decodeDXT(data, w, ht, h.format)
	out, err := os.Create(args[1])
	if err != nil {
		return err
	}
	defer out.Close()
	fmt.Printf("%s: %s %dx%d mips=%d -> %s\n", args[0], formatName[h.format], w, ht, h.mipmaps, args[1])
	return png.Encode(out, img)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fastdl-tools <vtfc|hashdir|template|vtf2png|vtf2hdr> ...")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "vtfc":
		err = cmdVtfc(os.Args[2:])
	case "hashdir":
		err = cmdHashdir(os.Args[2:])
	case "template":
		err = cmdTemplate(os.Args[2:])
	case "vtf2png":
		err = cmdVtf2png(os.Args[2:])
	case "vtf2hdr":
		err = cmdVtf2hdr(os.Args[2:])
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
