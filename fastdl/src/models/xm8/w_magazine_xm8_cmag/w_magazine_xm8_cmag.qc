// mdldecompiler version 0.16.0
// upgrades/w_magazine_galil_75.mdl

$modelname "@@MDLNAME(mdl,w_magazine_xm8_cmag.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox 3.804 -3.748 -5.908  8.449 3.739 2.984
$illumposition 0.013945 -3.146832 0.729023
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "attachment"
{
    studio "meshes/w_magazine_galil_75_reference.dmx"
}

$definebone "R Hand" "" -1.296402 4.031676 -0.967747 3.31 -84.438599 -1.5348  0 0 0 0 0 0
$definebone "W_MAGAZINE" "R Hand" 10.787577 0.221493 1.182987 -1.8483 84.445 -3.1459  0 0 0 0 0 0

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30
    activity "ACT_VM_IDLE" 1
}
