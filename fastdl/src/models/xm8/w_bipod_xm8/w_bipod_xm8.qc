// mdldecompiler version 0.16.0
// upgrades/w_bipod_galil.mdl

$modelname "@@MDLNAME(mdl,w_bipod_xm8.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox 7.752 -0.967 0.565  21.660999 0.964 2.84
$illumposition -0.250241 -11.742913 0.936151
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "studio"
{
    studio "meshes/w_bipod_galil_reference.dmx"
}

$definebone "R Hand" "" -1.296402 4.031676 -0.967747 3.31 -84.438599 -1.5348  0 0 0 0 0 0
$definebone "ATTACH_Bipod" "R Hand" 22.032579 -1.008643 5.063222 -3.1443 -5.6565 91.851097  0 0 0 0 0 0
$definebone "Bipod" "ATTACH_Bipod" 0.322617 -1.691486 -0.000331 -90 -88.957298 0  0 0 0 0 0 0
$definebone "BIPOD_LEFT" "Bipod" -0.363312 0.100264 0.044078 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_RIGHT" "Bipod" 0.355246 0.100264 0.044079 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_RIGHT001" "Bipod" 1.583838 -1.521484 0.2295 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_LEFT001" "Bipod" -1.502877 -1.521475 0.229506 0 0 0  0 0 0 0 0 0

$sequence "base_idle" {
    "anims/base_idle.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_IDLE" 1
}

$sequence "deployed_idle" {
    "anims/deployed_idle.dmx"  // 51 frames
    fps 30 loop
    activity "ACT_IDLE_DEPLOYED" 1
}
