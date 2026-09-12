// Created by Crowbar 0.55

$modelname "twp\w_m18.mdl"

$bodygroup "m84"
{
	studio "skm_1p_m18_world.smd"
}
$bodygroup "spoon"
{
	blank
	studio "skm_1p_m18_world_spoon.smd"
}


// PulseModel culls bones more aggressively than stock studiomdl, which dropped b_wpn and left
// this model with one bone instead of two. "none" is its spelling of stock $nocollapsebones.
$bonecullmethod none

$surfaceprop "weapon"

$contents "solid"

$cdmaterials "@@MATDIR(mat)@@"


$sequence "idle" {
	"skm_1p_m18_world.smd"
}

$collisionmodel "skm_1p_m18_world.smd"
{
	$mass 0
	$inertia 1.5
	$damping 0.5
	$rotdamping 0.2

}

$collisiontext
{
	animatedfriction 
	{
		"animfrictionmin" "1.000000"
		"animfrictionmax" "400.000000"
		"animfrictiontimein" "0.500000"
		"animfrictiontimeout" "0.300000"
		"animfrictiontimehold" "0.000000"
	}
	editparams 
	{
		"rootname" ""
		"totalmass" "50.000000"
	}
}
