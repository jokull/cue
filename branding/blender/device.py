"""device.py — an iPhone standing on a piano-black lacquer stage, showing a real Cue screenshot.
Renders the App Store frames (portrait, 1320x2868) and the website hero (landscape).

    blender --background --python branding/blender/device.py -- \
        --screen branding/screens/prepped/2-take-fun.png --pose 2 --out branding/out/device-2.png

Body dimensions approximate the 6.9" iPhone class (≈163.4 x 78.0 x 8.75 mm); the screen size is
derived from the 6.9" diagonal and the 1320x2868 screenshot aspect. Good to ~1 mm, which is far
below what shows at this framing — documented here and on the objects as estimates.
"""

import argparse
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Vector

MM = 0.001
BODY_W, BODY_H, BODY_T = 78.0 * MM, 163.4 * MM, 8.75 * MM  # estimate, 6.9" class
BODY_R = 13.0 * MM  # plan-view corner radius, estimate
SCREEN_DIAGONAL = 6.9 * 25.4 * MM
SCREEN_ASPECT = 1320 / 2868
SCREEN_H = SCREEN_DIAGONAL / math.hypot(1, SCREEN_ASPECT)
SCREEN_W = SCREEN_H * SCREEN_ASPECT
SCREEN_R = 11.0 * MM

LENS = 70
SENSOR = 36

# Per-shot pose: (yaw° turn toward camera-left, tilt° lean back, height_frac, bottom_frac)
# height_frac: how much of the frame height the phone fills; bottom_frac: where its base sits.
POSES = {
    1: (-9.0, 3.0, 0.70, 0.075),
    2: (8.0, 3.0, 0.70, 0.075),
    3: (-7.0, 3.0, 0.70, 0.075),
    4: (9.0, 3.0, 0.70, 0.075),
    5: (-8.0, 3.0, 0.70, 0.075),
    6: (7.0, 3.0, 0.70, 0.075),
    "hero": (-24.0, 5.0, 0.84, 0.09),
}


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--screen", required=True)
    p.add_argument("--pose", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--size", default="1320x2868", help="final WxH in pixels")
    p.add_argument("--preview", action="store_true")
    p.add_argument("--save-blend", default=None)
    return p.parse_args(argv)


def linear(rgb):
    def channel(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return tuple(channel(c) for c in rgb) + (1.0,)


def rounded_rect(width, height, radius, segments=24):
    points = []
    corners = [(width / 2 - radius, height / 2 - radius, 0), (-width / 2 + radius, height / 2 - radius, 90),
               (-width / 2 + radius, -height / 2 + radius, 180), (width / 2 - radius, -height / 2 + radius, 270)]
    for cx, cy, start in corners:
        for i in range(segments + 1):
            a = math.radians(start + 90 * i / segments)
            points.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return points


def body():
    """Extrude the plan outline, then round only the two horizontal edge rings (rail-to-face)."""
    mesh = bpy.data.meshes.new("Body")
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, -BODY_T / 2)) for x, y in rounded_rect(BODY_W, BODY_H, BODY_R)]
    face = bm.faces.new(verts)
    extruded = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in [g for g in extruded["geom"] if isinstance(g, bmesh.types.BMVert)]:
        v.co.z += BODY_T
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:
        f.material_index = 0 if abs(f.normal.z) < 0.5 else 1  # rail : glass
    weight = bm.edges.layers.float.new("bevel_weight_edge")
    for e in bm.edges:
        if len({round(v.co.z, 6) for v in e.verts}) == 1:
            e[weight] = 1.0
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Body", mesh)
    bpy.context.collection.objects.link(obj)
    bevel = obj.modifiers.new("Rail blend", "BEVEL")
    bevel.limit_method, bevel.width, bevel.segments, bevel.profile = "WEIGHT", 2.4 * MM, 8, 0.7
    obj.modifiers.new("Normals", "WEIGHTED_NORMAL")
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    obj["source"] = "≈163.4x78.0x8.75 mm, 6.9-inch class; estimate"

    rail = bpy.data.materials.new("Graphite rail")
    rail.use_nodes = True
    b = rail.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = linear((60, 60, 66))
    b.inputs["Metallic"].default_value = 1.0
    b.inputs["Roughness"].default_value = 0.24
    b.inputs["Anisotropic"].default_value = 0.4

    glass = bpy.data.materials.new("Front glass")
    glass.use_nodes = True
    g = glass.node_tree.nodes["Principled BSDF"]
    g.inputs["Base Color"].default_value = (0.004, 0.004, 0.005, 1)
    g.inputs["Roughness"].default_value = 0.03
    g.inputs["Coat Weight"].default_value = 1.0
    g.inputs["Coat Roughness"].default_value = 0.01
    mesh.materials.append(rail)
    mesh.materials.append(glass)
    return obj


def screen(image_path):
    """The screenshot as an emissive plane just above the glass, sampled in object space."""
    mesh = bpy.data.meshes.new("Screen")
    bm = bmesh.new()
    bm.faces.new([bm.verts.new((x, y, 0)) for x, y in rounded_rect(SCREEN_W, SCREEN_H, SCREEN_R, 32)])
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new("Screen", mesh)
    obj.location.z = BODY_T / 2 + 0.05 * MM
    bpy.context.collection.objects.link(obj)

    m = bpy.data.materials.new("Screen")
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    nodes.clear()
    coords = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1 / SCREEN_W, 1 / SCREEN_H, 1)
    mapping.inputs["Location"].default_value = (0.5, 0.5, 0)
    texture = nodes.new("ShaderNodeTexImage")
    texture.image = bpy.data.images.load(os.path.abspath(image_path))
    texture.extension = "CLIP"
    texture.interpolation = "Cubic"
    emit = nodes.new("ShaderNodeEmission")
    gloss = nodes.new("ShaderNodeBsdfGlossy")
    gloss.inputs["Roughness"].default_value = 0.02
    fresnel = nodes.new("ShaderNodeLayerWeight")
    fresnel.inputs["Blend"].default_value = 0.04  # a whisper of sheen; the UI must still read
    mix = nodes.new("ShaderNodeMixShader")
    out = nodes.new("ShaderNodeOutputMaterial")
    links.new(coords.outputs["Object"], mapping.inputs["Vector"])
    links.new(mapping.outputs["Vector"], texture.inputs["Vector"])
    links.new(texture.outputs["Color"], emit.inputs["Color"])
    links.new(fresnel.outputs["Fresnel"], mix.inputs["Fac"])
    links.new(emit.outputs["Emission"], mix.inputs[1])
    links.new(gloss.outputs["BSDF"], mix.inputs[2])
    links.new(mix.outputs["Shader"], out.inputs["Surface"])
    mesh.materials.append(m)
    obj["capture"] = os.path.abspath(image_path)
    return obj


def lacquer_floor(z):
    bpy.ops.mesh.primitive_plane_add(size=6, location=(0, 0.6, z))
    floor = bpy.context.object
    floor.name = "Piano-black stage"
    m = bpy.data.materials.new("Piano black")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = linear((3, 3, 4))
    b.inputs["Roughness"].default_value = 0.4
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.03
    floor.data.materials.append(m)


def gradient_softbox(name, location, rotation_deg, width, depth, strength):
    """Emissive card fading along its depth: seen in reflections, invisible to the camera."""
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
    along = nodes.new("ShaderNodeMapRange")
    along.inputs["From Min"].default_value = -0.5
    along.inputs["From Max"].default_value = 0.5
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "EASE"
    ramp.color_ramp.elements[0].color = (0, 0, 0, 1)
    ramp.color_ramp.elements[1].color = (1.0, 0.97, 0.93, 1)
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = strength
    out = nodes.new("ShaderNodeOutputMaterial")
    links.new(coords.outputs["Object"], split.inputs["Vector"])
    links.new(split.outputs["Y"], along.inputs["Value"])
    links.new(along.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], emit.inputs["Color"])
    links.new(emit.outputs["Emission"], out.inputs["Surface"])
    card.data.materials.append(m)


def area(name, location, rotation_deg, size_x, size_y, energy):
    light = bpy.data.lights.new(name, "AREA")
    light.shape = "RECTANGLE"
    light.size, light.size_y, light.energy = size_x, size_y, energy
    obj = bpy.data.objects.new(name, light)
    obj.location = location
    obj.rotation_euler = [math.radians(a) for a in rotation_deg]
    obj.visible_camera = False
    obj.visible_glossy = False  # lights shape the rails; only gradient cards show in reflections
    bpy.context.collection.objects.link(obj)


def build(args):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    world = bpy.data.worlds.new("Black")
    world.color = (0, 0, 0)
    # Blender 5 gives new worlds a node tree whose grey Background overrides world.color.
    if world.node_tree and "Background" in world.node_tree.nodes:
        world.node_tree.nodes["Background"].inputs["Color"].default_value = (0, 0, 0, 1)
    scene.world = world
    width, height = (int(v) for v in args.size.split("x"))

    phone = bpy.data.objects.new("Phone", None)
    bpy.context.collection.objects.link(phone)
    for part in (body(), screen(args.screen)):
        part.parent = phone

    pose = POSES[int(args.pose) if args.pose.isdigit() else args.pose]
    yaw, tilt, height_frac, bottom_frac = pose
    # Stand the phone up (screen toward −Y, the camera), lean it back, turn it.
    rotation = Euler((math.radians(90 - tilt), 0, math.radians(yaw)), "XYZ")
    phone.rotation_euler = rotation

    # Framing arithmetic: solve camera distance so the phone fills height_frac of the frame.
    corners = [rotation.to_matrix() @ Vector((sx * BODY_W / 2, sy * BODY_H / 2, sz * BODY_T / 2))
               for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)]
    projected_h = max(c.z for c in corners) - min(c.z for c in corners)
    projected_w = max(c.x for c in corners) - min(c.x for c in corners)
    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens = LENS
    cam_data.sensor_width = SENSOR
    cam_data.sensor_fit = "VERTICAL" if height >= width else "HORIZONTAL"
    cam_data.sensor_height = SENSOR * (height / width if height < width else 1)
    if height >= width:
        distance = projected_h / height_frac * LENS / SENSOR
        frame_h = distance * SENSOR / LENS
    else:
        frame_h = projected_h / height_frac
        distance = frame_h * LENS / cam_data.sensor_height
    phone.location.z = -frame_h / 2 + bottom_frac * frame_h - min(c.z for c in corners)
    cam = bpy.data.objects.new("Camera", cam_data)
    cam.location = (0, -distance, 0)
    cam.rotation_euler = (math.radians(90), 0, 0)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam

    lacquer_floor(phone.location.z + min(c.z for c in corners))
    gradient_softbox("Gradient card, overhead-back", (0, 0.35, 0.32), (-62, 0, 0), 1.4, 0.7, 0.7)
    gradient_softbox("Gradient strip, left rail", (-0.28, -0.05, 0.05), (0, -80, 0), 0.4, 0.5, 1.6)
    area("Key softbox, front-left", (-0.35, -0.45, 0.25), (70, 0, -35), 0.4, 0.4, 6.0)
    area("Rim kicker, back-right", (0.3, 0.3, 0.12), (-70, 0, 140), 0.25, 0.05, 4.0)

    scene["construction"] = "bmesh slab + weighted rail bevel; object-space emissive screen; lacquer stage"
    scene["pose"] = str(pose)
    return scene, width, height, projected_w


def render(scene, width, height, args):
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24 if args.preview else 192
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
    scale = 1 if args.preview else 2
    scene.render.resolution_x, scene.render.resolution_y = width * scale, height * scale
    scene.view_settings.view_transform = "Standard"  # the screenshot's sRGB must come out unchanged
    scene.view_settings.look = "None"
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.filepath = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(scene.render.filepath), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    if scale != 1:
        image = bpy.data.images.load(scene.render.filepath)
        image.scale(width, height)
        image.save()
    if args.save_blend:
        bpy.ops.file.pack_all()
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))
    print("RENDER_OK", scene.render.filepath)


if __name__ == "__main__":
    arguments = parse_args()
    built, w, h, _ = build(arguments)
    render(built, w, h, arguments)
