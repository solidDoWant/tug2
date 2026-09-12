package main

// Minimal VTF reader/writer: 2D, single frame/face, DXT1/DXT5 and uncompressed BGRA8888.
//
// Hand-rolled because the alternatives are Windows-only (VTFEdit, vtex) or decode-only (no_vtf).
//
// VTF stores mipmaps SMALLEST FIRST, so the full-size image is the LAST chunk of the data block.

import (
	"encoding/binary"
	"fmt"
	"image"
	"os"
)

const vtfHeaderSize = 80

// Image formats, as stored in the header.
const (
	fmtRGBA8888      = 0
	fmtBGRA8888      = 12
	fmtDXT1          = 13
	fmtDXT3          = 14
	fmtDXT5          = 15
	fmtRGBA16161616F = 24
)

var formatByName = map[string]uint32{
	"DXT1": fmtDXT1, "DXT3": fmtDXT3, "DXT5": fmtDXT5,
	"BGRA8888": fmtBGRA8888, "RGBA8888": fmtRGBA8888,
	"RGBA16161616F": fmtRGBA16161616F,
}

var formatName = func() map[uint32]string {
	m := map[uint32]string{}
	for k, v := range formatByName {
		m[v] = k
	}
	return m
}()

// Texture flags. Only the ones the sidecar can set, plus the two the writer infers.
var flagByName = map[string]uint32{
	"POINTSAMPLE": 0x1, "TRILINEAR": 0x2, "CLAMPS": 0x4, "CLAMPT": 0x8,
	"ANISOTROPIC": 0x10, "HINT_DXT5": 0x20, "SRGB": 0x40, "NORMALMAP": 0x80,
	"NOMIP": 0x100, "NOLOD": 0x200, "ALL_MIPS": 0x400, "PROCEDURAL": 0x800,
	"ONEBITALPHA": 0x1000, "EIGHTBITALPHA": 0x2000, "ENVMAP": 0x4000,
	"SSBUMP": 0x8000000,
}

func blockBytes(f uint32) int {
	switch f {
	case fmtDXT1:
		return 8
	case fmtDXT3, fmtDXT5:
		return 16
	}
	return 0
}

func pixelBytes(f uint32) int {
	switch f {
	case fmtBGRA8888, fmtRGBA8888:
		return 4
	case fmtRGBA16161616F:
		return 8
	}
	return 0
}

// mipSize is the byte count of one mip level. DXT rounds up to whole 4x4 blocks.
func mipSize(f uint32, w, h int) int {
	if bb := blockBytes(f); bb != 0 {
		return max(1, (w+3)/4) * max(1, (h+3)/4) * bb
	}
	return w * h * pixelBytes(f)
}

type vtfHeader struct {
	major, minor  uint32
	headerSize    uint32
	width, height uint16
	flags         uint32
	frames        uint16
	reflectivity  [3]float32
	bumpScale     float32
	format        uint32
	mipmaps       uint8
	lowFormat     int32
	lowW, lowH    uint8
	depth         uint16
}

func readVTFHeader(d []byte) (*vtfHeader, error) {
	if len(d) < vtfHeaderSize || string(d[0:4]) != "VTF\x00" {
		return nil, fmt.Errorf("not a VTF")
	}
	le := binary.LittleEndian
	h := &vtfHeader{
		major: le.Uint32(d[4:]), minor: le.Uint32(d[8:]),
		headerSize: le.Uint32(d[12:]),
		width:      le.Uint16(d[16:]), height: le.Uint16(d[18:]),
		flags: le.Uint32(d[20:]), frames: le.Uint16(d[24:]),
		format: le.Uint32(d[52:]), mipmaps: d[56],
		lowFormat: int32(le.Uint32(d[57:])), lowW: d[61], lowH: d[62],
		depth: 1,
	}
	for i := 0; i < 3; i++ {
		h.reflectivity[i] = f32(le.Uint32(d[32+i*4:]))
	}
	h.bumpScale = f32(le.Uint32(d[48:]))
	if h.minor >= 2 {
		h.depth = le.Uint16(d[63:])
	}
	return h, nil
}

// writeVTF emits a 2D single-frame VTF. No low-res thumbnail; the engine treats it as optional.
func writeVTF(path string, img *image.NRGBA, format, flags uint32, bumpScale float32,
	major, minor uint32, mipmaps bool) (int, error) {

	w := img.Bounds().Dx()
	h := img.Bounds().Dy()

	levels := []*image.NRGBA{img}
	if mipmaps {
		cur := img
		for cw, ch := w, h; cw > 1 || ch > 1; {
			cw, ch = max(1, cw/2), max(1, ch/2)
			cur = halve(cur)
			levels = append(levels, cur)
		}
	}

	hdr := make([]byte, vtfHeaderSize)
	le := binary.LittleEndian
	copy(hdr[0:], "VTF\x00")
	le.PutUint32(hdr[4:], major)
	le.PutUint32(hdr[8:], minor)
	le.PutUint32(hdr[12:], vtfHeaderSize)
	le.PutUint16(hdr[16:], uint16(w))
	le.PutUint16(hdr[18:], uint16(h))
	le.PutUint32(hdr[20:], flags)
	le.PutUint16(hdr[24:], 1) // frames
	le.PutUint16(hdr[26:], 0) // firstFrame
	for i, v := range reflectivity(img) {
		le.PutUint32(hdr[32+i*4:], u32(v))
	}
	le.PutUint32(hdr[48:], u32(bumpScale))
	le.PutUint32(hdr[52:], format)
	hdr[56] = uint8(len(levels))
	le.PutUint32(hdr[57:], 0xFFFFFFFF) // no low-res image
	hdr[61], hdr[62] = 0, 0
	le.PutUint16(hdr[63:], 1) // depth

	body := make([]byte, 0, mipSize(format, w, h)*4/3)
	for i := len(levels) - 1; i >= 0; i-- { // VTF stores the smallest mip first
		body = append(body, encodeLevel(levels[i], format)...)
	}

	out := append(hdr, body...)
	if err := os.WriteFile(path, out, 0o644); err != nil {
		return 0, err
	}
	return len(out), nil
}

func encodeLevel(img *image.NRGBA, format uint32) []byte {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	if blockBytes(format) != 0 {
		return encodeDXT(img, format)
	}
	out := make([]byte, 0, w*h*4)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			p := img.PixOffset(x, y)
			r, g, b, a := img.Pix[p], img.Pix[p+1], img.Pix[p+2], img.Pix[p+3]
			if format == fmtBGRA8888 {
				out = append(out, b, g, r, a)
			} else {
				out = append(out, r, g, b, a)
			}
		}
	}
	return out
}

// reflectivity is the mean RGB of the top mip, normalised. Source's lighting compiler uses it to
// tint bounced light without reading the pixels.
func reflectivity(img *image.NRGBA) [3]float32 {
	var sum [3]float64
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	n := float64(w * h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			p := img.PixOffset(x, y)
			sum[0] += float64(img.Pix[p])
			sum[1] += float64(img.Pix[p+1])
			sum[2] += float64(img.Pix[p+2])
		}
	}
	var out [3]float32
	for i := range out {
		out[i] = float32(sum[i] / n / 255.0)
	}
	return out
}

// halve is a 2x2 box filter. Box is the conventional mipmap filter and, unlike a windowed-sinc,
// introduces no ringing on the hard edges these textures have.
func halve(src *image.NRGBA) *image.NRGBA {
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	dw, dh := max(1, sw/2), max(1, sh/2)
	dst := image.NewNRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		for x := 0; x < dw; x++ {
			var sum [4]int
			var n int
			for dy := 0; dy < 2; dy++ {
				for dx := 0; dx < 2; dx++ {
					sx, sy := x*2+dx, y*2+dy
					if sx >= sw || sy >= sh {
						continue
					}
					p := src.PixOffset(sx, sy)
					for c := 0; c < 4; c++ {
						sum[c] += int(src.Pix[p+c])
					}
					n++
				}
			}
			p := dst.PixOffset(x, y)
			for c := 0; c < 4; c++ {
				dst.Pix[p+c] = uint8(sum[c] / n)
			}
		}
	}
	return dst
}
