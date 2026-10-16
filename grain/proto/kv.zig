//! kv.v1: a small key-value store, with undoable writes.
const idl = @import("grain").idl;

pub const name = "kv";
pub const version = 1;
pub const doc = "A small in-memory key-value store (64-bit keys and values). Every write can be undone.";

pub const get = idl.Method(.{ .label = 1, .effect = .pure, .doc = "Read a key." }, struct {
    key: u64,
    pub const docs = .{ .key = "The key" };
}, struct {
    value: u64,
    found: bool,
    pub const docs = .{ .value = "Its value (0 if not found)", .found = "Whether the key exists" };
});

pub const put = idl.Method(.{ .label = 2, .effect = .mutates, .undo = "restore", .doc = "Set a key; returns what it held before." }, struct {
    key: u64,
    value: u64,
    pub const docs = .{ .key = "The key", .value = "The new value" };
}, struct {
    previous: u64,
    had: bool,
    pub const docs = .{ .previous = "The old value (0 if none)", .had = "Whether the key existed" };
});

pub const remove = idl.Method(.{ .label = 3, .effect = .mutates, .undo = "restore", .doc = "Delete a key; returns what it held." }, struct {
    key: u64,
    pub const docs = .{ .key = "The key" };
}, struct {
    previous: u64,
    had: bool,
    pub const docs = .{ .previous = "The old value (0 if none)", .had = "Whether the key existed" };
});

pub const restore = idl.Method(.{ .label = 4, .effect = .mutates, .doc = "Put a key back as it was: set it to previous if had, else delete it." }, struct {
    key: u64,
    previous: u64,
    had: bool,
    pub const docs = .{ .key = "The key", .previous = "The value to restore", .had = "Whether the key should exist" };
}, struct {});

pub const count = idl.Method(.{ .label = 5, .effect = .pure, .doc = "How many keys are stored." }, struct {}, struct {
    count: u64,
    pub const docs = .{ .count = "Number of keys" };
});
