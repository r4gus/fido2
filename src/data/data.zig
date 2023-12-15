const std = @import("std");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

const cbor = @import("zbor");
const crypto = @import("../crypto.zig");
const Resources = @import("../Resources.zig");

/// The state/ data of the Authenticator
pub const PublicData = struct {
    meta: struct {
        /// Valid Y/n
        valid: bool,
        /// HKDF-SHA256 salt for key extraction
        salt: [32]u8,
        /// 96-bit counter for the Aes256Gcm nonce
        nonce_ctr: [12]u8,
        /// Pin attempts left
        pin_retries: u8,
    },
    /// Force a pin change
    forcePINChange: ?bool = null,
    /// The encrypted secret data (e.g. master secret)
    c: []const u8, // ms || pinHash || pinLen || signCtr || padding
    /// The tag belonging to the encrypted data
    tag: [16]u8,

    pub fn isValid(self: *const @This()) bool {
        return self.meta.valid;
    }

    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.c);
    }

    pub fn set_secret_data(
        self: *@This(),
        sd: *const SecretData,
        pin_key: [32]u8,
        allocator: std.mem.Allocator,
    ) void {
        // Update nonce counter
        var nctr: u96 = std.mem.readIntSliceLittle(u96, self.meta.nonce_ctr[0..]);
        nctr += 1;
        var nctr_raw: [12]u8 = undefined;
        std.mem.writeIntSliceLittle(u96, nctr_raw[0..], nctr);

        // Encrypt data
        var tmp_tag: [16]u8 = undefined;
        const tmp_c = encryptSecretData(
            allocator,
            &tmp_tag,
            sd,
            pin_key,
            nctr_raw,
        ) catch unreachable;

        self.deinit(allocator);

        self.c = tmp_c;
        std.mem.copy(u8, self.tag[0..], tmp_tag[0..]);
        self.meta.nonce_ctr = nctr_raw;
    }

    /// Load the public data from memory.
    pub fn load(
        f: *const fn (a: std.mem.Allocator) Resources.LoadError![]u8,
        allocator: std.mem.Allocator,
    ) !@This() {
        // Loading may fail due to no data being present or corrupted.
        // Storing data should always succeed.
        var d = try f(allocator);
        defer allocator.free(d);
        return try cbor.parse(@This(), try cbor.DataItem.new(d), .{
            .allocator = allocator,
        });
    }

    /// Store the given data to memory.
    pub fn store(
        self: *@This(),
        s: *const fn (d: []const u8) void,
        allocator: std.mem.Allocator,
    ) void {
        var arr = std.ArrayList(u8).init(allocator);
        defer arr.deinit();
        var writer = arr.writer();

        // reserve bytes for cbor size
        writer.writeAll("\x00\x00\x00\x00") catch unreachable;

        // Serialize PublicData to cbor
        cbor.stringify(self, .{}, writer) catch unreachable;

        // Prepend size. This might help reading back the data if no
        // underlying file system is available.
        const len = @intCast(u32, arr.items.len - 4);
        std.mem.writeIntSliceLittle(u32, arr.items[0..4], len);

        // Now store `SIZE || CBOR`
        s(arr.items[0..]);
    }

    /// Reset the authenticator to a default state, invalidating the
    /// master secret.
    pub fn reset(
        s: *const fn (d: []const u8) void,
        rand: *const fn (b: []u8) void,
        allocator: std.mem.Allocator,
        ctr: [12]u8,
    ) void {
        const default_pin = "candystick";

        // Prepare secret data
        var secret_data: SecretData = undefined;
        secret_data.master_secret = crypto.ms.create_master_secret(rand);
        secret_data.pin_hash = crypto.pin.pin_hash(default_pin);
        secret_data.pin_length = default_pin.len;
        secret_data.sign_ctr = 0;

        // Prepare public data
        var public_data: PublicData = undefined;
        defer public_data.deinit(allocator);
        public_data.meta.valid = true;
        rand(public_data.meta.salt[0..]);
        //public_data.meta.salt = "\xcd\xb1\xa6\x1b\xc0\x54\x7a\x3e\x4c\xa7\x61\x88\x4a\xad\x3d\x9f\xfd\x1d\xb1\x16\x77\x71\xf3\x22\x51\x1c\x5a\x42\x16\x2c\x27\xc0".*;
        public_data.meta.nonce_ctr = ctr;
        public_data.meta.pin_retries = 8;

        // Derive key from pin
        const key = Hkdf.extract(public_data.meta.salt[0..], secret_data.pin_hash[0..]);

        // Encrypt secret data
        public_data.c = encryptSecretData(
            allocator,
            &public_data.tag,
            &secret_data,
            key,
            public_data.meta.nonce_ctr,
        ) catch unreachable;

        public_data.store(s, allocator);
    }
};

/// This data must not be stored as plain-text
pub const SecretData = struct {
    /// The master secret used for key derivation, mac's, etc.
    master_secret: [32]u8,
    /// First 16 byte of the hash of the currently set pin
    pin_hash: [16]u8,
    /// Length of the pin (max 63 bytes)
    pin_length: u8,
    /// Global counter of sucessfull assertions
    sign_ctr: u32,
};

/// Serialize the given SecretData to CBOR and the encrypt it using AES256-GCM.
///
/// # Arguments
/// * `allocator` - An Allocator
/// * `tag`- Pointer to a tag buffer (its important to store this value)
/// * `d` - Pointer to the SecretData to encrypt
/// * `key`- The encryption key
/// * `nonce`- A nonce (every nonce must be used at most once!)
///
/// Returns a owned slice that points to the encrypted data.
/// The caller is responsible for freeing the allocated memory.
pub fn encryptSecretData(
    allocator: std.mem.Allocator,
    tag: *[Aes256Gcm.tag_length]u8,
    d: *const SecretData,
    key: [Aes256Gcm.key_length]u8,
    nonce: [Aes256Gcm.nonce_length]u8,
) ![]u8 {
    // Serialize the data to cbor
    var arr = std.ArrayList(u8).init(allocator);
    defer arr.deinit();
    try cbor.stringify(d, .{}, arr.writer());

    // Encrypt serialized data using AES256-GCM
    var c = try allocator.alloc(u8, arr.items.len);
    errdefer allocator.free(c);
    Aes256Gcm.encrypt(c, tag, arr.items, "", nonce, key);

    return c;
}

pub fn decryptSecretData(
    allocator: std.mem.Allocator,
    c: []const u8,
    tag: []const u8,
    key: [Aes256Gcm.key_length]u8,
    nonce: [Aes256Gcm.nonce_length]u8,
) !SecretData {
    // Decrypt data
    var d = try allocator.alloc(u8, c.len);
    defer allocator.free(d);
    try Aes256Gcm.decrypt(d, c, tag[0..16].*, "", nonce, key);

    // Decode CBOR data
    return try cbor.parse(SecretData, try cbor.DataItem.new(d), .{});
}

test "encrypt SecretData test 1" {
    const c = "\xed\x39\x54\x4e\xf1\xb8\x93\x5a\x6d\x8c\x7b\xea\xa7\x53\xa6\x17\x68\xa3\x93\xd5\xda\xa0\x5f\xf9\xbd\x9c\xdb\xcc\x21\x7e\xfe\xb7\x4a\x0b\x39\x56\x2f\xa0\x7c\x30\x8f\x8b\xf8\x7f\xf7\xaf\xb3\x18\xfd\x8f\x99\xd3\xd7\x7a\x9c\x33\xe6\x7f\xb6\x3d\x69\x93\xbc\x26\xaf\x93\x94\x5b\x37\xd2\xbb\x1d\xda\x06\x14\xf8\x9c\x74\xbb\xa0\x74\x9f\xdf\x05\x79\x00\x57\xdc\x08\xac\xd1\x94\xcb\xcb\x1b\xd7\xc5\x4e\x00";
    const tag = "\x07\xa8\x4a\x1d\xc4\x6f\x1d\x77\xb1\xc4\x91\xb9\xf1\x27\xa2\xdc";

    const d = SecretData{
        .master_secret = "\xb6\xdb\x5e\x48\x11\x56\x1c\xb3\x4f\xfc\x84\x40\x83\x34\xe3\x6a\x26\x9c\xd2\x56\xcf\x3d\xce\x2c\x61\x69\x55\x80\xa4\xca\x50\x1a".*,
        .pin_hash = "\xb4\x5e\xc7\xa7\x75\xac\x3d\xb5\x87\x6a\x42\xc0\xcd\xd7\x04\x8e".*,
        .pin_length = 8,
        .sign_ctr = 256,
    };

    const nonce: [Aes256Gcm.nonce_length]u8 = "\x7a\x80\xf9\xd1\xc3\xae\x82\xfc\xd6\xef\x82\x4e".*;
    const key: [Aes256Gcm.key_length]u8 = "\x47\x20\xe2\x4b\x5d\xe7\x17\x13\x3e\x2c\xef\xc8\x23\x8e\x42\x4a\x82\x5e\x21\xed\x8e\x3f\x8e\xa6\xa0\x5e\xdd\x90\x65\x21\x88\xf6".*;

    const allocator = std.testing.allocator;
    var tag2: [Aes256Gcm.tag_length]u8 = undefined;
    const c2 = try encryptSecretData(allocator, &tag2, &d, key, nonce);
    defer allocator.free(c2);

    try std.testing.expectEqualSlices(u8, c, c2);
    try std.testing.expectEqualSlices(u8, tag, &tag2);
}

test "decrypt SecretData test 1" {
    const c = "\xed\x39\x54\x4e\xf1\xb8\x93\x5a\x6d\x8c\x7b\xea\xa7\x53\xa6\x17\x68\xa3\x93\xd5\xda\xa0\x5f\xf9\xbd\x9c\xdb\xcc\x21\x7e\xfe\xb7\x4a\x0b\x39\x56\x2f\xa0\x7c\x30\x8f\x8b\xf8\x7f\xf7\xaf\xb3\x18\xfd\x8f\x99\xd3\xd7\x7a\x9c\x33\xe6\x7f\xb6\x3d\x69\x93\xbc\x26\xaf\x93\x94\x5b\x37\xd2\xbb\x1d\xda\x06\x14\xf8\x9c\x74\xbb\xa0\x74\x9f\xdf\x05\x79\x00\x57\xdc\x08\xac\xd1\x94\xcb\xcb\x1b\xd7\xc5\x4e\x00";
    const tag = "\x07\xa8\x4a\x1d\xc4\x6f\x1d\x77\xb1\xc4\x91\xb9\xf1\x27\xa2\xdc";
    const nonce: [Aes256Gcm.nonce_length]u8 = "\x7a\x80\xf9\xd1\xc3\xae\x82\xfc\xd6\xef\x82\x4e".*;
    const key: [Aes256Gcm.key_length]u8 = "\x47\x20\xe2\x4b\x5d\xe7\x17\x13\x3e\x2c\xef\xc8\x23\x8e\x42\x4a\x82\x5e\x21\xed\x8e\x3f\x8e\xa6\xa0\x5e\xdd\x90\x65\x21\x88\xf6".*;

    const allocator = std.testing.allocator;

    const sd = try decryptSecretData(allocator, c, tag, key, nonce);

    try std.testing.expectEqualSlices(u8, "\xb6\xdb\x5e\x48\x11\x56\x1c\xb3\x4f\xfc\x84\x40\x83\x34\xe3\x6a\x26\x9c\xd2\x56\xcf\x3d\xce\x2c\x61\x69\x55\x80\xa4\xca\x50\x1a", &sd.master_secret);
    try std.testing.expectEqualSlices(u8, "\xb4\x5e\xc7\xa7\x75\xac\x3d\xb5\x87\x6a\x42\xc0\xcd\xd7\x04\x8e", &sd.pin_hash);
    try std.testing.expectEqual(@intCast(u8, 8), sd.pin_length);
    try std.testing.expectEqual(@intCast(u32, 256), sd.sign_ctr);
}
