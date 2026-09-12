package main

// DXT1/DXT5 block codecs.
//
// Encoding uses bounding-box endpoint selection: the endpoints are the per-channel max and min of
// each 4x4 block, and each pixel takes the nearest of four interpolated entries. Worse than a
// principal-axis fit only on strongly bimodal blocks, and indistinguishable on photographic texture.

import (
	"encoding/binary"
	"image"
)

func to565(r, g, b int) uint16 {
	return uint16(((r>>3)&0x1F)<<11 | ((g>>2)&0x3F)<<5 | ((b >> 3) & 0x1F))
}

func from565(c uint16) (int, int, int) {
	return int((c>>11)&0x1F) * 255 / 31,
		int((c>>5)&0x3F) * 255 / 63,
		int(c&0x1F) * 255 / 31
}

// blockAt gathers one 4x4 block as 16 RGBA quads, replicating edge pixels where the image does not
// reach a multiple of four.
func blockAt(img *image.NRGBA, bx, by int) (px [16][4]int) {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	for i := 0; i < 16; i++ {
		x := min(bx*4+i%4, w-1)
		y := min(by*4+i/4, h-1)
		p := img.PixOffset(x, y)
		px[i] = [4]int{int(img.Pix[p]), int(img.Pix[p+1]), int(img.Pix[p+2]), int(img.Pix[p+3])}
	}
	return px
}

func encodeDXT(img *image.NRGBA, format uint32) []byte {
	w, h := img.Bounds().Dx(), img.Bounds().Dy()
	bw, bh := max(1, (w+3)/4), max(1, (h+3)/4)
	bb := blockBytes(format)
	out := make([]byte, 0, bw*bh*bb)
	le := binary.LittleEndian
	buf := make([]byte, 16)

	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			px := blockAt(img, bx, by)

			// Colour endpoints: per-channel extremes of the block.
			lo := [3]int{255, 255, 255}
			hi := [3]int{0, 0, 0}
			for _, p := range px {
				for c := 0; c < 3; c++ {
					lo[c] = min(lo[c], p[c])
					hi[c] = max(hi[c], p[c])
				}
			}
			hi5 := to565(hi[0], hi[1], hi[2])
			lo5 := to565(lo[0], lo[1], lo[2])
			c0, c1 := max(hi5, lo5), min(hi5, lo5)

			var pal [4][3]int
			pal[0][0], pal[0][1], pal[0][2] = from565(c0)
			pal[1][0], pal[1][1], pal[1][2] = from565(c1)
			for c := 0; c < 3; c++ {
				pal[2][c] = (2*pal[0][c] + pal[1][c]) / 3
				pal[3][c] = (pal[0][c] + 2*pal[1][c]) / 3
			}

			var cbits uint32
			if c0 != c1 { // a solid block leaves every index at 0, whichever mode it decodes as
				for i, p := range px {
					best, bestD := 0, 1<<30
					for k := 0; k < 4; k++ {
						d := 0
						for c := 0; c < 3; c++ {
							diff := p[c] - pal[k][c]
							d += diff * diff
						}
						if d < bestD { // strictly less: first match wins on a tie
							best, bestD = k, d
						}
					}
					cbits |= uint32(best&3) << (2 * i)
				}
			}

			if format == fmtDXT5 {
				a0, a1 := 0, 255
				for _, p := range px {
					a0 = max(a0, p[3])
					a1 = min(a1, p[3])
				}
				var tbl [8]int
				tbl[0], tbl[1] = a0, a1
				for i := 0; i < 6; i++ {
					tbl[2+i] = ((7-i)*a0 + (1+i)*a1) / 7
				}
				var abits uint64
				if a0 != a1 {
					for i, p := range px {
						best, bestD := 0, 1<<30
						for k := 0; k < 8; k++ {
							d := p[3] - tbl[k]
							if d < 0 {
								d = -d
							}
							if d < bestD {
								best, bestD = k, d
							}
						}
						abits |= uint64(best&7) << (3 * i)
					}
				}
				buf[0], buf[1] = uint8(a0), uint8(a1)
				for i := 0; i < 6; i++ {
					buf[2+i] = uint8(abits >> (8 * i))
				}
				le.PutUint16(buf[8:], c0)
				le.PutUint16(buf[10:], c1)
				le.PutUint32(buf[12:], cbits)
				out = append(out, buf[:16]...)
			} else {
				le.PutUint16(buf[0:], c0)
				le.PutUint16(buf[2:], c1)
				le.PutUint32(buf[4:], cbits)
				out = append(out, buf[:8]...)
			}
		}
	}
	return out
}

// decodeDXT expands a DXT1/DXT5 mip into an NRGBA image.
func decodeDXT(data []byte, w, h int, format uint32) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	bw, bh := max(1, (w+3)/4), max(1, (h+3)/4)
	bb := blockBytes(format)
	le := binary.LittleEndian

	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			off := (by*bw + bx) * bb
			if off+bb > len(data) {
				return img
			}
			var alpha [16]int
			for i := range alpha {
				alpha[i] = 255
			}
			coff := off
			if format == fmtDXT5 {
				a0, a1 := int(data[off]), int(data[off+1])
				var bits uint64
				for i := 0; i < 6; i++ {
					bits |= uint64(data[off+2+i]) << (8 * i)
				}
				var tbl [8]int
				tbl[0], tbl[1] = a0, a1
				if a0 > a1 {
					for i := 0; i < 6; i++ {
						tbl[2+i] = ((7-i)*a0 + (1+i)*a1) / 7
					}
				} else {
					for i := 0; i < 4; i++ {
						tbl[2+i] = ((5-i)*a0 + (1+i)*a1) / 5
					}
					tbl[6], tbl[7] = 0, 255
				}
				for i := 0; i < 16; i++ {
					alpha[i] = tbl[(bits>>(3*i))&7]
				}
				coff = off + 8
			}

			c0, c1 := le.Uint16(data[coff:]), le.Uint16(data[coff+2:])
			idx := le.Uint32(data[coff+4:])
			var pal [4][3]int
			pal[0][0], pal[0][1], pal[0][2] = from565(c0)
			pal[1][0], pal[1][1], pal[1][2] = from565(c1)
			opaque := c0 > c1 || format == fmtDXT5
			for c := 0; c < 3; c++ {
				if opaque {
					pal[2][c] = (2*pal[0][c] + pal[1][c]) / 3
					pal[3][c] = (pal[0][c] + 2*pal[1][c]) / 3
				} else {
					pal[2][c] = (pal[0][c] + pal[1][c]) / 2
					pal[3][c] = 0
				}
			}

			for i := 0; i < 16; i++ {
				x, y := bx*4+i%4, by*4+i/4
				if x >= w || y >= h {
					continue
				}
				k := int(idx>>(2*i)) & 3
				a := alpha[i]
				if format == fmtDXT1 && !opaque && k == 3 {
					a = 0
				}
				p := img.PixOffset(x, y)
				img.Pix[p] = uint8(pal[k][0])
				img.Pix[p+1] = uint8(pal[k][1])
				img.Pix[p+2] = uint8(pal[k][2])
				img.Pix[p+3] = uint8(a)
			}
		}
	}
	return img
}
