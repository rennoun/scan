# Mizan 3D — iPhone precision 3D scanner (v0.1)

Turns an iPhone Pro (LiDAR) into a 3D scanner, in the spirit of Creality Scan.

## What v0.1 does

| Feature | Status |
|---|---|
| **Object mode**: guided capture (Apple Object Capture), LiDAR bounding box, coverage feedback, multiple passes, flip object | ✅ |
| On-device 3D reconstruction (photogrammetry) → USDZ | ✅ |
| **Large / Room mode**: live LiDAR mesh while you sweep → OBJ | ✅ |
| 3D viewer (orbit/zoom), **point-to-point measuring in mm** | ✅ |
| **Scale calibration**: "Set real length" from the mat's 100 mm bar or a caliper value | ✅ |
| Export **STL / OBJ / PLY in millimetres** (scale applied), USDZ, photos .zip | ✅ |
| Printable **scale mat** (in-app, AirPrint) | ✅ |
| In-app log viewer (debugging without Xcode) | ✅ |
| Scans visible in the Files app (On My iPhone › Mizan 3D) | ✅ |
| Automatic coded-marker detection (marker mode) | ⏳ v0.2 |
| Mesh editing (crop, plane cut, hole fill) | ⏳ v0.3 |
| Scan-vs-CAD deviation map | ⏳ Pro |

Requires iOS 17+ and an iPhone with LiDAR (12 Pro or newer, incl. 17 Pro Max).

---

## Build & install from Windows (no Mac)

### 1. Put the code on GitHub
1. Create a free account at github.com → **New repository** → name `Mizan3D` (private is fine).
2. Click **uploading an existing file** and drag the *contents* of this folder (including the hidden `.github` folder — on Windows enable "Show hidden items"), or use GitHub Desktop.
3. Commit to the `main` branch.

### 2. Let GitHub build the app
1. Open the repo → **Actions** tab → enable workflows if asked.
2. The workflow **Build iOS app (unsigned IPA)** runs on every push (or click **Run workflow**).
3. When it's green (≈5–8 min), open the run → **Artifacts** → download `Mizan3D-unsigned-ipa` and unzip it → `Mizan3D-unsigned.ipa`.
4. If it's red, download the `build-log` artifact and send it to Claude.

### 3. Install on the iPhone with Sideloadly
1. On Windows install **iTunes** (from apple.com, not the Store version if possible) and **Sideloadly** (sideloadly.io).
2. Connect the iPhone by USB, tap **Trust** on the phone.
3. In Sideloadly: drag the `.ipa`, enter your Apple ID, click **Start**.
4. On the iPhone:
   - Settings › Privacy & Security › **Developer Mode** → On (restarts the phone).
   - Settings › General › **VPN & Device Management** → your Apple ID → **Trust**.
5. Open **Mizan 3D**.

With a free Apple ID the app expires after **7 days** → just repeat step 3 (your scans stay on the phone).

### On a Mac later
```
brew install xcodegen
xcodegen generate
open Mizan3D.xcodeproj
```
Choose your team in Signing & Capabilities, plug in the iPhone, press Run.

---

## How to get the best precision

1. Print `Mizan3D/Resources/Mizan-scale-mat-A4.pdf` at **actual size**; check a bar = 100 mm.
2. Soft, even light. Matte the part (scanning spray/talc) if shiny, black or transparent.
3. Object mode → 2–3 passes at different heights, flip the part for the bottom.
4. Build the model → **Measure** a known dimension → **Set real length**.
5. Export **STL** (mm) → slicer / CAD.

For maximum detail, export the photos (.zip) and process them on a Mac (Object Capture *Full/Raw*), or with RealityScan / Metashape / COLMAP on a PC.

## Project layout

```
project.yml                      XcodeGen project definition
.github/workflows/build-ios.yml  cloud build → unsigned IPA
Mizan3D/
  App/          app entry, theme
  Models/       ScanProject, ProjectStore (Documents/Scans/<id>/)
  Capture/      ObjectCapture model + screen, LiDAR screen
  Processing/   on-device photogrammetry
  Viewer/       SceneKit viewer, measuring, export
  Views/        Home, project detail, log, scale mat
  Utils/        MeshData (STL/OBJ/PLY writers), files, log
  Resources/    scale mat PDF
```
