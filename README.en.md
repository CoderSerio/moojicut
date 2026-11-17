<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="96" alt="Mooji Cut logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

<p align="center"><strong>Consider it captured.</strong></p>

<p align="center">A simple screenshot and screen recording app, powered by MoonBit. Capture your screen, highlight what matters, and edit recordings with straightforward tools.</p>

<p align="center"><a href="https://coderserio.github.io/moojicut/">Website</a> · <a href="https://github.com/CoderSerio/moojicut/releases/latest">Download Latest</a> · <a href="https://github.com/CoderSerio/moojicut/issues">Report an Issue</a> · <a href="https://github.com/CoderSerio/moojicut">Source Code</a></p>

## Download and Get Started

Current release: **[0.1.0-alpha.20](https://github.com/CoderSerio/moojicut/releases/tag/v0.1.0-alpha.20)**. Mooji Cut is still in alpha, and features differ across platforms.

| System | Download | Requirements and installation |
| --- | --- | --- |
| macOS | [Apple Silicon · ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-macos-arm64.zip) | macOS 26+; unzip and move Mooji Cut to Applications. |
| Windows | [Intel / AMD x64 · ZIP](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-windows-x64.zip) | Windows 10/11; extract all files and run `MoojiCut.exe`. |
| Linux | [x86_64 · tar.gz](https://github.com/CoderSerio/moojicut/releases/download/v0.1.0-alpha.20/moojicut-0.1.0-alpha.20-linux-x64.tar.gz) | An Ubuntu 22.04+ compatible environment; install the [system dependencies (简体中文)](docs/guide.zh-CN.md#下载与开始使用), extract the archive, and run `./launch.sh`. |

You do not need to install MoonBit, Node.js, or Python. SHA256 checksum files accompany the packages. The macOS app is signed with a development certificate but is not yet notarized by Apple. The Windows app is unsigned. Your system may ask for confirmation when you first open either app.

Installed macOS versions can upgrade through Settings → Updates → Check for Updates. Windows and Linux can check for, download, and verify updates; then quit the old version and manually extract the new package to replace it. See the [usage and build guide (简体中文)](docs/guide.zh-CN.md) for details.

## Why Mooji Cut

- **Simple by default.** Focus on everyday capture, annotation, and basic editing. Mooji Cut stays in your menu bar or system tray, ready when you need it.
- **Tools your way.** On macOS, enable, disable, and reorder screenshot tools individually to keep frequent actions within reach.
- **Processed locally.** Capture and edit on your computer. You choose how to save and share the results.

## Capture and Edit

| Task | With Mooji Cut |
| --- | --- |
| Explain with a screenshot | Select an area, add arrows, rectangles, ellipses, and text, cover or pixelate parts of the image, then copy the result into a chat or document. |
| Keep a reference visible | Pin a screenshot on screen and adjust its size and opacity while you work. |
| Extract text | On macOS, use local OCR and system translation, then edit and copy the results. |
| Record a walkthrough | Choose what to record and start after a countdown. Continue editing on macOS or Windows; save a WebM file on Linux. |

Undo and redo let you make adjustments as you go.

### Screen Recording and Video Editing

| Platform | Recording | Editing after recording |
| --- | --- | --- |
| macOS | Record a region, window, or full screen, with optional system audio; save as MP4 | Split, reorder, and delete clips; close gaps; expand or unlink audio tracks; view audio waveforms; change clip speed; crop, mute, and export. |
| Windows | Select a region and cancel the countdown if needed; silent MP4, up to 1920 × 1080 at 15 fps | The existing native editor supports trimming the start and end, removing sections, cropping, undo, and redo. |
| Linux | Select a region on X11 or choose a source through the system recording portal on Wayland; silent WebM, up to 1920 × 1080 at 15 fps | Save the recording file; a video editor is not yet integrated. |

The macOS timeline supports zoom, undo, and redo. Editing and previewing preserve the original recording; saving exports the edited video. Preview speed only changes playback, while clip speed changes the exported duration. Editing currently uses a single recording, without multiple source files, subtitles, transitions, or zoom-and-pan keyframes.

Windows and Linux share MoonBit recording state and countdown rules. Neither currently supports audio recording or pausing. Automated recording and media checks have passed on Windows and Linux X11. Wayland authorization, multiple displays, and mixed DPI setups still need testing on physical devices. Scrolling capture remains disabled by default.

## Tools and Plugins

On macOS, go to Settings → Plugin Management → Screenshot Tools to manage rectangles, arrows, text, solid covers, and pinning. Toggle each tool or select it and use Move Up / Move Down to change its position. Settings are saved automatically. Annotation and user plugin tools appear in the left toolbar group; Pin, Cancel, and Done appear in the right action group.

Use Import Plugin to import a precompiled plugin ZIP. Its tools appear in the same list, where you can enable, disable, and reorder them. After selecting a screenshot area, run a plugin from the screenshot toolbar, view its text result, and click Copy Text when needed. Plugins currently receive only screenshot metadata, such as dimensions and format. They cannot read image pixels, access the network or files, or provide custom interfaces.

**The user plugin host has been verified only on Apple Silicon Macs.** Windows and Linux do not yet integrate user plugins or this management interface. Recording controls and video editing are not yet open to user plugin extensions. See the [usage and build guide (简体中文)](docs/guide.zh-CN.md#插件管理选择工具和导入插件) for import steps and instructions for packaging the example plugin.

## Development and Contributions

Mooji Cut uses **MoonBit** for shared UI, interaction, and editing logic. Platform adapters provide windows, drawing, capture, and media capabilities. Some native product interfaces still need to be migrated.

See the [build instructions (简体中文)](docs/guide.zh-CN.md#从源码构建) to get started.

The [architecture and implementation plan (简体中文)](docs/architecture.md) documents the directory structure, plugin system, platform boundaries, and CLI-first automation. It distinguishes the current implementation from its goals and serves as the reference for future architecture discussions and migration work.

Bug reports, UI improvements, and code contributions are welcome. We'd also love to discuss how plugins could fit into your everyday workflow.

## License

[MIT License](LICENSE). Third-party components are covered by their respective licenses.
