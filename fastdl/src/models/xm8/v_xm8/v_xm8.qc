// mdldecompiler version 0.16.0
// v_galil_sar.mdl

$modelname "@@MDLNAME(mdl,v_xm8.mdl)@@"

$surfaceprop "default"
$contents solid

$bbox -16.278 -5.806 -18.718  19.844 7.74 2.696
$illumposition -4.635392 -5.693193 -4.64817
$maxeyedeflection 90

$cdmaterials "@@MATDIR(mat)@@"

$bodygroup "Weapon"
{
    studio "meshes/xm8.dmx"
}

$attachment "camera" "camera" 0 0 0 rotate 0 0 0
$attachment "muzzle" "A_Muzzle" 0 0 0 rotate 0 0 0
$attachment "muzzle_supp" "A_Muzzle_Supp" 0 0 0 rotate 0 0 0
$attachment "shell" "A_Eject" 0 0 0 rotate 0 0 0
$attachment "muzzle_ads" "A_Muzzle_Ironsight" 0 0 0 rotate 0 0 0
$attachment "Suppressor" "A_Suppressor" 0 0 0 rotate 0 0 0
$attachment "Laser" "A_UnderBarrel" 0 0 0 rotate 0 0 0
$attachment "ModKit" "A_Modkit" 0 0 0 rotate 0 0 0
$attachment "Optic" "A_Optic" 0 0 0 rotate 0 0 0
$attachment "Foregrip" "A_Foregrip" 0 0 0 rotate 0 0 0
$attachment "Magazine" "Magazine" 0 0 0 rotate 0 0 0

$definebone "mag" "" -3.059554 -12.993446 -6.918 0 0 90  0 0 0 0 0 0
$definebone "bullet" "mag" 0.000133 3.107925 -0.000189 0 0 -90  0 0 0 0 0 0
$definebone "body" "" -3.059554 -7.298472 -4.585165 0 0 90  0 0 0 0 0 0
$definebone "bolt" "body" -0.000446 2.974639 6.592388 0 0 0  0 0 0 0 0 0
$definebone "charger" "bolt" 0 -0.000475 1.141954 0 0 0  0 0 0 0 0 0
$definebone "magrel" "body" 0.493652 -0.776542 4.122589 0 0 0  0 0 0 0 0 0
$definebone "A_Muzzle" "body" -0.000446 1.678165 20.139969 -90 -90 0  0 0 0 0 0 0
$definebone "A_Muzzle_Ironsight" "body" 3.059553 4.58517 27.664299 -90 -90 0  0 0 0 0 0 0
$definebone "A_Muzzle_Supp" "body" -0.000446 1.674766 24.794121 -90 0.0001 0  0 0 0 0 0 0
$definebone "A_Suppressor" "body" -0.000446 1.678085 18.595913 0 -180 90  0 0 0 0 0 0
$definebone "A_LaserFlashlight" "body" -0.171011 1.94433 14.997159 -90 89.915901 0  0 0 0 0 0 0
$definebone "A_Foregrip" "body" -0.000446 0.218193 12.252156 0.0001 -180 90  0 0 0 0 0 0
$definebone "A_Modkit" "body" -0.000146 1.845413 4.291192 0.0001 -180 0  0 0 0 0 0 0
$definebone "A_Optic" "body" -0.000116 4.066885 5.384402 0.0001 -180 0  0 0 0 0 0 0
$definebone "A_Eject" "body" -0.748187 2.11832 5.527739 -3.8302 165.421494 89.768997  0 0 0 0 0 0
$definebone "A_UnderBarrel" "body" -0.000446 1.941545 15.600236 -90 89.9496 0  0 0 0 0 0 0
$definebone "Bipod_Base" "body" -0.000446 -0.617262 15.771287 0.0001 0 -90  0 0 0 0 0 0
$definebone "Bipod_joint2" "Bipod_Base" -1.229857 1.585859 0.785401 14.6096 23.0851 -64.3526  0 0 0 0 0 0
$definebone "Bipod_joint1" "Bipod_Base" 1.097398 1.585857 0.785401 -14.5646 -22.990801 -64.411003  0 0 0 0 0 0
$definebone "Bipod_Right" "Bipod_Base" -0.928719 0.633511 0.598631 23.494699 0.0264 -89.9711  0 0 0 0 0 0
$definebone "Bipod_Left" "Bipod_Base" 0.903784 0.633511 0.600363 -23.403299 -0.0268 -90.029099  0 0 0 0 0 0
$definebone "camera" "" 0 0 0 0 -90 0  0 0 0 0 0 0
$definebone "L Clavicle" "" 1.878655 -3.375305 -7.815828 0 0 0  0 0 0 0 0 0
$definebone "L UpperArm" "L Clavicle" 5.85365 0 0 19.319599 -123.715599 -84.867104  0 0 0 0 0 0
$definebone "L Forearm" "L UpperArm" 10.390503 0 0 0 -66.182899 0  0 0 0 0 0 0
$definebone "L Hand" "L Forearm" 8.525419 0.000001 -0.000001 -6.2234 33.2775 -141.256607  0 0 0 0 0 0
$definebone "L Finger4" "L Hand" 2.426951 -0.353605 1.013782 -17.497299 39.689499 -43.2421  0 0 0 0 0 0
$definebone "L Finger41" "L Finger4" 1.104662 -0.000001 -0.000001 -6.7454 77.952499 -3.2329  0 0 0 0 0 0
$definebone "L Finger42" "L Finger41" 0.908443 0.000001 0 0 -3.4086 0  0 0 0 0 0 0
$definebone "L Finger3" "L Hand" 2.689438 -0.342859 0.236188 -31.9231 18.184799 -23.7757  0 0 0 0 0 0
$definebone "L Finger31" "L Finger3" 1.43979 0 0.000002 0 96.379303 0  0 0 0 0 0 0
$definebone "L Finger32" "L Finger31" 0.982985 -0.000001 0.000002 0 8.6248 0  0 0 0 0 0 0
$definebone "L Finger2" "L Hand" 2.813027 -0.266274 -0.544264 -33.250801 -21.9737 4.1994  0 0 0 0 0 0
$definebone "L Finger21" "L Finger2" 1.445765 0 0 0 91.308098 0  0 0 0 0 0 0
$definebone "L Finger22" "L Finger21" 1.053747 0.000002 0.000002 0 31.3288 0  0 0 0 0 0 0
$definebone "L Finger1" "L Hand" 2.828093 -0.209479 -1.286458 -19.5096 -45.026699 22.329399  0 0 0 0 0 0
$definebone "L Finger11" "L Finger1" 1.382521 0.000001 -0.000001 -4.7706 62.320599 -1.9647  0 0 0 0 0 0
$definebone "L Finger12" "L Finger11" 0.865911 -0.000004 -0.000001 0 25.4182 0  0 0 0 0 0 0
$definebone "L Finger0" "L Hand" 0.555149 0.315169 -0.822494 28.417801 22.3367 114.550003  0 0 0 0 0 0
$definebone "L Finger01" "L Finger0" 1.556972 -0.000001 -0.000002 -17.1957 17.275299 -5.6991  0 0 0 0 0 0
$definebone "L Finger02" "L Finger01" 1.22109 0 0.000002 -18.086901 -3.1816 0.1788  0 0 0 0 0 0
$definebone "L ForeTwist" "L Forearm" 0 0 0 0 0 -8.8246  0 0 0 0 0 0
$definebone "L ForeTwist1" "L ForeTwist" 1.217917 0 0.000001 0 0 -12.6066  0 0 0 0 0 0
$definebone "L ForeTwist2" "L ForeTwist1" 1.217922 0.000002 0 0 0 -8.8246  0 0 0 0 0 0
$definebone "L ForeTwist3" "L ForeTwist2" 1.217919 -0.000002 0 0 0 -8.8246  0 0 0 0 0 0
$definebone "L ForeTwist4" "L ForeTwist3" 1.217921 0.000002 0.000002 0 0 -8.8246  0 0 0 0 0 0
$definebone "L ForeTwist5" "L ForeTwist4" 1.21792 -0.000001 -0.000002 0 0 -8.8246  0 0 0 0 0 0
$definebone "L ForeTwist6" "L ForeTwist5" 1.217921 -0.000001 0.000001 0 0 -8.8246  0 0 0 0 0 0
$definebone "R Clavicle" "" -1.951073 10.90823 -2.335756 0 -179.999802 179.999802  0 0 0 0 0 0
$definebone "R UpperArm" "R Clavicle" 5.85365 0 0 -35.527802 -107.830498 94.171799  0 0 0 0 0 0
$definebone "R Forearm" "R UpperArm" 10.3905 -0.000003 0 0 -54.833599 0  0 0 0 0 0 0
$definebone "R Hand" "R Forearm" 8.52542 -0.000003 0 24.898199 29.931101 91.165199  0 0 0 0 0 0
$definebone "R Finger4" "R Hand" 2.42695 -0.353603 -1.013782 5.2501 17.5846 -5.3585  0 0 0 0 0 0
$definebone "R Finger41" "R Finger4" 1.104661 0 0 0 62.706902 0  0 0 0 0 0 0
$definebone "R Finger42" "R Finger41" 0.908446 -0.000002 0 0 63.952099 0  0 0 0 0 0 0
$definebone "R Finger3" "R Hand" 2.689438 -0.34286 -0.236187 5.4702 40.376301 -5.1025  0 0 0 0 0 0
$definebone "R Finger31" "R Finger3" 1.439799 0 0 0 79.867897 0  0 0 0 0 0 0
$definebone "R Finger32" "R Finger31" 0.982992 0.000001 0 -4.5488 53.071999 0  0 0 0 0 0 0
$definebone "R Finger2" "R Hand" 2.813025 -0.266275 0.544263 9.7613 40.435299 -3.1438  0 0 0 0 0 0
$definebone "R Finger21" "R Finger2" 1.445759 0 0 0 89.026703 0  0 0 0 0 0 0
$definebone "R Finger22" "R Finger21" 1.05375 -0.000001 0 0 50.962898 0  0 0 0 0 0 0
$definebone "R Finger1" "R Hand" 2.828086 -0.209481 1.28646 -14.1154 11.6348 5.0292  0 0 0 0 0 0
$definebone "R Finger11" "R Finger1" 1.382519 0 0 4.8798 35.428299 0.9434  0 0 0 0 0 0
$definebone "R Finger12" "R Finger11" 0.865908 -0.000002 0 4.9109 55.911301 -0.0176  0 0 0 0 0 0
$definebone "R Finger0" "R Hand" 0.55514 0.315171 0.822495 -22.362301 27.9179 -112.108704  0 0 0 0 0 0
$definebone "R Finger01" "R Finger0" 1.55697 0 0 0 16.6549 0  0 0 0 0 0 0
$definebone "R Finger02" "R Finger01" 1.221088 -0.000002 -0.000001 12.5078 50.629902 0  0 0 0 0 0 0
$definebone "R ForeTwist" "R Forearm" 0 0.000001 0 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist1" "R ForeTwist" 1.217918 -0.000001 0 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist2" "R ForeTwist1" 1.217919 0 0 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist3" "R ForeTwist2" 1.217919 0 0 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist4" "R ForeTwist3" 1.217919 0 -0.000001 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist5" "R ForeTwist4" 1.217919 0 0 0 0 0  0 0 0 0 0 0
$definebone "R ForeTwist6" "R ForeTwist5" 1.217921 0 0 0 0 0  0 0 0 0 0 0
$definebone "Weapon" "" 2.224609 1.84375 -0.616211 0.0489 -90.011002 -0.0033  0 0 0 0 0 0
$definebone "Trigger" "Weapon" 0 0 0 0 0 0  0 0 0 0 0 0
$definebone "Bipod_Swivel" "A_UnderBarrel" 0 0 0 0 0 0  0 0 0 0 0 0
$definebone "Magazine" "Weapon" 0 0 0 0 0 0  0 0 0 0 0 0

$bonemerge "mag"
$bonemerge "bullet"
$bonemerge "body"
$bonemerge "magrel"
$bonemerge "A_Muzzle"
$bonemerge "A_Muzzle_Supp"
$bonemerge "A_Suppressor"
$bonemerge "A_LaserFlashlight"
$bonemerge "A_Modkit"
$bonemerge "A_Optic"
$bonemerge "A_UnderBarrel"
$bonemerge "Bipod_Base"
$bonemerge "Bipod_joint2"
$bonemerge "Bipod_joint1"
$bonemerge "Bipod_Right"
$bonemerge "Bipod_Left"
$bonemerge "L Clavicle"
$bonemerge "L UpperArm"
$bonemerge "L Forearm"
$bonemerge "L Hand"
$bonemerge "L Finger4"
$bonemerge "L Finger41"
$bonemerge "L Finger42"
$bonemerge "L Finger3"
$bonemerge "L Finger31"
$bonemerge "L Finger32"
$bonemerge "L Finger2"
$bonemerge "L Finger21"
$bonemerge "L Finger22"
$bonemerge "L Finger1"
$bonemerge "L Finger11"
$bonemerge "L Finger12"
$bonemerge "L Finger0"
$bonemerge "L Finger01"
$bonemerge "L Finger02"
$bonemerge "L ForeTwist"
$bonemerge "L ForeTwist1"
$bonemerge "L ForeTwist2"
$bonemerge "L ForeTwist3"
$bonemerge "L ForeTwist4"
$bonemerge "L ForeTwist5"
$bonemerge "L ForeTwist6"
$bonemerge "R Clavicle"
$bonemerge "R UpperArm"
$bonemerge "R Forearm"
$bonemerge "R Hand"
$bonemerge "R Finger4"
$bonemerge "R Finger41"
$bonemerge "R Finger42"
$bonemerge "R Finger3"
$bonemerge "R Finger31"
$bonemerge "R Finger32"
$bonemerge "R Finger2"
$bonemerge "R Finger21"
$bonemerge "R Finger22"
$bonemerge "R Finger1"
$bonemerge "R Finger11"
$bonemerge "R Finger12"
$bonemerge "R Finger0"
$bonemerge "R Finger01"
$bonemerge "R Finger02"
$bonemerge "R ForeTwist"
$bonemerge "R ForeTwist1"
$bonemerge "R ForeTwist2"
$bonemerge "R ForeTwist3"
$bonemerge "R ForeTwist4"
$bonemerge "R ForeTwist5"
$bonemerge "R ForeTwist6"
$bonemerge "Weapon"
$bonemerge "Trigger"
$bonemerge "Bipod_Swivel"

$weightlist "weights_delta_foregrip" {
    "mag" 0
    "bullet" 0
    "body" 0
    "bolt" 0
    "charger" 0
    "magrel" 0
    "A_Muzzle" 0
    "A_Muzzle_Ironsight" 0
    "A_Muzzle_Supp" 0
    "A_Suppressor" 0
    "A_LaserFlashlight" 0
    "A_Foregrip" 1
    "A_Modkit" 0
    "A_Optic" 0
    "A_Eject" 0
    "A_UnderBarrel" 0
    "Bipod_Base" 0
    "Bipod_joint2" 0
    "Bipod_joint1" 0
    "Bipod_Right" 0
    "Bipod_Left" 0
    "camera" 0
    "L Clavicle" 1
    "R Clavicle" 0
    "R UpperArm" 0
    "R Forearm" 0
    "R Hand" 0
    "R Finger4" 0
    "R Finger41" 0
    "R Finger42" 0
    "R Finger3" 0
    "R Finger31" 0
    "R Finger32" 0
    "R Finger2" 0
    "R Finger21" 0
    "R Finger22" 0
    "R Finger1" 0
    "R Finger11" 0
    "R Finger12" 0
    "R Finger0" 0
    "R Finger01" 0
    "R Finger02" 0
    "R ForeTwist" 0
    "R ForeTwist1" 0
    "R ForeTwist2" 0
    "R ForeTwist3" 0
    "R ForeTwist4" 0
    "R ForeTwist5" 0
    "R ForeTwist6" 0
    "Weapon" 0
    "Trigger" 0
    "Bipod_Swivel" 0
    "Magazine" 0
}

$animation "a_bindpose" "anims/a_bindpose.dmx" fps 30  // the pose the deltas subtract

$sequence "menu" {
    "anims/menu.dmx"  // 51 frames
    fps 30
    activity "ACT_VM_MENU" 1
    snap
}

$sequence "idle" {
    "anims/idle.dmx"  // 1 frames
    fps 30 loop
    hidden
}

$sequence "delta_iron" {
    "anims/delta_iron.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_foregrip" {
    "anims/delta_foregrip.dmx"  // 1 frames
    fps 30
    subtract "a_bindpose" 0
    delta
    weightlist "weights_delta_foregrip"
}

$sequence "delta_eotech" {
    "anims/delta_eotech.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_kobra" {
    "anims/delta_kobra.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_aimp" {
    "anims/delta_aimp.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_aimp2x" {
    "anims/delta_aimp2x.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_elcan" {
    "anims/delta_elcan.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_po" {
    "anims/delta_po.dmx"  // 3 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_scope" {
    "anims/delta_scope.dmx"  // 1 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_scope_2" {
    "anims/delta_scope_2.dmx"  // 1 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "delta_deployed" {
    "anims/delta_deployed.dmx"  // 1 frames
    fps 30
    subtract "a_bindpose" 0
    delta
}

$sequence "base_idle" {
    "anims/base_idle.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IDLE" 1
}

$sequence "base_ready" {
    "anims/base_ready.dmx"  // 79 frames
    fps 30
    activity "ACT_VM_READY" 1
    snap
    { event 5004 0 "Universal.Draw" }
    { event 5004 28 "Weapon_Galil.Boltback" }
    { event 5004 46 "Weapon_Galil.Boltrelease" }
    { event 5004 60 "Universal.LeanIn" }
}

$sequence "base_draw" {
    "anims/base_draw.dmx"  // 23 frames
    fps 31
    activity "ACT_VM_DRAW" 1
    snap
    { event 5004 0 "Universal.Draw" }
}

$sequence "base_holster" {
    "anims/base_holster.dmx"  // 20 frames
    fps 34
    activity "ACT_VM_HOLSTER" 1
    { event 5004 0 "Universal.Holster" }
}

$sequence "base_crawl" {
    "anims/base_crawl.dmx"  // 46 frames
    fps 30 loop
    activity "ACT_VM_CRAWL" 1
    { event 5004 0 "Universal.LeftCrawl" }
    { event 5004 22 "Universal.RightCrawl" }
}

$sequence "base_down" {
    "anims/base_down.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_DOWN" 1
}

$sequence "base_fire" {
    "anims/base_fire.dmx"  // 31 frames
    fps 42
    activity "ACT_VM_PRIMARYATTACK" 1
    snap
    fadein 0.02
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "base_dryfire" {
    "anims/base_dryfire.dmx"  // 21 frames
    fps 30
    activity "ACT_VM_DRYFIRE" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "base_fireselect" {
    "anims/base_fireselect.dmx"  // 31 frames
    fps 30
    activity "ACT_VM_FIREMODE" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}

$sequence "base_reload" {
    "anims/base_reload.dmx"  // 116 frames
    fps 32.200001
    activity "ACT_VM_RELOAD" 1
    { event 5004 14 "Weapon_Galil.Magrelease" }
    { event 5004 23 "Weapon_Galil.Magout" }
    { event 5004 80 "Weapon_Galil.Magin" }
    { event 46 70 }
    { event 5004 98 "Weapon_Galil.Rattle" }
}

$sequence "base_reloadempty" {
    "anims/base_reloadempty.dmx"  // 163 frames
    fps 32.200001
    activity "ACT_VM_RELOADEMPTY" 1
    { event 5004 27 "Weapon_Galil.Magrelease" }
    { event 5004 35 "Weapon_Galil.Magout" }
    { event 5004 95 "Weapon_Galil.Magin" }
    { event 46 70 }
    { event 5004 142 "Weapon_Galil.Rattle" }
    { event 5004 122 "Weapon_Galil.Boltback" }
    { event 5004 133 "Weapon_Galil.Boltrelease" }
}

$sequence "base_reload_drum" {
    "anims/base_reload_drum.dmx"  // 176 frames
    fps 31.799999
    activity "ACT_VM_RELOAD_MAG1" 1
    { event 5004 22 "Weapon_Galil.Magrelease" }
    { event 5004 29 "Weapon_Galil.DrumMagout" }
    { event 5004 38 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 78 "Weapon_Galil.DrumMagFetch" }
    { event 5004 110 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 128 "Weapon_Galil.DrumMagHit" }
}

$sequence "base_reloadempty_drum" {
    "anims/base_reloadempty_drum.dmx"  // 241 frames
    fps 31.799999
    activity "ACT_VM_RELOADEMPTY_MAG1" 1
    { event 5004 22 "Weapon_Galil.Magrelease" }
    { event 5004 29 "Weapon_Galil.DrumMagout" }
    { event 5004 38 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 78 "Weapon_Galil.DrumMagFetch" }
    { event 5004 110 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 130 "Weapon_Galil.DrumMagHit" }
    { event 5004 166 "Weapon_Galil.Boltback" }
    { event 5004 183 "Weapon_Galil.Magrelease" }
    { event 5004 198 "Weapon_Galil.Boltrelease" }
    { event 5004 214 "Weapon_Galil.Rattle" }
    { event 5004 222 "Universal.LeanIn" }
}

$sequence "base_sprint" {
    "anims/base_sprint.dmx"  // 31 frames
    fps 38 loop
    activity "ACT_VM_SPRINT" 1
}

$sequence "iron_down" {
    "anims/iron_down.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IDOWN" 1
}

$sequence "iron_fire_a" {
    "anims/iron_fire_a.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "iron_fire_b" {
    "anims/iron_fire_b.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "iron_fire_c" {
    "anims/iron_fire_c.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "iron_dryfire" {
    "anims/iron_dryfire.dmx"  // 6 frames
    fps 30
    activity "ACT_VM_ISHOOTDRY" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "iron_fireselect" {
    "anims/iron_fireselect.dmx"  // 31 frames
    fps 30
    activity "ACT_VM_IFIREMODE" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}

$sequence "foregrip_ready" {
    "anims/foregrip_ready.dmx"  // 79 frames
    fps 30
    activity "ACT_VM_READY_FOREGRIP" 1
    snap
    { event 5004 0 "Universal.Draw" }
    { event 5004 28 "Weapon_Galil.Boltback" }
    { event 5004 46 "Weapon_Galil.Boltrelease" }
    { event 5004 60 "Universal.LeanIn" }
}

$sequence "foregrip_draw" {
    "anims/foregrip_draw.dmx"  // 23 frames
    fps 31
    activity "ACT_VM_DRAW_FOREGRIP" 1
    snap
    { event 5004 0 "Universal.Draw" }
}

$sequence "foregrip_holster" {
    "anims/foregrip_holster.dmx"  // 20 frames
    fps 34
    activity "ACT_VM_HOLSTER_FOREGRIP" 1
    { event 5004 0 "Universal.Holster" }
}

$sequence "foregrip_crawl" {
    "anims/foregrip_crawl.dmx"  // 46 frames
    fps 30 loop
    activity "ACT_VM_CRAWL_FOREGRIP" 1
    { event 5004 0 "Universal.LeftCrawl" }
    { event 5004 22 "Universal.RightCrawl" }
}

$sequence "foregrip_down" {
    "anims/foregrip_down.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_DOWN_FOREGRIP" 1
}

$sequence "foregrip_fire" {
    "anims/foregrip_fire.dmx"  // 31 frames
    fps 42
    activity "ACT_VM_PRIMARYATTACK_FOREGRIP" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "foregrip_dryfire" {
    "anims/foregrip_dryfire.dmx"  // 21 frames
    fps 30
    activity "ACT_VM_DRYFIRE_FOREGRIP" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "foregrip_fireselect" {
    "anims/foregrip_fireselect.dmx"  // 31 frames
    fps 30
    activity "ACT_VM_FIREMODE_FOREGRIP" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}

$sequence "foregrip_reload" {
    "anims/foregrip_reload.dmx"  // 116 frames
    fps 32.200001
    activity "ACT_VM_RELOAD_FOREGRIP" 1
    { event 5004 14 "Weapon_Galil.Magrelease" }
    { event 5004 23 "Weapon_Galil.Magout" }
    { event 5004 80 "Weapon_Galil.Magin" }
    { event 46 70 }
    { event 5004 98 "Weapon_Galil.Rattle" }
}

$sequence "foregrip_reloadempty" {
    "anims/foregrip_reloadempty.dmx"  // 163 frames
    fps 32.200001
    activity "ACT_VM_RELOADEMPTY_FOREGRIP" 1
    { event 5004 27 "Weapon_Galil.Magrelease" }
    { event 5004 35 "Weapon_Galil.Magout" }
    { event 5004 95 "Weapon_Galil.Magin" }
    { event 46 70 }
    { event 5004 142 "Weapon_Galil.Rattle" }
    { event 5004 122 "Weapon_Galil.Boltback" }
    { event 5004 133 "Weapon_Galil.Boltrelease" }
}

$sequence "foregrip_reload_drum" {
    "anims/foregrip_reload_drum.dmx"  // 176 frames
    fps 31.799999
    activity "ACT_VM_RELOAD_FOREGRIP_MAG1" 1
    { event 5004 22 "Weapon_Galil.Magrelease" }
    { event 5004 29 "Weapon_Galil.DrumMagout" }
    { event 5004 38 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 78 "Weapon_Galil.DrumMagFetch" }
    { event 5004 110 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 128 "Weapon_Galil.DrumMagHit" }
}

$sequence "foregrip_reloadempty_drum" {
    "anims/foregrip_reloadempty_drum.dmx"  // 241 frames
    fps 31.799999
    activity "ACT_VM_RELOADEMPTY_FOREGRIP_MAG1" 1
    { event 5004 22 "Weapon_Galil.Magrelease" }
    { event 5004 29 "Weapon_Galil.DrumMagout" }
    { event 5004 38 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 78 "Weapon_Galil.DrumMagFetch" }
    { event 5004 110 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 130 "Weapon_Galil.DrumMagHit" }
    { event 5004 166 "Weapon_Galil.Boltback" }
    { event 5004 198 "Weapon_Galil.Boltrelease" }
    { event 5004 214 "Weapon_Galil.Rattle" }
    { event 5004 222 "Universal.LeanIn" }
}

$sequence "foregrip_sprint" {
    "anims/foregrip_sprint.dmx"  // 31 frames
    fps 38 loop
    activity "ACT_VM_SPRINT_FOREGRIP" 1
}

$sequence "foregrip_iron_down" {
    "anims/foregrip_iron_down.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IDOWN_FOREGRIP" 1
}

$sequence "foregrip_iron_fire_a" {
    "anims/foregrip_iron_fire_a.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT_FOREGRIP" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "foregrip_iron_fire_b" {
    "anims/foregrip_iron_fire_b.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT_FOREGRIP" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "foregrip_iron_fire_c" {
    "anims/foregrip_iron_fire_c.dmx"  // 6 frames
    fps 20
    activity "ACT_VM_ISHOOT_FOREGRIP" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "foregrip_iron_dryfire" {
    "anims/foregrip_iron_dryfire.dmx"  // 6 frames
    fps 30
    activity "ACT_VM_ISHOOTDRY_FOREGRIP" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "foregrip_iron_fireselect" {
    "anims/foregrip_iron_fireselect.dmx"  // 31 frames
    fps 30
    activity "ACT_VM_IFIREMODE_FOREGRIP" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}

$sequence "deployed_idle" {
    "anims/deployed_idle.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IDLE_DEPLOYED" 1
}

$sequence "deployed_in" {
    "anims/deployed_in.dmx"  // 65 frames
    fps 37.200001
    activity "ACT_VM_DEPLOYED_IN" 1
    { event 5004 24 "Universal.BipodDeployStart" }
    { event 5004 29 "Universal.BipodDeployEnd" }
}

$sequence "deployed_out" {
    "anims/deployed_out.dmx"  // 74 frames
    fps 37.5
    activity "ACT_VM_DEPLOYED_OUT" 1
    { event 5004 14 "Universal.LeanIn" }
    { event 5004 39 "Universal.BipodRetract" }
}

$sequence "deployed_fire" {
    "anims/deployed_fire.dmx"  // 8 frames
    fps 30
    activity "ACT_VM_PRIMARYATTACK_DEPLOYED" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "deployed_dryfire" {
    "anims/deployed_dryfire.dmx"  // 21 frames
    fps 30
    activity "ACT_VM_DRYFIRE_DEPLOYED" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "deployed_fireselect" {
    "anims/deployed_fireselect.dmx"  // 25 frames
    fps 30
    activity "ACT_VM_FIREMODE_DEPLOYED" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}

$sequence "deployed_reload" {
    "anims/deployed_reload.dmx"  // 116 frames
    fps 30
    activity "ACT_VM_RELOAD_DEPLOYED" 1
    snap
    { event 5004 20 "Weapon_Galil.Magrelease" }
    { event 5004 26 "Weapon_Galil.Magout" }
    { event 5004 88 "Weapon_Galil.Magin" }
    { event 46 70 }
}

$sequence "deployed_reload_empty" {
    "anims/deployed_reload_empty.dmx"  // 163 frames
    fps 30
    activity "ACT_VM_RELOADEMPTY_DEPLOYED" 1
    snap
    { event 5004 20 "Weapon_Galil.Magrelease" }
    { event 5004 26 "Weapon_Galil.Magout" }
    { event 5004 85 "Weapon_Galil.Magin" }
    { event 46 70 }
    { event 5004 123 "Weapon_Galil.Boltback" }
    { event 5004 141 "Weapon_Galil.Boltrelease" }
}

$sequence "deployed_reload_drum" {
    "anims/deployed_reload_drum.dmx"  // 176 frames
    fps 31.799999
    activity "ACT_VM_RELOAD_DEPLOYED_MAG1" 1
    snap
    { event 5004 20 "Weapon_Galil.Magrelease" }
    { event 5004 26 "Weapon_Galil.Magout" }
    { event 5004 48 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 85 "Weapon_Galil.DrumMagFetch" }
    { event 5004 115 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 143 "Weapon_Galil.DrumMagHit" }
    { event 5004 160 "Universal.LeanIn" }
}

$sequence "deployed_reload_empty_drum" {
    "anims/deployed_reload_empty_drum.dmx"  // 241 frames
    fps 31.799999
    activity "ACT_VM_RELOADEMPTY_DEPLOYED_MAG1" 1
    snap
    { event 5004 20 "Weapon_Galil.Magrelease" }
    { event 5004 26 "Weapon_Galil.Magout" }
    { event 5004 48 "Weapon_Galil.DrumMagoutRattle" }
    { event 5004 85 "Weapon_Galil.DrumMagFetch" }
    { event 5004 115 "Weapon_Galil.DrumMagin" }
    { event 46 116 }
    { event 5004 143 "Weapon_Galil.DrumMagHit" }
    { event 5004 196 "Weapon_Galil.Boltback" }
    { event 5004 214 "Weapon_Galil.Boltrelease" }
    { event 5004 223 "Universal.LeanIn" }
}

$sequence "deployed_iron" {
    "anims/deployed_iron.dmx"  // 1 frames
    fps 30 loop
    activity "ACT_VM_IIDLE_DEPLOYED" 1
}

$sequence "deployed_iron_fire_a" {
    "anims/deployed_iron_fire_a.dmx"  // 6 frames
    fps 30
    activity "ACT_VM_ISHOOT_DEPLOYED" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "deployed_iron_fire_b" {
    "anims/deployed_iron_fire_b.dmx"  // 6 frames
    fps 30
    activity "ACT_VM_ISHOOT_DEPLOYED" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "deployed_iron_fire_c" {
    "anims/deployed_iron_fire_c.dmx"  // 6 frames
    fps 30
    activity "ACT_VM_ISHOOT_DEPLOYED" 1
    snap
    { event "AE_MUZZLEFLASH" 0 }
    { event "AE_CL_CREATE_PARTICLE_BRASS" 0 }
}

$sequence "deployed_iron_dryfire" {
    "anims/deployed_iron_dryfire.dmx"  // 5 frames
    fps 30
    activity "ACT_VM_ISHOOTDRY_DEPLOYED" 1
    snap
    { event 5004 0 "Weapon_Galil.Empty" }
}

$sequence "deployed_iron_fireselect" {
    "anims/deployed_iron_fireselect.dmx"  // 25 frames
    fps 30
    activity "ACT_VM_IFIREMODE_DEPLOYED" 1
    snap
    { event 5004 8 "Weapon_Galil.ROF" }
}
