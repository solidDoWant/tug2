// mdldecompiler version 0.16.0
// w_galil_sar.mdl

$modelname "@@MDLNAME(mdl,w_xm8.mdl)@@"

$surfaceprop "weapon"
$contents solid

$bbox -17.319 -4.681 -7.491  30.827 4.633 8.049
$illumposition 0.034111 -6.531301 1.583977
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "studio"
{
    studio "meshes/w_galil_sar_reference.dmx"
}

$attachment "muzzle" "ATTACH_Muzzle" 0 0 0 rotate 0 0 0
$attachment "shell" "ATTACH_Eject" 0 0 0 rotate 0 0 0
$attachment "modkit" "ATTACH_ModKit" 0 0 0 rotate 0 0 0
$attachment "optic" "ATTACH_ModKit" 0 0 0 rotate 0 0 0
$attachment "bipod" "ATTACH_Bipod" 0 0 0 rotate 0 0 0
$attachment "foregrip" "ATTACH_Foregrip" 0 0 0 rotate 0 0 0
$attachment "silencer" "ATTACH_Muzzle" 0 0 0 rotate 0 0 0
$attachment "laser" "ATTACH_Laser" 0 0 0 rotate 0 0 0

$definebone "R Hand" "" -1.296402 4.031676 -0.967747 3.31 -84.438599 -1.5348  0 0 0 0 0 0
$definebone "W_MAGAZINE" "R Hand" 10.787577 0.221493 1.182987 -1.8483 84.445 -3.1459  0 0 0 0 0 0
$definebone "W_BOLT" "R Hand" 9.668125 0.337664 5.087355 -1.8483 84.445 -3.1459  0 0 0 0 0 0
$definebone "ATTACH_Eject" "R Hand" 9.831348 -0.953596 4.945217 -19.543501 -96.354301 3.8419  0 0 0 0 0 0
$definebone "ATTACH_Foregrip" "R Hand" 17.725761 -0.535821 3.548473 3.1443 174.343506 88.148903  0 0 0 0 0 0
$definebone "ATTACH_Laser" "R Hand" 21.04353 -1.483767 5.633864 -3.1443 -5.6565 1.8511  0 0 0 0 0 0
$definebone "ATTACH_Muzzle" "R Hand" 26.726778 -1.503909 5.710268 -3.1443 -5.6565 91.851196  0 0 0 0 0 0
$definebone "ATTACH_Bipod" "R Hand" 22.032579 -1.008643 5.063222 -3.1443 -5.6565 91.851097  0 0 0 0 0 0
$definebone "ATTACH_ModKit" "R Hand" 9.197144 0.156703 7.576663 -3.1444 -5.6566 91.851097  0 0 0 0 0 0
$definebone "Bipod" "ATTACH_Bipod" 0.322617 -1.691486 -0.000331 -90 -88.957298 0  0 0 0 0 0 0
$definebone "BIPOD_LEFT" "Bipod" -0.363312 0.100264 0.044078 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_RIGHT" "Bipod" 0.355246 0.100264 0.044079 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_RIGHT001" "Bipod" 1.583838 -1.521484 0.2295 0 0 0  0 0 0 0 0 0
$definebone "BIPOD_LEFT001" "Bipod" -1.502877 -1.521475 0.229506 0 0 0  0 0 0 0 0 0

$bonemerge "R Hand"
$bonemerge "W_MAGAZINE"
$bonemerge "ATTACH_Bipod"
$bonemerge "Bipod"
$bonemerge "BIPOD_LEFT"
$bonemerge "BIPOD_RIGHT"
$bonemerge "BIPOD_RIGHT001"
$bonemerge "BIPOD_LEFT001"

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30
    activity "ACT_IDLE" 1
}

$collisionmodel "meshes/w_galil_sar_physics.dmx"
{
    $mass 8
    $damping 2.5
    $rotdamping 2.5
    $inertia 0.5
}
