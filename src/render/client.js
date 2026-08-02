const DEFAULT_ENDPOINT = new URL("/v1/render", import.meta.url).href;

function resolveTarget(target) {
  if (typeof target === "string") target = document.querySelector(target);
  if (!(target instanceof Element)) throw new TypeError("Lightpanda renderer target not found");
  return target;
}

function aborted(signal) {
  return signal.reason ?? new DOMException("Lightpanda render superseded", "AbortError");
}

function waitForFrame(iframe, url, signal, isCurrent) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
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

    if (signal.aborted) return cancelled();
    iframe.addEventListener("load", loaded, { once: true });
    iframe.addEventListener("error", failed, { once: true });
    signal.addEventListener("abort", cancelled, { once: true });
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
  #controller = null;
  #sequence = 0;
  #lastRequest = null;

  constructor(target, options = {}) {
    super();
    this.#target = resolveTarget(target);
    this.#endpoint = new URL(options.endpoint ?? DEFAULT_ENDPOINT, document.baseURI).href;
    this.#token = options.token ?? null;

    const iframe = document.createElement("iframe");
    iframe.setAttribute("sandbox", "");
    iframe.title = options.title ?? "Lightpanda rendered page";
    iframe.loading = "eager";
    iframe.referrerPolicy = "no-referrer";
    iframe.style.cssText = options.style ?? "display:block;width:100%;height:100%;border:0";
    if (options.className) iframe.className = options.className;
    const supportsCredentialless = "credentialless" in iframe;
    if (options.requireCredentialless && !supportsCredentialless) {
      throw new Error("This browser does not support credentialless iframes");
    }
    if (options.credentialless !== false && supportsCredentialless) iframe.credentialless = true;
    this.iframe = iframe;

    if (options.replace === false) this.#target.append(iframe);
    else this.#target.replaceChildren(iframe);
  }

  async render(url, options = {}) {
    const source = new URL(url, document.baseURI).href;
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;

    const bounds = this.#target.getBoundingClientRect();
    const request = {
      url: source,
      wait_ms: options.waitMs,
      wait_until: options.waitUntil,
      wait_selector: options.waitSelector,
      width: Math.max(1, Math.round((options.width ?? bounds.width) || 1280)),
      height: Math.max(1, Math.round((options.height ?? bounds.height) || 720)),
    };
    for (const key of Object.keys(request)) {
      if (request[key] == null) delete request[key];
    }
    this.#lastRequest = { url: source, options: { ...options } };

    let pendingBlobUrl = null;
    try {
      const headers = { accept: "text/html", "content-type": "application/json" };
      if (this.#token) headers.authorization = `Bearer ${this.#token}`;
      const response = await fetch(this.#endpoint, {
        method: "POST",
        headers,
        body: JSON.stringify(request),
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
      );
      // The iframe retains its parsed document after load; keeping the object
      // URL alive would retain a duplicate full response Blob.
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
    this.iframe.remove();
  }
}

export function attachLightpandaRenderer(target, options) {
  return new LightpandaRenderer(target, options);
}
