const DEFAULT_ENDPOINT = new URL("/v1/render", import.meta.url).href;

function resolveTarget(target) {
  if (typeof target === "string") target = document.querySelector(target);
  if (!(target instanceof Element)) throw new TypeError("Lightpanda renderer target not found");
  return target;
}

function configureResourcePolicy(iframe, options) {
  const directResources = options.directResources === true;
  const supportsCredentialless = "credentialless" in iframe;
  const useCredentialless = options.credentialless !== false;
  if (options.requireCredentialless && !supportsCredentialless) {
    throw new Error("This browser does not support credentialless iframes");
  }
  if (directResources &&
      (!supportsCredentialless || !useCredentialless) &&
      options.allowCredentialedResources !== true) {
    throw new Error(
      "Direct client resources require a credentialless iframe or " +
      "allowCredentialedResources: true",
    );
  }
  if (useCredentialless && supportsCredentialless) iframe.credentialless = true;
  return directResources;
}

function aborted(signal) {
  return signal.reason ?? new DOMException("Lightpanda render superseded", "AbortError");
}

function waitForFrame(iframe, url, signal, isCurrent, timeoutMs) {
  return new Promise((resolve, reject) => {
    let timer = null;
    const cleanup = () => {
      clearTimeout(timer);
      iframe.removeEventListener("load", loaded);
      iframe.removeEventListener("error", failed);
      signal.removeEventListener("abort", cancelled);
    };
    const loaded = () => {
      cleanup();
      if (!isCurrent()) reject(aborted(signal));
      else resolve();
    };
    const failed = () => {
      cleanup();
      reject(new Error("Lightpanda iframe failed to load the snapshot"));
    };
    const cancelled = () => {
      cleanup();
      reject(aborted(signal));
    };
    const timedOut = () => {
      cleanup();
      reject(new Error("Lightpanda iframe snapshot load timed out"));
    };

    if (signal.aborted) return cancelled();
    iframe.addEventListener("load", loaded, { once: true });
    iframe.addEventListener("error", failed, { once: true });
    signal.addEventListener("abort", cancelled, { once: true });
    timer = setTimeout(timedOut, timeoutMs);
    iframe.src = url;
  });
}

/**
 * Attach Lightpanda's DOM output to a real browser renderer.
 *
 * Lightpanda executes page JavaScript and returns a script-free HTML snapshot.
 * This class loads that snapshot into an opaque, fully sandboxed iframe; CSS,
 * image/font decoding, layout, paint and compositing therefore happen here in
 * the user's browser, never in the Lightpanda process.
 */
export class LightpandaRenderer extends EventTarget {
  #target;
  #endpoint;
  #token;
  #directResources;
  #controller = null;
  #inflight = null;
  #sequence = 0;
  #lastRequest = null;
  #loadTimeoutMs;

  constructor(target, options = {}) {
    super();
    this.#target = resolveTarget(target);
    this.#endpoint = new URL(options.endpoint ?? DEFAULT_ENDPOINT, document.baseURI).href;
    this.#token = options.token ?? null;
    const loadTimeoutMs = Number(options.snapshotLoadTimeout ?? options.loadTimeout ?? 10_000);
    this.#loadTimeoutMs =
      Math.max(100, Number.isFinite(loadTimeoutMs) ? loadTimeoutMs : 10_000);

    const iframe = document.createElement("iframe");
    iframe.setAttribute("sandbox", "");
    iframe.title = options.title ?? "Lightpanda rendered page";
    iframe.loading = "eager";
    iframe.referrerPolicy = "no-referrer";
    iframe.style.cssText = options.style ?? "display:block;width:100%;height:100%;border:0";
    // One-shot snapshots are intentionally inert. Their opaque sandbox keeps
    // the parent from installing an in-document anchor-navigation blocker.
    iframe.inert = true;
    iframe.tabIndex = -1;
    iframe.style.pointerEvents = "none";
    if (options.className) iframe.className = options.className;
    this.#directResources = configureResourcePolicy(iframe, options);
    this.iframe = iframe;

    if (options.replace === false) this.#target.append(iframe);
    else this.#target.replaceChildren(iframe);
  }

  render(url, options = {}) {
    // render() is not async, so an invalid URL would throw at the call site
    // instead of rejecting. Every caller uses .catch(), so reject instead.
    let source;
    try {
      source = new URL(url, document.baseURI).href;
    } catch (err) {
      return Promise.reject(err);
    }
    const bounds = this.#target.getBoundingClientRect();
    const request = {
      url: source,
      wait_ms: options.waitMs,
      wait_until: options.waitUntil,
      wait_selector: options.waitSelector,
      width: Math.max(1, Math.round((options.width ?? bounds.width) || 1280)),
      height: Math.max(1, Math.round((options.height ?? bounds.height) || 720)),
      direct_resources: this.#directResources,
    };
    for (const key of Object.keys(request)) {
      if (request[key] == null) delete request[key];
    }
    const body = JSON.stringify(request);
    if (this.#inflight?.body === body) return this.#inflight.promise;

    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;
    this.#lastRequest = { url: source, options: { ...options } };

    const inflight = { body, promise: null };
    this.#inflight = inflight;
    inflight.promise = this.#render(source, body, controller, sequence, inflight);
    return inflight.promise;
  }

  async #render(source, body, controller, sequence, inflight) {
    let pendingBlobUrl = null;
    try {
      const headers = { accept: "text/html", "content-type": "application/json" };
      if (this.#token) headers.authorization = `Bearer ${this.#token}`;
      const response = await fetch(this.#endpoint, {
        method: "POST",
        headers,
        body,
        credentials: "omit",
        signal: controller.signal,
      });
      if (!response.ok) {
        const detail = (await response.text()).slice(0, 512);
        throw new Error(`Lightpanda render failed (${response.status}): ${detail}`);
      }

      const blob = await response.blob();
      if (sequence !== this.#sequence) throw aborted(controller.signal);

      pendingBlobUrl = URL.createObjectURL(blob);
      await waitForFrame(
        this.iframe,
        pendingBlobUrl,
        controller.signal,
        () => sequence === this.#sequence,
        this.#loadTimeoutMs,
      );
      URL.revokeObjectURL(pendingBlobUrl);
      pendingBlobUrl = null;
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      this.dispatchEvent(new CustomEvent("render", { detail: { url: source } }));
      return this.iframe;
    } catch (error) {
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("rendererror", { detail: error }));
      }
      throw error;
    } finally {
      if (pendingBlobUrl) URL.revokeObjectURL(pendingBlobUrl);
      if (this.#controller === controller) this.#controller = null;
      if (this.#inflight === inflight) this.#inflight = null;
    }
  }

  refresh(options = undefined) {
    if (!this.#lastRequest) throw new Error("render() must be called before refresh()");
    return this.render(
      this.#lastRequest.url,
      options ? { ...this.#lastRequest.options, ...options } : this.#lastRequest.options,
    );
  }

  destroy() {
    ++this.#sequence;
    this.#controller?.abort();
    this.#controller = null;
    this.#inflight = null;
    this.iframe.remove();
  }
}

export function attachLightpandaRenderer(target, options) {
  return new LightpandaRenderer(target, options);
}

function liveEndpoints(endpoint, ticketEndpoint) {
  const base = endpoint ? document.baseURI : import.meta.url;
  const control = new URL(endpoint ?? "/v1/live", base);
  const websocket = new URL(control);
  const ticket = new URL(ticketEndpoint ?? "/v1/live-ticket", control);
  if (websocket.protocol === "http:") websocket.protocol = "ws:";
  if (websocket.protocol === "https:") websocket.protocol = "wss:";
  if (ticket.protocol === "ws:") ticket.protocol = "http:";
  if (ticket.protocol === "wss:") ticket.protocol = "https:";
  return { websocket: websocket.href, ticket: ticket.href };
}

function liveNavigationCommand(type) {
  return type === "open" ||
    type === "navigate" ||
    type === "back" ||
    type === "forward" ||
    type === "reload";
}

function supportedSnapshotEncodings() {
  const encodings = [];
  if (typeof DecompressionStream === "function") {
    for (const encoding of ["br", "gzip"]) {
      try {
        new DecompressionStream(encoding);
        encodings.push(encoding);
      } catch {}
    }
  }
  encodings.push("identity");
  return encodings;
}

async function decodeSnapshot(data, encoding, expectedBytes) {
  const input = typeof Blob !== "undefined" && data instanceof Blob
    ? await data.arrayBuffer()
    : data;
  if (!(input instanceof ArrayBuffer)) {
    throw new Error("Lightpanda live snapshot is not an ArrayBuffer");
  }

  let output = input;
  if (encoding !== "identity") {
    const stream = new Blob([input]).stream().pipeThrough(
      new DecompressionStream(encoding),
    );
    output = await new Response(stream).arrayBuffer();
  }
  if (output.byteLength !== expectedBytes) {
    throw new Error("Lightpanda live snapshot size does not match metadata");
  }
  return output;
}

/**
 * Rebuild a full snapshot from the frame this connection already holds.
 *
 * The server re-serializes the whole document on every update, so it sends only
 * the region that moved: a shared head length, a shared tail length, and the
 * literal bytes between them. `base_bytes` is checked rather than trusted --
 * patching the wrong document would corrupt the page silently, so a desync has
 * to surface as an error and close the socket.
 */
export function applySnapshotDelta(base, body, delta) {
  const { prefix, suffix, base_bytes: baseBytes } = delta;
  for (const value of [prefix, suffix, baseBytes]) {
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new Error("Lightpanda live snapshot delta is malformed");
    }
  }
  if (base == null || base.byteLength !== baseBytes ||
      prefix + suffix > base.byteLength) {
    throw new Error("Lightpanda live snapshot delta does not match the held document");
  }
  const patch = new Uint8Array(body);
  const rebuilt = new Uint8Array(prefix + patch.byteLength + suffix);
  rebuilt.set(base.subarray(0, prefix), 0);
  rebuilt.set(patch, prefix);
  rebuilt.set(base.subarray(base.byteLength - suffix), prefix + patch.byteLength);
  return rebuilt;
}

function editableValueElement(element) {
  if (element?.nodeType !== 1) return false;
  if (element.localName === "textarea" || element.localName === "select") return true;
  if (element.localName !== "input") return false;
  return !["button", "checkbox", "file", "hidden", "image", "radio", "reset", "submit"]
    .includes(element.type);
}

// Any surface the viewer edits with a local caret. `editableValueElement` stays
// the narrower "has a .value we can read and fill" test.
// ponytail: contenteditable text is not written back — the fill command only
// understands input/textarea/select. Keys still reach the page's listeners.
function editableTextElement(element) {
  if (editableValueElement(element)) return true;
  return element?.nodeType === 1 && element.isContentEditable === true;
}

// Keystrokes the browser applies locally and the debounced `fill` syncs.
// Forwarding these as well would double-insert them in Lightpanda.
function localTextEditKey(event, element) {
  if (!editableTextElement(element) || element.localName === "select") return false;
  if (event.ctrlKey || event.metaKey || event.altKey) return false;
  return event.key.length === 1 ||
    event.key === "Enter" ||
    event.key === "Backspace" ||
    event.key === "Delete";
}

// Suppressing the local default keeps the remote view authoritative for
// scrolling and activation, but must not steal the viewer's own browser
// shortcuts (copy/paste, reload) or fight sequential focus navigation, which
// both sides derive from the same DOM order.
function preventLocalKeyDefault(event, element) {
  if (event.ctrlKey || event.metaKey) return false;
  if (event.key === "Tab") return false;
  return !editableTextElement(element);
}

function browserOwnedClickDefault(element) {
  if (editableTextElement(element)) return true;
  if (element?.localName === "input" &&
      (element.type === "checkbox" || element.type === "radio")) return true;
  return element?.closest?.("summary") != null;
}

function snapshotDocuments(root) {
  const documents = [];
  const pending = [root];
  const seen = new Set();
  while (pending.length > 0) {
    const doc = pending.shift();
    if (!doc || seen.has(doc)) continue;
    seen.add(doc);
    documents.push(doc);
    for (const iframe of doc.querySelectorAll("iframe[data-lightpanda-live-frame]")) {
      try {
        if (iframe.contentDocument) pending.push(iframe.contentDocument);
      } catch {}
    }
  }
  return documents;
}

// Lightpanda has no rasterizer, so a <canvas> can never arrive as pixels. The
// server records the 2D op stream instead and we replay it here, onto the real
// canvas in the viewer's browser. Ops are cumulative: each snapshot carries only
// what was drawn since the last one, so an animation costs a constant number of
// bytes per frame.
const CANVAS_OPS_ATTR = "data-lp-canvas";

const CANVAS_OP_METHODS = {
  sv: "save", rs: "restore",
  sc: "scale", ro: "rotate", tr: "translate",
  tf: "transform", st: "setTransform", rt: "resetTransform",
  cr: "clearRect", fr: "fillRect", sr: "strokeRect",
  bp: "beginPath", cp: "closePath", mv: "moveTo", ln: "lineTo",
  qc: "quadraticCurveTo", bc: "bezierCurveTo", ar: "arc", at: "arcTo", re: "rect",
  fl: "fill", sk: "stroke", cl: "clip",
  ft: "fillText", sx: "strokeText",
};

const CANVAS_OP_PROPERTIES = {
  FS: "fillStyle", SS: "strokeStyle", LW: "lineWidth", GA: "globalAlpha", FO: "font",
};

// A leading "!" means the server's bounded log overflowed and dropped ops, so
// the replay is knowingly incomplete.
export function parseCanvasOps(value) {
  const truncated = value.startsWith("!");
  const body = truncated ? value.slice(1) : value;
  if (body.trim() === "") return { truncated, ops: [] };
  const ops = JSON.parse(`[${body}]`);
  if (!Array.isArray(ops)) throw new TypeError("Lightpanda canvas ops are not an array");
  return { truncated, ops };
}

export function applyCanvasOps(ctx, ops, imageFor) {
  for (const op of ops) {
    if (!Array.isArray(op) || op.length === 0) continue;
    const [name, ...args] = op;
    try {
      if (name === "z") {
        // Full-canvas clear: the server collapsed its log here, so the client
        // must start from an empty canvas to stay in step.
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
        ctx.beginPath();
        continue;
      }
      if (name === "di") {
        const [src, ...rest] = args;
        if (typeof src !== "string" || typeof imageFor !== "function") continue;
        const image = imageFor(src);
        if (!image) continue;
        if (image.complete && image.naturalWidth > 0) {
          ctx.drawImage(image, ...rest);
        } else {
          // First paint of a sprite races its download. Redrawing on load keeps
          // the pixel there; later frames hit the cache and draw synchronously.
          image.addEventListener("load", () => {
            try {
              ctx.drawImage(image, ...rest);
            } catch {}
          }, { once: true });
        }
        continue;
      }
      const property = CANVAS_OP_PROPERTIES[name];
      if (property) {
        ctx[property] = args[0];
        continue;
      }
      const method = CANVAS_OP_METHODS[name];
      if (method) ctx[method](...args);
    } catch {
      // One bad op must not abandon the rest of the frame.
    }
  }
}

function sameSnapshotElement(current, fresh, currentKeys, keyMarker) {
  if (current?.nodeType !== 1 || fresh?.nodeType !== 1) return false;
  if (current.namespaceURI !== fresh.namespaceURI ||
      current.localName !== fresh.localName) return false;
  const freshKey = fresh.getAttribute(keyMarker);
  const currentKey = currentKeys.get(current);
  return freshKey === null ? currentKey == null : currentKey === freshKey;
}

function syncSnapshotAttributes(current, fresh, keepSrcdoc) {
  for (const attribute of [...current.attributes]) {
    if (keepSrcdoc && attribute.namespaceURI == null &&
        attribute.localName === "srcdoc") continue;
    const present = attribute.namespaceURI == null
      ? fresh.hasAttribute(attribute.name)
      : fresh.hasAttributeNS(attribute.namespaceURI, attribute.localName);
    if (present) continue;
    if (attribute.namespaceURI == null) current.removeAttribute(attribute.name);
    else current.removeAttributeNS(attribute.namespaceURI, attribute.localName);
  }
  for (const attribute of fresh.attributes) {
    if (keepSrcdoc && attribute.namespaceURI == null &&
        attribute.localName === "srcdoc") continue;
    const value = attribute.namespaceURI == null
      ? current.getAttribute(attribute.name)
      : current.getAttributeNS(attribute.namespaceURI, attribute.localName);
    if (value === attribute.value) continue;
    current.setAttributeNS(attribute.namespaceURI, attribute.name, attribute.value);
  }
}

function syncSnapshotControlState(current, fresh) {
  if (current.localName === "input") {
    if (current.type !== "file" && current.value !== fresh.value) {
      current.value = fresh.value;
    }
    current.checked = fresh.checked;
    current.indeterminate =
      fresh.hasAttribute("data-lightpanda-live-indeterminate");
  } else if (current.localName === "textarea") {
    if (current.value !== fresh.value) current.value = fresh.value;
  } else if (current.localName === "select") {
    const selectedIndex =
      fresh.hasAttribute("data-lightpanda-live-selected-none")
        ? -1
        : fresh.selectedIndex;
    if (current.selectedIndex !== selectedIndex) current.selectedIndex = selectedIndex;
  } else if (current.localName === "option") {
    current.selected = fresh.selected;
  }
}

function reconcileSnapshotElement(
  current,
  fresh,
  currentKeys,
  currentElements,
  keyMarker,
  framePairs,
) {
  const liveFrame =
    current.localName === "iframe" &&
    fresh.localName === "iframe" &&
    current.hasAttribute("data-lightpanda-live-frame") &&
    fresh.hasAttribute("data-lightpanda-live-frame");
  syncSnapshotAttributes(current, fresh, liveFrame);
  if (liveFrame) {
    if (!current.contentDocument || !fresh.contentDocument) {
      throw new Error("Lightpanda live frame cannot be reconciled");
    }
    framePairs.push([current.contentDocument, fresh.contentDocument]);
    return;
  }
  reconcileSnapshotChildren(
    current,
    fresh,
    currentKeys,
    currentElements,
    keyMarker,
    framePairs,
  );
  syncSnapshotControlState(current, fresh);
}

function reconcileSnapshotChildren(
  current,
  fresh,
  currentKeys,
  currentElements,
  keyMarker,
  framePairs,
) {
  let cursor = current.firstChild;
  for (const freshChild of [...fresh.childNodes]) {
    let match = null;
    if (freshChild.nodeType === 1) {
      const key = freshChild.getAttribute(keyMarker);
      const keyed = key == null ? null : currentElements.get(key);
      if (sameSnapshotElement(keyed, freshChild, currentKeys, keyMarker)) {
        if (keyed.ownerDocument !== current.ownerDocument ||
            keyed === current ||
            keyed.contains(current)) {
          throw new Error("Lightpanda keyed node cannot be moved safely");
        }
        match = keyed;
      } else if (sameSnapshotElement(cursor, freshChild, currentKeys, keyMarker)) {
        match = cursor;
      }
    } else if (cursor?.nodeType === freshChild.nodeType &&
        (freshChild.nodeType === 3 || freshChild.nodeType === 8)) {
      match = cursor;
    }

    if (match == null) {
      match = current.ownerDocument.importNode(freshChild, true);
      current.insertBefore(match, cursor);
    } else {
      if (match !== cursor) {
        if (typeof current.moveBefore !== "function") {
          throw new Error("This browser cannot preserve a moved live node");
        }
        current.moveBefore(match, cursor);
      }
      if (match.nodeType === 1) {
        reconcileSnapshotElement(
          match,
          freshChild,
          currentKeys,
          currentElements,
          keyMarker,
          framePairs,
        );
      } else if (match.data !== freshChild.data) {
        match.data = freshChild.data;
      }
    }
    cursor = match.nextSibling;
  }
  while (cursor) {
    const next = cursor.nextSibling;
    cursor.remove();
    cursor = next;
  }
}

function animationSnapshotSignature(element) {
  const html = element.outerHTML;
  let hash = 2_166_136_261;
  for (let i = 0; i < html.length; i++) {
    hash = Math.imul(hash ^ html.charCodeAt(i), 16_777_619);
  }
  return `${html.length}:${hash >>> 0}`;
}

function deepestActiveElement(root) {
  let doc = root;
  let element = doc?.activeElement ?? null;
  while (element?.matches?.("iframe[data-lightpanda-live-frame]")) {
    try {
      doc = element.contentDocument;
    } catch {
      break;
    }
    if (!doc) break;
    element = doc.activeElement;
  }
  return { doc, element };
}

/**
 * Attach an interactive Lightpanda live session to a browser iframe.
 *
 * The iframe may share the parent origin so interactions can be captured, but
 * scripts remain disabled by the sandbox. Lightpanda remains the sole runtime.
 */
export class LightpandaVirtualBrowser extends EventTarget {
  #target;
  #endpoint;
  #ticketEndpoint;
  #token;
  #snapshotEncodings;
  #directResources;
  #socket = null;
  #connecting = null;
  #pending = null;
  #tail = Promise.resolve();
  #nextId = 0;
  #pollMs;
  #maxPollMs;
  #pollDelayMs;
  #pollTimer = null;
  #polling = false;
  #reconnectTimer = null;
  #reconnectDelayMs = 250;
  #reconnecting = false;
  #lastOpenPayload = null;
  #opened = false;
  #destroyed = false;
  #closeDispatched = false;
  #captureCleanup = [];
  #editTimers = new Map();
  #dirtyEdits = new Map();
  #scrollTimer = null;
  #cancelFrame = null;
  #scrollX = 0;
  #scrollY = 0;
  #scrollOffsets = new Map();
  #hoverKey = null;
  #coalescedPayloads = new Map();
  #coalescedPending = new Map();
  #connectController = null;
  #connectTimeoutMs;
  #commandTimeoutMs;
  #lastSnapshotBytes = 0;
  // The last full snapshot this connection reconstructed. Deltas are measured
  // against it server-side, so the two copies must stay in lockstep; the server
  // keeps its base per connection, so this resets with the socket.
  #snapshotBase = null;
  #snapshotLoadTimeoutMs;
  #viewEpoch = 0;
  #lifecycleToken = 0;
  #opening = 0;
  #targetVersion = null;
  #targetIds = new WeakMap();
  #targetKeys = new WeakMap();
  #targetElements = [];
  #continuityTargets = new Map();
  #authoritativeValues = new Map();
  #animationSignatures = new Map();
  #canvasImages = new Map();
  #url = null;
  #title = "";
  #canGoBack = false;
  #canGoForward = false;

  constructor(target, options = {}) {
    super();
    this.#target = resolveTarget(target);
    const endpoints = liveEndpoints(options.endpoint, options.ticketEndpoint);
    this.#endpoint = endpoints.websocket;
    this.#ticketEndpoint = endpoints.ticket;
    this.#token = options.token ?? null;
    this.#snapshotEncodings = supportedSnapshotEncodings();
    const pollMs = Number(options.pollInterval ?? options.snapshotInterval ?? 500);
    this.#pollMs = Math.max(100, Number.isFinite(pollMs) ? pollMs : 500);
    this.#maxPollMs = Math.max(this.#pollMs, 2_000);
    this.#pollDelayMs = this.#pollMs;
    const connectTimeoutMs = Number(options.connectTimeout ?? 10_000);
    this.#connectTimeoutMs =
      Math.max(100, Number.isFinite(connectTimeoutMs) ? connectTimeoutMs : 10_000);
    const commandTimeoutMs = Number(options.commandTimeout ?? 15_000);
    this.#commandTimeoutMs =
      Math.max(100, Number.isFinite(commandTimeoutMs) ? commandTimeoutMs : 15_000);
    const loadTimeoutMs = Number(options.snapshotLoadTimeout ?? 10_000);
    this.#snapshotLoadTimeoutMs =
      Math.max(100, Number.isFinite(loadTimeoutMs) ? loadTimeoutMs : 10_000);

    const iframe = document.createElement("iframe");
    iframe.setAttribute("sandbox", "allow-same-origin");
    iframe.title = options.title ?? "Lightpanda virtual browser";
    iframe.loading = "eager";
    iframe.referrerPolicy = "no-referrer";
    iframe.style.cssText = options.style ?? "display:block;width:100%;height:100%;border:0";
    if (options.className) iframe.className = options.className;
    this.#directResources = configureResourcePolicy(iframe, options);
    this.iframe = iframe;

    if (options.replace === false) this.#target.append(iframe);
    else this.#target.replaceChildren(iframe);
  }

  async #connect() {
    if (this.#destroyed) throw new Error("Lightpanda virtual browser is destroyed");
    if (this.#socket?.readyState === WebSocket.OPEN) return this.#socket;
    if (this.#connecting) return this.#connecting;

    const connecting = this.#replaceSocket();
    this.#connecting = connecting;
    try {
      return await connecting;
    } finally {
      if (this.#connecting === connecting) this.#connecting = null;
    }
  }

  async #replaceSocket() {
    const previous = this.#socket;
    if (previous) {
      await new Promise((resolve, reject) => {
        let timer = null;
        const cleanup = () => {
          clearTimeout(timer);
          previous.removeEventListener("close", closed);
        };
        const closed = () => {
          cleanup();
          resolve();
        };
        previous.addEventListener("close", closed, { once: true });
        timer = setTimeout(() => {
          cleanup();
          reject(new Error("Lightpanda live WebSocket close timed out"));
        }, this.#connectTimeoutMs);
        if (this.#socket !== previous) closed();
      });
    }
    if (this.#destroyed) throw new Error("Lightpanda virtual browser is destroyed");
    return this.#openSocket();
  }

  async #openSocket() {
    const controller = new AbortController();
    this.#connectController = controller;
    const timeout = setTimeout(() => {
      controller.abort(new Error("Lightpanda live connection timed out"));
    }, this.#connectTimeoutMs);
    let socket = null;
    const headers = { accept: "application/json" };
    if (this.#token) headers.authorization = `Bearer ${this.#token}`;
    try {
      const response = await fetch(this.#ticketEndpoint, {
        method: "POST",
        headers,
        credentials: "omit",
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) {
        const detail = (await response.text()).slice(0, 512);
        throw new Error(`Lightpanda live ticket failed (${response.status}): ${detail}`);
      }
      const body = await response.json();
      if (typeof body.ticket !== "string" || body.ticket.length > 128) {
        throw new Error("Lightpanda live ticket response is invalid");
      }
      if (this.#destroyed) throw new Error("Lightpanda virtual browser is destroyed");

      const endpoint = new URL(this.#endpoint);
      endpoint.searchParams.set("ticket", body.ticket);
      endpoint.searchParams.set("snapshot_encodings", this.#snapshotEncodings.join(","));
      socket = new WebSocket(endpoint);
      socket.binaryType = "arraybuffer";
      this.#socket = socket;
      this.#closeDispatched = false;
      // A fresh connection starts with an empty base on both ends.
      this.#snapshotBase = null;
      socket.addEventListener("message", (event) => this.#onMessage(socket, event));
      socket.addEventListener("close", () => this.#onSocketClose(socket));

      await new Promise((resolve, reject) => {
        const opened = () => {
          cleanup();
          resolve();
        };
        const failed = () => {
          cleanup();
          reject(new Error("Lightpanda live WebSocket failed to connect"));
        };
        const cancelled = () => {
          cleanup();
          reject(controller.signal.reason);
        };
        const cleanup = () => {
          socket.removeEventListener("open", opened);
          socket.removeEventListener("error", failed);
          socket.removeEventListener("close", failed);
          controller.signal.removeEventListener("abort", cancelled);
        };
        socket.addEventListener("open", opened, { once: true });
        socket.addEventListener("error", failed, { once: true });
        socket.addEventListener("close", failed, { once: true });
        controller.signal.addEventListener("abort", cancelled, { once: true });
      });
      return socket;
    } catch (error) {
      if (this.#socket === socket) this.#socket = null;
      socket?.close();
      throw error;
    } finally {
      clearTimeout(timeout);
      if (this.#connectController === controller) this.#connectController = null;
    }
  }

  #onSocketClose(socket) {
    if (this.#socket !== socket) return;
    const shouldReconnect =
      !this.#destroyed &&
      this.#lastOpenPayload !== null;
    const error = new Error("Lightpanda live WebSocket closed");
    this.#cancelFrame?.(error);
    this.#rejectPending(error);
    this.#socket = null;
    this.#opened = false;
    this.#stopPolling();
    this.#detachCapture();
    this.iframe.inert = true;
    this.#clearEdits();
    this.#clearTargets();
    this.#clearScrollTimer();
    if (shouldReconnect) {
      if (!this.#reconnecting) {
        this.dispatchEvent(new CustomEvent("reconnecting", {
          detail: { delay: this.#reconnectDelayMs },
        }));
        this.#scheduleReconnect();
      }
    } else {
      this.#dispatchClose();
    }
  }

  #scheduleReconnect() {
    if (this.#reconnectTimer !== null ||
        this.#destroyed ||
        this.#lastOpenPayload === null) return;
    const payload = this.#lastOpenPayload;
    const lifecycleToken = this.#lifecycleToken;
    const delay = this.#reconnectDelayMs;
    this.#reconnectTimer = setTimeout(async () => {
      this.#reconnectTimer = null;
      if (this.#destroyed ||
          lifecycleToken !== this.#lifecycleToken ||
          payload !== this.#lastOpenPayload) return;
      this.#reconnecting = true;
      ++this.#opening;
      try {
        const response = await this.#enqueueLifecycle("open", payload);
        if (payload !== this.#lastOpenPayload) return;
        if (!this.#opened || this.#socket?.readyState !== WebSocket.OPEN) {
          this.#reconnectDelayMs = Math.min(2_000, delay * 2);
          this.#scheduleReconnect();
          return;
        }
        this.#reconnectDelayMs = 250;
        this.dispatchEvent(new CustomEvent("reconnect", { detail: { response } }));
      } catch {
        if (!this.#destroyed &&
            lifecycleToken === this.#lifecycleToken &&
            payload === this.#lastOpenPayload) {
          this.#reconnectDelayMs = Math.min(2_000, delay * 2);
          this.#scheduleReconnect();
        }
      } finally {
        --this.#opening;
        this.#reconnecting = false;
      }
    }, delay);
  }

  #cancelReconnect(clearRequest = false) {
    clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = null;
    this.#reconnectDelayMs = 250;
    this.#reconnecting = false;
    if (clearRequest) this.#lastOpenPayload = null;
  }

  #takePending(expected = this.#pending) {
    if (!expected || this.#pending !== expected) return null;
    clearTimeout(expected.timer);
    this.#pending = null;
    return expected;
  }

  #rejectPending(error, expected = this.#pending) {
    const pending = this.#takePending(expected);
    pending?.reject(error);
  }

  #protocolError(socket, message) {
    const error = new Error(message);
    this.#cancelFrame?.(error);
    this.#rejectPending(error);
    if (this.#socket === socket && socket.readyState <= WebSocket.OPEN) {
      socket.close(1002, "Lightpanda protocol error");
    }
  }

  #onMessage(socket, event) {
    if (this.#socket !== socket) return;
    const pending = this.#pending;
    if (!pending) {
      this.#protocolError(socket, "Lightpanda live WebSocket returned an unsolicited frame");
      return;
    }

    if (typeof event.data === "string") {
      if (pending.response) {
        this.#protocolError(socket, "Lightpanda live WebSocket returned duplicate metadata");
        return;
      }
      let response;
      try {
        response = JSON.parse(event.data);
      } catch {
        this.#protocolError(socket, "Lightpanda live WebSocket returned invalid JSON");
        return;
      }
      if (!response || typeof response !== "object" || Array.isArray(response) ||
          !Number.isInteger(response.id) || typeof response.ok !== "boolean") {
        this.#protocolError(socket, "Lightpanda live WebSocket returned invalid metadata");
        return;
      }
      if (response.id !== pending.id) {
        this.#protocolError(
          socket,
          `Lightpanda live response id mismatch: expected ${pending.id}, got ${response.id}`,
        );
        return;
      }
      if (!response.ok) {
        if (typeof response.error !== "string") {
          this.#protocolError(socket, "Lightpanda live WebSocket returned an invalid error");
          return;
        }
        this.#rejectPending(new Error(response.error), pending);
        return;
      }
      if (typeof response.snapshot !== "boolean" || typeof response.closed !== "boolean") {
        this.#protocolError(socket, "Lightpanda live WebSocket returned invalid success metadata");
        return;
      }
      if (response.warning != null && typeof response.warning !== "string") {
        this.#protocolError(socket, "Lightpanda live WebSocket returned an invalid warning");
        return;
      }
      const expectsClose = pending.type === "close";
      // A degraded snapshot (too large to serialize) answers with a warning
      // instead of a document, including for navigations.
      const expectsSnapshot = liveNavigationCommand(pending.type) &&
        typeof response.warning !== "string";
      if (response.closed !== expectsClose ||
          (expectsClose && response.snapshot) ||
          (expectsSnapshot && !response.snapshot)) {
        this.#protocolError(socket, "Lightpanda live WebSocket returned inconsistent success metadata");
        return;
      }
      if (typeof response.can_go_back !== "boolean" ||
          typeof response.can_go_forward !== "boolean") {
        this.#protocolError(socket, "Lightpanda live WebSocket returned invalid history state");
        return;
      }
      if (response.snapshot) {
        if (typeof response.target_version !== "string" ||
            !/^[0-9a-f]{16}$/.test(response.target_version) ||
            response.target_version === "0000000000000000") {
          this.#protocolError(socket, "Lightpanda live WebSocket returned an invalid target version");
          return;
        }
        if (!this.#snapshotEncodings.includes(response.snapshot_encoding) ||
            !Number.isSafeInteger(response.snapshot_bytes) ||
            response.snapshot_bytes < 0) {
          this.#protocolError(socket, "Lightpanda live WebSocket returned invalid snapshot encoding metadata");
          return;
        }
        const delta = response.snapshot_delta;
        if (delta != null && (typeof delta !== "object" ||
            !Number.isSafeInteger(delta.prefix) || delta.prefix < 0 ||
            !Number.isSafeInteger(delta.suffix) || delta.suffix < 0 ||
            !Number.isSafeInteger(delta.base_bytes) || delta.base_bytes < 0)) {
          this.#protocolError(socket, "Lightpanda live WebSocket returned an invalid snapshot delta");
          return;
        }
        pending.response = response;
        return;
      }
      if (response.target_version !== null ||
          response.snapshot_encoding !== null ||
          response.snapshot_delta != null ||
          response.snapshot_bytes !== 0) {
        this.#protocolError(socket, "Lightpanda live WebSocket returned unexpected snapshot metadata");
        return;
      }
      this.#takePending(pending)?.resolve({
        response,
        superseded: pending.viewEpoch !== this.#viewEpoch,
      });
      return;
    }

    if (!pending.response?.snapshot) {
      this.#protocolError(socket, "Lightpanda live WebSocket returned an unexpected binary frame");
      return;
    }
    if (!(event.data instanceof ArrayBuffer) &&
        !(typeof Blob !== "undefined" && event.data instanceof Blob)) {
      this.#protocolError(socket, "Lightpanda live WebSocket returned invalid snapshot data");
      return;
    }
    if (pending.receiving) {
      this.#protocolError(socket, "Lightpanda live WebSocket returned duplicate snapshot data");
      return;
    }

    const response = pending.response;
    pending.receiving = true;
    const superseded = pending.viewEpoch !== this.#viewEpoch;
    decodeSnapshot(
      event.data,
      response.snapshot_encoding,
      response.snapshot_bytes,
    ).then((body) => {
      // The server measures its next delta against the frame it just sent, so
      // the base has to advance even for a frame this view will never paint.
      // Skipping it here would desynchronize every later delta.
      const full = response.snapshot_delta == null
        ? new Uint8Array(body)
        : applySnapshotDelta(this.#snapshotBase, body, response.snapshot_delta);
      this.#snapshotBase = full;
      if (superseded) return undefined;
      return this.#swapSnapshot(
        full.buffer,
        response.target_version,
        liveNavigationCommand(pending.type),
        pending.context,
        () => this.#pending === pending &&
          this.#socket === socket &&
          pending.viewEpoch === this.#viewEpoch,
      );
    }).then(
      () => {
        if (superseded) {
          this.#takePending(pending)?.resolve({ response, superseded: true });
          return;
        }
        const page = this.#readPageState();
        response.url = page.url;
        response.title = page.title;
        this.#takePending(pending)?.resolve({ response, superseded: false });
      },
      (error) => {
        if (this.#pending !== pending) return;
        if (error?.name === "AbortError") {
          this.#takePending(pending)?.resolve({ response, superseded: true });
          return;
        }
        this.#rejectPending(error, pending);
        if (this.#socket === socket && socket.readyState <= WebSocket.OPEN) {
          socket.close(1002, "Lightpanda snapshot error");
        }
      },
    );
  }

  async #swapSnapshot(data, targetVersion, replaceView, context, isCurrent) {
    this.#lastSnapshotBytes = data?.byteLength ?? data?.size ?? 0;
    const bytes = typeof Blob !== "undefined" && data instanceof Blob
      ? await data.arrayBuffer()
      : data;
    if (!(bytes instanceof ArrayBuffer)) {
      throw new Error("Lightpanda live snapshot is not an ArrayBuffer");
    }
    if (!isCurrent()) {
      throw new DOMException("Lightpanda live snapshot was superseded", "AbortError");
    }

    const previousFrame = this.iframe;
    const nextFrame = previousFrame.cloneNode(false);
    nextFrame.inert = false;
    nextFrame.removeAttribute("inert");
    const frameStyle = nextFrame.getAttribute("style");
    if ("credentialless" in previousFrame && previousFrame.credentialless) {
      nextFrame.credentialless = true;
    }
    nextFrame.style.display = "none";
    nextFrame.removeAttribute("src");
    nextFrame.removeAttribute("srcdoc");

    const html = new TextDecoder().decode(bytes);
    let committed = false;
    const focus = replaceView ? null : this.#captureFocus();

    if (!replaceView) {
      try {
        const fresh = new DOMParser().parseFromString(html, "text/html");
        const inertFrame = { contentDocument: fresh };
        if (this.#canReconcileSnapshot(previousFrame, inertFrame, targetVersion)) {
          this.#detachCapture();
          this.#reconcileSnapshot(previousFrame, inertFrame, targetVersion);
          this.#hydrateSnapshot(previousFrame, targetVersion, context);
          this.#attachCapture(focus);
          committed = true;
          return;
        }
      } catch {
        // Nested frame trees and unsafe merges use the isolated iframe fallback.
      }
    }

    try {
      await new Promise((resolve, reject) => {
        let timer = null;
        const cleanup = () => {
          clearTimeout(timer);
          nextFrame.removeEventListener("load", loaded);
          nextFrame.removeEventListener("error", failed);
          this.#cancelFrame = null;
        };
        const loaded = () => {
          cleanup();
          resolve();
        };
        const failed = () => {
          cleanup();
          reject(new Error("Lightpanda iframe failed to load the live snapshot"));
        };
        const timedOut = () => {
          cleanup();
          reject(new Error("Lightpanda iframe live snapshot load timed out"));
        };
        this.#cancelFrame = (error) => {
          cleanup();
          reject(error);
        };
        nextFrame.addEventListener("load", loaded, { once: true });
        nextFrame.addEventListener("error", failed, { once: true });
        timer = setTimeout(timedOut, this.#snapshotLoadTimeoutMs);
        nextFrame.srcdoc = html;
        previousFrame.after(nextFrame);
        if (!nextFrame.isConnected) {
          cleanup();
          reject(new Error("Lightpanda live iframe is not connected"));
        }
      });
      if (this.#destroyed || !isCurrent()) {
        throw new DOMException("Lightpanda live snapshot was superseded", "AbortError");
      }

      if (replaceView) {
        this.#clearEdits();
        this.#clearScrollTimer();
        this.#scrollOffsets.clear();
        this.#scrollX = 0;
        this.#scrollY = 0;
      }
      if (!replaceView && this.#canReconcileSnapshot(previousFrame, nextFrame, targetVersion)) {
        this.#detachCapture();
        try {
          this.#reconcileSnapshot(previousFrame, nextFrame, targetVersion);
          this.#hydrateSnapshot(previousFrame, targetVersion, context);
          this.#attachCapture(focus);
          nextFrame.remove();
          committed = true;
          return;
        } catch {
          // The staging frame is untouched. If a merge is unsafe, the normal
          // whole-frame commit below remains an atomic fallback.
        }
      }
      this.#hydrateSnapshot(nextFrame, targetVersion, context);
      this.#installNavigationBlocker(nextFrame.contentDocument);
      this.#detachCapture();
      if (frameStyle == null) nextFrame.removeAttribute("style");
      else nextFrame.setAttribute("style", frameStyle);
      this.iframe = nextFrame;
      previousFrame.remove();
      this.#attachCapture(focus);
      committed = true;
    } finally {
      if (!committed) nextFrame.remove();
    }
  }

  #canReconcileSnapshot(previousFrame, nextFrame, targetVersion) {
    const current = previousFrame.contentDocument;
    const fresh = nextFrame.contentDocument;
    if (!current?.documentElement || !fresh?.documentElement) return false;
    if (current.documentElement.namespaceURI !== fresh.documentElement.namespaceURI ||
        current.documentElement.localName !== fresh.documentElement.localName) return false;

    const currentDocuments = snapshotDocuments(current);
    const freshDocuments = snapshotDocuments(fresh);
    if (currentDocuments.length !== freshDocuments.length) return false;
    const keyMarker = `data-lp-k-${targetVersion}`;
    if (this.#targetKeys.get(current.documentElement) !==
        fresh.documentElement.getAttribute(keyMarker)) return false;
    const keys = new Set();
    for (const document of freshDocuments) {
      for (const element of document.querySelectorAll(`[${keyMarker}]`)) {
        const key = element.getAttribute(keyMarker);
        if (!/^[0-9a-f]{16}$/.test(key ?? "") || keys.has(key)) return false;
        keys.add(key);
      }
    }
    const currentFrames = currentDocuments.flatMap((document) => [
      ...document.querySelectorAll("iframe[data-lightpanda-live-frame]"),
    ]);
    const freshFrames = freshDocuments.flatMap((document) => [
      ...document.querySelectorAll("iframe[data-lightpanda-live-frame]"),
    ]);
    if (currentFrames.length !== freshFrames.length) return false;
    for (const frame of freshFrames) {
      const key = frame.getAttribute(keyMarker);
      const currentFrame = this.#continuityTargets.get(key)?.element;
      if (currentFrame?.localName !== "iframe" ||
          !currentFrame.hasAttribute("data-lightpanda-live-frame") ||
          !currentFrame.contentDocument ||
          !frame.contentDocument) return false;
      if (this.#targetKeys.get(currentFrame.contentDocument.documentElement) !==
          frame.contentDocument.documentElement?.getAttribute(keyMarker)) return false;
    }
    return keys.size > 0;
  }

  #reconcileSnapshot(previousFrame, nextFrame, targetVersion) {
    const current = previousFrame.contentDocument;
    const fresh = nextFrame.contentDocument;
    if (!current?.documentElement || !fresh?.documentElement) {
      throw new Error("Lightpanda live snapshot cannot be reconciled");
    }
    const currentElements = new Map();
    for (const [key, value] of this.#continuityTargets) {
      currentElements.set(key, value.element);
    }
    const framePairs = [];
    reconcileSnapshotElement(
      current.documentElement,
      fresh.documentElement,
      this.#targetKeys,
      currentElements,
      `data-lp-k-${targetVersion}`,
      framePairs,
    );
    for (let i = 0; i < framePairs.length; i++) {
      const [currentFrame, freshFrame] = framePairs[i];
      if (!currentFrame.documentElement || !freshFrame.documentElement ||
          currentFrame.documentElement.namespaceURI !==
            freshFrame.documentElement.namespaceURI ||
          currentFrame.documentElement.localName !==
            freshFrame.documentElement.localName) {
        throw new Error("Lightpanda live frame tree changed");
      }
      reconcileSnapshotElement(
        currentFrame.documentElement,
        freshFrame.documentElement,
        this.#targetKeys,
        currentElements,
        `data-lp-k-${targetVersion}`,
        framePairs,
      );
    }
  }

  #hydrateSnapshot(iframe, targetVersion, context) {
    const doc = iframe.contentDocument;
    if (!doc) throw new Error("Lightpanda live snapshot is not accessible");

    const marker = `data-lp-t-${targetVersion}`;
    const keyMarker = `data-lp-k-${targetVersion}`;
    const documents = snapshotDocuments(doc);
    const marked = documents.flatMap((current) => [
      ...current.querySelectorAll(`[${marker}]`),
    ]);
    const keyed = documents.flatMap((current) => [
      ...current.querySelectorAll(`[${keyMarker}]`),
    ]);
    const ids = new WeakMap();
    const keys = new WeakMap();
    const elements = [];
    const continuityTargets = new Map();
    const authoritativeValues = new Map();
    try {
      if (marked.length === 0 || marked.length !== keyed.length) {
        throw new Error("Lightpanda live snapshot target markers are incomplete");
      }
      for (const element of marked) {
        const raw = element.getAttribute(marker);
        const key = element.getAttribute(keyMarker);
        if (!/^[1-9][0-9]{0,4}$/.test(raw ?? "")) {
          throw new Error("Lightpanda live snapshot contains an invalid target id");
        }
        if (!/^[0-9a-f]{16}$/.test(key ?? "") || continuityTargets.has(key)) {
          throw new Error("Lightpanda live snapshot contains an invalid continuity key");
        }
        const id = Number(raw);
        if (id > 65_535 || elements[id]) {
          throw new Error("Lightpanda live snapshot contains a duplicate or out-of-range target id");
        }
        ids.set(element, id);
        keys.set(element, key);
        elements[id] = element;
        continuityTargets.set(key, {
          element,
          target: { version: targetVersion, id, key },
        });
      }
    } finally {
      for (const element of marked) element.removeAttribute(marker);
      for (const element of keyed) element.removeAttribute(keyMarker);
    }

    for (const current of documents) {
      for (const element of current.querySelectorAll("[data-lightpanda-live-indeterminate]")) {
        if (element.localName === "input") element.indeterminate = true;
        element.removeAttribute("data-lightpanda-live-indeterminate");
      }
      for (const element of current.querySelectorAll("[data-lightpanda-live-selected-none]")) {
        if (element.localName === "select") element.selectedIndex = -1;
        element.removeAttribute("data-lightpanda-live-selected-none");
      }
    }
    for (const [key, current] of continuityTargets) {
      if (editableValueElement(current.element)) {
        authoritativeValues.set(key, current.element.value);
      }
    }

    for (const [key, edit] of this.#dirtyEdits) {
      const current = continuityTargets.get(key);
      if (current && editableValueElement(current.element)) {
        edit.target = current.target;
        edit.redacted =
          current.element.localName === "input" && current.element.type === "password";
        edit.baseline = authoritativeValues.get(key) ?? edit.baseline;
        if (!edit.redacted && (context?.edit === edit || (!edit.dirty && !edit.sending))) {
          clearTimeout(this.#editTimers.get(key));
          this.#editTimers.delete(key);
          this.#dirtyEdits.delete(key);
        }
      } else {
        clearTimeout(this.#editTimers.get(key));
        this.#editTimers.delete(key);
        this.#dirtyEdits.delete(key);
      }
    }
    this.#targetVersion = targetVersion;
    this.#targetIds = ids;
    this.#targetKeys = keys;
    this.#targetElements = elements;
    this.#continuityTargets = continuityTargets;
    this.#authoritativeValues = authoritativeValues;
    for (const key of this.#animationSignatures.keys()) {
      if (!continuityTargets.has(key)) this.#animationSignatures.delete(key);
    }
    this.#replayCanvasOps(documents);
  }

  // ponytail: a canvas only replays the ops recorded since the previous
  // snapshot, so if a whole-document swap replaces the element the strokes drawn
  // before the swap are lost. The next full-canvas clear resynchronises, which
  // for anything animating is the very next frame. Upgrade path if a static
  // canvas ever shows the seam: have the client ack applied snapshots and let
  // the server resend the whole log when an ack is missed.
  #replayCanvasOps(documents) {
    for (const doc of documents) {
      for (const canvas of doc.querySelectorAll(`canvas[${CANVAS_OPS_ATTR}]`)) {
        const value = canvas.getAttribute(CANVAS_OPS_ATTR);
        canvas.removeAttribute(CANVAS_OPS_ATTR);
        let parsed;
        try {
          parsed = parseCanvasOps(value ?? "");
        } catch {
          continue;
        }
        if (parsed.ops.length === 0) continue;
        const ctx = canvas.getContext?.("2d");
        if (!ctx) continue;
        applyCanvasOps(ctx, parsed.ops, (src) => this.#canvasImage(src));
      }
    }
  }

  // Sprites are named by URL and fetched by the viewer's browser straight from
  // origin, so the bitmap never crosses the Lightpanda wire.
  #canvasImage(src) {
    let image = this.#canvasImages.get(src);
    if (!image) {
      image = new Image();
      image.decoding = "async";
      image.src = src;
      this.#canvasImages.set(src, image);
    }
    return image;
  }

  #installNavigationBlocker(doc) {
    if (!doc) throw new Error("Lightpanda live snapshot is not accessible");
    const blockAnchor = (event) => {
      const element = event.target?.nodeType === 1
        ? event.target
        : event.target?.parentElement;
      if (element?.closest("a[href],area[href]")) event.preventDefault();
    };
    for (const current of snapshotDocuments(doc)) {
      current.addEventListener("click", blockAnchor, true);
      current.addEventListener("auxclick", blockAnchor, true);
      current.addEventListener("submit", (event) => event.preventDefault(), true);
    }
  }

  #targetFor(element) {
    const id = this.#targetIds.get(element);
    const key = this.#targetKeys.get(element);
    if (!this.#targetVersion || !Number.isInteger(id) || typeof key !== "string") {
      throw new Error("Lightpanda live snapshot target is unavailable");
    }
    return { version: this.#targetVersion, id, key };
  }

  #wireTarget(target) {
    return { version: target.version, id: target.id };
  }

  #targetForKey(key) {
    const target = this.#continuityTargets.get(key)?.target;
    if (!target) throw new Error("Lightpanda live snapshot target is unavailable");
    return target;
  }

  #elementForTarget(target) {
    if (!target?.key) return null;
    return this.#continuityTargets.get(target.key)?.element ?? null;
  }

  #targetKey(target) {
    return target.key;
  }

  #clearTargets() {
    this.#hoverKey = null;
    this.#scrollOffsets.clear();
    this.#coalescedPayloads.clear();
    this.#coalescedPending.clear();
    this.#targetVersion = null;
    this.#targetIds = new WeakMap();
    this.#targetKeys = new WeakMap();
    this.#targetElements = [];
    this.#continuityTargets = new Map();
    this.#authoritativeValues = new Map();
    this.#animationSignatures.clear();
  }

  #listen(target, type, listener, options) {
    target.addEventListener(type, listener, options);
    this.#captureCleanup.push(() => target.removeEventListener(type, listener, options));
  }

  #detachCapture() {
    for (const cleanup of this.#captureCleanup.splice(0)) cleanup();
  }

  #clearEdits() {
    for (const timer of this.#editTimers.values()) clearTimeout(timer);
    this.#editTimers.clear();
    this.#dirtyEdits.clear();
  }

  #reconcileEdit(key, edit) {
    const element = this.#elementForTarget(edit.target);
    if (editableValueElement(element)) element.value = edit.baseline;
    clearTimeout(this.#editTimers.get(key));
    this.#editTimers.delete(key);
    if (this.#dirtyEdits.get(key) === edit) this.#dirtyEdits.delete(key);
  }

  #reconcileAcknowledgedEdits() {
    for (const [key, edit] of this.#dirtyEdits) {
      if (!edit.redacted && !edit.dirty && !edit.sending) {
        this.#reconcileEdit(key, edit);
      }
    }
  }

  #clearScrollTimer() {
    clearTimeout(this.#scrollTimer);
    this.#scrollTimer = null;
  }

  #captureFocus() {
    const doc = this.iframe.contentDocument;
    if (!doc) return null;
    const active = deepestActiveElement(doc);
    const element = active.element;
    if (!element || element === active.doc.body || element === active.doc.documentElement) {
      return null;
    }
    let target;
    try {
      target = this.#targetFor(element);
    } catch {
      return null;
    }
    return {
      target,
      start: editableValueElement(element) ? element.selectionStart : null,
      end: editableValueElement(element) ? element.selectionEnd : null,
      direction: editableValueElement(element) ? element.selectionDirection : null,
    };
  }

  #attachCapture(focus) {
    const doc = this.iframe.contentDocument;
    if (!doc) throw new Error("Lightpanda live snapshot is not accessible");

    const view = doc.defaultView;
    const documents = snapshotDocuments(doc);

    const rememberEdit = (element) => {
      const target = this.#targetFor(element);
      const key = this.#targetKey(target);
      this.#dirtyEdits.set(key, {
        target,
        value: element.value,
        baseline: this.#authoritativeValues.get(key) ?? element.value,
        redacted: element.localName === "input" && element.type === "password",
        dirty: true,
        sending: false,
      });
      return key;
    };
    const sendFill = (key, snapshot, expectedEdit = this.#dirtyEdits.get(key)) => {
      const edit = this.#dirtyEdits.get(key);
      if (!edit || edit !== expectedEdit) return Promise.resolve();
      clearTimeout(this.#editTimers.get(key));
      this.#editTimers.delete(key);
      edit.sending = true;
      const wantsSnapshot = snapshot !== false;
      return this.#enqueue("fill", () => {
        if (this.#dirtyEdits.get(key) !== edit) {
          throw new DOMException("Lightpanda live edit was superseded", "AbortError");
        }
        return {
          target: this.#wireTarget(this.#targetForKey(key)),
          value: edit.value,
          ...(snapshot === false ? { snapshot: false } : {}),
        };
      }, { edit }).then((response) => {
        if (this.#dirtyEdits.get(key) === edit) {
          edit.sending = false;
          if (edit.redacted) edit.dirty = false;
          else if (response.snapshot) this.#dirtyEdits.delete(key);
          else if (wantsSnapshot) this.#reconcileEdit(key, edit);
          else edit.dirty = false;
        }
        return response;
      }).catch((error) => {
        if (this.#dirtyEdits.get(key) === edit) {
          edit.sending = false;
        }
        throw error;
      });
    };
    const debounceEdit = (key, edit) => {
      clearTimeout(this.#editTimers.get(key));
      const timer = setTimeout(() => {
        if (this.#editTimers.get(key) !== timer ||
            this.#dirtyEdits.get(key) !== edit) return;
        sendFill(key, false, edit).catch(() => {});
      }, 250);
      this.#editTimers.set(key, timer);
    };
    const debounceFill = (event) => {
      const element = event.target;
      if (!editableValueElement(element)) return;
      const key = rememberEdit(element);
      this.#wakePolling();
      debounceEdit(key, this.#dirtyEdits.get(key));
    };

    const captureClick = (event) => {
      if (event.target?.nodeType !== 1) return;
      if (event.target.closest("a[href],area[href]")) event.preventDefault();
      const element = event.target;
      if (!browserOwnedClickDefault(element)) event.preventDefault();
      this.#wakePolling();
      if (this.#scrollTimer != null) {
        clearTimeout(this.#scrollTimer);
        this.#scrollTimer = null;
        this.scroll(this.#scrollX, this.#scrollY).catch(() => {});
      }
      const key = this.#targetKey(this.#targetFor(element));
      this.#enqueue("click", () => ({
        target: this.#wireTarget(this.#targetForKey(key)),
        x: Math.round(event.clientX),
        y: Math.round(event.clientY),
        alt_key: event.altKey,
        ctrl_key: event.ctrlKey,
        meta_key: event.metaKey,
        shift_key: event.shiftKey,
      })).catch(() => {});
    };
    const captureChange = (event) => {
      if (!editableValueElement(event.target)) return;
      const key = rememberEdit(event.target);
      this.#wakePolling();
      sendFill(key, true, this.#dirtyEdits.get(key)).catch(() => {});
    };
    const captureAnimationEnd = (event) => {
      if (!event.isTrusted || event.target?.nodeType !== 1) return;
      const key = this.#targetKey(this.#targetFor(event.target));
      const identity = `${event.animationName ?? ""}\0${event.pseudoElement ?? ""}`;
      const signature = animationSnapshotSignature(event.target);
      let signatures = this.#animationSignatures.get(key);
      if (!signatures) {
        signatures = new Map();
        this.#animationSignatures.set(key, signatures);
      }
      if (signatures.get(identity) === signature) return;
      signatures.set(identity, signature);
      this.#wakePolling();
      this.#enqueue("animationend", () => ({
        target: this.#wireTarget(this.#targetForKey(key)),
      })).catch(() => {
        if (signatures.get(identity) === signature) signatures.delete(identity);
      });
    };
    const targetKeyFor = (element) => {
      if (element?.nodeType !== 1) return null;
      try {
        return this.#targetKey(this.#targetFor(element));
      } catch {
        return null;
      }
    };
    const wireTargetFor = (key) => (key == null
      ? {}
      : { target: this.#wireTarget(this.#targetForKey(key)) });

    const mousePayload = (event, extra) => ({
      x: Math.round(event.clientX),
      y: Math.round(event.clientY),
      button: event.button ?? 0,
      buttons: event.buttons ?? 0,
      detail: event.detail ?? 0,
      alt_key: event.altKey,
      ctrl_key: event.ctrlKey,
      meta_key: event.metaKey,
      shift_key: event.shiftKey,
      ...extra,
    });

    const sendMouse = (type, key, event, extra = {}) => {
      if (key == null) return;
      const shared = mousePayload(event, extra);
      this.#wakePolling();
      return this.#enqueueCoalesced(
        type === "mousemove" ? "mousemove" : `${type}:${key}`,
        type,
        () => ({ ...wireTargetFor(key), ...shared }),
      ).catch(() => {});
    };

    // Button transitions must never coalesce. Dropping one half of a down/up
    // pair leaves the far side with a stuck button, and press-and-hold, drag,
    // drag-and-drop and sliders are all defined by the exact sequence arriving
    // in order.
    const sendMouseOrdered = (type, key, event, extra = {}) => {
      if (key == null) return;
      const shared = mousePayload(event, extra);
      this.#wakePolling();
      return this.#enqueue(type, () => ({ ...wireTargetFor(key), ...shared })).catch(() => {});
    };

    const captureMouseDown = (event) => {
      sendMouseOrdered("mousedown", targetKeyFor(event.target), event);
    };
    // The press may start on one element and finish on another (a drag off a
    // slider thumb), so the release is addressed to wherever it actually landed.
    const captureMouseUp = (event) => {
      sendMouseOrdered("mouseup", targetKeyFor(event.target), event);
    };

    let lastMoveAt = 0;
    const capturePointerMove = (event) => {
      const element = event.target?.nodeType === 1 ? event.target : null;
      if (!element) return;
      const key = targetKeyFor(element);
      if (key !== this.#hoverKey) {
        const left = this.#hoverKey;
        // CSS :hover already works locally; these drive the page's own JS
        // menus, tooltips and mega-nav, which never open without them.
        this.#hoverKey = key;
        if (left != null) sendMouse("mouseout", left, event);
        sendMouse("mouseover", key, event);
      }
      const now = event.timeStamp ?? 0;
      if (now - lastMoveAt < 50) return;
      lastMoveAt = now;
      sendMouse("mousemove", key, event, { snapshot: false });
    };

    const captureContextMenu = (event) => {
      event.preventDefault();
      sendMouse("contextmenu", targetKeyFor(event.target), event, { button: 2 });
    };
    const captureDoubleClick = (event) => {
      sendMouse("dblclick", targetKeyFor(event.target), event, { detail: 2 });
    };

    let wheelTimer = null;
    // Keyed by target: a single global accumulator would deliver one element's
    // scroll distance to whichever element the last wheel event happened to hit.
    const wheelPending = new Map();
    const flushWheel = () => {
      wheelTimer = null;
      const batch = [...wheelPending.values()];
      wheelPending.clear();
      for (const pending of batch) {
        this.#enqueue("wheel", () => ({
          ...wireTargetFor(pending.key),
          x: pending.x,
          y: pending.y,
          delta_x: pending.delta_x,
          delta_y: pending.delta_y,
          alt_key: pending.alt_key,
          ctrl_key: pending.ctrl_key,
          meta_key: pending.meta_key,
          shift_key: pending.shift_key,
        })).catch(() => {});
      }
    };
    const captureWheel = (event) => {
      const element = event.target?.nodeType === 1 ? event.target : null;
      const key = targetKeyFor(element);
      if (key == null) return;
      // Deltas accumulate: replacing them would drop scroll distance.
      const pending = wheelPending.get(key) ?? { key, delta_x: 0, delta_y: 0 };
      pending.delta_x += event.deltaX;
      pending.delta_y += event.deltaY;
      pending.x = Math.round(event.clientX);
      pending.y = Math.round(event.clientY);
      pending.alt_key = event.altKey;
      pending.ctrl_key = event.ctrlKey;
      pending.meta_key = event.metaKey;
      pending.shift_key = event.shiftKey;
      wheelPending.set(key, pending);
      this.#wakePolling();
      clearTimeout(wheelTimer);
      wheelTimer = setTimeout(flushWheel, 60);
    };
    this.#captureCleanup.push(() => clearTimeout(wheelTimer));

    const captureContainerScroll = (event) => {
      const element = event.target;
      if (element?.nodeType !== 1) return;
      const key = targetKeyFor(element);
      if (key == null) return;
      const offset = { top: element.scrollTop, left: element.scrollLeft };
      // Restoring an offset after a reconcile fires a scroll event of its own.
      // Scroll events are async, so compare values rather than use a flag.
      const previous = this.#scrollOffsets.get(key);
      if (previous?.top === offset.top && previous?.left === offset.left) return;
      this.#scrollOffsets.set(key, offset);
      this.#wakePolling();
      this.#enqueueCoalesced(`scroll:${key}`, "scroll", () => ({
        ...wireTargetFor(key),
        x: offset.left,
        y: offset.top,
        snapshot: false,
      })).catch(() => {});
    };

    const forwardKey = (down, event, element) => {
      const key = targetKeyFor(element);
      const detail = {
        key: event.key,
        code: event.code ?? "",
        location: event.location ?? 0,
        repeat: event.repeat === true,
        alt_key: event.altKey,
        ctrl_key: event.ctrlKey,
        meta_key: event.metaKey,
        shift_key: event.shiftKey,
      };
      const type = down ? "keydown" : "keyup";
      const payload = () => ({ ...wireTargetFor(key), ...detail });
      this.#wakePolling();
      // Only auto-repeat is safe to drop; every distinct press and release is
      // meaningful state on the far side.
      const send = detail.repeat
        ? this.#enqueueCoalesced(`${type}:${event.key}`, type, payload)
        : this.#enqueue(type, payload);
      send.catch(() => {});
    };

    // "press" is a fused keydown+keyup on the far side, so the browser's own
    // keyup for that same Enter must not be forwarded a second time.
    let swallowEnterKeyup = false;

    const captureKeyup = (event) => {
      const element = event.target;
      if (event.isComposing) return;
      if (event.key === "Enter" && swallowEnterKeyup) {
        swallowEnterKeyup = false;
        return;
      }
      if (localTextEditKey(event, element)) return;
      forwardKey(false, event, element);
    };

    const captureKeydown = (event) => {
      const element = event.target;
      if (event.isComposing) return;
      if (event.key === "Enter" &&
          element?.localName === "input" &&
          editableValueElement(element)) {
        event.preventDefault();
        swallowEnterKeyup = true;
        const key = rememberEdit(element);
        this.#wakePolling();
        sendFill(key, true, this.#dirtyEdits.get(key))
          .then(() => {
            return this.#enqueue("press", () => ({
              target: this.#wireTarget(this.#targetForKey(key)),
              key: "Enter",
            }));
          })
          .catch(() => {});
        return;
      }

      if (localTextEditKey(event, element)) return;
      if (preventLocalKeyDefault(event, element)) event.preventDefault();
      forwardKey(true, event, element);
    };
    for (const current of documents) {
      this.#listen(current, "click", captureClick, true);
      this.#listen(current, "input", debounceFill, true);
      this.#listen(current, "change", captureChange, true);
      this.#listen(current, "animationend", captureAnimationEnd, true);
      this.#listen(current, "keydown", captureKeydown, true);
      this.#listen(current, "keyup", captureKeyup, true);
      this.#listen(current, "mousedown", captureMouseDown, true);
      this.#listen(current, "mouseup", captureMouseUp, true);
      this.#listen(current, "mousemove", capturePointerMove, true);
      this.#listen(current, "contextmenu", captureContextMenu, true);
      this.#listen(current, "dblclick", captureDoubleClick, true);
      this.#listen(current, "wheel", captureWheel, { capture: true, passive: true });
      this.#listen(current, "scroll", captureContainerScroll, true);
    }

    if (view) {
      this.#listen(view, "scroll", () => {
        const x = Math.round(view.scrollX);
        const y = Math.round(view.scrollY);
        if (x === this.#scrollX && y === this.#scrollY) return;
        this.#scrollX = x;
        this.#scrollY = y;
        this.#wakePolling();
        clearTimeout(this.#scrollTimer);
        this.#scrollTimer = setTimeout(() => {
          this.#scrollTimer = null;
          this.scroll(this.#scrollX, this.#scrollY, { snapshot: false }).catch(() => {});
        }, 100);
      }, true);
    }

    for (const [key, edit] of this.#dirtyEdits) {
      const element = this.#elementForTarget(edit.target);
      if (!editableValueElement(element)) {
        clearTimeout(this.#editTimers.get(key));
        this.#editTimers.delete(key);
        this.#dirtyEdits.delete(key);
        continue;
      }
      element.value = edit.value;
      if (edit.dirty && !edit.sending && !this.#editTimers.has(key)) {
        sendFill(key, false, edit).catch(() => {});
      }
    }

    // Every reconcile rebuilds the inner scroll containers at offset 0. Replay
    // the offsets we recorded, keyed by the reconciler's stable element keys.
    for (const [key, offset] of this.#scrollOffsets) {
      const element = this.#continuityTargets.get(key)?.element;
      if (!element?.isConnected) {
        this.#scrollOffsets.delete(key);
        continue;
      }
      try {
        if (element.scrollTop !== offset.top) element.scrollTop = offset.top;
        if (element.scrollLeft !== offset.left) element.scrollLeft = offset.left;
      } catch {}
    }

    try {
      view?.scrollTo(this.#scrollX, this.#scrollY);
      const restored = focus ? this.#elementForTarget(focus.target) : null;
      if (restored) {
        restored.focus({ preventScroll: true });
        if (typeof restored.setSelectionRange === "function" && focus.start != null) {
          restored.setSelectionRange(focus.start, focus.end, focus.direction);
        }
      }
    } catch {}
  }

  #queue(command) {
    const result = this.#tail.then(command, command);
    this.#tail = result.catch(() => {});
    return result;
  }

  // Held keys and pointer motion produce events far faster than the serialized
  // command chain drains them. Keep only the newest payload per slot instead of
  // growing an unbounded backlog of stale input.
  #enqueueCoalesced(slot, type, payload) {
    this.#coalescedPayloads.set(slot, payload);
    const inflight = this.#coalescedPending.get(slot);
    if (inflight) return inflight;
    let resolved = null;
    const promise = this.#enqueue(type, () => {
      if (resolved === null) {
        this.#coalescedPending.delete(slot);
        resolved = this.#coalescedPayloads.get(slot) ?? null;
        this.#coalescedPayloads.delete(slot);
      }
      if (!resolved) {
        throw new DOMException("Lightpanda live input was superseded", "AbortError");
      }
      return resolved();
    });
    this.#coalescedPending.set(slot, promise);
    return promise;
  }

  #enqueue(type, payload = {}, context = null) {
    const viewEpoch = this.#viewEpoch;
    const command = () => this.#execute(type, payload, viewEpoch, context);
    return this.#queue(command);
  }

  #enqueueLifecycle(type, payload) {
    const lifecycleToken = this.#lifecycleToken;
    return this.#queue(() => {
      if (lifecycleToken !== this.#lifecycleToken) {
        throw new DOMException("Lightpanda live command was superseded", "AbortError");
      }
      return this.#executeLifecycle(type, payload, lifecycleToken);
    });
  }

  #enqueueClose(hadOpenedSession) {
    const viewEpoch = this.#viewEpoch;
    return this.#queue(() => {
      if (viewEpoch !== this.#viewEpoch) {
        throw new DOMException("Lightpanda live command was superseded", "AbortError");
      }
      if (!hadOpenedSession || this.#socket?.readyState !== WebSocket.OPEN) {
        this.#dispatchClose();
        return;
      }
      return this.#execute("close", {}, viewEpoch, null);
    });
  }

  async #executeLifecycle(type, payload, lifecycleToken) {
    const recovery = {
      opened: this.#opened,
      socket: this.#socket,
      iframe: this.iframe,
      targetVersion: this.#targetVersion,
      targets: this.#continuityTargets,
    };
    const viewEpoch = ++this.#viewEpoch;
    this.#cancelFrame?.(
      new DOMException("Lightpanda live snapshot was superseded", "AbortError"),
    );
    this.#opened = false;
    this.#stopPolling();
    try {
      const response = await this.#execute(type, payload, viewEpoch, null);
      if (viewEpoch === this.#viewEpoch &&
          lifecycleToken === this.#lifecycleToken &&
          (type === "open" || recovery.opened)) {
        this.#opened = true;
        this.#startPolling();
      }
      return response;
    } catch (error) {
      const currentLifecycle =
        viewEpoch === this.#viewEpoch &&
        lifecycleToken === this.#lifecycleToken &&
        !this.#destroyed;
      if (currentLifecycle && type === "open") {
        this.#detachCapture();
        this.#clearEdits();
        this.#clearTargets();
        this.#clearScrollTimer();
        this.iframe.inert = true;
        this.#socket?.close();
      } else if (currentLifecycle &&
          type !== "open" &&
          liveNavigationCommand(type) &&
          recovery.opened &&
          recovery.targetVersion !== null &&
          this.#socket === recovery.socket &&
          recovery.socket?.readyState === WebSocket.OPEN &&
          this.iframe === recovery.iframe &&
          this.#targetVersion === recovery.targetVersion &&
          this.#continuityTargets === recovery.targets) {
        this.#opened = true;
        this.#startPolling();
      }
      throw error;
    }
  }

  async #execute(type, payload, viewEpoch, context) {
    try {
      if (viewEpoch !== this.#viewEpoch) {
        throw new DOMException("Lightpanda live command was superseded", "AbortError");
      }
      const resolvePayload = () => typeof payload === "function" ? payload() : payload;
      let commandPayload = resolvePayload();
      let response;
      try {
        response = await this.#executeCommand(type, commandPayload, viewEpoch, context);
      } catch (error) {
        if (typeof payload !== "function" ||
            error?.message !== "live target is stale") {
          throw error;
        }
        const refreshed = await this.#executeCommand("snapshot", {}, viewEpoch, null);
        this.#dispatchResult("snapshot", {}, refreshed);
        commandPayload = resolvePayload();
        response = await this.#executeCommand(type, commandPayload, viewEpoch, context);
      }
      this.#dispatchResult(type, commandPayload, response);
      return response;
    } catch (error) {
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("error", { detail: error }));
      }
      throw error;
    }
  }

  async #executeCommand(type, payload, viewEpoch, context) {
    if (viewEpoch !== this.#viewEpoch) {
      throw new DOMException("Lightpanda live command was superseded", "AbortError");
    }
    const socket = await this.#connect();
    if (this.#destroyed) throw new Error("Lightpanda virtual browser is destroyed");
    if (viewEpoch !== this.#viewEpoch) {
      throw new DOMException("Lightpanda live command was superseded", "AbortError");
    }
    const id = ++this.#nextId;
    const completed = await new Promise((resolve, reject) => {
      const pending = {
        id,
        type,
        response: null,
        receiving: false,
        viewEpoch,
        context,
        resolve,
        reject,
        timer: null,
      };
      pending.timer = setTimeout(() => {
        if (this.#pending !== pending) return;
        const error = new Error(`Lightpanda live command timed out: ${type}`);
        this.#cancelFrame?.(error);
        this.#rejectPending(error, pending);
        if (this.#socket === socket && socket.readyState <= WebSocket.OPEN) {
          socket.close(1002, "Lightpanda command timeout");
        }
      }, this.#commandTimeoutMs);
      this.#pending = pending;
      try {
        socket.send(JSON.stringify({ id, type, ...payload }));
      } catch (error) {
        this.#rejectPending(error, pending);
      }
    });
    if (completed.superseded) {
      throw new DOMException("Lightpanda live command was superseded", "AbortError");
    }
    return completed.response;
  }

  #readPageState() {
    const doc = this.iframe.contentDocument;
    const base = doc?.baseURI;
    return {
      url: typeof base === "string" && !base.startsWith("about:") ? base : this.#url,
      title: doc?.title ?? this.#title,
    };
  }

  #dispatchResult(type, payload, response) {
    this.#canGoBack = response.can_go_back;
    this.#canGoForward = response.can_go_forward;
    if (typeof response.warning === "string") {
      this.dispatchEvent(new CustomEvent("warning", {
        detail: { type, warning: response.warning },
      }));
    }
    if (response.snapshot) {
      this.#url = response.url ?? this.#url;
      this.#title = response.title ?? this.#title;
      if (this.#lastOpenPayload && this.#url) {
        this.#lastOpenPayload.url = this.#url;
      }
    }
    this.dispatchEvent(new CustomEvent("state", {
      detail: {
        url: this.#url,
        title: this.#title,
        canGoBack: this.#canGoBack,
        canGoForward: this.#canGoForward,
      },
    }));
    if (response.snapshot) {
      this.#pollDelayMs = this.#snapshotPollDelay();
      this.dispatchEvent(new CustomEvent("snapshot", {
        detail: { type, response, iframe: this.iframe },
      }));
    }
    if (type === "snapshot" && !response.snapshot) this.#reconcileAcknowledgedEdits();
    if (type === "open") {
      this.dispatchEvent(new CustomEvent("open", { detail: { ...payload, response } }));
    } else if (type === "close") {
      this.#dispatchClose(response);
    } else if (type !== "snapshot") {
      this.dispatchEvent(new CustomEvent("action", { detail: { type, ...payload, response } }));
    }
    if (type !== "snapshot") this.#wakePolling();
  }

  #dispatchClose(response = undefined) {
    if (this.#closeDispatched) return;
    this.#closeDispatched = true;
    this.dispatchEvent(new CustomEvent("close", { detail: response }));
  }

  #startPolling() {
    this.#stopPolling();
    this.#polling = true;
    this.#pollDelayMs = this.#snapshotPollDelay();
    this.#schedulePoll();
  }

  #snapshotPollDelay() {
    const smallSnapshotBytes = 256 * 1024;
    if (this.#lastSnapshotBytes <= smallSnapshotBytes) return this.#pollMs;
    return Math.min(
      this.#maxPollMs,
      Math.round(this.#pollMs * this.#lastSnapshotBytes / smallSnapshotBytes),
    );
  }

  #schedulePoll() {
    if (!this.#polling || !this.#opened || this.#destroyed) return;
    clearTimeout(this.#pollTimer);
    this.#pollTimer = setTimeout(() => this.#poll(), this.#pollDelayMs);
  }

  async #poll() {
    this.#pollTimer = null;
    if (!this.#polling || !this.#opened || this.#destroyed) return;
    try {
      // The server suppresses unchanged snapshots before serialization, so
      // large pages can poll less often without slowing down small pages.
      const response = await this.snapshot();
      if (!response.snapshot) this.#pollDelayMs = this.#snapshotPollDelay();
    } catch {
      if (!this.#opened) return;
      this.#pollDelayMs = Math.min(
        this.#maxPollMs,
        Math.max(this.#pollMs, this.#pollDelayMs * 2),
      );
    }
    this.#schedulePoll();
  }

  #wakePolling() {
    this.#pollDelayMs = this.#pollMs;
    if (this.#pollTimer != null) this.#schedulePoll();
  }

  #stopPolling() {
    this.#polling = false;
    clearTimeout(this.#pollTimer);
    this.#pollTimer = null;
    this.#pollDelayMs = this.#pollMs;
  }

  async open(url, options = {}) {
    const source = new URL(url, document.baseURI).href;
    const bounds = this.#target.getBoundingClientRect();
    const payload = {
      url: source,
      width: Math.max(1, Math.round((options.width ?? bounds.width) || 1280)),
      height: Math.max(1, Math.round((options.height ?? bounds.height) || 720)),
      wait_ms: options.waitMs,
      wait_until: options.waitUntil,
      direct_resources: this.#directResources,
    };
    for (const key of Object.keys(payload)) {
      if (payload[key] == null) delete payload[key];
    }
    this.#cancelReconnect();

    ++this.#opening;
    try {
      const response = await this.#enqueueLifecycle("open", payload);
      this.#lastOpenPayload = {
        ...payload,
        url: this.#url ?? payload.url,
      };
      return response;
    } finally {
      --this.#opening;
    }
  }

  snapshot(options = {}) {
    return this.#enqueue("snapshot",
      options.snapshot === false ? { snapshot: false } : {});
  }

  async navigate(url) {
    const source = new URL(url, document.baseURI).href;
    const response = await this.#enqueueLifecycle("navigate", { url: source });
    if (this.#lastOpenPayload) this.#lastOpenPayload = {
      ...this.#lastOpenPayload,
      url: this.#url ?? source,
    };
    return response;
  }

  async back() {
    return this.#enqueueLifecycle("back", {});
  }

  async forward() {
    return this.#enqueueLifecycle("forward", {});
  }

  async reload() {
    return this.#enqueueLifecycle("reload", {});
  }

  click(selector) {
    return this.#enqueue("click", { selector });
  }

  fill(selector, value, options = {}) {
    return this.#enqueue("fill", {
      selector,
      value,
      ...(options.snapshot === false ? { snapshot: false } : {}),
    });
  }

  press(selector, key) {
    if (key === undefined) {
      key = selector;
      selector = undefined;
    }
    return this.#enqueue("press", selector == null ? { key } : { selector, key });
  }

  scroll(x, y, options = {}) {
    return this.#enqueue("scroll", {
      x,
      y,
      ...(options.snapshot === false ? { snapshot: false } : {}),
    });
  }

  async close() {
    const hadOpenedSession = this.#opened;
    ++this.#lifecycleToken;
    ++this.#viewEpoch;
    this.#cancelReconnect(true);
    this.#cancelFrame?.(
      new DOMException("Lightpanda live snapshot was superseded", "AbortError"),
    );
    this.#connectController?.abort(
      new DOMException("Lightpanda live connection was closed", "AbortError"),
    );
    this.#opened = false;
    this.#stopPolling();
    this.#detachCapture();
    this.iframe.inert = true;
    this.#clearEdits();
    this.#clearTargets();
    this.#clearScrollTimer();
    if (this.#opening === 0 &&
        (!this.#socket || this.#socket.readyState > WebSocket.OPEN)) {
      this.#dispatchClose();
      return;
    }
    try {
      return await this.#enqueueClose(hadOpenedSession);
    } finally {
      this.#socket?.close();
    }
  }

  get url() {
    return this.#url;
  }

  get title() {
    return this.#title;
  }

  get canGoBack() {
    return this.#canGoBack;
  }

  get canGoForward() {
    return this.#canGoForward;
  }

  destroy() {
    if (this.#destroyed) return;
    this.#destroyed = true;
    ++this.#lifecycleToken;
    ++this.#viewEpoch;
    this.#cancelReconnect(true);
    this.#opened = false;
    this.#stopPolling();
    this.#detachCapture();
    this.#clearEdits();
    this.#clearTargets();
    this.#clearScrollTimer();
    this.#connectController?.abort(new Error("Lightpanda virtual browser is destroyed"));
    this.#cancelFrame?.(new Error("Lightpanda virtual browser is destroyed"));
    this.#rejectPending(new Error("Lightpanda virtual browser is destroyed"));
    this.#socket?.close();
    this.#socket = null;
    this.iframe.remove();
    this.#dispatchClose();
  }
}

export function attachLightpandaVirtualBrowser(target, options) {
  return new LightpandaVirtualBrowser(target, options);
}
