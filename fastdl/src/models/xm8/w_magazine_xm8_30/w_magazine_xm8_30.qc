// mdldecompiler version 0.16.0
// upgrades/w_magazine_galil_35.mdl

$modelname "@@MDLNAME(mdl,w_magazine_xm8_30.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox 3.787 -0.53 -6.028  8.898 0.521 2.961
$illumposition 1.618232 -3.387131 -1.091128
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "attachment"
{
    studio "meshes/w_magazine_galil_35_reference.dmx"
}

$definebone "R Hand" "" -1.296402 4.031676 -0.967747 3.31 -84.438599 -1.5348  0 0 0 0 0 0
$definebone "W_MAGAZINE" "R Hand" 10.787577 0.221493 1.182987 -1.8483 84.445 -3.1459  0 0 0 0 0 0

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30
    activity "ACT_VM_IDLE" 1
}
