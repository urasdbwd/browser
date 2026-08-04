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

const std = @import("std");
const posix = std.posix;
const libcurl = @import("../sys/libcurl.zig");

const IpFilter = @This();

/// Binary representation for bitwise CIDR comparison.
pub const Ipv4Addr = [4]u8;
pub const Ipv6Addr = [16]u8;

pub const CidrV4 = struct {
    network: u32,
    mask: u32,

    fn fromPrefix(addr: Ipv4Addr, prefix_len: u6) CidrV4 {
        const network = std.mem.readInt(u32, &addr, .big);
        const mask: u32 = if (prefix_len == 0)
            0
        else if (prefix_len == 32)
            0xFFFFFFFF
        else
            ~(@as(u32, 0xFFFFFFFF) >> @intCast(prefix_len));
        return .{ .network = network, .mask = mask };
    }
};

pub const CidrV6 = struct {
    network_hi: u64,
    network_lo: u64,
    mask_hi: u64,
    mask_lo: u64,

    fn fromPrefix(addr: Ipv6Addr, prefix_len: u8) CidrV6 {
        const network_hi = std.mem.readInt(u64, addr[0..8], .big);
        const network_lo = std.mem.readInt(u64, addr[8..16], .big);
        var mask_hi: u64 = 0;
        var mask_lo: u64 = 0;
        if (prefix_len > 0) {
            if (prefix_len < 64) {
                mask_hi = ~(@as(u64, 0xFFFFFFFFFFFFFFFF) >> @intCast(prefix_len));
            } else if (prefix_len == 64) {
                mask_hi = 0xFFFFFFFFFFFFFFFF;
            } else if (prefix_len < 128) {
                mask_hi = 0xFFFFFFFFFFFFFFFF;
                mask_lo = ~(@as(u64, 0xFFFFFFFFFFFFFFFF) >> @intCast(prefix_len - 64));
            } else {
                // prefix_len == 128
                mask_hi = 0xFFFFFFFFFFFFFFFF;
                mask_lo = 0xFFFFFFFFFFFFFFFF;
            }
        }
        return .{ .network_hi = network_hi, .network_lo = network_lo, .mask_hi = mask_hi, .mask_lo = mask_lo };
    }
};

// IpFilter fields
block_private: bool,
cidrs: ?Cidrs,

// ── Comptime helpers ─────────────────────────────────────────────────────────

/// Comptime helper: parse dotted-decimal IPv4 to [4]u8.
fn parseIpv4Comptime(comptime s: []const u8) Ipv4Addr {
    var result: Ipv4Addr = undefined;
    var octet: u8 = 0;
    var octet_idx: usize = 0;
    for (s) |ch| {
        if (ch == '.') {
            result[octet_idx] = octet;
            octet_idx += 1;
            octet = 0;
        } else {
            octet = octet * 10 + (ch - '0');
        }
    }
    result[octet_idx] = octet;
    return result;
}

/// Comptime helper: build a CidrV4.
fn makeCidrV4(comptime addr: []const u8, comptime prefix: u6) CidrV4 {
    return CidrV4.fromPrefix(parseIpv4Comptime(addr), prefix);
}

/// Comptime helper: build a CidrV6 from a 16-byte literal array.
fn makeCidrV6(comptime bytes: Ipv6Addr, comptime prefix: u8) CidrV6 {
    return CidrV6.fromPrefix(bytes, prefix);
}

// ── Comptime CIDR range tables ───────────────────────────────────────────────

// Non-global-unicast ranges from the IANA IPv4 Special-Purpose Address
// Registry, plus multicast from RFC 1112.
const PRIVATE_V4 = [_]CidrV4{
    makeCidrV4("0.0.0.0", 8), // current network
    makeCidrV4("10.0.0.0", 8), // RFC1918
    makeCidrV4("100.64.0.0", 10), // shared address space
    makeCidrV4("127.0.0.0", 8), // loopback
    makeCidrV4("169.254.0.0", 16), // link-local
    makeCidrV4("172.16.0.0", 12), // RFC1918
    makeCidrV4("192.0.0.0", 24), // IETF protocol assignments
    makeCidrV4("192.0.2.0", 24), // documentation
    makeCidrV4("192.88.99.0", 24), // deprecated 6to4 relay anycast
    makeCidrV4("192.168.0.0", 16), // RFC1918
    makeCidrV4("198.18.0.0", 15), // benchmarking
    makeCidrV4("198.51.100.0", 24), // documentation
    makeCidrV4("203.0.113.0", 24), // documentation
    makeCidrV4("224.0.0.0", 4), // multicast
    makeCidrV4("240.0.0.0", 4), // reserved, including limited broadcast
};

const GLOBAL_V4_EXCEPTIONS = [_]CidrV4{
    makeCidrV4("192.0.0.9", 32), // PCP anycast
    makeCidrV4("192.0.0.10", 32), // TURN anycast
};

// Non-global-unicast ranges from the IANA IPv6 Special-Purpose Address
// Registry, plus multicast from RFC 4291. IPv4-mapped and well-known NAT64
// addresses are checked against the IPv4 policy by isBlockedV6.
const PRIVATE_V6 = [_]CidrV6{
    // ::/96 — unspecified, loopback, and deprecated IPv4-compatible addresses
    makeCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 96),
    // 64:ff9b:1::/48 — local-use IPv4/IPv6 translation
    makeCidrV6(.{ 0, 0x64, 0xff, 0x9b, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 48),
    // 100::/64 — discard-only
    makeCidrV6(.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 64),
    // 100:0:0:1::/64 — dummy prefix
    makeCidrV6(.{ 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, 64),
    // 2001::/23 — IETF protocol assignments
    makeCidrV6(.{ 0x20, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 23),
    // 2001:db8::/32 — documentation
    makeCidrV6(.{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 32),
    // 2002::/16 — 6to4
    makeCidrV6(.{ 0x20, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 16),
    // 3fff::/20 — documentation
    makeCidrV6(.{ 0x3f, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 20),
    // 5f00::/16 — segment-routing SIDs
    makeCidrV6(.{ 0x5f, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 16),
    // fc00::/7 — ULA
    makeCidrV6(.{ 0xfc, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 7),
    // fe80::/10 — link-local
    makeCidrV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 10),
    // fec0::/10 — deprecated site-local
    makeCidrV6(.{ 0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 10),
    // ff00::/8 — multicast
    makeCidrV6(.{ 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 8),
};

const GLOBAL_V6_EXCEPTIONS = [_]CidrV6{
    // Globally reachable sub-allocations of 2001::/23.
    makeCidrV6(.{ 0x20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 128),
    makeCidrV6(.{ 0x20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }, 128),
    makeCidrV6(.{ 0x20, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 }, 128),
    makeCidrV6(.{ 0x20, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 32),
    makeCidrV6(.{ 0x20, 1, 0, 4, 1, 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 48),
    makeCidrV6(.{ 0x20, 1, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 28),
    makeCidrV6(.{ 0x20, 1, 0, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 28),
};

// ── Runtime IP parsing ───────────────────────────────────────────────────────

/// Parse dotted-decimal IPv4 string to 4-byte array. Returns null on parse failure.
fn parseIpv4(str: []const u8) ?Ipv4Addr {
    var addr: Ipv4Addr = undefined;
    var it = std.mem.splitScalar(u8, str, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        addr[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return addr;
}

/// Parse IPv6 string to 16-byte array. Handles compressed notation.
/// Strips zone ID (e.g. "fe80::1%eth0" -> "fe80::1").
/// Returns null on parse failure.
fn parseIpv6(str: []const u8) ?Ipv6Addr {
    // Strip zone ID
    const clean = if (std.mem.indexOfScalar(u8, str, '%')) |idx| str[0..idx] else str;
    const parsed = std.Io.net.IpAddress.parseIp6(clean, 0) catch return null;
    return parsed.ip6.bytes;
}

// ── CIDR matching ────────────────────────────────────────────────────────────

/// Detect IPv4-mapped IPv6 address (::ffff:x.x.x.x).
/// Returns the embedded IPv4 address if detected, null otherwise.
fn isIpv4Mapped(addr: Ipv6Addr) ?Ipv4Addr {
    // IPv4-mapped prefix: 10 zero bytes + 2 0xFF bytes
    const prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (!std.mem.eql(u8, addr[0..12], &prefix)) return null;
    return addr[12..16].*;
}

/// Detect the RFC 6052 well-known NAT64 prefix (64:ff9b::/96).
/// Network-specific translation prefixes cannot be inferred from an address;
/// operators must add their configured prefix to the custom block CIDRs.
fn isIpv4Translated(addr: Ipv6Addr) ?Ipv4Addr {
    const prefix = [12]u8{ 0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (!std.mem.eql(u8, addr[0..12], &prefix)) return null;
    return addr[12..16].*;
}

/// Check if IPv4 address falls within a CIDR range.
fn matchesCidrV4(addr: Ipv4Addr, cidr: CidrV4) bool {
    const addr_int = std.mem.readInt(u32, &addr, .big);
    return (addr_int ^ cidr.network) & cidr.mask == 0;
}

/// Check if IPv6 address falls within a CIDR range.
fn matchesCidrV6(addr: Ipv6Addr, cidr: CidrV6) bool {
    const addr_hi = std.mem.readInt(u64, addr[0..8], .big);
    const addr_lo = std.mem.readInt(u64, addr[8..16], .big);
    return ((addr_hi ^ cidr.network_hi) & cidr.mask_hi == 0) and
        ((addr_lo ^ cidr.network_lo) & cidr.mask_lo == 0);
}

// ── Public API ───────────────────────────────────────────────────────────────

pub const Cidrs = struct {
    v4: []CidrV4,
    v6: []CidrV6,
    allow_v4: []CidrV4,
    allow_v6: []CidrV6,

    pub fn deinit(self: Cidrs, allocator: std.mem.Allocator) void {
        allocator.free(self.v4);
        allocator.free(self.v6);
        allocator.free(self.allow_v4);
        allocator.free(self.allow_v6);
    }
};

/// Parse a comma-separated list of CIDR strings (e.g. "10.0.0.0/8,2001:db8::/32")
/// into a Cidrs struct. Entries prefixed with '-' are added to the allow list
/// (e.g. "-10.0.0.42/32" exempts that IP from blocking).
/// Caller owns the returned Cidrs and must free them via Cidrs.deinit.
/// Returns error.InvalidCidr on any malformed entry.
pub fn parseCidrList(
    allocator: std.mem.Allocator,
    cidr_str: []const u8,
) !Cidrs {
    var v4_list: std.ArrayList(CidrV4) = .empty;
    errdefer v4_list.deinit(allocator);
    var v6_list: std.ArrayList(CidrV6) = .empty;
    errdefer v6_list.deinit(allocator);
    var allow_v4_list: std.ArrayList(CidrV4) = .empty;
    errdefer allow_v4_list.deinit(allocator);
    var allow_v6_list: std.ArrayList(CidrV6) = .empty;
    errdefer allow_v6_list.deinit(allocator);

    var it = std.mem.splitScalar(u8, cidr_str, ',');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;

        const is_allow = trimmed[0] == '-';
        const cidr_part = if (is_allow) trimmed[1..] else trimmed;

        const slash = std.mem.indexOfScalar(u8, cidr_part, '/') orelse return error.InvalidCidr;
        const addr_str = cidr_part[0..slash];
        const prefix_str = cidr_part[slash + 1 ..];

        if (parseIpv4(addr_str)) |v4| {
            const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidCidr;
            if (prefix > 32) return error.InvalidCidr;
            const cidr = CidrV4.fromPrefix(v4, @intCast(prefix));
            if (is_allow) {
                try allow_v4_list.append(allocator, cidr);
            } else {
                try v4_list.append(allocator, cidr);
            }
        } else if (parseIpv6(addr_str)) |v6| {
            const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return error.InvalidCidr;
            if (prefix > 128) return error.InvalidCidr;
            const cidr = CidrV6.fromPrefix(v6, prefix);
            if (is_allow) {
                try allow_v6_list.append(allocator, cidr);
            } else {
                try v6_list.append(allocator, cidr);
            }
        } else {
            return error.InvalidCidr;
        }
    }

    const v4 = try v4_list.toOwnedSlice(allocator);
    errdefer allocator.free(v4);
    const v6 = try v6_list.toOwnedSlice(allocator);
    errdefer allocator.free(v6);
    const allow_v4 = try allow_v4_list.toOwnedSlice(allocator);
    errdefer allocator.free(allow_v4);
    const allow_v6 = try allow_v6_list.toOwnedSlice(allocator);
    return .{ .v4 = v4, .v6 = v6, .allow_v4 = allow_v4, .allow_v6 = allow_v6 };
}

// Create an IpFilter. Set block_private to block outbound requests to
// non-global-unicast and multicast ranges. Pass parsed CIDRs for additional
// custom block/allow ranges; the filter takes ownership of the Cidrs and will
// free them on deinit.
pub fn init(
    block_private: bool,
    cidrs: ?Cidrs,
) IpFilter {
    return .{
        .block_private = block_private,
        .cidrs = cidrs,
    };
}

pub fn deinit(self: IpFilter, allocator: std.mem.Allocator) void {
    if (self.cidrs) |c| {
        c.deinit(allocator);
    }
}

pub fn hasBlockedRanges(self: *const IpFilter) bool {
    if (self.block_private) return true;
    const cidrs = self.cidrs orelse return false;
    return cidrs.v4.len > 0 or cidrs.v6.len > 0;
}

fn isAllowedV4(self: *const IpFilter, addr: Ipv4Addr) bool {
    if (self.cidrs) |c| {
        for (c.allow_v4) |cidr| {
            if (matchesCidrV4(addr, cidr)) return true;
        }
    }
    return false;
}

fn isAllowedV6(self: *const IpFilter, addr: Ipv6Addr) bool {
    if (self.cidrs) |c| {
        for (c.allow_v6) |cidr| {
            if (matchesCidrV6(addr, cidr)) return true;
        }
    }
    return false;
}

fn isCustomBlockedV4(self: *const IpFilter, addr: Ipv4Addr) bool {
    if (self.cidrs) |c| {
        for (c.v4) |cidr| {
            if (matchesCidrV4(addr, cidr)) return true;
        }
    }
    return false;
}

fn isCustomBlockedV6(self: *const IpFilter, addr: Ipv6Addr) bool {
    if (self.cidrs) |c| {
        for (c.v6) |cidr| {
            if (matchesCidrV6(addr, cidr)) return true;
        }
    }
    return false;
}

fn isBlockedV4(self: *const IpFilter, addr: Ipv4Addr) bool {
    if (self.isAllowedV4(addr)) return false;
    if (self.isCustomBlockedV4(addr)) return true;

    if (self.block_private) {
        for (GLOBAL_V4_EXCEPTIONS) |cidr| {
            if (matchesCidrV4(addr, cidr)) {
                return false;
            }
        }
        for (PRIVATE_V4) |cidr| {
            if (matchesCidrV4(addr, cidr)) {
                return true;
            }
        }
    }

    return false;
}

fn isBlockedV6(self: *const IpFilter, addr: Ipv6Addr) bool {
    if (self.isAllowedV6(addr)) return false;

    const embedded_v4: ?Ipv4Addr = if (isIpv4Mapped(addr)) |v4|
        v4
    else
        isIpv4Translated(addr);
    if (embedded_v4) |v4| {
        // Explicit allows take precedence across both representations.
        if (self.isAllowedV4(v4)) return false;
        if (self.isCustomBlockedV6(addr)) return true;
        return self.isBlockedV4(v4);
    }

    if (self.isCustomBlockedV6(addr)) return true;

    if (self.block_private) {
        for (GLOBAL_V6_EXCEPTIONS) |cidr| {
            if (matchesCidrV6(addr, cidr)) {
                return false;
            }
        }
        for (PRIVATE_V6) |cidr| {
            if (matchesCidrV6(addr, cidr)) {
                return true;
            }
        }
    }
    return false;
}

/// Check if an address from curl's opensocket callback should be blocked.
/// Extracts the IP directly from the sockaddr structure; no string parsing needed.
/// Fail-closed: unknown address family -> true (blocked).
pub fn isBlockedSockaddr(self: *const IpFilter, sa: *const libcurl.CurlSockAddr) bool {
    switch (sa.family) {
        posix.AF.INET => {
            const sin: *const posix.sockaddr.in = @ptrCast(&sa.addr);
            // sin.addr is in network byte order (big-endian); convert to host bytes
            const bytes: [4]u8 = @bitCast(sin.addr);
            return self.isBlockedV4(bytes);
        },
        posix.AF.INET6 => {
            const sin6: *const posix.sockaddr.in6 = @ptrCast(&sa.addr);
            return self.isBlockedV6(sin6.addr);
        },
        else => return true, // unknown family -> fail-closed
    }
}

const testing = @import("../testing.zig");
test "IpFilter: IPv4 CIDR matching: private group boundaries" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("0.0.0.0"));

    // Loopback
    try testing.expect(filter.testBlocked("127.0.0.1"));
    try testing.expect(filter.testBlocked("127.255.255.255"));
    try testing.expect(!filter.testBlocked("128.0.0.1"));

    // RFC1918 10.0.0.0/8
    try testing.expect(filter.testBlocked("10.0.0.1"));
    try testing.expect(filter.testBlocked("10.255.255.255"));
    try testing.expect(!filter.testBlocked("11.0.0.0"));

    // RFC1918 172.16.0.0/12 — critical boundary
    try testing.expect(!filter.testBlocked("172.15.255.255")); // MUST NOT block
    try testing.expect(filter.testBlocked("172.16.0.0")); // MUST block
    try testing.expect(filter.testBlocked("172.31.255.255")); // MUST block
    try testing.expect(!filter.testBlocked("172.32.0.0")); // MUST NOT block

    // RFC1918 192.168.0.0/16
    try testing.expect(filter.testBlocked("192.168.0.1"));
    try testing.expect(!filter.testBlocked("192.169.0.0"));

    // Link-local
    try testing.expect(filter.testBlocked("169.254.1.1"));
    try testing.expect(!filter.testBlocked("169.255.0.0"));

    // Public IP — must NOT be blocked
    try testing.expect(!filter.testBlocked("8.8.8.8"));
    try testing.expect(!filter.testBlocked("1.1.1.1"));
    try testing.expect(!filter.testBlocked("93.184.216.34")); // example.com
}

test "IpFilter: IPv4 special-purpose boundaries" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    const cases = [_]struct {
        ip: []const u8,
        blocked: bool,
    }{
        .{ .ip = "100.63.255.255", .blocked = false },
        .{ .ip = "100.64.0.0", .blocked = true },
        .{ .ip = "100.127.255.255", .blocked = true },
        .{ .ip = "100.128.0.0", .blocked = false },
        .{ .ip = "192.0.0.0", .blocked = true },
        .{ .ip = "192.0.0.8", .blocked = true },
        .{ .ip = "192.0.0.9", .blocked = false },
        .{ .ip = "192.0.0.10", .blocked = false },
        .{ .ip = "192.0.0.11", .blocked = true },
        .{ .ip = "192.0.0.169", .blocked = true },
        .{ .ip = "192.0.0.170", .blocked = true },
        .{ .ip = "192.0.0.171", .blocked = true },
        .{ .ip = "192.0.0.172", .blocked = true },
        .{ .ip = "192.0.1.0", .blocked = false },
        .{ .ip = "192.0.2.1", .blocked = true },
        .{ .ip = "192.88.98.255", .blocked = false },
        .{ .ip = "192.88.99.0", .blocked = true },
        .{ .ip = "192.88.99.255", .blocked = true },
        .{ .ip = "192.88.100.0", .blocked = false },
        .{ .ip = "198.17.255.255", .blocked = false },
        .{ .ip = "198.18.0.0", .blocked = true },
        .{ .ip = "198.19.255.255", .blocked = true },
        .{ .ip = "198.20.0.0", .blocked = false },
        .{ .ip = "198.51.100.1", .blocked = true },
        .{ .ip = "203.0.113.1", .blocked = true },
        .{ .ip = "223.255.255.255", .blocked = false },
        .{ .ip = "224.0.0.0", .blocked = true },
        .{ .ip = "239.255.255.255", .blocked = true },
        .{ .ip = "240.0.0.0", .blocked = true },
        .{ .ip = "255.255.255.255", .blocked = true },
    };

    for (cases) |case| {
        try testing.expectEqual(case.blocked, filter.testBlocked(case.ip));
    }
}

test "IpFilter: IPv6 CIDR matching: private group" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("::")); // unspecified
    try testing.expect(filter.testBlocked("::1")); // localhost
    try testing.expect(filter.testBlocked("fe80::1")); // link-local
    try testing.expect(filter.testBlocked("fc00::1")); // ULA
    try testing.expect(filter.testBlocked("fd00::1")); // ULA (fd is fc00::/7)
    try testing.expect(filter.testBlocked("2001:db8::1")); // documentation
    try testing.expect(filter.testBlocked("3fff::1")); // documentation
    try testing.expect(filter.testBlocked("100::1")); // discard-only
    try testing.expect(filter.testBlocked("ff02::1")); // multicast
    try testing.expect(!filter.testBlocked("2606:4700::1111")); // Cloudflare
}

test "IpFilter: IPv6 special-purpose boundaries" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    const cases = [_]struct {
        ip: []const u8,
        blocked: bool,
    }{
        .{ .ip = "64:ff9b::1", .blocked = true },
        .{ .ip = "64:ff9b::808:808", .blocked = false },
        .{ .ip = "64:ff9b:1::", .blocked = true },
        .{ .ip = "64:ff9b:1:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "64:ff9b:2::", .blocked = false },
        .{ .ip = "100::", .blocked = true },
        .{ .ip = "100::ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "100:0:0:1::1", .blocked = true },
        .{ .ip = "100:0:0:2::", .blocked = false },
        .{ .ip = "2001::", .blocked = true },
        .{ .ip = "2001:0:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "2001:1::1", .blocked = false },
        .{ .ip = "2001:1::4", .blocked = true },
        .{ .ip = "2001:2::1", .blocked = true },
        .{ .ip = "2001:3::1", .blocked = false },
        .{ .ip = "2001:4:112::1", .blocked = false },
        .{ .ip = "2001:4:113::1", .blocked = true },
        .{ .ip = "2001:f:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "2001:10::", .blocked = true },
        .{ .ip = "2001:1f:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "2001:20::", .blocked = false },
        .{ .ip = "2001:30::", .blocked = false },
        .{ .ip = "2001:40::", .blocked = true },
        .{ .ip = "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "2001:200::", .blocked = false },
        .{ .ip = "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "2001:db9::", .blocked = false },
        .{ .ip = "2002::1", .blocked = true },
        .{ .ip = "2003::1", .blocked = false },
        .{ .ip = "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "3fff:1000::", .blocked = false },
        .{ .ip = "5f00::1", .blocked = true },
        .{ .ip = "5f01::1", .blocked = false },
        .{ .ip = "fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = false },
        .{ .ip = "fe80::", .blocked = true },
        .{ .ip = "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
        .{ .ip = "fec0::", .blocked = true },
        .{ .ip = "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", .blocked = true },
    };

    for (cases) |case| {
        try testing.expectEqual(case.blocked, filter.testBlocked(case.ip));
    }
}

test "IpFilter: IPv4-mapped IPv6 bypass prevention" {
    const filter = IpFilter.init(true, null);
    defer filter.deinit(testing.allocator);

    // ::ffff:127.0.0.1 must be blocked (maps to loopback)
    try testing.expect(filter.testBlocked("::ffff:127.0.0.1"));
    // ::ffff:10.0.0.1 must be blocked (maps to RFC1918)
    try testing.expect(filter.testBlocked("::ffff:10.0.0.1"));
    // Mapped shared and documentation ranges must also be blocked
    try testing.expect(filter.testBlocked("::ffff:100.64.0.1"));
    try testing.expect(filter.testBlocked("::ffff:192.0.2.1"));
    // ::ffff:8.8.8.8 must NOT be blocked (maps to public)
    try testing.expect(!filter.testBlocked("::ffff:8.8.8.8"));
}

test "IpFilter: IPv6 CIDRs override embedded IPv4 decisions" {
    const cidrs = try parseCidrList(
        testing.allocator,
        "-::ffff:127.0.0.1/128,-64:ff9b::7f00:1/128,::ffff:8.8.8.8/128,64:ff9b::808:808/128",
    );
    const filter = IpFilter.init(true, cidrs);
    defer filter.deinit(testing.allocator);

    try testing.expect(!filter.testBlocked("::ffff:127.0.0.1"));
    try testing.expect(!filter.testBlocked("64:ff9b::7f00:1"));
    try testing.expect(filter.testBlocked("::ffff:8.8.8.8"));
    try testing.expect(filter.testBlocked("64:ff9b::808:808"));
}

test "IpFilter: allow CIDRs take precedence across embedded forms" {
    const cidrs = try parseCidrList(
        testing.allocator,
        "-127.0.0.1/32,0:0:0:0:0:ffff:0:0/96,64:ff9b:0:0:0:0:0:0/96,8.8.8.8/32,-0:0:0:0:0:ffff:808:808/128,-64:ff9b:0:0:0:0:808:808/128",
    );
    const filter = IpFilter.init(true, cidrs);
    defer filter.deinit(testing.allocator);

    // An IPv4 allow overrides a block on the outer IPv6 form.
    try testing.expect(!filter.testBlocked("::ffff:127.0.0.1"));
    try testing.expect(!filter.testBlocked("64:ff9b::7f00:1"));

    // An IPv6 allow overrides a block on the embedded IPv4 form.
    try testing.expect(!filter.testBlocked("::ffff:8.8.8.8"));
    try testing.expect(!filter.testBlocked("64:ff9b::808:808"));
}

test "IpFilter: fail-closed: unknown address family blocked by isBlockedSockaddr" {
    const filter = IpFilter.init(false, null);
    defer filter.deinit(testing.allocator);

    // Construct a sockaddr with an unknown address family
    var sa: libcurl.CurlSockAddr = .{
        .family = 255, // not AF_INET or AF_INET6
        .socktype = posix.SOCK.STREAM,
        .protocol = 0,
        .addrlen = 0,
        .addr = undefined,
    };
    try testing.expect(filter.isBlockedSockaddr(&sa));
}

test "IpFilter: custom CIDR ranges" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24");
    const filter = IpFilter.init(false, cidrs);
    defer filter.deinit(testing.allocator);

    try testing.expect(filter.testBlocked("203.0.113.1")); // in custom range
    try testing.expect(filter.testBlocked("203.0.113.255")); // in custom range
    try testing.expect(!filter.testBlocked("203.0.114.0")); // outside custom range
    try testing.expect(!filter.testBlocked("8.8.8.8")); // not in range
}

test "IpFilter: private group blocks cloud metadata IP via link-local" {
    // 169.254.169.254 is in link-local (169.254.0.0/16) which is in the private group.
    // Users who want targeted cloud-metadata-only blocking can use --block-cidrs.
    const filter_private = IpFilter.init(true, null);
    defer filter_private.deinit(testing.allocator);
    const filter_none = IpFilter.init(false, null);
    defer filter_none.deinit(testing.allocator);

    try testing.expect(filter_private.testBlocked("169.254.169.254")); // blocked via link-local
    try testing.expect(!filter_none.testBlocked("169.254.169.254")); // not blocked when disabled
}

test "IpFilter: parseCidrList: mixed IPv4 and IPv6" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24, 2001:db8::/32, 192.168.1.0/24");

    try testing.expectEqual(2, cidrs.v4.len);
    try testing.expectEqual(1, cidrs.v6.len);

    // spot-check: 203.0.113.0/24 and 192.168.1.0/24
    const f = IpFilter.init(false, cidrs);
    defer f.deinit(testing.allocator);
    try testing.expect(f.testBlocked("203.0.113.1"));
    try testing.expect(!f.testBlocked("203.0.114.0"));
    try testing.expect(f.testBlocked("192.168.1.1"));
    try testing.expect(f.testBlocked("2001:db8::1"));
    try testing.expect(!f.testBlocked("2001:db9::1"));
}

test "IpFilter: allow list exempts from private blocking" {
    const cidrs = try parseCidrList(testing.allocator, "-10.0.0.42/32,-100.64.0.1/32,-fc00::1/128,-100::1/128");
    const filter = IpFilter.init(true, cidrs);
    defer filter.deinit(testing.allocator);

    // Allowed IPs pass through despite being in private ranges
    try testing.expect(!filter.testBlocked("10.0.0.42"));
    try testing.expect(!filter.testBlocked("100.64.0.1"));
    try testing.expect(!filter.testBlocked("::ffff:100.64.0.1"));
    try testing.expect(!filter.testBlocked("64:ff9b::6440:1"));
    try testing.expect(!filter.testBlocked("fc00::1"));
    try testing.expect(!filter.testBlocked("100::1"));

    // Other private IPs still blocked
    try testing.expect(filter.testBlocked("10.0.0.43"));
    try testing.expect(filter.testBlocked("::ffff:100.64.0.2"));
    try testing.expect(filter.testBlocked("64:ff9b::6440:2"));
    try testing.expect(filter.testBlocked("10.0.0.41"));
    try testing.expect(filter.testBlocked("192.168.1.1"));
    try testing.expect(filter.testBlocked("fc00::2"));
}

test "IpFilter: hasBlockedRanges ignores allow-only CIDRs" {
    const none = IpFilter.init(false, null);
    defer none.deinit(testing.allocator);
    try testing.expect(!none.hasBlockedRanges());

    const private = IpFilter.init(true, null);
    defer private.deinit(testing.allocator);
    try testing.expect(private.hasBlockedRanges());

    const blocked_cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24");
    const custom = IpFilter.init(false, blocked_cidrs);
    defer custom.deinit(testing.allocator);
    try testing.expect(custom.hasBlockedRanges());

    const allowed_cidrs = try parseCidrList(testing.allocator, "-10.0.0.0/8");
    const allow_only = IpFilter.init(false, allowed_cidrs);
    defer allow_only.deinit(testing.allocator);
    try testing.expect(!allow_only.hasBlockedRanges());
}

test "IpFilter: allow list exempts from custom CIDR blocking" {
    const cidrs = try parseCidrList(testing.allocator, "203.0.113.0/24,-203.0.113.100/32");
    const filter = IpFilter.init(false, cidrs);
    defer filter.deinit(testing.allocator);

    try testing.expect(!filter.testBlocked("203.0.113.100")); // allowed
    try testing.expect(filter.testBlocked("203.0.113.99")); // blocked
    try testing.expect(filter.testBlocked("203.0.113.101")); // blocked
}

test "IpFilter: parseCidrList: allow entries with '-' prefix" {
    const cidrs = try parseCidrList(testing.allocator, "10.0.0.0/8,-10.0.0.42/32,-fc00::1/128");

    try testing.expectEqual(1, cidrs.v4.len);
    try testing.expectEqual(0, cidrs.v6.len);
    try testing.expectEqual(1, cidrs.allow_v4.len);
    try testing.expectEqual(1, cidrs.allow_v6.len);

    const f = IpFilter.init(false, cidrs);
    defer f.deinit(testing.allocator);
    try testing.expect(!f.testBlocked("10.0.0.42")); // allowed
    try testing.expect(f.testBlocked("10.0.0.43")); // blocked
    try testing.expect(!f.testBlocked("fc00::1")); // allowed (not blocked by custom, but allow-listed)
}

test "IpFilter: parseCidrList: invalid input returns error" {
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "not-a-cidr"));
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0/33")); // prefix too large
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0")); // missing prefix
    try testing.expectError(error.InvalidCidr, parseCidrList(testing.allocator, "10.0.0.0/abc")); // non-numeric prefix
}

test "IpFilter: matchesCidrV4: exact match /32" {
    const cidr = CidrV4.fromPrefix(.{ 192, 168, 1, 100 }, 32);
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 100 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 101 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 99 }, cidr));
}

test "IpFilter: matchesCidrV4: /0 matches everything" {
    const cidr = CidrV4.fromPrefix(.{ 0, 0, 0, 0 }, 0);
    try testing.expect(matchesCidrV4(.{ 0, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 255, 255, 255, 255 }, cidr));
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 1 }, cidr));
}

test "IpFilter: matchesCidrV4: /8 boundary" {
    const cidr = CidrV4.fromPrefix(.{ 10, 0, 0, 0 }, 8);
    try testing.expect(matchesCidrV4(.{ 10, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 10, 255, 255, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 11, 0, 0, 0 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 9, 255, 255, 255 }, cidr));
}

test "IpFilter: matchesCidrV4: /12 boundary (172.16.0.0/12)" {
    const cidr = CidrV4.fromPrefix(.{ 172, 16, 0, 0 }, 12);
    // In range
    try testing.expect(matchesCidrV4(.{ 172, 16, 0, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 172, 31, 255, 255 }, cidr));
    try testing.expect(matchesCidrV4(.{ 172, 20, 100, 50 }, cidr));
    // Out of range
    try testing.expect(!matchesCidrV4(.{ 172, 15, 255, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 172, 32, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV4: /24 network" {
    const cidr = CidrV4.fromPrefix(.{ 203, 0, 113, 0 }, 24);
    try testing.expect(matchesCidrV4(.{ 203, 0, 113, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 203, 0, 113, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 203, 0, 112, 255 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 203, 0, 114, 0 }, cidr));
}

test "IpFilter: matchesCidrV4: non-byte-aligned /25" {
    const cidr = CidrV4.fromPrefix(.{ 192, 168, 1, 0 }, 25);
    // 192.168.1.0 - 192.168.1.127 should match
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 0 }, cidr));
    try testing.expect(matchesCidrV4(.{ 192, 168, 1, 127 }, cidr));
    // 192.168.1.128+ should not match
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 128 }, cidr));
    try testing.expect(!matchesCidrV4(.{ 192, 168, 1, 255 }, cidr));
}

test "IpFilter: matchesCidrV6: /128 exact match" {
    const addr: Ipv6Addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const cidr = CidrV6.fromPrefix(addr, 128);
    try testing.expect(matchesCidrV6(addr, cidr));

    var different = addr;
    different[15] = 2;
    try testing.expect(!matchesCidrV6(different, cidr));
}

test "IpFilter: matchesCidrV6: /0 matches everything" {
    const cidr = CidrV6.fromPrefix(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 0);
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
}

test "IpFilter: matchesCidrV6: /64 boundary" {
    // 2001:db8::/64
    const cidr = CidrV6.fromPrefix(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 64);
    // In range - any suffix in lower 64 bits
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    // Out of range - different prefix
    try testing.expect(!matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: /48 network" {
    // 2001:db8:abcd::/48
    const cidr = CidrV6.fromPrefix(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 48);
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xcd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    try testing.expect(!matchesCidrV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0xab, 0xce, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: /10 link-local (fe80::/10)" {
    const cidr = CidrV6.fromPrefix(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 10);
    // fe80:: through febf:: should match (first 10 bits: 1111111010)
    try testing.expect(matchesCidrV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0xfe, 0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, cidr));
    // fec0:: should NOT match (11th bit differs)
    try testing.expect(!matchesCidrV6(.{ 0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, cidr));
}

test "IpFilter: matchesCidrV6: prefix > 64 bits (/96)" {
    // ::ffff:0:0/96 (IPv4-mapped prefix)
    const cidr = CidrV6.fromPrefix(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0 }, 96);
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1 }, cidr));
    try testing.expect(matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1 }, cidr));
    try testing.expect(!matchesCidrV6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 192, 168, 1, 1 }, cidr));
}

/// Test-only convenience: parse an IP string and check against the filter.
/// Test inputs must be valid IPs; unreachable on parse failure.
fn testBlocked(self: *const IpFilter, ip: []const u8) bool {
    if (parseIpv4(ip)) |v4| return self.isBlockedV4(v4);
    if (parseIpv6(ip)) |v6| return self.isBlockedV6(v6);
    unreachable;
}
