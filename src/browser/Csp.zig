// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Content-Security-Policy enforcement for external `<script src>` fetches.
//!
//! Not enforcing CSP is itself a fingerprint: a page that ships a policy its
//! own scripts violate expects those scripts to be blocked, and a client that
//! fetches them anyway looks exactly like Puppeteer's `Page.setBypassCSP`.
//!
//! ponytail: `script-src` (with `default-src` fallback) against a resolved URL
//! is all this covers. NOT implemented, and each one makes a policy
//! undecidable rather than stricter — anything this file can't decide is
//! allowed:
//!   * nonces (`'nonce-...'`), hashes (`'sha256-...'`) and `'strict-dynamic'`
//!     — they can authorise a script whose URL alone says nothing, so a source
//!     list containing one fails open for that whole policy.
//!   * inline script and `eval` enforcement — `'unsafe-inline'` /
//!     `'unsafe-eval'` are parsed (so they don't read as unknown) but only
//!     external fetches are gated. Upgrade path: call `allowsInline` from
//!     `ScriptManager.addInlineScript`.
//!   * `report-uri` / `report-to`, Report-Only mode, and the
//!     `securitypolicyviolation` event — a block is silent apart from a debug
//!     log, where a real browser also reports it.
//!   * every other directive: `frame-ancestors`, `sandbox`, `style-src`,
//!     `img-src`, `connect-src`, `worker-src`, `upgrade-insecure-requests`.
//! Fail-open is deliberate. A matcher that wrongly blocks breaks real pages on
//! every load; one that wrongly allows only leaves the pre-existing behaviour.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("URL.zig");
const Frame = @import("Frame.zig");
const Element = @import("webapi/Element.zig");
const Document = @import("webapi/Document.zig");

const log = lp.log;

const header_name = "content-security-policy";

/// False only when some policy on this document positively forbids fetching
/// `url` as a script. Every policy has to allow it independently — multiple
/// policies intersect, they never widen each other.
pub fn allowsScript(frame: *Frame, url: [:0]const u8) bool {
    for (frame._http_headers.items) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, header_name)) continue;
        if (!policyListAllows(h.value, frame, url)) return false;
    }

    // Only `<head>` metas are honoured, and only those already parsed: a
    // policy governs the resources fetched after it, which is what the
    // streaming parser gives us for free by calling us as each <script> is
    // created.
    const document = frame.window._document.is(Document.HTMLDocument) orelse return true;
    const head = document.getHead() orelse return true;
    var it = head.asNode().childrenIterator();
    while (it.next()) |node| {
        const element = node.is(Element) orelse continue;
        if (element.getTag() != .meta) continue;
        const equiv = element.getAttributeSafe(comptime .wrap("http-equiv")) orelse continue;
        if (!std.ascii.eqlIgnoreCase(equiv, header_name)) continue;
        const content = element.getAttributeSafe(comptime .wrap("content")) orelse continue;
        if (!policyListAllows(content, frame, url)) return false;
    }
    return true;
}

// One header value (or one meta content) can carry several comma-separated
// policies, each enforced on its own.
fn policyListAllows(list: []const u8, frame: *Frame, url: [:0]const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |policy| {
        if (!policyAllows(policy, frame, url)) return false;
    }
    return true;
}

fn policyAllows(policy: []const u8, frame: *Frame, url: [:0]const u8) bool {
    // Only the first occurrence of a directive counts; later copies are junk.
    var fallback: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, policy, ';');
    while (it.next()) |raw| {
        const directive = std.mem.trim(u8, raw, &std.ascii.whitespace);
        const name_end = std.mem.indexOfAny(u8, directive, &std.ascii.whitespace) orelse directive.len;
        const name = directive[0..name_end];

        if (std.ascii.eqlIgnoreCase(name, "script-src")) {
            return sourceListAllows(directive[name_end..], frame, url);
        }
        if (fallback == null and std.ascii.eqlIgnoreCase(name, "default-src")) {
            fallback = directive[name_end..];
        }
    }

    // No script-src and no default-src: this policy says nothing about scripts.
    return sourceListAllows(fallback orelse return true, frame, url);
}

fn sourceListAllows(list: []const u8, frame: *Frame, url: [:0]const u8) bool {
    var matched = false;
    var it = std.mem.tokenizeAny(u8, list, &std.ascii.whitespace);
    while (it.next()) |source| {
        switch (matchSource(source, frame, url)) {
            .match => matched = true,
            .no_match => {},
            // Undecidable source: stop pretending we know and allow.
            .unknown => return true,
        }
    }
    return matched;
}

const Match = enum { match, no_match, unknown };

const inline_keywords = [_][]const u8{
    "'unsafe-inline'",
    "'unsafe-eval'",
    "'wasm-unsafe-eval'",
    "'unsafe-hashes'",
    "'report-sample'",
    "'inline-speculation-rules'",
};

fn matchSource(source: []const u8, frame: *Frame, url: [:0]const u8) Match {
    const url_scheme = URL.getProtocol(url);

    if (source[0] == '\'') {
        if (std.ascii.eqlIgnoreCase(source, "'none'")) return .no_match;
        if (std.ascii.eqlIgnoreCase(source, "'self'")) {
            return if (matchesSelf(frame, url)) .match else .no_match;
        }
        // Keywords that govern inline script or eval, never a URL fetch. Known,
        // so they don't poison the policy, but they can't authorise `url`.
        for (inline_keywords) |keyword| {
            if (std.ascii.eqlIgnoreCase(source, keyword)) return .no_match;
        }
        // 'nonce-...', 'sha256-...', 'strict-dynamic', or something newer than
        // this list: all can authorise a script we can't judge from its URL.
        return .unknown;
    }

    if (std.mem.eql(u8, source, "*")) {
        // `*` covers network schemes only; data:/blob:/filesystem: must be named.
        for ([_][]const u8{ "data:", "blob:", "filesystem:" }) |opaque_scheme| {
            if (std.ascii.eqlIgnoreCase(url_scheme, opaque_scheme)) return .no_match;
        }
        return .match;
    }

    // Scheme-only source: "https:", "blob:", ...
    if (source[source.len - 1] == ':' and std.mem.indexOfScalar(u8, source, '/') == null) {
        return if (schemeMatches(source, url_scheme)) .match else .no_match;
    }

    return matchHost(source, frame, url);
}

// CSP3: an insecure scheme expression also authorises its secure upgrade.
fn schemeMatches(expression: []const u8, url_scheme: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(expression, url_scheme)) return true;
    if (std.ascii.eqlIgnoreCase(expression, "http:")) return std.ascii.eqlIgnoreCase(url_scheme, "https:");
    if (std.ascii.eqlIgnoreCase(expression, "ws:")) return std.ascii.eqlIgnoreCase(url_scheme, "wss:");
    return false;
}

fn defaultPort(scheme: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(scheme, "https:") or std.ascii.eqlIgnoreCase(scheme, "wss:")) return "443";
    if (std.ascii.eqlIgnoreCase(scheme, "http:") or std.ascii.eqlIgnoreCase(scheme, "ws:")) return "80";
    return "";
}

fn matchesSelf(frame: *Frame, url: [:0]const u8) bool {
    const origin = frame.origin orelse return false;
    const separator = std.mem.indexOf(u8, origin, "://") orelse return false;
    const origin_scheme = origin[0 .. separator + 1];
    const url_scheme = URL.getProtocol(url);

    if (!schemeMatches(origin_scheme, url_scheme)) return false;
    if (!std.ascii.eqlIgnoreCase(URL.getOriginHostname(origin), URL.getHostname(url))) return false;

    const origin_host = URL.getHost(origin);
    const origin_hostname = URL.getOriginHostname(origin);
    const origin_port = if (origin_host.len > origin_hostname.len) origin_host[origin_hostname.len + 1 ..] else "";
    const url_port = URL.getPort(url);

    // Both implicit covers the http -> https upgrade, whose default ports differ.
    if (origin_port.len == 0 and url_port.len == 0) return true;
    return std.mem.eql(u8, portOr(origin_port, origin_scheme), portOr(url_port, url_scheme));
}

fn portOr(port: []const u8, scheme: []const u8) []const u8 {
    return if (port.len == 0) defaultPort(scheme) else port;
}

// host-source: [scheme "://"] host [":" port] [path]
fn matchHost(source: []const u8, frame: *Frame, url: [:0]const u8) Match {
    const url_scheme = URL.getProtocol(url);
    var rest = source;

    if (std.mem.indexOf(u8, rest, "://")) |i| {
        if (i == 0) return .unknown;
        if (!schemeMatches(rest[0 .. i + 1], url_scheme)) return .no_match;
        rest = rest[i + 3 ..];
    } else if (frame.origin) |origin| {
        // No scheme in the expression: the document's own scheme is implied.
        const separator = std.mem.indexOf(u8, origin, "://") orelse return .unknown;
        if (!schemeMatches(origin[0 .. separator + 1], url_scheme)) return .no_match;
    }

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const path = rest[path_start..];
    var host = rest[0..path_start];
    var port: []const u8 = "";

    if (host.len > 0 and host[host.len - 1] != ']') {
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |i| {
            const candidate = host[i + 1 ..];
            if (std.mem.eql(u8, candidate, "*") or isDigits(candidate)) {
                port = candidate;
                host = host[0..i];
            }
        }
    }
    if (host.len == 0) return .unknown;

    if (std.mem.startsWith(u8, host, "*.")) {
        // "*.example.com" matches any subdomain, never the bare domain.
        if (!std.ascii.endsWithIgnoreCase(URL.getHostname(url), host[1..])) return .no_match;
    } else if (!std.ascii.eqlIgnoreCase(host, URL.getHostname(url))) {
        return .no_match;
    }

    if (!std.mem.eql(u8, port, "*")) {
        // An omitted port means the url must be on its scheme's default port.
        const want = if (port.len == 0) defaultPort(url_scheme) else port;
        if (!std.mem.eql(u8, want, portOr(URL.getPort(url), url_scheme))) return .no_match;
    }

    if (path.len == 0 or std.mem.eql(u8, path, "/")) return .match;
    const url_path = URL.getPathname(url);
    if (path[path.len - 1] == '/') {
        return if (std.mem.startsWith(u8, url_path, path)) .match else .no_match;
    }
    return if (std.mem.eql(u8, url_path, path)) .match else .no_match;
}

fn isDigits(str: []const u8) bool {
    if (str.len == 0) return false;
    for (str) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Debug-logs a block. Split out so the enforcement site stays one `if`.
pub fn logBlocked(url: []const u8, ctx: []const u8) void {
    log.debug(.http, "csp blocked script", .{ .url = url, .ctx = ctx });
}

const testing = @import("../testing.zig");

// Drives the matcher through a frame carrying one header-delivered policy,
// which is also the only coverage the response-header path gets (the meta path
// is covered by src/browser/tests/csp/).
fn expectPolicy(expected: bool, policy: []const u8, url: [:0]const u8) !void {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    frame.origin = "http://127.0.0.1:9582";
    try frame._http_headers.append(frame.arena, .{
        .name = "Content-Security-Policy",
        .value = policy,
    });
    try testing.expectEqual(expected, allowsScript(frame, url));
}

test "Csp: html" {
    try testing.htmlRunner("csp", .{});
}

test "Csp: no policy allows" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();
    frame.origin = "http://127.0.0.1:9582";
    try testing.expectEqual(true, allowsScript(frame, "https://evil.example/x.js"));
}

test "Csp: keywords" {
    try expectPolicy(false, "script-src 'none'", "http://127.0.0.1:9582/a.js");
    try expectPolicy(true, "script-src 'self'", "http://127.0.0.1:9582/a.js");
    try expectPolicy(false, "script-src 'self'", "http://localhost:9582/a.js");
    try expectPolicy(false, "script-src 'self'", "http://127.0.0.1:1234/a.js");
    // 'unsafe-inline'/'unsafe-eval' say nothing about a URL: nothing matches.
    try expectPolicy(false, "script-src 'unsafe-inline' 'unsafe-eval'", "http://127.0.0.1:9582/a.js");
    // `*` covers network schemes but not the opaque ones.
    try expectPolicy(true, "script-src *", "https://evil.example/x.js");
    try expectPolicy(false, "script-src *", "data:text/javascript,1");
    try expectPolicy(true, "script-src * data:", "data:text/javascript,1");
}

test "Csp: scheme sources" {
    try expectPolicy(true, "script-src https:", "https://evil.example/x.js");
    try expectPolicy(false, "script-src https:", "http://evil.example/x.js");
    // An http: expression also authorises https, but not the reverse.
    try expectPolicy(true, "script-src http:", "https://evil.example/x.js");
    try expectPolicy(true, "script-src blob:", "blob:http://127.0.0.1:9582/abc");
    try expectPolicy(false, "script-src blob:", "http://127.0.0.1:9582/a.js");
}

test "Csp: host sources" {
    try expectPolicy(true, "script-src http://cdn.example.com", "http://cdn.example.com/a.js");
    try expectPolicy(false, "script-src http://cdn.example.com", "http://other.example.com/a.js");
    // Wildcard matches subdomains, never the bare domain.
    try expectPolicy(true, "script-src http://*.example.com", "http://cdn.example.com/a.js");
    try expectPolicy(false, "script-src http://*.example.com", "http://example.com/a.js");
    try expectPolicy(false, "script-src http://*.example.com", "http://example.com.evil.net/a.js");
    // An omitted port means the scheme's default port.
    try expectPolicy(false, "script-src http://cdn.example.com", "http://cdn.example.com:8080/a.js");
    try expectPolicy(true, "script-src http://cdn.example.com:8080", "http://cdn.example.com:8080/a.js");
    try expectPolicy(true, "script-src http://cdn.example.com:*", "http://cdn.example.com:8080/a.js");
    // A schemeless expression inherits the document's scheme.
    try expectPolicy(true, "script-src cdn.example.com", "http://cdn.example.com/a.js");
    try expectPolicy(true, "script-src cdn.example.com", "https://cdn.example.com/a.js");
    // Paths: a trailing slash is a prefix, anything else is exact.
    try expectPolicy(true, "script-src http://cdn.example.com/js/", "http://cdn.example.com/js/a.js");
    try expectPolicy(false, "script-src http://cdn.example.com/js/", "http://cdn.example.com/lib/a.js");
    try expectPolicy(true, "script-src http://cdn.example.com/js/a.js", "http://cdn.example.com/js/a.js");
    try expectPolicy(false, "script-src http://cdn.example.com/js/a.js", "http://cdn.example.com/js/b.js");
}

test "Csp: default-src fallback" {
    try expectPolicy(false, "default-src 'none'", "http://127.0.0.1:9582/a.js");
    try expectPolicy(false, "default-src 'self'", "http://evil.example/a.js");
    // script-src wins over a stricter default-src, whichever order they're in.
    try expectPolicy(true, "default-src 'none'; script-src 'self'", "http://127.0.0.1:9582/a.js");
    try expectPolicy(true, "script-src 'self'; default-src 'none'", "http://127.0.0.1:9582/a.js");
    // A policy that mentions neither says nothing about scripts.
    try expectPolicy(true, "img-src 'none'; style-src 'none'", "http://evil.example/a.js");
}

test "Csp: policies intersect" {
    // Comma-separated policies in one header: each must allow independently.
    try expectPolicy(false, "script-src 'self', script-src https:", "http://127.0.0.1:9582/a.js");
    try expectPolicy(true, "script-src 'self', script-src http:", "http://127.0.0.1:9582/a.js");
}

test "Csp: fails open on the undecidable" {
    // Nonces, hashes and strict-dynamic can authorise a script whose URL alone
    // proves nothing, so the whole policy stops being enforceable.
    try expectPolicy(true, "script-src 'nonce-abc123'", "http://evil.example/a.js");
    try expectPolicy(true, "script-src 'sha256-AAAA'", "http://evil.example/a.js");
    try expectPolicy(true, "script-src 'self' 'strict-dynamic'", "http://evil.example/a.js");
    try expectPolicy(true, "script-src 'some-future-keyword'", "http://evil.example/a.js");
    // Garbage that parses to no host at all.
    try expectPolicy(true, "script-src ://", "http://evil.example/a.js");
    try expectPolicy(true, "script-src :8080", "http://evil.example/a.js");
}
