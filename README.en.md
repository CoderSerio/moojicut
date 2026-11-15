<p align="center">
  <img src="assets/brand/mooji-cut/app-icon-rounded-preview.png" width="96" alt="Mooji Cut logo" />
</p>

<h1 align="center">Mooji Cut</h1>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

<p align="center"><strong>Consider it captured.</strong></p>

<p align="center">A simple screenshot and screen recording app, powered by MoonBit. Capture your screen, highlight what matters, and trim recordings.</p>

<p align="center"><a href="https://github.com/CoderSerio/moojicut/releases">Download Preview</a> · <a href="https://github.com/CoderSerio/moojicut/issues">Report an Issue</a> · <a href="https://github.com/CoderSerio/moojicut">Source Code</a></p>

## Why Mooji Cut

- **Simple by default.** Focus on everyday capture, annotation, and basic editing. Mooji Cut stays in your menu bar or system tray, ready when you need it.
- **Tools your way.** The macOS development version lets you enable, disable, and reorder built-in and plugin screenshot tools individually.
- **Processed locally.** Capture and edit on your computer. You choose how to save and share the results.

## Capture and Edit

| Task | With Mooji Cut |
| --- | --- |
| Explain with a screenshot | Select an area, add arrows, rectangles, and text, cover sensitive details, then copy the result into a chat or document. |
| Keep a reference visible | Pin a screenshot on screen and adjust its size and opacity while you work. |
| Show a process | Record a walkthrough, trim the beginning and end, remove unwanted sections, crop the frame, and export the result. |

Undo and redo let you make adjustments as you go.

Mooji Cut is in early preview. This README covers the `0.1.0-alpha.12` development candidate; published builds may not include all of these features. Platform support and known limitations are listed in the release notes for each version.

## Tools and Plugins

In the macOS development version, go to Settings → Plugin Management → Screenshot Tools to manage rectangles, arrows, text, solid covers, and pinning. Toggle each tool or select it and use Move Up / Move Down to change its position. The screenshot toolbar reflects your choices, and settings are saved automatically.

Use Import Plugin to import a precompiled plugin ZIP. Its tools appear in the same list, where you can enable, disable, and reorder them. After selecting a screenshot area, run a plugin from the screenshot toolbar, view its text result, and click Copy Text when needed. Plugins currently receive only screenshot metadata, such as dimensions and format. They cannot read image pixels, access the network or files, or provide custom interfaces.

**The plugin host has been verified only on Apple Silicon Macs.** The Windows and Linux apps retain the feature scope described in the usage guide; user plugins and this management interface are not yet integrated. See the [usage and build guide (简体中文)](docs/guide.zh-CN.md) for import steps and instructions for packaging the example plugin.

## Get Started

Download a version for your system from the [releases page](https://github.com/CoderSerio/moojicut/releases). Each release includes installation instructions, permission setup, and a list of changes. The [usage and build guide (简体中文)](docs/guide.zh-CN.md) covers the development version in more detail.

## Development and Contributions

Mooji Cut's annotation and video editing core is written in **MoonBit**, with native interfaces and system capture APIs on each platform.

See the [build instructions (简体中文)](docs/guide.zh-CN.md#从源码构建) to get started.

Bug reports, UI improvements, and code contributions are welcome. We'd also love to discuss how plugins could fit into your everyday workflow.

## License

[MIT License](LICENSE). Third-party components are covered by their respective licenses.
