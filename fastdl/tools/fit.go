package main

// fit scales an image to cover a target size and crops the overflow - what a map vote image needs,
// since the sources are workshop previews of whatever aspect the mapper uploaded, and the vote panel
// draws a fixed 2:1 texture.
//
// Sidecar keys (see vtfc.go):
//
//	"fit"    "512x256"   target size
//	"focusx" "0.5"       where the crop window sits across the overflow, 0 = left edge, 1 = right
//	"focusy" "0.5"       likewise, 0 = top, 1 = bottom
//	"zoom"   "1"         crop tighter than the aspect needs, e.g. 1.25 keeps 80% of each side -
//	                     for a HUD or viewmodel that sits too far in for the aspect crop to reach
//
// The focus keys are how a bad crop is fixed: move the window, rebuild. The source stays the
// untouched preview, so no re-download and no second generation of JPEG artifacts.

import (
	"fmt"
	"image"
	"math"
	"strconv"
	"strings"
)

func parseFit(cfg map[string]string) (w, h int, fx, fy, zoom float64, ok bool, err error) {
	spec := cfg["fit"]
	if spec == "" {
		return 0, 0, 0, 0, 0, false, nil
	}
	a, b, found := strings.Cut(strings.ToLower(spec), "x")
	if w, err = strconv.Atoi(a); !found || err != nil || w <= 0 {
		return 0, 0, 0, 0, 0, false, fmt.Errorf("fit %q: want WxH", spec)
	}
	if h, err = strconv.Atoi(b); err != nil || h <= 0 {
		return 0, 0, 0, 0, 0, false, fmt.Errorf("fit %q: want WxH", spec)
	}
	zoom = 1
	if v := cfg["zoom"]; v != "" {
		if zoom, err = strconv.ParseFloat(v, 64); err != nil || zoom < 1 {
			return 0, 0, 0, 0, 0, false, fmt.Errorf("zoom %q: want a number of at least 1", v)
		}
	}
	focus := func(key string) (float64, error) {
		v := cfg[key]
		if v == "" {
			return 0.5, nil
		}
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 1 {
			return 0, fmt.Errorf("%s %q: want a number from 0 to 1", key, v)
		}
		return f, nil
	}
	if fx, err = focus("focusx"); err != nil {
		return
	}
	if fy, err = focus("focusy"); err != nil {
		return
	}
	return w, h, fx, fy, zoom, true, nil
}

// fitImage returns src scaled so it covers w x h (times zoom), then cropped to exactly w x h.
//
// Resampling is an exact box filter: each output pixel is the area-weighted mean of the source
// pixels its footprint covers. Every source here is larger than the target, so this is always a
// downscale, where a box filter is alias-free and has no ringing. On the rare upscale it degrades to
// nearest-neighbour, which is visible but not wrong.
func fitImage(src *image.NRGBA, w, h int, fx, fy, zoom float64) *image.NRGBA {
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	scale := math.Max(float64(w)/float64(sw), float64(h)/float64(sh)) * zoom

	// The crop window, in source pixels. At zoom 1 one of the two dimensions spans the whole source.
	cw, ch := float64(w)/scale, float64(h)/scale
	x0 := (float64(sw) - cw) * fx
	y0 := (float64(sh) - ch) * fy
	step := 1 / scale

	dst := image.NewNRGBA(image.Rect(0, 0, w, h))
	for oy := 0; oy < h; oy++ {
		ya, yb := y0+float64(oy)*step, y0+float64(oy+1)*step
		for ox := 0; ox < w; ox++ {
			xa, xb := x0+float64(ox)*step, x0+float64(ox+1)*step
			var acc [4]float64
			var total float64
			for sy := int(ya); sy < sh && float64(sy) < yb; sy++ {
				wy := math.Min(yb, float64(sy+1)) - math.Max(ya, float64(sy))
				if wy <= 0 {
					continue
				}
				for sx := int(xa); sx < sw && float64(sx) < xb; sx++ {
					wx := math.Min(xb, float64(sx+1)) - math.Max(xa, float64(sx))
					if wx <= 0 {
						continue
					}
					wgt := wx * wy
					p := src.PixOffset(src.Bounds().Min.X+sx, src.Bounds().Min.Y+sy)
					for c := 0; c < 4; c++ {
						acc[c] += float64(src.Pix[p+c]) * wgt
					}
					total += wgt
				}
			}
			q := dst.PixOffset(ox, oy)
			for c := 0; c < 4; c++ {
				dst.Pix[q+c] = uint8(math.Round(acc[c] / total))
			}
		}
	}
	return dst
}
