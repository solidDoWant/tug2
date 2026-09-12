"""Render a weapon's buy-menu icon from its model source. Run inside Blender:

    blender --background --factory-startup --python render_icon.py -- \
        --smd <mesh.smd> --texture <diffuse.png> --out <icon.png> [--config <cfg.txt>]

Why this exists: the inventory slot icon is drawn by CInventoryWeaponSlot from a fixed
materials/vgui/inventory/<weapon>.vmt, so the game will not render the model there the way the
WeaponPreview CModelPanel does. Rendering it at build time keeps the icon in step with the texture.

The SMD is parsed here rather than through Blender Source Tools: the format is simple ASCII and
driving that addon headlessly adds a version-pinned dependency for no benefit.

Cycles on CPU, because EEVEE needs a GPU/GL context that a build container does not have.

WHY THIS IS PYTHON when the rest of the tooling is Go: Blender embeds CPython and its API (bpy) is
Python-only - there is no Go binding, so a Blender script cannot be anything else. The SMD parse
lives here rather than in Go because this script needs the data in memory anyway; emitting an
intermediate format from Go would add a format and a step for no gain.

NOTE ON FRAMING: nothing records the camera the original icon was rendered with, so yaw/pitch/margin
in the config are there to be tuned by eye against the shipped icon.
"""
import math
import os
import re
import sys

import bpy
import mathutils

DEFAULTS = {
    "model": "",                    # SMD to render; repeat the key to combine bodygroups
    "texture": "",                  # diffuse PNG, relative to the textures source dir
    "normal": "",                   # tangent-space normal map, relative to the render source dir
    "orm": "",                      # channel-packed ORM map (R occlusion, G roughness, B metal)
    "envmap": "",                   # equirectangular .hdr for the world, same directory
    "envmap_strength": 1.0,
    "envmap_rotation": 0.0,         # degrees about Z, to aim the reflection
    "rough_channel": "G",           # roughness channel
    "invert_rough": 0,              # set only if the map stores gloss rather than roughness
    "metal_channel": "B",           # metalness channel; blank to fall back to the constant below
    "roughness_multiplier": 0.75,   # $roughnessmultiplier from the VMT
    "width": 1024, "height": 512, "samples": 160,
    "yaw": 0.0, "pitch": 0.0, "roll": 0.0,
    "margin": 1.12, "fov": 32.0,
    "projection": "PERSP",          # PERSP or ORTHO
    "flip_v": 0,                    # SMD and Blender agree on V; flip only if it looks mirrored
    "key_energy": 2400.0, "fill_energy": 500.0, "world_strength": 0.5,
    "roughness": 0.32, "metallic": 1.0,
}


def parse_config(path):
    cfg = dict(DEFAULTS)
    cfg["_models"] = []
    if not path or not os.path.exists(path):
        return cfg
    for line in open(path, encoding="utf-8"):
        line = line.split("//")[0].strip()
        m = re.match(r'"?([A-Za-z_]+)"?\s+"?([^"\s]+)"?', line)
        if not m:
            continue
        k, v = m.group(1).lower(), m.group(2)
        if k == "model":
            cfg["_models"].append(v)
            continue
        if k not in cfg:
            continue
        cfg[k] = v if isinstance(cfg[k], str) else type(cfg[k])(float(v))
    return cfg


def parse_smd(path, flip_v):
    """Return (verts, faces, loop_uvs, loop_normals). Triangles are kept independent, so loops map
    1:1 onto vertices and per-vertex UVs/normals need no reconciliation."""
    verts, faces, uvs, normals = [], [], [], []
    section = None
    pending = []
    with open(path, encoding="latin-1") as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            low = line.lower()
            if low in ("nodes", "skeleton", "triangles", "vertexanimation"):
                section = low
                continue
            if low == "end":
                section = None
                continue
            if section != "triangles":
                continue
            parts = line.split()
            # A material name line has no leading numeric bone index.
            try:
                float(parts[0])
            except (ValueError, IndexError):
                pending = []
                continue
            if len(parts) < 9:
                continue
            x, y, z = (float(v) for v in parts[1:4])
            nx, ny, nz = (float(v) for v in parts[4:7])
            u, v = float(parts[7]), float(parts[8])
            if flip_v:
                v = 1.0 - v
            pending.append(((x, y, z), (nx, ny, nz), (u, v)))
            if len(pending) == 3:
                base = len(verts)
                for p, n, t in pending:
                    verts.append(p)
                    normals.append(n)
                    uvs.append(t)
                faces.append((base, base + 1, base + 2))
                pending = []
    return verts, faces, uvs, normals


def build_object(verts, faces, uvs, normals, cfg):
    mesh = bpy.data.meshes.new("icon_mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()

    uv_layer = mesh.uv_layers.new(name="UVMap")
    for i, loop in enumerate(mesh.loops):
        uv_layer.data[i].uv = uvs[loop.vertex_index]

    # Custom split normals keep the model's own shading rather than recomputing it.
    mesh.use_auto_smooth = True
    mesh.normals_split_custom_set([normals[l.vertex_index] for l in mesh.loops])

    obj = bpy.data.objects.new("icon", mesh)
    bpy.context.collection.objects.link(obj)

    mat = bpy.data.materials.new("icon_mat")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Metallic"].default_value = cfg["metallic"]
    bsdf.inputs["Roughness"].default_value = cfg["roughness"]

    def image_node(path, non_color):
        n = nt.nodes.new("ShaderNodeTexImage")
        n.image = bpy.data.images.load(path)
        # Normal and gloss data are values, not colour: sRGB-decoding them corrupts both.
        n.image.colorspace_settings.name = "Non-Color" if non_color else "sRGB"
        return n

    if cfg["texture_path"] and os.path.exists(cfg["texture_path"]):
        nt.links.new(bsdf.inputs["Base Color"], image_node(cfg["texture_path"], False).outputs["Color"])

    if cfg["normal_path"] and os.path.exists(cfg["normal_path"]):
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(nm.inputs["Color"], image_node(cfg["normal_path"], True).outputs["Color"])
        nt.links.new(bsdf.inputs["Normal"], nm.outputs["Normal"])

    if cfg["orm_path"] and os.path.exists(cfg["orm_path"]):
        # Channel-packed ORM, the glTF convention: R ambient occlusion, G roughness, B metalness.
        # The VMT's $roughnessmultiplier is the tell that G is roughness and not gloss - you would
        # not scale a gloss value by a roughness multiplier. Reading it as gloss (and so inverting
        # it) gives roughness ~0.2 on a full metal, which looks like foil.
        tex = image_node(cfg["orm_path"], True)
        try:
            sep = nt.nodes.new("ShaderNodeSeparateColor")
            sep_in, outs = "Color", {"R": "Red", "G": "Green", "B": "Blue"}
        except RuntimeError:                       # older Blender
            sep = nt.nodes.new("ShaderNodeSeparateRGB")
            sep_in, outs = "Image", {"R": "R", "G": "G", "B": "B"}
        nt.links.new(sep.inputs[sep_in], tex.outputs["Color"])

        rough = sep.outputs[outs.get(str(cfg["rough_channel"]).upper(), outs["G"])]
        if int(cfg["invert_rough"]):
            inv = nt.nodes.new("ShaderNodeInvert")
            nt.links.new(inv.inputs["Color"], rough)
            rough = inv.outputs["Color"]
        mul = nt.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.inputs[1].default_value = float(cfg["roughness_multiplier"])
        nt.links.new(mul.inputs[0], rough)
        nt.links.new(bsdf.inputs["Roughness"], mul.outputs["Value"])

        mc = str(cfg["metal_channel"]).upper()
        if mc in outs:
            # B spans the full 0-255, which is what a paint-versus-bare-metal mask looks like.
            # Forcing metallic to 1 everywhere makes painted areas behave like mirrors.
            nt.links.new(bsdf.inputs["Metallic"], sep.outputs[outs[mc]])

    obj.data.materials.append(mat)
    return obj


def frame_camera(obj, cfg):
    """Aim the camera from a yaw/pitch orbit and fit the model's extent along BOTH axes.

    Fitting a bounding sphere over-zooms an elongated subject, and Blender's default sensor_fit
    ("AUTO") makes camera.angle the FOV along the LARGER render axis - horizontal on a wide icon -
    so treating it as vertical clips a tall model. sensor_fit is pinned to VERTICAL here and the
    bounding box is measured in camera space, which makes the fit independent of both.
    """
    bbox = [obj.matrix_world @ mathutils.Vector(c) for c in obj.bound_box]
    lo = mathutils.Vector((min(v.x for v in bbox), min(v.y for v in bbox), min(v.z for v in bbox)))
    hi = mathutils.Vector((max(v.x for v in bbox), max(v.y for v in bbox), max(v.z for v in bbox)))
    center = (lo + hi) / 2.0
    radius = max((hi - lo).length / 2.0, 1e-6)

    yaw, pitch = math.radians(cfg["yaw"]), math.radians(cfg["pitch"])
    # Direction from the subject towards the camera.
    back = mathutils.Vector((
        math.cos(pitch) * math.sin(yaw),
        -math.cos(pitch) * math.cos(yaw),
        math.sin(pitch),
    )).normalized()
    right = back.cross(mathutils.Vector((0, 0, 1)))
    if right.length < 1e-6:                      # looking straight down the Z axis
        right = mathutils.Vector((1, 0, 0))
    right.normalize()
    up = right.cross(back).normalized()

    # Half-extents of the bounding box as seen by the camera.
    half_w = max(abs((v - center).dot(right)) for v in bbox)
    half_h = max(abs((v - center).dot(up)) for v in bbox)

    aspect = cfg["width"] / max(1.0, cfg["height"])
    cam_data = bpy.data.cameras.new("cam")
    cam_data.sensor_fit = "VERTICAL"

    if cfg["projection"].upper() == "ORTHO":
        cam_data.type = "ORTHO"
        # ortho_scale applies to the vertical sensor, so widen it if the subject is the wider one.
        cam_data.ortho_scale = 2.0 * max(half_h, half_w / aspect) * cfg["margin"]
        dist = radius * 4.0
    else:
        v_half = math.radians(cfg["fov"]) / 2.0
        h_half = math.atan(math.tan(v_half) * aspect)
        dist = max(half_h / math.tan(v_half), half_w / math.tan(h_half)) * cfg["margin"]
        cam_data.lens_unit = "FOV"
        cam_data.angle_y = 2.0 * v_half

    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = center + back * dist
    cam.rotation_euler = (-back).to_track_quat("-Z", "Y").to_euler()
    cam.rotation_euler.rotate_axis("Z", math.radians(cfg["roll"]))
    bpy.context.scene.camera = cam
    return center, radius


def add_lights(center, radius, cfg):
    def area(name, loc, energy, size):
        d = bpy.data.lights.new(name, type="AREA")
        d.energy = energy
        d.size = size
        o = bpy.data.objects.new(name, d)
        o.location = center + mathutils.Vector(loc)
        o.rotation_euler = (center - o.location).normalized().to_track_quat("-Z", "Y").to_euler()
        bpy.context.collection.objects.link(o)

    r = radius * 4.0
    area("key", (r * 0.6, -r, r * 0.8), cfg["key_energy"], radius * 3)
    area("fill", (-r * 0.8, -r * 0.5, r * 0.2), cfg["fill_energy"], radius * 4)

    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    wt = world.node_tree
    bg = wt.nodes["Background"]
    env_path = cfg.get("envmap_path", "")
    if env_path and os.path.exists(env_path):
        # A metal reflects its surroundings, so an HDR environment is what gives it bright, sharp
        # speculars instead of flat shading. Strength and rotation aim it.
        env = wt.nodes.new("ShaderNodeTexEnvironment")
        env.image = bpy.data.images.load(env_path)
        mapping = wt.nodes.new("ShaderNodeMapping")
        mapping.inputs["Rotation"].default_value[2] = math.radians(cfg["envmap_rotation"])
        coord = wt.nodes.new("ShaderNodeTexCoord")
        wt.links.new(mapping.inputs["Vector"], coord.outputs["Generated"])
        wt.links.new(env.inputs["Vector"], mapping.outputs["Vector"])
        wt.links.new(bg.inputs["Color"], env.outputs["Color"])
        bg.inputs["Strength"].default_value = cfg["envmap_strength"]
    else:
        bg.inputs["Color"].default_value = (1, 1, 1, 1)
        bg.inputs["Strength"].default_value = cfg["world_strength"]
    bpy.context.scene.world = world


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {}
    for i in range(0, len(argv) - 1, 2):
        opts[argv[i].lstrip("-")] = argv[i + 1]
    cfg = parse_config(opts.get("config"))
    models = [os.path.join(opts.get("models", "."), m) for m in cfg["_models"]]
    if not models and opts.get("smd"):
        models = [opts["smd"]]
    if not opts.get("texture") and cfg["texture"]:
        opts["texture"] = os.path.join(opts.get("textures", "."), cfg["texture"])
    rdir = opts.get("render", ".")
    for key in ("normal", "orm", "envmap"):
        if cfg[key]:
            opts[key] = os.path.join(rdir, cfg[key])
    if not models:
        sys.exit("render_icon: no model given (--smd, or one or more \"model\" config lines)")
    if "out" not in opts:
        sys.exit("render_icon: --out is required")

    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)

    verts, faces, uvs, normals = [], [], [], []
    for path in models:
        v, f, u, n = parse_smd(path, int(cfg["flip_v"]))
        if not f:
            sys.exit(f"render_icon: no triangles parsed from {path}")
        off = len(verts)
        verts.extend(v)
        uvs.extend(u)
        normals.extend(n)
        faces.extend([(a + off, b + off, c + off) for a, b, c in f])
    if not faces:
        sys.exit("render_icon: no triangles parsed")
    for key in ("texture", "normal", "orm", "envmap"):
        cfg[key + "_path"] = opts.get(key, "")
    obj = build_object(verts, faces, uvs, normals, cfg)
    center, radius = frame_camera(obj, cfg)
    add_lights(center, radius, cfg)

    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = int(cfg["samples"])
    # Debian's Blender is built without OpenImageDenoise, and Cycles enables denoising by default,
    # so leaving it on is a hard error. Sample count carries the noise floor instead.
    scene.cycles.use_denoising = False
    scene.render.film_transparent = True
    scene.render.resolution_x = int(cfg["width"])
    scene.render.resolution_y = int(cfg["height"])
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.filepath = opts["out"]

    print(f"render_icon: {len(models)} mesh(es), {len(faces)} tris, "
          f"{int(cfg['width'])}x{int(cfg['height'])}, "
          f"{int(cfg['samples'])} samples, yaw {cfg['yaw']} pitch {cfg['pitch']}")
    bpy.ops.render.render(write_still=True)
    print(f"render_icon: wrote {opts['out']}")


main()
