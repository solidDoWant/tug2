package main

import "math"

func f32(u uint32) float32 { return math.Float32frombits(u) }
func u32(f float32) uint32 { return math.Float32bits(f) }
