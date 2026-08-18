# Vista

<p align="center">
  <img src="docs/hero1.png" width="49%" alt="Dollhouse view of a room scanned with Vista">
  <img src="docs/hero2.png" width="49%" alt="Cutaway view of the same scan">
</p>

*A real room, scanned on an iPhone and viewed in Vista's own 3D viewer (dollhouse and cutaway modes).*

iOS 3D room scanning: LiDAR depth frames are fused into a TSDF volume **on the
phone**, surfaced with marching cubes into a watertight colored mesh, and
explored in an in-app 3D/AR viewer built for people who have never used a 3D
tool.

The reconstruction core of this app is extracted and open-sourced as
[swift-tsdf](https://github.com/stevyf93II/swift-tsdf) — same math, packaged as
a dependency-free Swift library with a test suite. That suite caught a real
weight-cap bug in this app's integrator before it was ever caught on a device;
the fix is ported back here.

## What it does

Point an iPhone at a room. Vista captures synchronized LiDAR depth
(256×192 Float32), ARKit confidence maps, RGB frames, and camera poses, and
fuses them **on device** into a truncated signed distance field. Marching cubes
extracts a watertight, vertex-colored mesh — overlapping observations average
into one clean surface instead of stacking into the doubled shells and phantom
triangles that ARKit's scene mesh produces. The stated quality bar is Polycam;
fused TSDF geometry (instead of ARKit's ARMeshAnchor output) is the headline
move toward it.

Scans open in **Vista Touch**, an in-app 3D/AR viewer with an orbit-locked
camera — the model physically cannot drift off screen — plus dollhouse,
see-through-walls, and cutaway modes (the hero images above are screenshots of
it). Meshes export as GLB, PLY, and USDZ.

## Capture modes

- **Room scan** — LiDAR + TSDF fusion, the pipeline above.
- **Object capture** — iOS 17+ `PhotogrammetrySession` with depth, gravity,
  and object masks; aim, start, orbit.

## Optional cloud bake

High-resolution texture baking runs on a companion Python backend (Modal +
Open3D; not part of this repo). The app zips a bake bundle
(`mesh.ply` + `manifest.json` + frames), uploads it in 10 MB chunks, polls,
and downloads a textured multi-page GLB. The server contract is documented in
`Vista/BakeUploader.swift`.

**The app is fully functional without it** — cloud features stay off until a
server URL and token are set in Settings → Advanced setup.

## Relationship to swift-tsdf

The TSDF integrator and marching cubes in this app are the origin of
[swift-tsdf](https://github.com/stevyf93II/swift-tsdf). The library's
sphere-reconstruction test suite caught a weight-cap averaging bug that had
been silently drifting surfaces in this app whenever the camera dwelled —
fixed there first, ported back here. Extracting reusable math into a tested
package paid for itself immediately.

## Building

Requirements: an iPhone with LiDAR (12 Pro or later), iOS 17+, Xcode 16+.

1. Open `Vista.xcodeproj`, set your signing team.
2. Run on a device — the simulator has no LiDAR.

Distribution builds go out through TestFlight.

## License

MIT
