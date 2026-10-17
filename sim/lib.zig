//! The simulated machine and its random driver, for tools outside sim/
//! (the fuzz targets and the model checker).
pub const machine = @import("machine.zig");
pub const driver = @import("driver.zig");
pub const arch = machine.arch;
pub const Machine = machine.Machine;
