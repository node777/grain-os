//! The Bochs display (QEMU's `bochs-display`, and the VBE "DISPI" interface
//! many emulators and simple display cards share): a linear framebuffer the
//! card scans out as it is, and a few registers to choose the mode.
//!
//! BAR 0 is the framebuffer; BAR 2 holds the DISPI registers (16 bits each,
//! from offset 0x500). Pixels are 32-bit, 0x00RRGGBB, as paint.zig draws:
//! a store is on the screen, with nothing to flush.
const std = @import("std");

pub const vendor: u16 = 0x1234;
pub const device: u16 = 0x1111;

pub fn supports(v: u16, d: u16) bool {
    return v == vendor and d == device;
}

const Index = enum(usize) { id = 0, xres = 1, yres = 2, bpp = 3, enable = 4, bank = 5, virt_width = 6, virt_height = 7, x_offset = 8, y_offset = 9 };
const enabled: u16 = 0x01;
const linear_framebuffer: u16 = 0x40;

pub const Error = error{ NotBochs, TooLarge };

pub const Bochs = struct {
    fb: []u32,
    width: u32,
    height: u32,
    regs: usize,

    pub fn init(fb_va: usize, fb_size: u64, regs: usize, width: u32, height: u32) Error!Bochs {
        const b: Bochs = .{ .fb = @as([*]u32, @ptrFromInt(fb_va))[0 .. width * height], .width = width, .height = height, .regs = regs };
        if (b.read(.id) & 0xfff0 != 0xb0c0) return error.NotBochs;
        if (@as(u64, width) * height * 4 > fb_size) return error.TooLarge;
        b.write(.enable, 0);
        b.write(.xres, @intCast(width));
        b.write(.yres, @intCast(height));
        b.write(.bpp, 32);
        b.write(.virt_width, @intCast(width));
        b.write(.virt_height, @intCast(height));
        b.write(.x_offset, 0);
        b.write(.y_offset, 0);
        b.write(.enable, enabled | linear_framebuffer);
        return b;
    }

    fn read(b: *const Bochs, i: Index) u16 {
        return @as(*volatile u16, @ptrFromInt(b.regs + 0x500 + @intFromEnum(i) * 2)).*;
    }
    fn write(b: *const Bochs, i: Index, v: u16) void {
        @as(*volatile u16, @ptrFromInt(b.regs + 0x500 + @intFromEnum(i) * 2)).* = v;
    }
};
