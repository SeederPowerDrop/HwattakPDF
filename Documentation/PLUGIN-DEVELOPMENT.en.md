# Build a HwattakPDF plugin

Turn a useful reading or study workflow into a package other people can install. This guide describes the **2026-09-05 stabilization source**. A package declares host commands or text templates; it does not execute JavaScript, Swift, Wasm, or a custom web panel.

[한국어 가이드](PLUGIN-DEVELOPMENT.md) · [Command API](PLUGIN-HOST-API.md) · [Compatibility and proposals](PLUGIN-COMPATIBILITY.md) · [Security](PLUGIN-SECURITY.md) · [Examples](../Examples/Plugins/README.md)

## Start without a compiler

You need macOS 14+, HwattakPDF, a plain-text editor, and a test PDF without personal data. You do **not** need Node.js or a Swift build to write a plugin.

1. Copy `Examples/Plugins/OfflineChecklist.hwattakplugin` or `CommunityStarter.hwattakplugin` into your development directory.
2. Replace the example `identifier`, `displayName`, and `author`. Keep your identifier stable across updates; do not publish using the shared `org.example.*` placeholder.
3. Edit the manifest in UTF-8. Use the plugin manager to select the **directory**, review its permissions, and install it.
4. Execute from the Plugins menu. For document actions, open a test PDF and use **Shift–Command–P** to search commands. The current palette requires an open PDF; the static checklist also works from the menu without one.
5. Edit the source package and select it again in the manager to perform a reviewed update. Editing the installed copy directly can trigger quarantine.

Here is a complete, zero-permission manifest. Save it as `manifest.json` inside a directory named `MyChecklist.hwattakplugin`:

```json
{
  "schemaVersion": 1,
  "identifier": "org.example.my-checklist",
  "displayName": "My Reading Checklist",
  "version": "1.0.0",
  "author": "Your name",
  "description": "Displays a local reading checklist without reading PDF text.",
  "minimumHostVersion": "0.8.0",
  "capabilities": [],
  "actions": [
    {
      "id": "show-checklist",
      "title": "Show reading checklist",
      "output": "showText",
      "template": "Read. Mark one key idea. Explain it. Save your PDF."
    }
  ]
}
```

## Choose the smallest useful API

| Task | API / required permission |
| --- | --- |
| Static instructions | `showText`, no permissions |
| Selected text in a template | `{{selection}}` / `selectedText` |
| Filename and page reference | metadata tokens / `documentMetadata` |
| Copy a Markdown quote | `copyText` / `clipboardWrite` plus token permissions |
| Search a public HTTPS site | `openURL` / `externalURL` plus token permissions; user confirmation on every invocation |
| Highlight or underline | schema 3 `documentCommand` / `annotationWrite` |
| Pen, eraser, selection | schema 3 `documentCommand` / `toolControl` |
| Mode or page navigation | schema 3 `documentCommand` / `workspaceNavigation` |

Declare the **exact union** of the permissions required by all actions. Unused permissions also fail validation. Host highlighting uses the current selection without exporting its text and does not require `selectedText`.

For document commands, `template` is an empty string and `command` contains one supported `kind`. There are ten kinds: `highlight`, `underline`, `pen`, `eraser`, `selection`, `viewerMode`, `editingMode`, `studyMode`, `nextPage`, and `previousPage`. Styles are limited to `color` (`#RRGGBB`), `width` (0.2–32), and `opacity` (0.1–1); pen does not accept opacity. See the [command reference](PLUGIN-HOST-API.md) for defaults and conditions.

Use [CommunityStarter](../Examples/Plugins/CommunityStarter.hwattakplugin/manifest.json) for executable presets. Study mode and pen selection are separate commands; action sequences are not supported. Annotation edits use host Undo/Redo and save behavior. Disabling a plugin does not remove annotations already added to the PDF.

## Compatibility matters

The stabilization source supports schemas **1, 2, and 3**. Earlier binaries also labeled **0.8.0/build 18** may not support schema 3. `minimumHostVersion: "0.8.0"` cannot distinguish them. Record the exact tested artifact/source revision and installation result in your README. Do not add an unsupported `minimumHostBuild` key.

Plugin `version` and `minimumHostVersion` use three numeric components; prerelease suffixes and version ranges are unsupported. The manager permits reviewed replacement with the same or a lower plugin version, so publish clear release notes and retain rollback artifacts.

Obsidian `main.js`, its API, vault access, settings tabs, and `obsidian://` links are not directly supported. You can use [MarkdownQuote](../Examples/Plugins/MarkdownQuote.hwattakplugin/manifest.json) to copy text and paste it into an Obsidian note. This is a text exchange workflow, not automatic vault synchronization. Sidecar/pen input is handled by the Mac host; a pen preset is not an iPad application or device driver.

## Validate with the real host rules

Optional command-line checks require this source checkout and its macOS Swift/Xcode toolchain. Run from the repository root:

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/CommunityStarter.hwattakplugin
zsh scripts/validate_plugin.sh --examples
```

The first run builds the test module. A successful result includes `PLUGIN VALID:` and a zero exit status. This invokes the native package validator and community installation trust rules using a temporary registry. It does not install the package into your user registry or execute package code.

An optional second argument supplies a host version string to the **current** validator:

```sh
zsh scripts/validate_plugin.sh Examples/Plugins/CommunityStarter.hwattakplugin 0.7.0
```

That must fail because the example declares a 0.8.0 minimum. It does not emulate an older binary, parser, OS, or PDFKit. Test every host version you claim to support in the actual app.

Check normal use, missing selections, unsupported modes, first/last pages, Undo/Redo, save/reopen, disable/update/remove, and cancellation of external-link confirmation. Static validation does not prove runtime PDF behavior or performance.

## Package and publish

Only these files are allowed directly inside the package: `manifest.json`, `README.md`, `LICENSE`, `LICENSE.md`, `icon.png`. No subdirectories, hidden files, symlinks, executable files, or developer-generated `installation.json`. The PNG is currently signature-checked but not displayed as a plugin icon.

Limits: 32 installed packages, 24 actions per package, 5 files / 2 MiB total, 128 KiB manifest, 1 MiB per auxiliary file. See the [full format reference](PLUGINS.md) for field and output limits.

Keep screenshots, changelogs, tests, repository metadata, and CI configuration **outside** the installable directory. Publish a directory or a ZIP users must extract before installation. Validate the extracted package before release. Source code and release provenance, a license, supported host/OS versions, permission/data-flow explanations, issue contact, and a private security reporting channel belong in the README. Fields such as `homepage`, `settings`, `hotkeys`, and `repository` are not supported manifest keys.

The current app has no online marketplace, auto-updater, publisher signature verification, or automated malware certification. Manifest digests detect changes; they do not authenticate the publisher. Packages must not contain API keys, private PDF samples, or personal information. URL encoding is not anonymization, and clipboard writes use the system clipboard. Existing host recovery settings can retain local copies of document edits.

Repository examples are MPL-2.0 licensed. Preserve applicable notices when reusing them. Make your own licensing and support terms clear.

## Help shape the next API

If a feature needs computation, events, new document access, or custom UI, describe the user problem, bounded inputs/results, permissions, cancellation, Undo, document replacement, resource budget, and compatibility tests in an [API proposal](https://github.com/SeederPowerDrop/HwattakPDF/issues/new/choose). New host functionality currently requires a core change and a new app build.

A future executable SDK or community directory needs separate design and review; it is not available today. The [compatibility document](PLUGIN-COMPATIBILITY.md) records proposed stages without presenting them as shipping APIs. Report vulnerabilities through [SECURITY.md](../SECURITY.md), not public issues containing sensitive data.
