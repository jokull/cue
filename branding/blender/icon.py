"""icon.py — the Cue app icon: three teleprompter lines, the one being read lit caption-yellow,
a red record dot as the cursor. Concept B from the Codex image-generation round
(branding/generated/icon-concept-b.png), rebuilt as glossy 3D so it renders identically every time.

    blender --background --python branding/blender/icon.py -- --out branding/out/icon-1024.png

Units are icon-canvas units: the orthographic camera frames exactly 1.0 x 1.0, so every size
below is a fraction of the icon's width.
"""

import argparse
import math
import os
import sys

import bpy

# --- Parameters -------------------------------------------------------------------------------

FINAL = 1024
SUPER = 2  # render 2x, downscale when saving

BAR_W = 0.54  # line length
BAR_H = 0.108  # line thickness
BAR_DEPTH = 0.108  # equal to thickness, so each line is a fully round rod
BAR_GAP = 0.185  # centre-to-centre spacing of the three lines
BARS_X = 0.07  # shift the stack right so the dot and stack centre together
DOT_R = 0.066  # red cursor dot radius
DOT_GAP = 0.045  # space between dot and the yellow line

# sRGB brand colours (#FF3B30 record red, #FFD60A caption yellow), converted to linear below.
RED = (0xFF, 0x3B, 0x30)
YELLOW = (0xFF, 0xD6, 0x0A)
WHITE = (0xC8, 0xC8, 0xCE)  # renders near-white once lit
BG_CENTER = (0x24, 0x24, 0x28)  # lifted centre of the studio sweep
BG_EDGE = (0x05, 0x05, 0x06)  # near-black corners

KEY_ENERGY = 45.0  # large soft key, upper left — draws the long highlight on each pill
RIM_ENERGY = 25.0  # strip from lower right — separates pill edges from the background
FILL_ENERGY = 3.0  # weak frontal fill so the white lines read as white, not grey


def linear(rgb):
    def channel(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return tuple(channel(c) for c in rgb) + (1.0,)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--preview", action="store_true")
    p.add_argument("--save-blend", default=None)
    # studio: flat unlit sweep, Standard view — exact brand colours, reads at 29pt.
    # luxe: physical piano-black stage, layered materials, AgX, lens post — the premium hero.
    # quicksilver: the lines and dot as poured liquid chrome on black (metaballs + striped studio).
    p.add_argument("--look", choices=["studio", "luxe", "quicksilver"], default="studio")
    p.add_argument("--seed", type=int, default=11, help="quicksilver: shape of the puddles")
    return p.parse_args(argv)


# --- Scene ------------------------------------------------------------------------------------


def material(name, color, roughness, coat=0.0, emission=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.08
    if emission:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    return m


def pill(name, x, y, w, h, mat):
    """A capsule: a box whose bevel is half its thickness, so the ends and edges are fully round."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y, BAR_DEPTH / 2))
    obj = bpy.context.object
    obj.name = name
    obj.scale = (w, h, BAR_DEPTH)
    bpy.ops.object.transform_apply(scale=True)
    bevel = obj.modifiers.new("Round", "BEVEL")
    bevel.width = min(h, BAR_DEPTH) / 2 - 0.0005
    bevel.limit_method = "NONE"
    bevel.segments = 16
    bevel.affect = "EDGES"
    obj.modifiers.new("Smooth", "WEIGHTED_NORMAL")
    bpy.ops.object.shade_smooth()
    obj.data.materials.append(mat)
    obj["role"] = "teleprompter line"
    return obj


def backdrop():
    """Unlit radial gradient: a studio sweep that is lightest behind the lines."""
    bpy.ops.mesh.primitive_plane_add(size=1.6, location=(0, 0, 0))
    plane = bpy.context.object
    plane.name = "Studio sweep"
    m = bpy.data.materials.new("Sweep")
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    coords = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1.25, 1.25, 1)
    gradient = nodes.new("ShaderNodeTexGradient")
    gradient.gradient_type = "QUADRATIC_SPHERE"
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = linear(BG_EDGE)
    ramp.color_ramp.elements[1].color = linear(BG_CENTER)
    ramp.color_ramp.elements[1].position = 0.9
    links.new(coords.outputs["Object"], split.inputs["Vector"])
    links.new(split.outputs["Y"], along.inputs["Value"])
    links.new(along.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(emit.outputs["Emission"], out.inputs["Surface"])
    plane.data.materials.append(m)


def area(name, location, rotation_deg, size_x, size_y, energy, color=(1, 1, 1)):
    light = bpy.data.lights.new(name, "AREA")
    light.shape = "RECTANGLE"
    light.size, light.size_y = size_x, size_y
    light.energy = energy
    light.color = color
    obj = bpy.data.objects.new(name, light)
    obj.location = location
    obj.rotation_euler = [math.radians(a) for a in rotation_deg]
    bpy.context.collection.objects.link(obj)


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    white = material("Line white", linear(WHITE), 0.22, coat=0.6)
    yellow = material("Caption yellow", linear(YELLOW), 0.2, coat=0.8, emission=0.04)
    red = material("Record red", linear(RED), 0.2, coat=0.7)

    backdrop()
    for row, mat in [(1, white), (0, yellow), (-1, white)]:
        pill(f"Line {row:+d}", BARS_X, row * BAR_GAP, BAR_W, BAR_H, mat)

    dot_x = BARS_X - BAR_W / 2 - DOT_GAP - DOT_R
    bpy.ops.mesh.primitive_uv_sphere_add(radius=DOT_R, segments=64, ring_count=32, location=(dot_x, 0, DOT_R * 0.7))
    dot = bpy.context.object
    dot.name = "Record dot"
    dot.scale.z = 0.8
    bpy.ops.object.shade_smooth()
    dot.data.materials.append(red)

    area("Large key softbox, upper left", (-0.55, 0.6, 1.1), (-30, -28, 0), 0.9, 0.9, KEY_ENERGY, (1.0, 0.97, 0.93))
    area("Rim strip, lower right", (0.8, -0.7, 0.35), (60, 50, 0), 1.2, 0.06, RIM_ENERGY)
    area("Frontal fill", (0, 0, 1.6), (0, 0, 0), 1.0, 1.0, FILL_ENERGY)

    cam_data = bpy.data.cameras.new("Icon camera")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 1.0
    cam = bpy.data.objects.new("Icon camera", cam_data)
    cam.location = (0, 0, 2)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    scene["construction"] = "ortho top-down; capsules are bevelled boxes; unlit gradient sweep"
    scene["concept"] = "branding/generated/icon-concept-b.png (Codex image generation)"
    return scene


# --- Luxe look ----------------------------------------------------------------------------------
#
# What makes a render read as "expensive", in order of impact:
#   1. A physical stage that reflects: piano-black lacquer under the objects mirrors them and
#      catches one long softbox gradient. A flat unlit background can never do this.
#   2. Big, distant softboxes for long smooth reflections, plus one grazing strip that draws a
#      thin bright line along every edge. Low key: no fill, darkness is part of the look.
#   3. Layered materials: a clear coat over everything, a tinted coat over a darker base for
#      candy depth, a little subsurface so whites glow instead of clipping, and light that
#      comes from *inside* glass rather than painted-on emission.
#   4. Khronos PBR Neutral: highlights roll off instead of clipping, and brand hues survive
#      (AgX would skew the caption yellow to amber).
#   5. Lens post: restrained bloom, a hair of chromatic dispersion, warm highlights over cool
#      shadows; then vignette and fine grain at final resolution (finish.py).

LUXE_LENS = 85  # mm; long lens flattens perspective like product photography
LUXE_TILT = 14  # degrees the camera looks down from vertical-front, so the stage recedes
LUXE_FRAME_W = 1.04  # stage width in frame at the subject


def luxe_material(name, base, roughness, coat_tint=None, coat_roughness=0.03, subsurface=0.0,
                  transmission=0.0, metallic=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = base
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Coat Weight"].default_value = 1.0
    bsdf.inputs["Coat Roughness"].default_value = coat_roughness
    if coat_tint:
        bsdf.inputs["Coat Tint"].default_value = coat_tint
    if subsurface:
        bsdf.inputs["Subsurface Weight"].default_value = subsurface
        bsdf.inputs["Subsurface Radius"].default_value = (0.02, 0.02, 0.02)
    if transmission:
        bsdf.inputs["Transmission Weight"].default_value = transmission
        bsdf.inputs["IOR"].default_value = 1.5
    return m


def gradient_softbox(name, location, rotation_deg, width, depth, strength, color=(1, 1, 1, 1)):
    """An emissive card that fades from full to nothing along its depth.

    Invisible to the camera but seen in reflections, so lacquer and coats show a soft graded
    sweep instead of the hard rectangle an area light leaves. This is the studio "strip with a
    diffusion gradient" that most premium product photography is lit with.
    """
    bpy.ops.mesh.primitive_plane_add(size=1, location=location)
    card = bpy.context.object
    card.name = name
    card.scale = (width, depth, 1)
    card.rotation_euler = [math.radians(a) for a in rotation_deg]
    card.visible_camera = False
    card.visible_shadow = False
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    coords = nodes.new("ShaderNodeTexCoord")
    split = nodes.new("ShaderNodeSeparateXYZ")
    along = nodes.new("ShaderNodeMapRange")  # object Y −0.5…0.5 → 0…1 along the card's depth
    along.inputs["From Min"].default_value = -0.5
    along.inputs["From Max"].default_value = 0.5
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].color = (0, 0, 0, 1)
    ramp.color_ramp.elements[1].color = color
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = strength
    out = nodes.new("ShaderNodeOutputMaterial")
    links.new(coords.outputs["Object"], split.inputs["Vector"])
    links.new(split.outputs["Y"], along.inputs["Value"])
    links.new(along.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(emit.outputs["Emission"], out.inputs["Surface"])
    card.data.materials.append(m)
    return card


def build_luxe():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    world = bpy.data.worlds.new("Black")
    world.color = (0, 0, 0)
    # Blender 5 gives new worlds a node tree whose grey Background overrides world.color.
    if world.node_tree and "Background" in world.node_tree.nodes:
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (0, 0, 0, 1)
    scene.world = world

    # Piano-black stage: near-black base, glassy clear coat.
    bpy.ops.mesh.primitive_plane_add(size=8, location=(0, 0, 0))
    stage = bpy.context.object
    stage.name = "Piano-black stage"
    stage.data.materials.append(luxe_material("Piano black", linear((3, 3, 4)), 0.4, coat_roughness=0.02))

    porcelain = luxe_material("Porcelain", linear((222, 222, 226)), 0.32, subsurface=0.2, coat_roughness=0.04)
    candy = luxe_material("Candy red", linear((120, 8, 6)), 0.3, coat_tint=linear(RED), coat_roughness=0.02)
    # AgX desaturates very bright yellow toward cream: keep the core modest, the glass saturated.
    glass = luxe_material("Caption glass", linear(YELLOW), 0.05, transmission=1.0, coat_roughness=0.01)
    core = bpy.data.materials.new("Caption light")
    core.use_nodes = True
    nodes = core.node_tree.nodes
    nodes.clear()
    emit = nodes.new("ShaderNodeEmission")
    # Deeper than the brand yellow: AgX and the glass both lift it back toward #FFD60A.
    emit.inputs["Color"].default_value = linear((0xFF, 0xCC, 0x00))
    emit.inputs["Strength"].default_value = 1.2
    out = nodes.new("ShaderNodeOutputMaterial")
    core.node_tree.links.new(emit.outputs["Emission"], out.inputs["Surface"])

    pill("Line +1", BARS_X, BAR_GAP, BAR_W, BAR_H, porcelain)
    pill("Line -1", BARS_X, -BAR_GAP, BAR_W, BAR_H, porcelain)
    pill("Line 0 glass", BARS_X, 0, BAR_W, BAR_H, glass)
    # The light lives inside the glass bar, so it glows through rather than being painted on.
    light_core = pill("Line 0 core", BARS_X, 0, BAR_W - BAR_H * 0.55, BAR_H * 0.42, core)
    light_core.location.z = BAR_DEPTH / 2
    light_core.scale.z = 0.42

    dot_x = BARS_X - BAR_W / 2 - DOT_GAP - DOT_R
    bpy.ops.mesh.primitive_uv_sphere_add(radius=DOT_R, segments=96, ring_count=48, location=(dot_x, 0, DOT_R))
    dot = bpy.context.object
    dot.name = "Record dot"
    bpy.ops.object.shade_smooth()
    dot.data.materials.append(candy)

    gradient_softbox("Gradient softbox, overhead-back", (0, 1.1, 1.9), (-38, 0, 0), 3.0, 1.6, 3.0, (1.0, 0.96, 0.9, 1))
    area("Key softbox for shape", (-0.9, 0.5, 1.6), (-20, -32, 0), 1.0, 1.0, 38.0, (1.0, 0.97, 0.93))
    area("Grazing edge strip, left", (-1.9, 0.2, 0.32), (0, -78, 0), 0.05, 2.6, 90.0)
    area("Back kicker, right", (1.4, 1.6, 0.5), (-70, 40, 0), 0.6, 0.15, 50.0, (0.96, 0.97, 1.0))
    for obj in bpy.context.scene.objects:
        if obj.type == "LIGHT":
            obj.visible_camera = False
            # Lights shape the objects; only the gradient card may appear in reflections.
            obj.visible_glossy = False

    cam_data = bpy.data.cameras.new("Hero camera")
    cam_data.lens = LUXE_LENS
    cam_data.sensor_fit = "HORIZONTAL"
    distance = LUXE_FRAME_W * LUXE_LENS / cam_data.sensor_width
    tilt = math.radians(LUXE_TILT)
    cam = bpy.data.objects.new("Hero camera", cam_data)
    cam.location = (0, -distance * math.sin(tilt), distance * math.cos(tilt) + BAR_DEPTH / 2)
    cam.rotation_euler = (tilt, 0, 0)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    scene["construction"] = "luxe: lacquer stage, porcelain/candy/lit-glass materials, AgX, lens post"
    scene["concept"] = "branding/generated/icon-concept-b.png (Codex image generation)"
    return scene


# --- Quicksilver look ---------------------------------------------------------------------------
#
# Liquid chrome is almost entirely what it reflects. Two ingredients:
#   1. Shape: metaballs. Chains of flattened ellipsoids with random radii fuse into puddles that
#      bulge and pinch like poured mercury; converted to mesh and subdivided so highlights flow.
#   2. Environment: hard black/white studio bands, warped by noise, visible only in reflections.
#      The camera sees pure black, so the forms float.

QS_RESOLUTION = 0.006  # metaball render resolution; smaller is smoother and slower


def quicksilver_world(scene):
    """A chrome studio as broad zones by elevation: soft overhead light, a dark band, one bright
    horizon line, a dim floor — lightly warped by noise so reflections flow like liquid."""
    world = bpy.data.worlds.new("Chrome studio")
    world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes.clear()
    coords = nodes.new("ShaderNodeTexCoord")
    warp = nodes.new("ShaderNodeTexNoise")
    warp.inputs["Scale"].default_value = 1.8
    warp.inputs["Detail"].default_value = 1.0
    bend = nodes.new("ShaderNodeMix")
    bend.data_type = "VECTOR"
    bend.inputs["Factor"].default_value = 0.28
    split = nodes.new("ShaderNodeSeparateXYZ")
    elevation = nodes.new("ShaderNodeMapRange")  # direction z −1…1 → 0 (floor) … 1 (zenith)
    elevation.inputs["From Min"].default_value = -1
    elevation.inputs["From Max"].default_value = 1
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    # Dark zenith (the flat tops read as deep chrome), a bright ring the domed slopes catch,
    # a hard horizon line for the rims, a dim floor.
    stops = [(0.0, 0.05), (0.40, 0.0), (0.48, 1.5), (0.53, 0.0), (0.66, 0.02), (0.76, 1.4), (0.84, 0.05), (1.0, 0.03)]
    elements = ramp.color_ramp.elements
    elements[0].position, elements[0].color = stops[0][0], (stops[0][1],) * 3 + (1,)
    elements[1].position, elements[1].color = stops[-1][0], (stops[-1][1],) * 3 + (1,)
    for position, value in stops[1:-1]:
        element = elements.new(position)
        element.color = (value, value, value * 1.03, 1)
    background = nodes.new("ShaderNodeBackground")
    black = nodes.new("ShaderNodeBackground")
    black.inputs["Color"].default_value = (0, 0, 0, 1)
    path = nodes.new("ShaderNodeLightPath")
    camera_only = nodes.new("ShaderNodeMixShader")
    out = nodes.new("ShaderNodeOutputWorld")
    links.new(coords.outputs["Generated"], warp.inputs["Vector"])
    links.new(coords.outputs["Generated"], bend.inputs["A"])
    links.new(warp.outputs["Color"], bend.inputs["B"])
    links.new(bend.outputs["Result"], split.inputs["Vector"])
    links.new(split.outputs["Z"], elevation.inputs["Value"])
    links.new(elevation.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], background.inputs["Color"])
    links.new(path.outputs["Is Camera Ray"], camera_only.inputs["Fac"])
    links.new(background.outputs["Background"], camera_only.inputs[1])
    links.new(black.outputs["Background"], camera_only.inputs[2])
    links.new(camera_only.outputs["Shader"], out.inputs["Surface"])
    scene.world = world


def build_quicksilver(seed):
    import random

    rng = random.Random(seed)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    quicksilver_world(scene)

    ball = bpy.data.metaballs.new("Quicksilver")
    ball.resolution = ball.render_resolution = QS_RESOLUTION
    ball.threshold = 0.6
    obj = bpy.data.objects.new("Quicksilver", ball)
    bpy.context.collection.objects.link(obj)

    def blob(x, y, rx, ry, rz):
        element = ball.elements.new(type="ELLIPSOID")
        element.co = (x, y, 0)
        element.radius = max(rx, ry)
        element.size_x, element.size_y, element.size_z = rx / element.radius, ry / element.radius, rz / element.radius

    for row in (1, 0, -1):
        y0 = row * BAR_GAP
        count = 9
        for i in range(count):
            t = i / (count - 1)
            x = BARS_X - BAR_W / 2 + BAR_H / 2 + t * (BAR_W - BAR_H)
            swell = 1 + rng.uniform(-0.3, 0.42)  # puddles bulge and pinch along their length
            blob(x, y0 + rng.uniform(-0.014, 0.014), BAR_H * 1.0 * swell, BAR_H * 0.78 * swell, BAR_H * 0.8 * swell)
    dot_x = BARS_X - BAR_W / 2 - DOT_GAP - DOT_R
    blob(dot_x, 0, DOT_R * 1.25, DOT_R * 1.25, DOT_R * 1.05)
    blob(dot_x + DOT_R * 0.55, -DOT_R * 0.5, DOT_R * 0.55, DOT_R * 0.5, DOT_R * 0.38)  # a droplet fusing in

    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target="MESH")
    mesh = bpy.context.object
    mesh.modifiers.new("Smooth", "SUBSURF").render_levels = 2
    bpy.ops.object.shade_smooth()

    chrome = bpy.data.materials.new("Quicksilver chrome")
    chrome.use_nodes = True
    bsdf = chrome.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.96, 0.96, 0.98, 1)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 0.035
    mesh.data.materials.append(chrome)

    # Tilted perspective so the domes read as volume; a top-down ortho view flattens chrome.
    cam_data = bpy.data.cameras.new("Icon camera")
    cam_data.lens = 70
    tilt = math.radians(22)
    distance = 1.06 * cam_data.lens / cam_data.sensor_width
    cam = bpy.data.objects.new("Icon camera", cam_data)
    cam.location = (0, -distance * math.sin(tilt), distance * math.cos(tilt))
    cam.rotation_euler = (tilt, 0, 0)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    scene["construction"] = f"quicksilver: metaball puddles (seed {seed}), striped studio world"
    return scene


def luxe_post(scene, neutral=False):
    """Bloom, dispersion and a warm/cool grade in Blender 5's compositor node group."""
    tree = bpy.data.node_groups.new("Lens post", "CompositorNodeTree")
    tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    scene.compositing_node_group = tree
    nodes, links = tree.nodes, tree.links

    layers = nodes.new("CompositorNodeRLayers")
    glare = nodes.new("CompositorNodeGlare")
    glare.inputs["Type"].default_value = "Bloom"
    glare.inputs["Threshold"].default_value = 0.85
    glare.inputs["Strength"].default_value = 0.35
    glare.inputs["Size"].default_value = 0.55
    lens = nodes.new("CompositorNodeLensdist")
    lens.inputs["Distortion"].default_value = 0.0
    lens.inputs["Dispersion"].default_value = 0.008
    grade = nodes.new("CompositorNodeColorBalance")
    grade.inputs["Type"].default_value = "Lift/Gamma/Gain"
    # A breath of cool in the shadows — except for chrome, which must stay neutral.
    grade.inputs["Color Lift"].default_value = (1, 1, 1, 1) if neutral else (0.99, 1.0, 1.015, 1)
    grade.inputs["Color Gain"].default_value = (1.04, 1.01, 0.96, 1)  # warm highlights
    output = nodes.new("NodeGroupOutput")

    links.new(layers.outputs["Image"], glare.inputs["Image"])
    links.new(glare.outputs["Image"], lens.inputs["Image"])
    links.new(lens.outputs["Image"], grade.inputs["Image"])
    links.new(grade.outputs["Image"], output.inputs[0])


def render(scene, args):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 32 if args.preview else 256
    scene.cycles.use_denoising = True
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for device in prefs.devices:
            device.use = True
        scene.cycles.device = "GPU"
    except Exception:
        scene.cycles.device = "CPU"
    scale = 1 if args.preview else SUPER
    scene.render.resolution_x = scene.render.resolution_y = FINAL * scale
    if args.look == "quicksilver":
        scene.view_settings.view_transform = "AgX"
        scene.view_settings.look = "AgX - Medium High Contrast"
        scene.cycles.max_bounces = 16
        luxe_post(scene, neutral=True)
    elif args.look == "luxe":
        # Khronos PBR Neutral rolls highlights off like AgX but keeps hues: AgX skews saturated
        # yellow toward amber, which breaks the brand colour. Made for e-commerce product shots.
        scene.view_settings.view_transform = "Khronos PBR Neutral"
        scene.view_settings.look = "None"
        scene.cycles.max_bounces = 16
        scene.cycles.transmission_bounces = 16
        luxe_post(scene)
    else:
        # Standard keeps the brand red and yellow exact; AgX would pull the yellow toward cream.
        scene.view_settings.view_transform = "Standard"
        scene.view_settings.look = "None"
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"  # App Store icons must have no alpha
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    scene.render.filepath = os.path.abspath(args.out)
    bpy.ops.render.render(write_still=True)

    if scale != 1:
        image = bpy.data.images.load(scene.render.filepath)
        image.scale(FINAL, FINAL)
        image.save()

    if args.save_blend:
        bpy.ops.file.pack_all()
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))
    print("RENDER_OK", scene.render.filepath, scene.view_settings.view_transform, scene.view_settings.look)


if __name__ == "__main__":
    arguments = parse_args()
    builders = {"luxe": build_luxe, "studio": build, "quicksilver": lambda: build_quicksilver(arguments.seed)}
    render(builders[arguments.look](), arguments)
