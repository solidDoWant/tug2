// mdldecompiler version 0.16.0
// upgrades/a_magazine_galil_75.mdl

$modelname "@@MDLNAME(mdl,a_magazine_xm8_cmag.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox 9.501 -4.793 -8.92  12.855 0.351 -2.771
$illumposition -3.057883 -12.843685 -5.041063
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "attachment"
{
    studio "meshes/a_magazine_galil_75_reference.dmx"
}

$definebone "mag" "" -3.059554 -12.993446 -6.918 0 0 90  0 0 0 0 0 0
$definebone "bullet" "mag" 0.000133 3.107925 -0.000189 0 0 -90  0 0 0 0 0 0

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30
    activity "ACT_VM_IDLE" 1
}
