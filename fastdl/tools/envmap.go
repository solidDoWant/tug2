package main

// Cubemap environment map -> equirectangular Radiance HDR, for use as the world background when
// rendering an icon.
//
// Why this is needed: the can's material declares $metal 1, and a metal has no diffuse colour of its
// own - its appearance IS the reflection of its surroundings. Lit only by a couple of lamps in an
// empty world it has nothing bright or sharp to reflect, so highlights come out dull. The envmap
// supplies those surroundings, and because it is stored as float16 it carries values above 1.0,
// which is what produces blown-out speculars rather than flat grey ones.
//
// Radiance .hdr rather than PNG because PNG would clamp to 8 bits and throw away exactly the
// above-1.0 range that matters here. Blender reads .hdr natively.

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

// halfToFloat decodes IEEE 754 binary16.
func halfToFloat(h uint16) float32 {
	sign := uint32(h>>15) << 31
	exp := (h >> 10) & 0x1F
	frac := uint32(h & 0x3FF)
	switch exp {
	case 0:
		if frac == 0 {
			return math.Float32frombits(sign)
		}
		// Subnormal: shift the fraction up until it is normalised. A half subnormal is
		// frac * 2^-24, so k shifts leave an exponent of -14-k.
		k := 0
		for frac&0x400 == 0 {
			frac <<= 1
			k++
		}
		frac &= 0x3FF
		return math.Float32frombits(sign | uint32(-14-k+127)<<23 | frac<<13)
	case 0x1F:
		return math.Float32frombits(sign | 0xFF<<23 | frac<<13)
	default:
		return math.Float32frombits(sign | (uint32(exp)-15+127)<<23 | frac<<13)
	}
}

// cubeFaces returns the six faces of the largest mip as float32 RGB.
//
// VTF orders data smallest mip first and, within a mip, one chunk per face - so the largest mip is
// the final six chunks.
func cubeFaces(d []byte, h *vtfHeader) ([][]float32, int, error) {
	if h.format != fmtRGBA16161616F {
		return nil, 0, fmt.Errorf("envmap: expected RGBA16161616F, got %s", formatName[h.format])
	}
	if h.flags&flagByName["ENVMAP"] == 0 {
		return nil, 0, fmt.Errorf("envmap: ENVMAP flag is not set; this is not a cubemap")
	}
	const faces = 6
	size := int(h.width)
	face := size * size * 8 // 4 channels x float16
	need := face * faces
	if len(d) < int(h.headerSize)+need {
		return nil, 0, fmt.Errorf("envmap: truncated (want %d bytes of face data)", need)
	}
	base := len(d) - need
	out := make([][]float32, faces)
	le := binary.LittleEndian
	for f := 0; f < faces; f++ {
		px := make([]float32, size*size*3)
		off := base + f*face
		for i := 0; i < size*size; i++ {
			for c := 0; c < 3; c++ {
				px[i*3+c] = halfToFloat(le.Uint16(d[off+i*8+c*2:]))
			}
		}
		out[f] = px
	}
	return out, size, nil
}

// sampleCube picks the face a direction hits and reads it with nearest sampling. Face order is
// Source's: +X, -X, +Y, -Y, +Z, -Z.
func sampleCube(faces [][]float32, size int, x, y, z float64) (float32, float32, float32) {
	ax, ay, az := math.Abs(x), math.Abs(y), math.Abs(z)
	var idx int
	var sc, tc, ma float64
	switch {
	case ax >= ay && ax >= az:
		ma = ax
		if x > 0 {
			idx, sc, tc = 0, -y, -z
		} else {
			idx, sc, tc = 1, y, -z
		}
	case ay >= az:
		ma = ay
		if y > 0 {
			idx, sc, tc = 2, x, -z
		} else {
			idx, sc, tc = 3, -x, -z
		}
	default:
		ma = az
		if z > 0 {
			idx, sc, tc = 4, x, y
		} else {
			idx, sc, tc = 5, x, -y
		}
	}
	if ma < 1e-12 {
		ma = 1e-12
	}
	u := (sc/ma + 1) * 0.5
	v := (tc/ma + 1) * 0.5
	px := clampInt(int(u*float64(size)), 0, size-1)
	py := clampInt(int((1-v)*float64(size)), 0, size-1)
	o := (py*size + px) * 3
	return faces[idx][o], faces[idx][o+1], faces[idx][o+2]
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// writeHDR emits flat (non-RLE) Radiance RGBE, which the format permits and Blender reads.
func writeHDR(path string, w, h int, rgb []float32) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	bw := bufio.NewWriter(f)
	fmt.Fprint(bw, "#?RADIANCE\n")
	fmt.Fprint(bw, "FORMAT=32-bit_rle_rgbe\n\n")
	fmt.Fprintf(bw, "-Y %d +X %d\n", h, w)
	for i := 0; i < w*h; i++ {
		r, g, b := float64(rgb[i*3]), float64(rgb[i*3+1]), float64(rgb[i*3+2])
		v := math.Max(r, math.Max(g, b))
		if v < 1e-32 {
			bw.Write([]byte{0, 0, 0, 0})
			continue
		}
		frac, exp := math.Frexp(v)
		s := frac * 256.0 / v
		bw.Write([]byte{
			byte(clampInt(int(r*s), 0, 255)),
			byte(clampInt(int(g*s), 0, 255)),
			byte(clampInt(int(b*s), 0, 255)),
			byte(clampInt(exp+128, 0, 255)),
		})
	}
	return bw.Flush()
}

func cmdVtf2hdr(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: vtf2hdr <in.vtf> <out.hdr> [equirect-width]")
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	hdr, err := readVTFHeader(raw)
	if err != nil {
		return err
	}
	faces, size, err := cubeFaces(raw, hdr)
	if err != nil {
		return err
	}
	w := size * 8
	if len(args) > 2 {
		if _, err := fmt.Sscanf(args[2], "%d", &w); err != nil {
			return fmt.Errorf("bad equirect width %q", args[2])
		}
	}
	h := w / 2

	out := make([]float32, w*h*3)
	var peak float32
	for y := 0; y < h; y++ {
		phi := (0.5 - (float64(y)+0.5)/float64(h)) * math.Pi // +pi/2 at the top
		for x := 0; x < w; x++ {
			theta := ((float64(x)+0.5)/float64(w)*2 - 1) * math.Pi
			// theta 0 faces -Y, matching Blender's default equirectangular orientation.
			dx := math.Cos(phi) * math.Sin(theta)
			dy := -math.Cos(phi) * math.Cos(theta)
			dz := math.Sin(phi)
			r, g, b := sampleCube(faces, size, dx, dy, dz)
			o := (y*w + x) * 3
			out[o], out[o+1], out[o+2] = r, g, b
			for _, c := range [3]float32{r, g, b} {
				if c > peak {
					peak = c
				}
			}
		}
	}
	if err := writeHDR(args[1], w, h, out); err != nil {
		return err
	}
	fmt.Printf("%s: cubemap %dx%d x6 -> equirect %dx%d, peak %.2f -> %s\n",
		args[0], size, size, w, h, peak, args[1])
	return nil
}
