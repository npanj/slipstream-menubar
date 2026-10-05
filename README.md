# Slipstream Menubar

A macOS menu bar item that starts, stops and watches a local
[Slipstream](https://github.com/npanj/slipstream) server, with a floating panel of
live serving and system charts. The menu design follows
[oMLX](https://github.com/jundot/omlx)'s menu bar app, reduced to the essentials.

The item shows Slipstream's bolt and, while serving, two live readouts in the style of
[Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s network indicator: ↓ prompt
tokens per second (incoming) over ↑ output tokens per second (outgoing).

<p>
  <img src="Assets/MenuBarItem.png" alt="The menu bar item with its ↓ prompt and ↑ output readout, and its menu: status, Stop Server, Stats Panel, Settings, About and Quit" width="322" align="top">
  &nbsp;
  <img src="Assets/StatsPanel.png" alt="The stats panel in the compact view: throughput, context and KV cache, requests, engine memory and system charts" width="415" align="top">
</p>

## Download & Install

### Option A: Homebrew (Installs both Menu Bar App and CLI Engine)

```zsh
brew install --cask npanj/tap/slipstream
```

### Option B: One-line install script

Paste into Terminal to download, verify, install and start the latest release:

```sh
curl -fsSL https://github.com/npanj/slipstream-menubar/raw/main/install.sh | sh
```

It installs into /Applications (~/Applications if that is not writable) and clears the
quarantine mark, so macOS opens the app without asking. `SLIPSTREAM_MENUBAR_TAG=v26.10.4` picks a
release; `sh install.sh --help` lists the options. On its first start the app sets up Slipstream
and a model.

Or, from the [latest release](https://github.com/npanj/slipstream-menubar/releases/latest), get
either `Slipstream-Menubar.<version>.dmg` (open it and drag the app onto *Applications*) or
`Slipstream-Menubar.app.<version>.zip` (unzip it and move *Slipstream Menubar.app* to
/Applications). The app is signed ad hoc, not notarized, so allow it once in *System Settings →
Privacy & Security → Open Anyway*, or run
`xattr -dr com.apple.quarantine "/Applications/Slipstream Menubar.app"`.

### Updates

The app looks for a newer release of itself about once a day (Settings → App → *Check for app
updates automatically*), and on **Check for Updates…** in the menu. When it finds one, it shows the
changes and offers *Update and Relaunch*, *Later* or *Skip This Version*. Updating downloads the
release's zip, verifies it against the release's checksums, checks that it is this app at that
version with an intact signature, puts it in place of the running copy and relaunches; the server
keeps running. If the app's folder is not writable, macOS asks for an administrator password.
Because each build is signed ad hoc, macOS may ask once after an update whether the app may use
its API key in the Keychain.

## Slipstream itself

The app runs the Slipstream it finds at `~/.local/bin/slipstream`, else `slipstream` on your
login shell's PATH. If there is none, the menu offers **Install Slipstream…**: it downloads the
latest release of [npanj/slipstream](https://github.com/npanj/slipstream/releases), shows the
progress, verifies the checksum, installs into `~/.local/share/slipstream/<version>` and links
`~/.local/bin/slipstream`, keeping the two newest versions, as the release's `install.sh` does:

```sh
curl -fsSL https://raw.githubusercontent.com/npanj/slipstream/main/install.sh | sh
```

Settings → Server → Run can switch to a source checkout instead.

The menu and Settings show the version the server is running. After an update is installed, the
running server keeps its version until it restarts; the status then reads "restart to update to
<version>", and the next start uses the new release.

## Models

First-run setup, **Download Model…** in the menu, and Settings → Model offer the supported models:

| Model | Format | Download | Memory |
|---|---|---|---|
| [Swift-Qwen3.8-Flash-Next V3](https://huggingface.co/MikeZ75/Swift-Qwen3.8-Flash-Next-V3-Splash) (default) | Splash Q4 | 107.7 GB | 64 GB Mac |
| [Swift-Qwen3.8-Flash-Next V3](https://huggingface.co/nitinpanj/Swift-Qwen3.8-Flash-Next-Q4_0-Q8out-v3-GGUF) (plus the shared MTP draft head) | GGUF | 104.5 GB | 64 GB Mac |
| [Qwen3.8-Flash-Next V3](https://huggingface.co/MikeZ75/Qwen3.8-Flash-Next-V3-Splash) | Splash Q4 | 107.7 GB | 64 GB Mac |
| [Qwen3.8-Flash-Next V3](https://huggingface.co/nitinpanj/qwen38-flash-next-v3) | GGUF | 104.5 GB | 64 GB Mac |

- **Splash Q4** (`splash-packed-q4-qwen4exp`) is Slipstream's own format, ready to run: the server
  starts in about 15 seconds and the model needs no more disk than its download. These packages
  are the GGUF models converted once and published on Hugging Face (license and credits as their
  sources).
- **GGUF** files are converted on the first start (about 4 minutes), which the Stats panel shows as
  a progress bar. Slipstream 26.10.4 or later converts in place, using the downloaded files up as
  it goes; Settings → *Keep GGUF files after preparing* keeps them instead, needing the model's
  size again on disk.

The Slipstream v2 engine loads only Qwen3.8-Flash-Next; Splash 1.0 packages such as
`incoai/Qwen3.8-27B-Splash` are refused before downloading.

**Adding a model:** Settings → Model has **Choose from disk…** (a folder with a model's GGUF files
or a prepared package) and **Load from Hugging Face…**: paste the model's id, `owner/name`, or its
page address. The repository is checked before anything is downloaded: by Slipstream itself
(`slipstream pull <owner/repo> --check`) when it supports that, otherwise by the app. It must hold
a Splash Q4 package or one `qwen4exp` model's GGUF files.

Slipstream itself downloads the model (`slipstream pull <owner/repo>`) into its model store,
`~/.slipstream/models/<owner>/<repo>`, the same folder `slipstream serve --model <owner/repo>`
uses, so a model is downloaded once. It also fetches the MTP draft head a GGUF repository lacks.
The window shows progress, speed and time left; at least 10 GB must stay free afterwards. On a
64 GB Mac the app raises `iogpu.wired_limit_mb` (Settings → Memory, default 59392) before each start.

## Web UI

**Open Web UI** (⌘O) opens Slipstream's chat page at `http://127.0.0.1:<port>/` in the default
browser. It is available while the server is running, unless Settings → Access → Disable web UI is
on.

## Uninstall and Cleanup

The last section of Settings lists the downloaded models with their sizes; each can be deleted on
its own (Stop and Delete when the server is running it). **Uninstall and Cleanup…** lists everything
the app and Slipstream put on this Mac, with sizes, and removes it after a confirmation:

- the Slipstream releases in `~/.local/share/slipstream`, and `~/.local/bin/slipstream` if it
  points into them
- Slipstream's data and caches in `~/Library/Application Support/Slipstream-v2`
- the app's settings, the server logs, the API key in the Keychain and the login item
- the models, each of which can be unticked to keep it
- the app itself, which goes to the Trash before it quits

It stops the server first. Homebrew, `hf`, Hugging Face's cache in `~/.cache/huggingface` and any
source checkout are left alone.

## Requirements

- macOS 15 or later on Apple Silicon (the Slipstream engine itself needs 26.4)
- Xcode or the Command Line Tools with Swift 6
- Slipstream: installed by the app or `install.sh`, or a built source checkout

## Build and run

```sh
make test      # unit tests for the core logic
make app       # build/Slipstream Menubar.app, signed ad hoc
make run       # build and open it with the stats panel showing
make install   # copy it to /Applications
```

On first launch, Settings opens if no model is set. The configuration is stored in
`~/Library/Application Support/Slipstream/menubar.json`, and the API key in the login
Keychain.

## How it works

- **Status.** The launcher records its pid, model and port in `serve.lock` (in
  `~/Library/Application Support/Slipstream-v2/runtime/` for a release,
  `<checkout>/build/runtime/` for a checkout) and then `execve`s into `server/server.py`, so
  that pid is the server. The app reads the lock, checks that the pid is a live
  Slipstream launcher or server, and probes `/health` and `/ready`. A server started from
  a terminal is found the same way and is shown as "started elsewhere".
- **Start.** Runs `slipstream serve --model … --port … [options]` in its own
  session with output to `~/Library/Logs/Slipstream/server.log` (the previous log is kept
  as `server.log.1`). While a GGUF model is being prepared, the status shows the
  converter's progress from the log.
- **Stop.** SIGTERM, then SIGKILL if the server is still running after 30 seconds.
  Force Stop sends SIGKILL right away.
- **Quit** leaves the server running; the next launch picks it up again.
- **Stats.** `/metrics` every two seconds while serving, every three
  seconds otherwise, plus `/status` every 15 seconds for the context limit. Token rates
  are counter deltas over a three-second wall-clock window. The engine's own
  `*_tokens_per_second` gauges divide by GPU step time and read far higher than what
  clients receive. History is kept when metrics stop arriving; the stretch without data
  is shaded gray and lines are not drawn across it.
- **Liveness.** `/ready` only decides when a starting server counts as running: once
  loaded, the server answers 503 there whenever it is saturated. After that, "Not
  responding" means three failed `/health` checks in a row.
- **System.** CPU from per-core tick counters, GPU utilization from the accelerator's
  IOKit `PerformanceStatistics`, memory from `vm_statistics64`, swap from
  `vm.swapusage`: public APIs only, no helper or entitlements.

## Settings

| Setting | Passed as |
|---|---|
| Run | the installed release, or a source checkout at a given path |
| Model | `--model`: one of the supported models, one added with Choose from disk… or Load from Hugging Face… |
| Port | `--port` |
| Max context | `--max-context` (empty = auto) |
| Max memory | `--max-memory` (empty = auto) |
| API key | `SLIPSTREAM_V2_API_KEY` in the server's environment; also sent by the app to read `/metrics` |
| Listen on the network | `--host 0.0.0.0` (off: 127.0.0.1 only); needs a launcher with `serve --host` ([npanj/slipstream#5](https://github.com/npanj/slipstream/pull/5)) |
| Allowed hosts | `--allowed-host`, repeated: extra names clients may use, such as `<mac>.local` |
| Disable web UI | `--no-webui` |
| Raise the GPU memory limit before starting | `sudo sysctl iogpu.wired_limit_mb=<limit>` (64 GB Macs; default 59392) |
| Start the server when the app launches | only if none is running already |
| Check for app updates automatically | about once a day, against this repository's releases |
| Open at login | a login item via `SMAppService` (needs the app in /Applications) |

With the network option on, other machines connect to `http://<this Mac's IP>:<port>`;
Settings lists the addresses and warns while no API key is set. Traffic is plain HTTP.

Changes take effect when the server restarts; Settings offers Save & Restart while one
is running.

## Layout

```
Sources/SlipstreamMenubarCore/   metrics parsing, rates, status logic, config, installation,
                                 model checks, cleanup, system sampling
Sources/SlipstreamMenubar/       AppKit menu, server control, SwiftUI panel and settings,
                                 installer, model download and uninstall windows
Tests/SlipstreamMenubarCoreTests/
scripts/build-app.sh             assembles and signs the .app bundle
scripts/fake-server.py           stand-in Slipstream server for testing (outages, busy, served requests)
scripts/make-icon.swift          draws Resources/AppIcon.icns from the bolt
scripts/stage-hub-package.py     stages a prepared model as a package for a Hugging Face upload
```

## Releases

Pushing a tag such as `v26.10.0` runs `.github/workflows/release.yml`: it tests, builds the app
with that version, and attaches a `.dmg`, a `.zip` and their SHA-256 sums to a GitHub release.
Running the workflow by hand with an existing tag rebuilds that release's files.

## Authors & Credits

- **Mike Zinner** ([@mzinner](https://github.com/mzinner)) — Creator and lead author of Slipstream Menubar.
- **Nitin** ([@npanj](https://github.com/npanj)) — Co-author and maintainer; creator of Slipstream.

## License

MIT License. Original work © 2026 Mike Zinner ([mzinner](https://github.com/mzinner)).
