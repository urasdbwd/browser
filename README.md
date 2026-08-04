<p align="center">
  <a href="https://lightpanda.io"><img src="https://cdn.lightpanda.io/assets/images/logo/lpd-logo.png" alt="Logo" height=170></a>
</p>
<h1 align="center">Lightpanda Browser</h1>
<p align="center">
<strong>The headless browser built from scratch for AI agents and automation.</strong><br>
Not a Chromium fork. Not a WebKit patch. A new browser, written in Zig.
</p>

</div>
<div align="center">

[![License](https://img.shields.io/github/license/lightpanda-io/browser)](https://github.com/lightpanda-io/browser/blob/main/LICENSE)
[![Twitter Follow](https://img.shields.io/twitter/follow/lightpanda_io)](https://twitter.com/lightpanda_io)
[![GitHub stars](https://img.shields.io/github/stars/lightpanda-io/browser)](https://github.com/lightpanda-io/browser)
[![Discord](https://img.shields.io/discord/1391984864894521354?style=flat-square&label=discord)](https://discord.gg/K63XeymfB5)

</div>
<div align="center">

[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/execution-time-v2.svg">
](https://github.com/lightpanda-io/demo)
&emsp;
[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/memory-frame-v2.svg">
](https://github.com/lightpanda-io/demo)
</div>

## Benchmarks

Requesting 933 real web pages over the network on a AWS EC2 m5.large instance.
See [benchmark details](https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md#crawler-benchmark).

| Metric | Lightpanda | Headless Chrome | Difference |
| :---- | :---- | :---- | :---- |
| Memory (peak, 100 pages) | 123MB | 2GB | ~16 less |
| Execution time (100 pages) | 5s | 46s | ~9x faster |

## Quick start

### Install

**Package Managers**

Latest nightly from Homebrew:
```console
brew install lightpanda-io/browser/lightpanda
```

Latest nightly from Arch Linux User Repository:
```console
yay -S lightpanda-nightly-bin
```

**Download from the nightly builds**

You can download the last binary from the [nightly
builds](https://github.com/lightpanda-io/browser/releases/tag/nightly) for
Linux and MacOS for both x86_64 and aarch64.

*For Linux*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux && \
chmod a+x ./lightpanda
```

Verify the binary before running anything:
```console
./lightpanda version
```

[Linux aarch64 is also available](https://github.com/lightpanda-io/browser/releases/tag/nightly)

> **Note:** The Linux release binaries are linked against glibc. On musl-based distros (Alpine, etc.) the binary fails with `cannot execute: required file not found` because the glibc dynamic linker is missing. Use a glibc-based base image (e.g., `FROM debian:bookworm-slim` or `FROM ubuntu:24.04`) or [build from sources](#build-from-sources).

*For MacOS*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-aarch64-macos && \
chmod a+x ./lightpanda
```

[MacOS x86_64 is also available](https://github.com/lightpanda-io/browser/releases/tag/nightly)

*For Windows + WSL2*

Lightpanda has no native Windows binary. Install it inside WSL following the Linux steps above.

WSL not installed? Run `wsl --install` from an administrator shell, restart, then open `wsl`.
See [Microsoft's WSL install guide](https://learn.microsoft.com/en-us/windows/wsl/install) for details.

Your automation client (Puppeteer, Playwright, etc.) can run either inside WSL or on the Windows host. WSL forwards `localhost:9222` automatically.

**Install from Docker**

Lightpanda provides [official Docker
images](https://hub.docker.com/r/lightpanda/browser) for both Linux amd64 and
arm64 architectures.
The following command fetches the Docker image and starts a new container exposing Lightpanda's CDP server on port `9222`.
```console
docker run -d --name lightpanda -p 127.0.0.1:9222:9222 lightpanda/browser:nightly
```

### Dump a URL

```console
./lightpanda fetch --obey-robots --dump html --log-format pretty  --log-level info https://demo-browser.lightpanda.io/campfire-commerce/
```

You can use `--dump markdown` to convert directly into markdown.
`--wait-until`, `--wait-ms`, `--wait-selector` and `--wait-script` are
available to adjust waiting time before dump.

### Render visually in the client browser

Lightpanda has no native pixel renderer. The `render` command keeps it that
way: Lightpanda executes page JavaScript and hands a script-free DOM snapshot
to an attachable browser library. The user's browser loads the preserved
stylesheets, images, fonts and media in explicit direct-resource mode, then
performs layout, paint, compositing and rasterization. Lightpanda never pays
the CPU or memory cost of those rendering stages.

```console
./lightpanda render --port 9223 --cors-origin http://localhost:5173
```

The command defaults to the low-memory `pi` resource profile even on desktop
hardware: one V8 isolate, a 64 MiB V8 heap limit, at most two connections and a
4 MiB uncompressed snapshot cap. These are configurable defaults, and the heap
limit is not a whole-process RSS cap. One-shot HTTP responses use negotiated
Brotli quality 0 or gzip level 1 only when the body is large and compressible;
live WebSocket snapshots are not application-compressed. Outbound private,
loopback and link-local addresses are blocked by default; use
`--allow-private-networks` only for a trusted local target.

```html
<div id="preview" style="height: 720px"></div>
<script type="module">
  import { attachLightpandaRenderer } from
    "http://127.0.0.1:9223/lightpanda-renderer.js";

  const renderer = attachLightpandaRenderer("#preview", {
    directResources: true,
    requireCredentialless: true,
  });
  await renderer.render("https://example.com", { waitUntil: "done" });
</script>
```

For a persistent, interactive virtual browser, attach the live client instead.
Lightpanda keeps the page, JavaScript heap, cookies and timers alive while the
user's browser renders successive script-free snapshots:

```html
<div id="browser" style="height: 720px"></div>
<script type="module">
  import { attachLightpandaVirtualBrowser } from
    "http://127.0.0.1:9223/lightpanda-renderer.js";

  const browser = attachLightpandaVirtualBrowser("#browser", {
    directResources: true,
    requireCredentialless: true,
  });
  await browser.open("https://example.com");
</script>
```

For a minimal browser-style viewer with Back, Forward, Reload and an address
bar, run:

```console
make build-dev
python3 -m http.server 8766 --bind 127.0.0.1
./zig-out/bin/lightpanda render --port 9223 \
  --cors-origin http://127.0.0.1:8766 --allow-private-networks
```

Then open
`http://127.0.0.1:8766/src/render/tests/live_client.html`. Its `endpoint` and
`target` query parameters override the local test defaults. The private-network
flag is needed only because this fixture renders another local test page.

The live client obtains a 30-second, single-use ticket from
`POST /v1/live-ticket`, then opens `GET /v1/live` as a WebSocket. A configured
bearer token is sent only to the ticket endpoint in the `Authorization` header,
not in the WebSocket URL. Clicks, text edits, common non-text key presses and
scrolling are sent back to the persistent Lightpanda session; the browser
client never executes target-page scripts. `back()`, `forward()`, `reload()`
and the `state` event expose the server-owned navigation history and committed
address. Unchanged snapshots are acknowledged without reloading the iframe,
and the server keeps timers and network work pumping between user commands.
The client polls every 500 ms by default. Snapshots up to 256 KiB retain that
interval; larger snapshots scale to 2 seconds, while an interaction restores
the base interval. Captured clicks use the exact rendered leaf element,
iframe-viewport coordinates and keyboard modifiers with opaque,
generation-bound element IDs. Stale nodes fail instead of being retargeted
through a CSS selector. Explicit API calls may still use selectors.
Loaded nested frames are transported as script-free `srcdoc` documents; clicks
and renderer-owned `animationend` timing route back to the owning server frame.
Same-page updates reconcile stable keyed elements in place instead of replacing
the iframe. This preserves the client's native focus, selection, scroll,
control, stylesheet, image/media decode and CSS animation state. Navigation and
unsafe frame-tree changes still replace the browsing context atomically.

Lightpanda owns target JavaScript, the authoritative DOM/CSSOM, timers, storage,
cookies, application network requests, form submission and navigation. The
client browser owns CSS layout and paint, hit testing, focus/caret/IME,
compositor scrolling, native controls and visual-resource decoding. Interaction
messages reconcile those two halves; target JavaScript is never executed in
both runtimes.

The server owns one V8 isolate and one live session. A second live connection
cannot take ownership while that session is active; its commands are rejected.
Reopening on the owning connection, or submitting a valid `POST /v1/render`,
closes the live session. Run one `render` process per independently concurrent
user. If an established live WebSocket drops, the client keeps the last painted
snapshot inert and reopens the Lightpanda session with bounded backoff.

Remote visual resources are blocked by default. Set `directResources: true`
to let the client browser fetch preserved stylesheets, images, fonts and media;
this does not make Lightpanda decode or render them. Direct mode requires a
credentialless iframe unless `allowCredentialedResources: true` explicitly
accepts sending browser credentials. It also exposes the client IP and network
to requests selected by the target page, so use it only for trusted targets or
behind a future resource broker.
Public anonymous CSS, images, fonts and media are suitable for direct client
rendering. Authenticated, origin-bound, signed or `blob:` visual resources need
an opaque Lightpanda resource relay: Lightpanda performs the authorized fetch
and the client receives undecoded bytes to render. Scripts, modules, WASM,
fetch/XHR/WebSocket traffic and storage remain server-only.

The one-shot library loads a short-lived Blob URL inside an opaque,
empty-sandbox iframe. The live client uses `srcdoc` and adds only
`allow-same-origin` so the parent can capture user input; it never adds
`allow-scripts`. Page scripts cannot execute a second time, and the HTML never
enters the parent via `innerHTML`. Both clients request a credentialless iframe
where supported and send no referrer. Set
`requireCredentialless: true` to fail closed on browsers without that feature;
otherwise remote stylesheet, image, font or media requests may still use site
cookies on older browsers. Those resources are fetched and decoded by the
client; Lightpanda only streams the script-free document state. The one-shot
iframe is inert and has pointer events disabled.
Live snapshots cancel capture-phase anchor clicks, auxiliary clicks and form
submission; context-menu or drag navigation inside the sandbox remains
browser-dependent.
For untrusted targets, host the viewer on a dedicated origin with no application
cookies or saved credentials. Contenteditable, pointer drags, nested-element
scrolling, drag/drop and file input are not yet transported by the live client.

Set an exact `--cors-origin` for browser use. A non-loopback bind also requires
an `--auth-token` of at least 16 bytes; pass the same value as the library's
`token` option. Live control rejects `--cors-origin '*'`; use one exact origin.
Terminate TLS at a trusted reverse proxy before exposing the service outside
the machine because WebSocket authentication and snapshots contain sensitive
session data. The virtual-browser API has no agent dependency and adds no
application-level agent identity, but it is not an anti-detection or CAPTCHA
bypass layer. The host page's CSP must allow the endpoint in `script-src` and
`connect-src`, plus `blob:` and its own `srcdoc` child in `frame-src`. A snapshot
transfers DOM and attributes, not a JavaScript heap, event listeners, canvas
pixels or the original site's origin. Target scripts never enter the client
snapshot; target application connections and workers execute only in
Lightpanda.
Authenticated/CORS-restricted resources require a trusted fetch-and-rewrite
broker that this server does not yet provide.

### Start a CDP server

```console
./lightpanda serve --obey-robots --log-format pretty  --log-level info --host 127.0.0.1 --port 9222
```
Once the CDP server started, you can run a Puppeteer script by configuring the
`browserWSEndpoint`.

### Start a WebDriver server

```console
./lightpanda serve --webdriver --host 127.0.0.1 --port 9515
```

This W3C WebDriver slice supports `GET /status`, session creation and
deletion, navigation, current URL, title, serialized page source, current
window handle(s), closing the sole window, timeouts, element lookup from the
document or an element, active element, element tag name, attribute, text, CSS
value, selected, and enabled state, element click, clear and send keys, and
`POST /session/{id}/execute/sync` and `/execute/async`. Element lookup honors
the session's implicit timeout and accepts the `css selector`, `link text`,
`partial link text`, `tag name` and `xpath` strategies. Scripts run in the
top-level browsing context; element references round-trip through `args` and
results, a thrown exception maps to `javascript error`, and the session's
`script` timeout maps to `script timeout`. It accepts one active session with
one top-level browsing context and loopback binds only; closing that context
closes the session. Use `browserName: "lightpanda"`; unsupported capabilities
fail session creation instead of being silently ignored. Element
interactability is "the engine considers it displayed", not the spec's full
pointer hit test, and the WebDriver private-use key codes are mapped only for
Backspace, Tab, Enter and Escape.

Unlike Chrome, pages in a WebDriver session report `navigator.webdriver ===
false`. Lightpanda deliberately never advertises that it is being automated —
that flag is the single loudest automation signal a page can read, and the
whole point of driving Lightpanda is to be indistinguishable from a human
session. If you need the standards-compliant `true`, you will have to patch
`Navigator.getWebdriver`.

<details>
<summary>Example Puppeteer script</summary>

```js
import puppeteer from 'puppeteer-core';

// use browserWSEndpoint to pass the Lightpanda's CDP server address.
const browser = await puppeteer.connect({
  browserWSEndpoint: "ws://127.0.0.1:9222",
});

// The rest of your script remains the same.
const context = await browser.createBrowserContext();
const frame = await context.newPage();

// Dump all the links from the frame.
await frame.goto('https://demo-browser.lightpanda.io/amiibo/', {waitUntil: "networkidle0"});

const links = await frame.evaluate(() => {
  return Array.from(document.querySelectorAll('a')).map(row => {
    return row.getAttribute('href');
  });
});

console.log(links);

await frame.close();
await context.close();
await browser.disconnect();
```
</details>

### Agent mode

`lightpanda agent` lets you drive the browser with a native agent. Describe what
you want in plain English or with slash commands, and it controls the browser:
navigating pages, clicking through flows, filling forms, extracting structured
data. Think of it as a robot you're directing to use the web, more than a
chatbot you're having a conversation with.

Because the agent runs inside the same process as the browser, every tool call
is a direct operation and you retain Lightpanda's speed and memory advantage.

The output of an agent session is a
[PandaScript](https://lightpanda.io/docs/usage/pandascript): vanilla JavaScript
with a small set of native browser primitives built directly into Lightpanda.
Run `/save` to export one from your current session, then replay it with
`lightpanda agent <script>.js`. Scripts are deterministic and token-free, so
you can prototype with the LLM and ship the output to production without a
model at runtime.

It supports Anthropic, OpenAI, Gemini, Google Vertex AI, Hugging Face, and
local models via Ollama. You can also run without an LLM using `--no-llm`,
which drops you into the REPL. See the
[agent documentation](https://lightpanda.io/docs/usage/agent) for the full
reference.

```console
./lightpanda agent                                    # auto-detects API key from env
./lightpanda agent --task "top story on news.ycombinator.com?"
./lightpanda agent --no-llm                           # basic REPL, no LLM
./lightpanda agent session.js                         # run a recorded script
./lightpanda agent --provider gemini --task "..."     # force a specific provider
VERTEX_API_KEY=... ./lightpanda agent --provider vertex             # Vertex AI, express mode
GOOGLE_CLOUD_PROJECT=my-proj ./lightpanda agent --provider vertex   # Vertex AI, token via gcloud auth
```

### Native MCP and skill

The MCP server communicates via MCP JSON-RPC 2.0 over stdio.

Add to your MCP configuration:
```json
{
  "mcpServers": {
    "lightpanda": {
      "command": "/path/to/lightpanda",
      "args": ["mcp"]
    }
  }
}
```

#### HTTP transport and independent sessions

For serving several agents from one process, start the MCP server over HTTP
instead of stdio by giving it a port (add `--host x.x.x.x` to specify the
interface to listen on):

```bash
lightpanda mcp --port 9223
```

Clients POST JSON-RPC to `http://host:9223/mcp`. Each connection is routed to
its own **browsing session** — its own page, cookies and memory — so agents no
longer clobber each other's page:

- A client that `initialize`s without an `Mcp-Session-Id` header is assigned a
  fresh session; the id comes back in the response's `Mcp-Session-Id` header.
  Send it on subsequent requests to stay on that session (**isolation**).
- Two agents that send the **same** `Mcp-Session-Id` share one browsing context
  (**sharing** — e.g. a workflow where several agents work the same page).
- The `session_new`, `session_list` and `session_close` tools manage sessions
  explicitly. Sending `DELETE /mcp` with an `Mcp-Session-Id` closes that session.

[Read full documentation](https://lightpanda.io/docs/open-source/guides/mcp-server)

A skill is available in [lightpanda-io/agent-skill](https://github.com/lightpanda-io/agent-skill).

### Telemetry

By default, Lightpanda collects and sends usage telemetry. This can be disabled by setting an environment variable `LIGHTPANDA_DISABLE_TELEMETRY=true`. You can read Lightpanda's privacy policy at: [https://lightpanda.io/privacy-policy](https://lightpanda.io/privacy-policy).

### Core dumps

Set `LIGHTPANDA_DISABLE_CORE_DUMP` (to any value) to suppress crash core dumps by zeroing the soft `RLIMIT_CORE` at startup.

## Status

Lightpanda is in Beta and currently a work in progress. Stability and coverage are improving and many websites now work.
You may still encounter errors or crashes. Please open an issue with specifics if so.

Here are the key features we have implemented:

- [ ] CORS [#2015](https://github.com/lightpanda-io/browser/issues/2015)
- [x] HTTP loader ([Libcurl](https://curl.se/libcurl/))
- [x] HTML parser ([html5ever](https://github.com/servo/html5ever))
- [x] DOM tree
- [x] Javascript support ([v8](https://v8.dev/))
- [x] DOM APIs
- [x] Ajax
  - [x] XHR API
  - [x] Fetch API
- [x] DOM dump
- [x] CDP/websockets server
- [x] Click
- [x] Input form
- [x] Cookies
- [x] Custom HTTP headers
- [x] Proxy support
- [x] Network interception
- [x] Respect `robots.txt` with option `--obey-robots`

NOTE: There are hundreds of Web APIs. Developing a browser (even just for headless mode) is a huge task. Coverage will increase over time.

## Build from sources

### Prerequisites

Lightpanda is written with [Zig](https://ziglang.org/) `0.16.0`. You have to
install it with the right version in order to build the project.

Lightpanda also depends on
[v8](https://chromium.googlesource.com/v8/v8.git),
[Libcurl](https://curl.se/libcurl/) and [html5ever](https://github.com/servo/html5ever).

To be able to build the v8 engine, you have to install some libs:

For **Debian/Ubuntu based Linux**:

```
sudo apt install xz-utils ca-certificates \
    pkg-config libglib2.0-dev \
    clang make curl git
```
You also need to [install Rust](https://rust-lang.org/tools/install/).

For systems with [**Nix**](https://nixos.org/download/), you can use the devShell:
```
nix develop
```

For **MacOS**, you need cmake and [Rust](https://rust-lang.org/tools/install/).
```
brew install cmake
```

### Build and run

You can build the entire browser with `make build` or `make build-dev` for debug
env.

But you can directly use the zig command: `zig build run`.

### Pi-class low-resource profile

To build an artifact tuned for a Pi-class memory and CPU budget on the current
platform, download the matching prebuilt V8 archive and build with bounded
parallelism:

```bash
make build-pi
./zig-out/bin/lightpanda serve
```

`build-pi` uses `ReleaseSmall` and makes the `pi` resource profile the binary's
default. The name describes its resource budget, not a requirement to run on
Raspberry Pi hardware. A regular build can select the same runtime limits
explicitly:

```bash
./zig-out/bin/lightpanda serve --resource-profile pi
```

The profile caps each V8 heap at 64 MiB, uses one V8 background worker, disables
V8 idle tasks, optional telemetry and speculative script preloads, and limits
HTTP/CDP/WebSocket concurrency and response sizes. It keeps iframe and Web
Worker loading enabled for web compatibility; use `--disable-subframes` or
`--disable-workers` when a workload does not need them. It also reduces pooled
arena retention from roughly 6 MiB to 448 KiB. Explicit numeric limits override
the profile. CDP response-body capture is capped at 8 MiB and 256 entries per
page lifecycle. MCP is capped at two V8-backed sessions, two simultaneous HTTP
connections and 4 MiB request/response buffers per connection.

Lightpanda is headless: it does not rasterize pixels or produce screenshots on
the server. DOM and JavaScript run in the browser process; page data is
serialized only when a CDP/MCP/fetch/render client asks for it. Render-handoff
mode also skips eager inline CSSOM construction and lets the attached client
browser do presentation work.

#### Embed v8 snapshot

Lighpanda uses v8 snapshot. By default, it is created on startup but you can
embed it by using the following commands:

Generate the snapshot.
```
zig build snapshot_creator -- src/snapshot.bin
```

Build using the snapshot binary.
```
zig build -Dsnapshot_path=../../snapshot.bin
```

See [#1279](https://github.com/lightpanda-io/browser/pull/1279) for more details.

## Test

### Unit Tests

You can test Lightpanda by running `make test`.

```bash
make test                                       # Run all tests
make test F="server"                            # Filter by substring
TEST_FILTER="WebApi: #selector_all" make test   # Filter main + subtest (separator: #)
TEST_VERBOSE=true make test
TEST_FAIL_FIRST=true make test
METRICS=true make test                          # Capture allocation/duration metrics as JSON
```

### End to end tests

To run end to end tests, you need to clone the [demo
repository](https://github.com/lightpanda-io/demo) into `../demo` dir.

You have to install the [demo's node
requirements](https://github.com/lightpanda-io/demo?tab=readme-ov-file#dependencies-1)

You also need to install [Go](https://go.dev) > v1.24.

```
make end2end
```

### Web Platform Tests

Lightpanda is tested against the standardized [Web Platform
Tests](https://web-platform-tests.org/).

We use [a fork](https://github.com/lightpanda-io/wpt/tree/fork) including a custom
[`testharnessreport.js`](https://github.com/lightpanda-io/wpt/commit/01a3115c076a3ad0c84849dbbf77a6e3d199c56f).

For reference, you can easily execute a WPT test case with your browser via
[wpt.live](https://wpt.live).

#### Configure WPT HTTP server

To run the test, you must clone the repository, configure the custom hosts and generate the
`MANIFEST.json` file.

Clone the repository with the `fork` branch.
```
git clone -b fork --depth=1 git@github.com:lightpanda-io/wpt.git
```

Enter into the `wpt/` dir.

Install custom domains in your `/etc/hosts`
```
./wpt make-hosts-file | sudo tee -a /etc/hosts
```

Generate `MANIFEST.json`
```
./wpt manifest
```
Use the [WPT's setup
guide](https://web-platform-tests.org/running-tests/from-local-system.html) for
details.

#### Run WPT test suite

An external [Go](https://go.dev) runner is provided by
[github.com/lightpanda-io/demo/](https://github.com/lightpanda-io/demo/)
repository, located into `wptrunner/` dir.
You need to clone the project first.

First start the WPT's HTTP server from your `wpt/` clone dir.
```
./wpt serve
```

Run a Lightpanda browser

```
zig build run -- --insecure-disable-tls-host-verification
```

Then you can start the wptrunner from the demo's clone dir:
```
cd wptrunner && go run .
```

Or one specific test:

```
cd wptrunner && go run . Node-childNodes.html
```

`wptrunner` command accepts `--summary` and `--json` options modifying output.
Also `--concurrency` define the concurrency limit.

:warning: Running the whole test suite will take a long time. In this case,
it's useful to build in `releaseFast` mode to make tests faster.

```
zig build -Doptimize=ReleaseFast run
```

## Contributing

See [CONTRIBUTING.md](https://github.com/lightpanda-io/browser/blob/main/CONTRIBUTING.md) for guidelines.
You must sign our [CLA](CLA.md) during the pull request process.
- [Discord](https://discord.gg/K63XeymfB5)

## Why Lightpanda?

### Javascript execution is mandatory for the modern web

Simple HTTP requests used to be enough for web automation. That's no longer the case. Javascript now drives most of the web:

- Ajax, Single Page Apps, infinite loading, instant search
- JS frameworks: React, Vue, Angular, and others

### Chrome is not the right tool

Running a full desktop browser on a server works, but it does not scale well. Chrome at hundreds or thousands of instances is expensive:

- Heavy on RAM and CPU
- Hard to package, deploy, and maintain at scale
- Many features are not necessary in headless made

### Lightpanda is built for performance

Supporting Javascript with real performance meant building from scratch rather than forking Chromium:

- Not based on Chromium, Blink, or WebKit
- Written in Zig, a low-level language with explicit memory control
- No graphical rendering engine
