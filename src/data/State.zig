//! The pinUvAuthTokenState using auth protocol two

const std = @import("std");
const Aes256 = std.crypto.core.aes.Aes256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

const crypto = @import("../crypto.zig");
const EcdhP256 = crypto.ecdh.EcdhP256;

const cose = @import("zbor").cose;

/// Buffer for a relying party id.
rp_id_raw: [128]u8 = undefined,
/// The relying party id, referencing rp_id_raw.
rp_id: ?[]const u8 = null,

/// The permissions set for the given pin token (if set).
permissions: u8 = 0,

/// The pin token is in use
in_use: bool = false,

/// The platform MUST invoke an authenticator operation
/// using the pinUvAuthToken within this time limit.
initial_usage_time_limit: u32 = 19000, // 19 s = 19000 ms
//
/// The length of time the user is considered "present",
/// as represented by the userPresent flag.
user_present_time_limit: u32 = 19000, // 19 s = 19000 ms
//
max_usage_time_period: u32 = 600000, // 10 min = 600 s = 600000 ms
//
user_verified: bool = false,

user_present: bool = false,

/// The time in ms `beginUsingPinUvAuthToken` was called.
/// Reference point to check if a time limit has been reached.
usage_timer: ?u32 = null,

/// Token has been used at least once
used: bool = false,

pinRetries: u8 = 8,

uvRetries: u8 = 8,

/// A ECDH key denoted by (a, aG) where "a" denotes
/// the private key and "aG" denotes the public key. A new
/// key is generated on each powerup.
authenticator_key_agreement_key: ?EcdhP256.KeyPair = null,

/// A random integer of length which is multiple of 16 bytes
/// (AES block length).
pin_token: [32]u8 = undefined,

/// Key for encrypting the authenticators secret data
pin_key: ?[32]u8 = null, //"\x88\x3c\xd9\xfa\x0d\x1e\x1d\xe9\xf8\xba\xb7\xf1\xf7\x78\x53\xf7\xaa\x54\xa1\xb5\x7f\x2b\xd6\x6e\x7d\xa0\x45\x79\x9f\xd7\x98\x02".*,

/// This function prepares the pinUvAuthToken for use by the platform, which has
/// invoked one of the pinUvAuthToken-issuing operations, by setting particular
/// pinUvAuthToken state variables to given use-case-specific values.
pub fn beginUsingPinUvAuthToken(self: *@This(), user_is_present: bool, start: u32) void {
    self.user_present = user_is_present;
    self.user_verified = true;
    self.initial_usage_time_limit = 19000; // 19 s = 19000 ms
    // Set the usage_timer to the current number of ms.
    // We wont use an observer but will instead always compare the
    // time_limit against usage_timer - millis().
    self.usage_timer = start;
    self.in_use = true;
}

/// Observes the pinUvAuthToken usage timer and takes appropriate action.
pub fn pinUvAuthTokenUsageTimerObserver(self: *@This(), time_ms: u32) void {
    if (self.usage_timer == null) return;
    const delta = time_ms - self.usage_timer.?;

    if (delta > self.user_present_time_limit) {
        // current user present time limit is reached
        if (self.in_use) self.user_present = false;
    }

    // If the initial usage time limit is reached without the platform using the pinUvAuthToken
    // in an authenticator operation then call stopUsingPinUvAuthToken(), and terminate these steps.
    if ((delta > self.initial_usage_time_limit and !self.used) or delta > self.max_usage_time_period) {
        self.in_use = false;
        self.initial_usage_time_limit = 19000;
        self.user_present_time_limit = 19000;
        self.user_verified = false;
        self.user_present = false;
        self.usage_timer = null;
        self.used = false;
        self.pin_key = null;
        return;
    }
}

/// If the pinUvAuthToken is in use then clear all of the pinUvAuthToken's
/// permissions, except for lbw.
pub fn clearPinUvAuthTokenPermissionsExceptLbw(self: *@This()) void {
    self.permissions &= 0x10;
}

pub fn stopUsingPinUvAuthToken(self: *@This()) void {
    self.rp_id = null;
    self.permissions = 0;
    self.is_use = false;
    self.initial_usage_time_limit = 19000;
    self.user_present_time_limit = 19000;
    self.max_usage_time_period = 600000;
    self.user_verified = false;
    self.user_present = false;
    self.usage_timer = null;
    self.used = false;
}

// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// PIN/UV Auth Protocol Two
// ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

pub fn initialize(self: *@This(), rand: *const fn ([]u8) void) void {
    self.regenerate(rand);
    self.resetPinUvAuthToken(rand);
}

/// Generate a fresh, random P-256 private key, x.
pub fn regenerate(self: *@This(), rand: *const fn ([]u8) void) void {
    var seed: [EcdhP256.secret_length]u8 = undefined;
    rand(seed[0..]);

    self.authenticator_key_agreement_key = EcdhP256.KeyPair.create(seed) catch unreachable;
    self.pin_token = undefined;
}

/// Generate a fresh 32 bytes pinUvAuthToken.
pub fn resetPinUvAuthToken(self: *@This(), rand: *const fn ([]u8) void) void {
    rand(self.pin_token[0..]);
}

pub fn getUserVerifiedFlagValue(self: *@This()) bool {
    return if (self.in_use) self.user_verified else false;
}

/// Return the public part of the key as COSE key.
pub fn getPublicKey(self: *const @This()) cose.Key {
    return cose.Key.fromP256Pub(
        .EcdhEsHkdf256,
        self.authenticator_key_agreement_key.?,
    );
}

pub fn ecdh(self: *const @This(), peer_cose_key: cose.Key) ![64]u8 {
    const shared_point = try EcdhP256.scalarmultXY(
        self.authenticator_key_agreement_key.?.secret_key,
        peer_cose_key.P256.@"-2",
        peer_cose_key.P256.@"-3",
    );
    // let z be the 32-byte, big-endian encoding of the x-coordinate
    // of the shared point
    const z: [32]u8 = shared_point.toUncompressedSec1()[1..33].*;

    // finalize shared secret
    var shared: [64]u8 = undefined;
    const salt: [32]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    const prk = Hkdf.extract(salt[0..], z[0..]);
    Hkdf.expand(shared[0..32], "CTAP2 HMAC key", prk);
    Hkdf.expand(shared[32..64], "CTAP2 AES key", prk);

    return shared;
}

/// Return the AES-256-CBC encryption of demPlaintext.
/// The iv must be randomly generated
/// The result is iv || ct
pub fn encrypt(
    iv: [16]u8,
    key: [64]u8,
    out: []u8,
    demPlaintext: []const u8,
) void {
    var _iv: [16]u8 = iv;
    std.mem.copy(u8, out[0..16], _iv[0..]);

    var ctx = Aes256.initEnc(key[32..].*);

    var i: usize = 0;
    while (i < demPlaintext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        std.mem.copy(u8, block[0..], demPlaintext[i .. i + 16]);

        // block[i] xor iv
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            block[j] ^= _iv[j];
        }

        var block2: [16]u8 = undefined;
        ctx.encrypt(&block2, &block);
        std.mem.copy(u8, out[i + 16 .. i + 32], block2[0..]);
        std.mem.copy(u8, _iv[0..], block2[0..]);
    }
}

/// Return the AES-256-CBC decryption of demCiphertext.
/// Expect key to have the form iv || ct
pub fn decrypt(
    key: [64]u8,
    out: []u8,
    demCiphertext: []const u8,
) void {
    var iv: [16]u8 = demCiphertext[0..16].*;
    var ctx = Aes256.initDec(key[32..].*);

    var i: usize = 16;
    while (i < demCiphertext.len) : (i += 16) {
        var block: [16]u8 = undefined;
        std.mem.copy(u8, block[0..], demCiphertext[i .. i + 16]);
        var block2: [16]u8 = undefined;

        ctx.decrypt(&block2, &block);

        // block[i] xor iv
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            block2[j] ^= iv[j];
        }

        std.mem.copy(u8, out[i - 16 .. i], block2[0..]);
        std.mem.copy(u8, iv[0..], block[0..]);
    }
}

/// Return the result of computing HMAC-SHA-256 on a 32-byte key and a message.
pub fn authenticate(key: [32]u8, message: []const u8) [Hmac.mac_length]u8 {
    var signature: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&signature, message, key[0..]);
    return signature;
}

/// Return true if HMAC(key, message) == signature
/// If the key is a pinUvAuthToken, it must be IN USE!
pub fn verify(key: [32]u8, message: []const u8, signature: [Hmac.mac_length]u8) bool {
    const signature2 = authenticate(key, message);
    return std.mem.eql(u8, signature2[0..], signature[0..]);
}

test "aes cbc encryption 1" {
    const iv = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const key = "\x82\x0e\x51\x5a\xfe\x6f\xdb\x9c\xf9\x25\xd5\xa7\x10\x87\x55\x3b\xee\x15\x1e\xc6\xa4\x7d\xc2\xb8\x11\xd4\xb9\x18\x57\x95\xf3\x7a\xe5\x88\xd5\xe0\xa3\x51\x16\x72\x51\x15\xca\x45\x3d\x65\x06\x99\xca\x95\x9d\x93\x07\x06\x58\xdd\xea\xb5\x06\xa9\x5a\x1d\x51\xf2";
    var out: [32]u8 = undefined;
    const in = "abcdefghjklmnopq";

    encrypt(iv, key.*, out[0..], in[0..]);

    try std.testing.expectEqualSlices(u8, iv[0..], out[0..16]);
    try std.testing.expectEqualSlices(u8, "\x2b\x0d\xaf\xde\xc8\xee\x0d\x22\x7d\xe7\x17\x78\xfe\xde\xc5\x31", out[16..]);
}

test "aes cbc decryption 1" {
    const key = "\x82\x0e\x51\x5a\xfe\x6f\xdb\x9c\xf9\x25\xd5\xa7\x10\x87\x55\x3b\xee\x15\x1e\xc6\xa4\x7d\xc2\xb8\x11\xd4\xb9\x18\x57\x95\xf3\x7a\xe5\x88\xd5\xe0\xa3\x51\x16\x72\x51\x15\xca\x45\x3d\x65\x06\x99\xca\x95\x9d\x93\x07\x06\x58\xdd\xea\xb5\x06\xa9\x5a\x1d\x51\xf2";
    var out: [16]u8 = undefined;
    const in = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x2b\x0d\xaf\xde\xc8\xee\x0d\x22\x7d\xe7\x17\x78\xfe\xde\xc5\x31";

    decrypt(key.*, out[0..], in[0..]);

    try std.testing.expectEqualSlices(u8, "abcdefghjklmnopq", out[0..]);
}

test "aes cbc encryption 2" {
    const iv = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const key = "\x82\x0e\x51\x5a\xfe\x6f\xdb\x9c\xf9\x25\xd5\xa7\x10\x87\x55\x3b\xee\x15\x1e\xc6\xa4\x7d\xc2\xb8\x11\xd4\xb9\x18\x57\x95\xf3\x7a\xe5\x88\xd5\xe0\xa3\x51\x16\x72\x51\x15\xca\x45\x3d\x65\x06\x99\xca\x95\x9d\x93\x07\x06\x58\xdd\xea\xb5\x06\xa9\x5a\x1d\x51\xf2";
    var out: [64]u8 = undefined;
    const in = "\xd2\xcb\xec\x7a\x7e\x0e\x65\x87\x0c\xeb\x7f\x1d\xbb\x98\x4a\x75\xd6\xb2\xce\x33\x2a\xb0\x84\x1b\xa6\xe6\x71\x61\x49\x74\xfd\x65\x08\xf1\xb2\x93\x1a\x25\xeb\xbc\x5b\xe9\xc5\x2c\x27\x92\x32\x99";

    encrypt(iv, key.*, out[0..], in[0..]);

    try std.testing.expectEqualSlices(u8, iv[0..], out[0..16]);
    try std.testing.expectEqualSlices(u8, "\xe1\xec\x5a\x74\x8c\xe3\x32\x5d\x37\x44\x34\x5a\xef\xfa\x93\xd1\xa7\xbb\x19\x00\x08\x6b\x59\xa5\xb4\x7a\x6b\x44\x52\x7a\xb8\xe7\xc3\x62\x4e\xfe\x45\x41\xec\xb0\x5e\xa8\x0f\xa3\xaf\xc8\x06\x1c", out[16..]);
}

test "aes cbc decryption 2" {
    const key = "\x82\x0e\x51\x5a\xfe\x6f\xdb\x9c\xf9\x25\xd5\xa7\x10\x87\x55\x3b\xee\x15\x1e\xc6\xa4\x7d\xc2\xb8\x11\xd4\xb9\x18\x57\x95\xf3\x7a\xe5\x88\xd5\xe0\xa3\x51\x16\x72\x51\x15\xca\x45\x3d\x65\x06\x99\xca\x95\x9d\x93\x07\x06\x58\xdd\xea\xb5\x06\xa9\x5a\x1d\x51\xf2";
    var out: [48]u8 = undefined;
    const in = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\xe1\xec\x5a\x74\x8c\xe3\x32\x5d\x37\x44\x34\x5a\xef\xfa\x93\xd1\xa7\xbb\x19\x00\x08\x6b\x59\xa5\xb4\x7a\x6b\x44\x52\x7a\xb8\xe7\xc3\x62\x4e\xfe\x45\x41\xec\xb0\x5e\xa8\x0f\xa3\xaf\xc8\x06\x1c";

    decrypt(key.*, out[0..], in[0..]);

    try std.testing.expectEqualSlices(u8, "\xd2\xcb\xec\x7a\x7e\x0e\x65\x87\x0c\xeb\x7f\x1d\xbb\x98\x4a\x75\xd6\xb2\xce\x33\x2a\xb0\x84\x1b\xa6\xe6\x71\x61\x49\x74\xfd\x65\x08\xf1\xb2\x93\x1a\x25\xeb\xbc\x5b\xe9\xc5\x2c\x27\x92\x32\x99", out[0..]);
}

test "authenticate 1" {
    const key = "\x0f\x76\xf0\x61\xf9\x88\x24\x0d\x19\xe5\x2e\x63\x8b\xdd\x12\x1e\x30\x1d\x03\xf0\x68\xae\xc1\xc3\x19\xd4\x76\x46\x6f\xff\xd0\x0e";
    const out = authenticate(key.*, "ctap2fido2webauthn");

    try std.testing.expectEqualSlices(u8, "\xeb\xdc\x72\xe5\xf1\x78\xfd\x08\x3f\x11\xfa\x37\x75\x54\x6c\x60\x4d\x00\x02\x9d\x44\x5c\x4e\xd2\xd5\xbf\x08\x4e\x4c\xe8\x45\x7c", out[0..]);
}

test "verify 1" {
    const key = "\x0f\x76\xf0\x61\xf9\x88\x24\x0d\x19\xe5\x2e\x63\x8b\xdd\x12\x1e\x30\x1d\x03\xf0\x68\xae\xc1\xc3\x19\xd4\x76\x46\x6f\xff\xd0\x0e";
    const out = verify(key.*, "ctap2fido2webauthn", "\xeb\xdc\x72\xe5\xf1\x78\xfd\x08\x3f\x11\xfa\x37\x75\x54\x6c\x60\x4d\x00\x02\x9d\x44\x5c\x4e\xd2\xd5\xbf\x08\x4e\x4c\xe8\x45\x7c".*);
    try std.testing.expectEqual(true, out);
}

test "verify 2" {
    const key = "\x0f\x76\xf0\x61\xf9\x88\x24\x0d\x19\xe5\x2e\x63\x8b\xdd\x12\x1e\x30\x1d\x03\xf0\x68\xae\xc1\xc3\x19\xd4\x76\x46\x6f\xff\xd0\x0e";
    const out = verify(key.*, "ctap2fido2webauthn", "\xeb\xdc\x72\xe5\xf1\x78\xfd\x08\x3f\x11\xfa\x37\x75\x54\x6c\x60\x4d\x00\x02\x9d\x44\x5c\x4e\xd2\xd5\xbf\x09\x4e\x4c\xe8\x45\x7c".*);
    try std.testing.expectEqual(false, out);
}
