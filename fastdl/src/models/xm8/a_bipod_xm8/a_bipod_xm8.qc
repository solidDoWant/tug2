// mdldecompiler version 0.16.0
// upgrades/a_bipod_galil.mdl

$modelname "@@MDLNAME(mdl,a_bipod_xm8.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox 12.519 -2.889 -4.162  22.506001 -1.569 -1.401
$illumposition -3.080549 -18.582739 -4.70775
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "attachment"
{
    studio "meshes/a_bipod_galil_reference.dmx"
}

$definebone "body" "" -3.059554 -7.298472 -4.585165 0 0 90  0 0 0 0 0 0
$definebone "Bipod_Base" "body" -0.000446 -0.617262 15.771287 0.0001 0 -90  0 0 0 0 0 0
$definebone "Bipod_joint2" "Bipod_Base" -1.229857 1.585859 0.785401 14.6096 23.0851 -64.3526  0 0 0 0 0 0
$definebone "Bipod_joint1" "Bipod_Base" 1.097398 1.585857 0.785401 -14.5646 -22.990801 -64.411003  0 0 0 0 0 0
$definebone "Bipod_Right" "Bipod_Base" -0.928719 0.633511 0.598631 23.494699 0.0264 -89.9711  0 0 0 0 0 0
$definebone "Bipod_Left" "Bipod_Base" 0.903784 0.633511 0.600363 -23.403299 -0.0268 -90.029099  0 0 0 0 0 0

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IDLE" 1
}
