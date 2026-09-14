package main

// template substitutes hashed content paths into files that reference other files.
//
// Each published group lives under a directory whose name carries a hash of its contents, so a
// referring file has to be told the resolved name at build time. Groups resolve bottom-up; each
// level is passed in with --set.
//
// Placeholders exist because each consumer wants a different path shape:
//
//	@@DIR(tex)@@              materials/models/twp_tex_ab12    game-relative, forward slashes
//	@@MATDIR(tex)@@           models\twp_tex_ab12\             $cdmaterials
//	@@MATPATH(tex,t_x)@@      models\twp_tex_ab12\t_x          VMT $basetexture, no extension
//	@@PATH(mdl,v_m18.mdl)@@   models/twp_ab12/v_m18.mdl        theater view_model
//	@@MDLNAME(mdl,v_m18.mdl)@@  twp_ab12\\v_m18.mdl              QC $modelname
//
// An unresolved placeholder fails the build; left in a shipped VMT it would be a missing-texture bug
// visible only in game.
//
// MDLNAME EXISTS BECAUSE $modelname IS A LOOKUP PATH, NOT A LABEL. datacache.so's MakeFilename
// builds the .vvd/.vtx/.phy filenames as "models/" + studiohdr_t::name (offset 0xc, which is
// whatever the QC's $modelname said) + the extension - NOT from the path the .mdl was loaded from.
// So a model published at models/twp_ab12/v_m18.mdl but compiled with $modelname "twp/v_m18.mdl"
// loads its .mdl from the hashed directory and its vertices from models/twp/v_m18.vvd, and the
// client refuses the pair with
//     Error Vertex File for 'twp\\v_m18.mdl' checksum <vvd> should be <mdl>
// once per frame, drawing nothing. Hashing the directory is worthless unless $modelname is hashed
// with it, because models/twp/ is a fixed path and therefore write-once on every client.

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var tokenRE = regexp.MustCompile(`@@([A-Z]+)\(([^)]*)\)@@`)

// .txt is deliberately absent: the localisation file is UTF-16LE and nothing under src/ needs .txt
// substitution, so treating it as binary is both safer and sufficient.
var textExt = map[string]bool{
	".vmt": true, ".qc": true, ".qci": true, ".smd": true,
	".theater": true, ".res": true, ".json": true,
}

func underMaterials(p string) string {
	return strings.TrimPrefix(p, "materials/")
}

func expand(text string, groups map[string]string, where string) (string, error) {
	var bad error
	out := tokenRE.ReplaceAllStringFunc(text, func(m string) string {
		sub := tokenRE.FindStringSubmatch(m)
		fn := sub[1]
		var args []string
		for _, a := range strings.Split(sub[2], ",") {
			if a = strings.TrimSpace(a); a != "" {
				args = append(args, a)
			}
		}
		if len(args) == 0 {
			bad = fmt.Errorf("%s: @@%s()@@ needs a group name", where, fn)
			return m
		}
		base, ok := groups[args[0]]
		if !ok {
			have := make([]string, 0, len(groups))
			for k := range groups {
				have = append(have, k)
			}
			bad = fmt.Errorf("%s: unknown group %q (have: %s)", where, args[0], strings.Join(have, ", "))
			return m
		}
		base = strings.Trim(base, "/")
		switch fn {
		case "DIR":
			return base
		case "MATDIR":
			return strings.ReplaceAll(underMaterials(base), "/", `\`) + `\`
		case "MATPATH":
			if len(args) != 2 {
				bad = fmt.Errorf("%s: @@MATPATH(group,name)@@ needs two arguments", where)
				return m
			}
			return strings.ReplaceAll(underMaterials(base), "/", `\`) + `\` + args[1]
		case "PATH":
			if len(args) != 2 {
				bad = fmt.Errorf("%s: @@PATH(group,file)@@ needs two arguments", where)
				return m
			}
			return base + "/" + args[1]
		case "MDLNAME":
			// $modelname is relative to models/ and uses backslashes, the same shape as
			// $cdmaterials is relative to materials/.
			if len(args) != 2 {
				bad = fmt.Errorf("%s: @@MDLNAME(group,file)@@ needs two arguments", where)
				return m
			}
			return strings.ReplaceAll(strings.TrimPrefix(base, "models/"), "/", `\`) + `\` + args[1]
		}
		bad = fmt.Errorf("%s: unknown placeholder @@%s@@", where, fn)
		return m
	})
	return out, bad
}

func cmdTemplate(args []string) error {
	groups := map[string]string{}
	lower := false
	var rest []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--set":
			if i+1 >= len(args) {
				return fmt.Errorf("--set needs name=dir")
			}
			k, v, _ := strings.Cut(args[i+1], "=")
			groups[k] = v
			i++
		case "--lowercase-names":
			// Model sources were authored on a case-insensitive filesystem, so the QC references and
			// the actual filenames disagree in both directions. References are already lowercase in
			// the tree; lowercasing the names here makes the pair consistent wherever the source is
			// checked out - renaming in the source tree cannot work, because a case-insensitive
			// checkout silently ignores it.
			lower = true
		default:
			rest = append(rest, args[i])
		}
	}
	if len(rest) != 2 {
		return fmt.Errorf("usage: template [--set name=dir ...] [--lowercase-names] <in-tree> <out-tree>")
	}
	srcRoot, outRoot := rest[0], rest[1]

	subst, copied := 0, 0
	err := filepath.WalkDir(srcRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(srcRoot, p)
		if err != nil {
			return err
		}
		name := d.Name()
		if lower {
			name = strings.ToLower(name)
		}
		dst := filepath.Join(outRoot, filepath.Dir(rel), name)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		raw, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if textExt[strings.ToLower(filepath.Ext(d.Name()))] {
			out, bad := expand(string(raw), groups, rel)
			if bad != nil {
				return bad
			}
			if out != string(raw) {
				subst++
			}
			return os.WriteFile(dst, []byte(out), 0o644)
		}
		copied++
		return os.WriteFile(dst, raw, 0o644)
	})
	if err != nil {
		return err
	}

	var leftover []string
	err = filepath.WalkDir(outRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !textExt[strings.ToLower(filepath.Ext(d.Name()))] {
			return err
		}
		raw, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if tokenRE.Match(raw) {
			r, _ := filepath.Rel(outRoot, p)
			leftover = append(leftover, r)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if len(leftover) > 0 {
		return fmt.Errorf("template: unresolved placeholders in:\n  %s", strings.Join(leftover, "\n  "))
	}
	fmt.Printf("template: %d file(s) substituted, %d copied verbatim\n", subst, copied)
	return nil
}
