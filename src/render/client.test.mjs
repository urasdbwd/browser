import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

class FakeElement {
  children = [];

  append(child) {
    child.isConnected = true;
    child.parent = this;
    this.children.push(child);
  }

  replaceChildren(child) {
    for (const current of this.children) current.isConnected = false;
    child.isConnected = true;
    child.parent = this;
    this.children = [child];
  }

  getBoundingClientRect() {
    return { width: 1280, height: 720 };
  }
}

class FakeSnapshotElement {
  #attributes;
  nodeType = 1;
  localName = "button";
  namespaceURI = "http://www.w3.org/1999/xhtml";
  type = "button";

  constructor(version) {
    this.#attributes = new Map([
      [`data-lp-t-${version}`, "1"],
      [`data-lp-k-${version}`, "0123456789abcdef"],
    ]);
  }

  getAttribute(name) {
    return this.#attributes.get(name) ?? null;
  }

  removeAttribute(name) {
    this.#attributes.delete(name);
  }
}

class FakeDocument {
  #element;
  #version;

  constructor(html) {
    this.#version = html.match(/data-lp-t-([0-9a-f]{16})/)?.[1] ??
      "0000000000000001";
    this.#element = new FakeSnapshotElement(this.#version);
    this.baseURI = html.match(/<base href="([^"]+)"/)?.[1] ?? "https://example.com/";
    this.title = html.match(/<title>([^<]*)<\/title>/)?.[1] ?? "";
    this.documentElement = {
      localName: "html",
      namespaceURI: "http://www.w3.org/1999/xhtml",
    };
    this.body = {};
    this.activeElement = this.body;
    this.defaultView = null;
  }

  querySelectorAll(selector) {
    if (selector === `[data-lp-t-${this.#version}]` ||
        selector === `[data-lp-k-${this.#version}]`) return [this.#element];
    return [];
  }

  #listeners = new Map();

  addEventListener(type, listener) {
    const listeners = this.#listeners.get(type) ?? new Set();
    listeners.add(listener);
    this.#listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    this.#listeners.get(type)?.delete(listener);
  }

  target() {
    return this.#element;
  }

  dispatch(type, event) {
    for (const listener of [...(this.#listeners.get(type) ?? [])]) listener(event);
  }
}

class FakeIframe extends FakeElement {
  #attributes = new Map();
  #listeners = new Map();
  style = {};
  isConnected = false;
  contentDocument = null;

  setAttribute(name, value) {
    this.#attributes.set(name, String(value));
  }

  getAttribute(name) {
    if (name === "style") return this.style.cssText ?? null;
    return this.#attributes.get(name) ?? null;
  }

  removeAttribute(name) {
    this.#attributes.delete(name);
  }

  cloneNode() {
    const clone = new FakeIframe();
    clone.style.cssText = this.style.cssText;
    return clone;
  }

  addEventListener(type, listener) {
    const listeners = this.#listeners.get(type) ?? new Set();
    listeners.add(listener);
    this.#listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    this.#listeners.get(type)?.delete(listener);
  }

  #dispatch(type) {
    for (const listener of [...(this.#listeners.get(type) ?? [])]) listener();
  }

  set src(value) {
    this._src = value;
    queueMicrotask(() => this.#dispatch("load"));
  }

  set srcdoc(value) {
    this._srcdoc = value;
    this.contentDocument = new FakeDocument(value);
    queueMicrotask(() => this.#dispatch("load"));
  }

  after(sibling) {
    sibling.isConnected = this.isConnected;
    sibling.parent = this.parent;
    this.parent?.children.push(sibling);
  }

  remove() {
    this.isConnected = false;
  }
}

class FakeWebSocket extends EventTarget {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances = [];
  static onSend = null;

  readyState = FakeWebSocket.CONNECTING;

  constructor(url) {
    super();
    this.url = url;
    FakeWebSocket.instances.push(this);
    queueMicrotask(() => {
      if (this.readyState !== FakeWebSocket.CONNECTING) return;
      this.readyState = FakeWebSocket.OPEN;
      this.dispatchEvent(new Event("open"));
    });
  }

  send(data) {
    FakeWebSocket.onSend?.(this, JSON.parse(data));
  }

  message(data) {
    const event = new Event("message");
    Object.defineProperty(event, "data", { value: data });
    this.dispatchEvent(event);
  }

  close() {
    if (this.readyState >= FakeWebSocket.CLOSING) return;
    this.readyState = FakeWebSocket.CLOSED;
    queueMicrotask(() => this.dispatchEvent(new Event("close")));
  }
}

async function loadRenderer() {
  const path = new URL("./client.js", import.meta.url);
  let source = await readFile(path, "utf8");
  source = source.replace(
    /^const DEFAULT_ENDPOINT = .*;$/m,
    'const DEFAULT_ENDPOINT = "https://renderer.test/v1/render";',
  );
  return import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
}

async function waitFor(predicate, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function successfulSnapshot(socket, command, title) {
  const version = "0000000000000001";
  const html = `<base href="https://example.com/"><title>${title}</title>` +
    `<button data-lp-t-${version}="1" data-lp-k-${version}="0123456789abcdef">ok</button>`;
  const bytes = new TextEncoder().encode(html).buffer;
  queueMicrotask(() => {
    socket.message(JSON.stringify({
      id: command.id,
      ok: true,
      snapshot: true,
      closed: false,
      can_go_back: false,
      can_go_forward: false,
      target_version: version,
      snapshot_encoding: "identity",
      snapshot_bytes: bytes.byteLength,
    }));
    socket.message(bytes);
  });
}

test("identical in-flight renders share one fetch", async () => {
  const original = {
    Element: globalThis.Element,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  const requests = [];
  globalThis.Element = FakeElement;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async (_endpoint, request) => {
    requests.push(request);
    return { ok: true, blob: async () => new Blob(["snapshot"]) };
  };
  try {
    const { LightpandaRenderer } = await loadRenderer();
    const renderer = new LightpandaRenderer(new FakeElement());
    await Promise.all([
      renderer.render("https://example.com/", { waitUntil: "done" }),
      renderer.render("https://example.com/", { waitUntil: "done" }),
    ]);
    try {
      assert.equal(requests.length, 1);
    } finally {
      renderer.destroy();
    }
  } finally {
    globalThis.Element = original.Element;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("one-shot render requests captcha solving and exposes its outcome", async () => {
  const original = {
    CustomEvent: globalThis.CustomEvent,
    Element: globalThis.Element,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  let requestBody = null;
  globalThis.CustomEvent ??= class CustomEvent extends Event {
    constructor(type, options = {}) {
      super(type);
      this.detail = options.detail;
    }
  };
  globalThis.Element = FakeElement;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async (_endpoint, request) => {
    requestBody = JSON.parse(request.body);
    return {
      ok: true,
      headers: { get: (name) => name === "x-lp-turnstile" ? "solved" : null },
      blob: async () => new Blob(["snapshot"]),
    };
  };

  let renderer = null;
  try {
    const { LightpandaRenderer } = await loadRenderer();
    renderer = new LightpandaRenderer(new FakeElement());
    let outcome = null;
    renderer.addEventListener("captcha", (event) => { outcome = event.detail.turnstile; });
    await renderer.render("https://example.com/", { solveCaptchas: true });

    assert.equal(requestBody.solve_captchas, true);
    assert.equal(requestBody.wait_ms, 30_000);
    assert.equal(renderer.turnstile, "solved");
    assert.equal(outcome, "solved");
  } finally {
    renderer?.destroy();
    globalThis.CustomEvent = original.CustomEvent;
    globalThis.Element = original.Element;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("successful reconnect emits once after the reopened snapshot is usable", async () => {
  const original = {
    CustomEvent: globalThis.CustomEvent,
    Element: globalThis.Element,
    WebSocket: globalThis.WebSocket,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  let ticketRequests = 0;
  FakeWebSocket.instances = [];
  globalThis.CustomEvent ??= class CustomEvent extends Event {
    constructor(type, options = {}) {
      super(type);
      this.detail = options.detail;
    }
  };
  globalThis.Element = FakeElement;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async () => {
    ticketRequests += 1;
    if (ticketRequests === 2) {
      return { ok: false, status: 503, text: async () => "restarting" };
    }
    return {
      ok: true,
      json: async () => ({ ticket: `ticket-${ticketRequests}` }),
    };
  };
  FakeWebSocket.onSend = (socket, command) => {
    successfulSnapshot(
      socket,
      command,
      FakeWebSocket.instances.length === 1 ? "Initial" : "Reopened",
    );
  };

  let browser = null;
  try {
    const { LightpandaVirtualBrowser } = await loadRenderer();
    browser = new LightpandaVirtualBrowser(new FakeElement(), {
      endpoint: "wss://renderer.test/v1/live",
      pollInterval: 60_000,
    });
    const lifecycle = [];
    browser.addEventListener("reconnecting", () => lifecycle.push("reconnecting"));
    browser.addEventListener("reconnect", () => {
      lifecycle.push("reconnect");
      assert.equal(browser.iframe.contentDocument?.title, "Reopened");
      assert.equal(browser.iframe.isConnected, true);
    });

    await browser.open("https://example.com/");
    FakeWebSocket.instances[0].close();
    await waitFor(() => ticketRequests === 2);
    assert.deepEqual(lifecycle, ["reconnecting"]);
    await waitFor(() => lifecycle.includes("reconnect"));
    assert.deepEqual(lifecycle, ["reconnecting", "reconnect"]);
  } finally {
    browser?.destroy();
    FakeWebSocket.onSend = null;
    globalThis.CustomEvent = original.CustomEvent;
    globalThis.Element = original.Element;
    globalThis.WebSocket = original.WebSocket;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("live renderer exposes an explicit captcha solve command", async () => {
  const original = {
    CustomEvent: globalThis.CustomEvent,
    Element: globalThis.Element,
    WebSocket: globalThis.WebSocket,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  FakeWebSocket.instances = [];
  globalThis.CustomEvent ??= class CustomEvent extends Event {
    constructor(type, options = {}) {
      super(type);
      this.detail = options.detail;
    }
  };
  globalThis.Element = FakeElement;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ ticket: "t" }) });

  const sent = [];
  FakeWebSocket.onSend = (socket, command) => {
    sent.push(command);
    if (command.type === "open") return successfulSnapshot(socket, command, "Captcha");
    queueMicrotask(() => socket.message(JSON.stringify({
      id: command.id,
      ok: true,
      snapshot: false,
      closed: false,
      can_go_back: false,
      can_go_forward: false,
      target_version: null,
      snapshot_encoding: null,
      snapshot_bytes: 0,
      turnstile: "solved",
    })));
  };

  let browser = null;
  try {
    const { LightpandaVirtualBrowser } = await loadRenderer();
    browser = new LightpandaVirtualBrowser(new FakeElement(), {
      endpoint: "wss://renderer.test/v1/live",
      pollInterval: 60_000,
    });
    await browser.open("https://example.com/");
    let outcome = null;
    browser.addEventListener("captcha", (event) => { outcome = event.detail.turnstile; });
    const response = await browser.solveCaptchas({ waitMs: 12_000 });

    const command = sent.find((value) => value.type === "solve_captchas");
    assert.equal(command.wait_ms, 12_000);
    assert.equal(response.turnstile, "solved");
    assert.equal(browser.turnstile, "solved");
    assert.equal(outcome, "solved");
  } finally {
    browser?.destroy();
    FakeWebSocket.onSend = null;
    globalThis.CustomEvent = original.CustomEvent;
    globalThis.Element = original.Element;
    globalThis.WebSocket = original.WebSocket;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("keydown and keyup are forwarded separately with full key state", async () => {
  const original = {
    CustomEvent: globalThis.CustomEvent,
    Element: globalThis.Element,
    WebSocket: globalThis.WebSocket,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  FakeWebSocket.instances = [];
  globalThis.CustomEvent ??= class CustomEvent extends Event {
    constructor(type, options = {}) {
      super(type);
      this.detail = options.detail;
    }
  };
  globalThis.Element = FakeElement;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ ticket: "t" }) });

  const sent = [];
  FakeWebSocket.onSend = (socket, command) => {
    sent.push(command);
    if (command.type === "open") return successfulSnapshot(socket, command, "Keys");
    queueMicrotask(() => socket.message(JSON.stringify({
      id: command.id,
      ok: true,
      snapshot: false,
      closed: false,
      can_go_back: false,
      can_go_forward: false,
      target_version: null,
      snapshot_encoding: null,
      snapshot_bytes: 0,
    })));
  };

  let browser = null;
  try {
    const { LightpandaVirtualBrowser } = await loadRenderer();
    browser = new LightpandaVirtualBrowser(new FakeElement(), {
      endpoint: "wss://renderer.test/v1/live",
      pollInterval: 60_000,
    });
    await browser.open("https://example.com/");

    const doc = browser.iframe.contentDocument;
    let prevented = 0;
    const keyEvent = (overrides) => ({
      target: doc.target(),
      key: "w",
      code: "KeyW",
      location: 0,
      repeat: false,
      isComposing: false,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: true,
      preventDefault: () => { prevented += 1; },
      ...overrides,
    });

    // A plain letter used to be dropped outside text fields.
    doc.dispatch("keydown", keyEvent({}));
    doc.dispatch("keyup", keyEvent({}));
    await waitFor(() => sent.some((command) => command.type === "keyup"));

    const down = sent.find((command) => command.type === "keydown");
    const up = sent.find((command) => command.type === "keyup");
    assert.equal(down.key, "w");
    assert.equal(down.code, "KeyW");
    assert.equal(down.repeat, false);
    assert.equal(down.location, 0);
    assert.equal(down.shift_key, true);
    assert.equal(down.ctrl_key, false);
    assert.deepEqual(down.target, { version: "0000000000000001", id: 1 });
    assert.equal(up.key, "w");
    assert.equal(up.code, "KeyW");
    // keydown suppresses the local default; keyup has none worth suppressing.
    assert.equal(prevented, 1);

    // Ctrl chords forward but must not steal the viewer's own shortcuts.
    prevented = 0;
    doc.dispatch("keydown", keyEvent({ key: "c", code: "KeyC", ctrlKey: true }));
    await waitFor(() => sent.filter((command) => command.type === "keydown").length === 2);
    assert.equal(prevented, 0);
    assert.equal(sent.filter((command) => command.type === "keydown")[1].ctrl_key, true);

    // Auto-repeat coalesces instead of building an unbounded backlog.
    const before = sent.length;
    for (let i = 0; i < 40; i++) {
      doc.dispatch("keydown", keyEvent({ repeat: true }));
    }
    await waitFor(() => sent.length > before);
    assert.ok(sent.length - before < 40, `expected coalescing, sent ${sent.length - before}`);
  } finally {
    browser?.destroy();
    FakeWebSocket.onSend = null;
    globalThis.CustomEvent = original.CustomEvent;
    globalThis.Element = original.Element;
    globalThis.WebSocket = original.WebSocket;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("canvas ops replay onto the viewer's real 2D context", async () => {
  const { parseCanvasOps, applyCanvasOps } = await loadRenderer();

  // The server ships JSON array elements without the enclosing brackets so it
  // can splice them straight into an attribute.
  const parsed = parseCanvasOps('["FS","#ff0000"],["fr",1,2,3,4],["ft","hi",5,6]');
  assert.equal(parsed.truncated, false);
  assert.equal(parsed.ops.length, 3);

  const calls = [];
  const ctx = {
    canvas: { width: 300, height: 150 },
    set fillStyle(value) { calls.push(["fillStyle", value]); },
    fillRect: (...args) => calls.push(["fillRect", ...args]),
    fillText: (...args) => calls.push(["fillText", ...args]),
    setTransform: (...args) => calls.push(["setTransform", ...args]),
    clearRect: (...args) => calls.push(["clearRect", ...args]),
    beginPath: () => calls.push(["beginPath"]),
    drawImage: (image, ...args) => calls.push(["drawImage", image.src, ...args]),
  };

  applyCanvasOps(ctx, parsed.ops, () => null);
  assert.deepEqual(calls, [
    ["fillStyle", "#ff0000"],
    ["fillRect", 1, 2, 3, 4],
    ["fillText", "hi", 5, 6],
  ]);

  // "z" is the server collapsing its log after a full-canvas clear; the client
  // has to wipe its canvas too or the two sides drift apart.
  calls.length = 0;
  applyCanvasOps(ctx, parseCanvasOps('["z"],["fr",0,0,1,1]').ops, () => null);
  assert.deepEqual(calls, [
    ["setTransform", 1, 0, 0, 1, 0, 0],
    ["clearRect", 0, 0, 300, 150],
    ["beginPath"],
    ["fillRect", 0, 0, 1, 1],
  ]);

  // A leading "!" flags a log that overflowed its cap server-side.
  const truncated = parseCanvasOps('!["sk"]');
  assert.equal(truncated.truncated, true);
  assert.deepEqual(truncated.ops, [["sk"]]);

  // Sprites are named by URL and drawn from the viewer's own cache, so the
  // bitmap never crosses the wire.
  calls.length = 0;
  const image = { complete: true, naturalWidth: 8, src: "https://cdn.test/s.png" };
  applyCanvasOps(ctx, parseCanvasOps('["di","https://cdn.test/s.png",4,5]').ops, () => image);
  assert.deepEqual(calls, [["drawImage", "https://cdn.test/s.png", 4, 5]]);

  // An image that has not finished downloading is drawn once it lands, rather
  // than dropped.
  calls.length = 0;
  let onLoad = null;
  const pending = {
    complete: false,
    naturalWidth: 0,
    src: "https://cdn.test/late.png",
    addEventListener: (type, listener) => { if (type === "load") onLoad = listener; },
  };
  applyCanvasOps(ctx, parseCanvasOps('["di","https://cdn.test/late.png",1,2]').ops, () => pending);
  assert.deepEqual(calls, []);
  onLoad();
  assert.deepEqual(calls, [["drawImage", "https://cdn.test/late.png", 1, 2]]);

  // One unknown or malformed op must not abandon the rest of the frame.
  calls.length = 0;
  applyCanvasOps(ctx, parseCanvasOps('["nope"],"junk",["fr",9,9,9,9]').ops, () => null);
  assert.deepEqual(calls, [["fillRect", 9, 9, 9, 9]]);
});

test("blocked subresources are reported instead of failing silently", async () => {
  const { blockedResources } = await loadRenderer();

  const doc = {
    querySelectorAll(selector) {
      if (selector === "img[src]") {
        return [
          { complete: true, naturalWidth: 0, src: "https://cdn.test/logo.png" },
          { complete: true, naturalWidth: 64, src: "https://cdn.test/ok.png" },
          // Still downloading: unknown, not blocked. The next snapshot decides.
          { complete: false, naturalWidth: 0, src: "https://cdn.test/slow.png" },
        ];
      }
      return [
        { sheet: null, href: "https://cdn.test/site.css" },
        { sheet: {}, href: "https://cdn.test/inline.css" },
      ];
    },
  };

  assert.deepEqual(blockedResources([doc]), [
    { kind: "image", uri: "https://cdn.test/logo.png" },
    { kind: "stylesheet", uri: "https://cdn.test/site.css" },
  ]);
  assert.deepEqual(blockedResources([{}]), []);
});

test("a missing credentialless iframe warns rather than breaking Firefox", async () => {
  const { configureResourcePolicy } = await loadRenderer();
  const warn = console.warn;
  const warnings = [];
  console.warn = (message) => warnings.push(message);
  try {
    // No "credentialless" property at all: every non-Chromium browser. Throwing
    // here used to make directResources unusable outside Chromium.
    assert.equal(configureResourcePolicy({}, { directResources: true }), "on");
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /credentialless/);

    // Opting into the strict policy still fails closed.
    assert.throws(
      () => configureResourcePolicy({}, {
        directResources: "on",
        requireCredentialless: true,
      }),
      /does not support credentialless/,
    );

    // Chromium: no warning, and the iframe is switched to credentialless.
    const chromium = { credentialless: false };
    warnings.length = 0;
    assert.equal(configureResourcePolicy(chromium, { directResources: "auto" }), "auto");
    assert.equal(chromium.credentialless, true);
    assert.deepEqual(warnings, []);

    // Turning credentialless off is the one case that must still fail closed:
    // the request would go out with the viewer's cookies.
    assert.throws(
      () => configureResourcePolicy({ credentialless: false }, {
        directResources: "on",
        credentialless: false,
      }),
      /allowCredentialedResources/,
    );
    assert.equal(
      configureResourcePolicy({ credentialless: false }, {
        directResources: "on",
        credentialless: false,
        allowCredentialedResources: true,
      }),
      "on",
    );

    // Default and alias mapping, plus a hard no on anything else.
    assert.equal(configureResourcePolicy({ credentialless: false }, {}), "off");
    assert.equal(
      configureResourcePolicy({ credentialless: false }, { directResources: false }),
      "off",
    );
    assert.throws(
      () => configureResourcePolicy({ credentialless: false }, { directResources: "maybe" }),
      /must be "on", "off" or "auto"/,
    );
  } finally {
    console.warn = warn;
  }
});

test("canvas pixels are mirrored into a replaced <img> the snapshot can lay out", async () => {
  const { mirrorCanvasPixels } = await loadRenderer();

  const makeElement = (localName) => {
    const attributes = new Map();
    return {
      localName,
      children: [],
      attributes,
      getAttribute: (name) => attributes.get(name) ?? null,
      setAttribute: (name, value) => attributes.set(name, String(value)),
      append(child) { this.children.push(child); },
      querySelector(selector) {
        const name = selector.slice(0, selector.indexOf("["));
        const attribute = selector.slice(selector.indexOf("[") + 1, -1);
        return this.children.find(
          (child) => child.localName === name && child.getAttribute(attribute) !== null,
        ) ?? null;
      },
    };
  };
  const canvas = makeElement("canvas");
  canvas.width = 480;
  canvas.height = 280;
  canvas.toDataURL = () => "data:image/png;base64,AAAA";
  canvas.style = {};
  canvas.ownerDocument = {
    createElement: makeElement,
    defaultView: { getComputedStyle: () => ({ display: "inline" }) },
  };

  const image = mirrorCanvasPixels(canvas);
  assert.equal(canvas.children.length, 1);
  assert.equal(image.localName, "img");
  // An <img> without dimensions would lay out at 0x0 in a scripting-disabled
  // document just as the canvas did.
  assert.equal(image.getAttribute("width"), "480");
  assert.equal(image.getAttribute("height"), "280");
  assert.equal(image.getAttribute("src"), "data:image/png;base64,AAAA");
  // An inline box does not wrap its block content, so the mirror would overflow
  // the canvas and page borders would land in the wrong place.
  assert.equal(canvas.style.display, "inline-block");

  // A later frame updates the same mirror instead of stacking a second one.
  canvas.toDataURL = () => "data:image/png;base64,BBBB";
  assert.equal(mirrorCanvasPixels(canvas), image);
  assert.equal(canvas.children.length, 1);
  assert.equal(image.getAttribute("src"), "data:image/png;base64,BBBB");

  // A tainted canvas throws on read; the snapshot must survive it.
  canvas.toDataURL = () => { throw new Error("tainted"); };
  assert.equal(mirrorCanvasPixels(canvas), null);
});

test("mousedown and mouseup are forwarded without coalescing", async () => {
  const original = {
    CustomEvent: globalThis.CustomEvent,
    Element: globalThis.Element,
    WebSocket: globalThis.WebSocket,
    document: globalThis.document,
    fetch: globalThis.fetch,
  };
  FakeWebSocket.instances = [];
  globalThis.CustomEvent ??= class CustomEvent extends Event {
    constructor(type, options = {}) {
      super(type);
      this.detail = options.detail;
    }
  };
  globalThis.Element = FakeElement;
  globalThis.WebSocket = FakeWebSocket;
  globalThis.document = {
    baseURI: "https://client.test/",
    createElement: () => new FakeIframe(),
    querySelector: () => null,
  };
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ ticket: "t" }) });

  const sent = [];
  FakeWebSocket.onSend = (socket, command) => {
    sent.push(command);
    if (command.type === "open") return successfulSnapshot(socket, command, "Mouse");
    queueMicrotask(() => socket.message(JSON.stringify({
      id: command.id,
      ok: true,
      snapshot: false,
      closed: false,
      can_go_back: false,
      can_go_forward: false,
      target_version: null,
      snapshot_encoding: null,
      snapshot_bytes: 0,
    })));
  };

  let browser = null;
  try {
    const { LightpandaVirtualBrowser } = await loadRenderer();
    browser = new LightpandaVirtualBrowser(new FakeElement(), {
      endpoint: "wss://renderer.test/v1/live",
      pollInterval: 60_000,
    });
    await browser.open("https://example.com/");

    const doc = browser.iframe.contentDocument;
    const mouseEvent = (overrides) => ({
      target: doc.target(),
      clientX: 12,
      clientY: 34,
      button: 0,
      buttons: 1,
      detail: 1,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false,
      preventDefault: () => {},
      ...overrides,
    });

    // Without these the far side never sees a press at all: no press-and-hold,
    // no drag, no slider.
    doc.dispatch("mousedown", mouseEvent({}));
    doc.dispatch("mouseup", mouseEvent({ buttons: 0 }));
    await waitFor(() => sent.some((command) => command.type === "mouseup"));

    const down = sent.find((command) => command.type === "mousedown");
    const up = sent.find((command) => command.type === "mouseup");
    assert.equal(down.x, 12);
    assert.equal(down.y, 34);
    assert.equal(down.buttons, 1);
    assert.equal(down.button, 0);
    assert.deepEqual(down.target, { version: "0000000000000001", id: 1 });
    assert.equal(up.buttons, 0);

    // A burst must not collapse: dropping half a pair leaves a stuck button.
    const before = sent.filter((command) => command.type === "mousedown").length;
    for (let i = 0; i < 5; i++) {
      doc.dispatch("mousedown", mouseEvent({}));
      doc.dispatch("mouseup", mouseEvent({ buttons: 0 }));
    }
    await waitFor(() => sent.filter((command) => command.type === "mouseup").length === 6);
    assert.equal(sent.filter((command) => command.type === "mousedown").length, before + 5);
  } finally {
    browser?.destroy();
    FakeWebSocket.onSend = null;
    globalThis.CustomEvent = original.CustomEvent;
    globalThis.Element = original.Element;
    globalThis.WebSocket = original.WebSocket;
    globalThis.document = original.document;
    globalThis.fetch = original.fetch;
  }
});

test("a snapshot delta rebuilds the document the server measured against", async () => {
  const { applySnapshotDelta } = await loadRenderer();
  const encode = (text) => new TextEncoder().encode(text);
  const decode = (bytes) => new TextDecoder().decode(bytes);

  const head = "<!doctype html><html><body><p>static</p>";
  const tail = "<p>tail</p></body></html>";
  const base = encode(head + "<b>0</b>" + tail);

  // The server ships the shared head length, the shared tail length and only
  // the literal bytes between them.
  const prefix = (head + "<b>").length;
  const suffix = ("</b>" + tail).length;
  const at = (body, over = {}) => applySnapshotDelta(base, encode(body).buffer, {
    prefix,
    suffix,
    base_bytes: base.byteLength,
    ...over,
  });

  assert.equal(decode(at("1")), head + "<b>1</b>" + tail);
  // Growth and shrinkage of the changed region both round-trip.
  assert.equal(decode(at("1234")), head + "<b>1234</b>" + tail);
  assert.equal(decode(at("")), head + "<b></b>" + tail);

  // Patching the wrong document would corrupt the page silently, so every way
  // the two sides can drift apart has to throw instead.
  assert.throws(
    () => applySnapshotDelta(null, encode("1").buffer, {
      prefix,
      suffix,
      base_bytes: base.byteLength,
    }),
    /does not match the held document/,
  );
  assert.throws(() => at("1", { base_bytes: base.byteLength + 1 }), /does not match/);
  assert.throws(
    () => at("1", { prefix: base.byteLength, suffix: base.byteLength }),
    /does not match/,
  );
  for (const bad of [-1, 1.5, "3", null, undefined, NaN]) {
    assert.throws(() => at("1", { prefix: bad }), /malformed|does not match/);
  }
});
