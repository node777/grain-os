//! Kumara: identity you own. A key in your hands, and yours for as long as
//! you hold it.
//!
//! An identity is an Ed25519 key pair. Its **name** is three words from a
//! bank of 1024 four-letter words (format v1), drawn from the hash of the
//! public key: `kelp-oryx-lute`. The name is a handle people can say and
//! remember; the identity itself is the public key, and the name only
//! points at it (30 bits: two keys can share a name, never a key).
//!
//! Signatures are made over a digest that binds a *context*, the name of
//! the domain that asked: a signature the Ledger asked for can never pass
//! as one made for anything else.
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
pub const Ed25519 = std.crypto.sign.Ed25519;

pub const name_len = 14; // "word-word-word"
pub const Name = [name_len]u8;

/// Word bank v1: 1024 common, plain four-letter words, sorted. Its order is
/// part of the format: never reorder or edit it; a new bank is a new version.
pub const bank_v1 = blk: {
    const words = [_][]const u8{
        "able", "acai", "acre", "afar", "ahoy", "aide", "airy", "akin", "ally", "aloe", "alto", "alum", "apex", "aqua", "arch", "area",
        "aria", "arid", "atom", "aunt", "aura", "auto", "avid", "axis", "axle", "axon", "baby", "back", "bait", "bake", "bale", "ball",
        "balm", "band", "bank", "bard", "bare", "bark", "barn", "base", "bask", "bass", "bath", "bead", "beak", "beam", "bean", "bear",
        "beat", "beep", "beet", "bell", "belt", "bend", "bent", "berg", "best", "beta", "bevy", "bike", "bill", "bind", "bird", "blue",
        "boar", "boat", "boba", "body", "bold", "bolt", "bond", "bone", "bony", "book", "boom", "boon", "boot", "born", "boss", "bowl",
        "bran", "brew", "brie", "brim", "brio", "brow", "buck", "buff", "bulb", "bulk", "bump", "bunt", "buoy", "bush", "busy", "buzz",
        "byte", "cafe", "cage", "cake", "calf", "call", "calm", "camp", "cane", "cape", "card", "care", "carp", "cart", "case", "cash",
        "cask", "cast", "cave", "cell", "cent", "chai", "chap", "char", "chat", "chef", "chew", "chia", "chic", "chin", "chip", "chop",
        "chum", "cite", "city", "clam", "clan", "clap", "claw", "clay", "clef", "clip", "club", "clue", "coal", "coat", "coax", "coco",
        "coda", "code", "coil", "coin", "cold", "colt", "comb", "come", "cone", "cook", "cool", "cope", "copy", "cord", "core", "cork",
        "corn", "cost", "cosy", "cove", "cozy", "crab", "crag", "crew", "crop", "crow", "crux", "cube", "cuff", "curb", "cure", "curl",
        "cute", "cyan", "dahl", "dais", "dale", "dare", "dark", "dart", "dash", "data", "date", "dawn", "deal", "dean", "dear", "deck",
        "deed", "deep", "deer", "deft", "deli", "dell", "desk", "dewy", "dhow", "dial", "dice", "diet", "dill", "dime", "dine", "ding",
        "disc", "dish", "disk", "diva", "dive", "dock", "dodo", "dojo", "doll", "dome", "door", "dory", "dose", "dove", "down", "draw",
        "drop", "drum", "dual", "duck", "duet", "dune", "dusk", "dust", "duty", "dyad", "earn", "ease", "east", "easy", "eave", "echo",
        "ecru", "eddy", "edge", "edit", "epic", "exam", "exit", "face", "fact", "fair", "fall", "fame", "fare", "farm", "fast", "fava",
        "fawn", "feat", "feed", "feel", "felt", "fend", "fern", "feta", "fete", "fife", "file", "fill", "film", "find", "fine", "fire",
        "firm", "fish", "five", "fizz", "flag", "flan", "flap", "flat", "flax", "flex", "flip", "flit", "flow", "flue", "flux", "foal",
        "foam", "fold", "folk", "fond", "font", "food", "foot", "ford", "fore", "fork", "form", "fort", "four", "fowl", "foxy", "fray",
        "free", "frog", "fuel", "full", "fund", "furl", "fuse", "fuss", "fuzz", "gain", "gait", "gala", "gale", "game", "garb", "gate",
        "gaze", "gear", "gene", "gent", "gift", "gill", "gilt", "gist", "give", "glad", "glee", "glen", "glow", "glue", "goal", "goat",
        "gold", "golf", "gong", "good", "gown", "grab", "grad", "gram", "gray", "grey", "grid", "grin", "grip", "grit", "grow", "gulf",
        "gull", "guru", "gust", "gyro", "hail", "hair", "hale", "half", "hall", "halo", "halt", "hand", "hang", "hard", "hare", "harp",
        "hash", "haul", "hawk", "haze", "hazy", "head", "heal", "heap", "hear", "heat", "heed", "heel", "heft", "helm", "help", "hemp",
        "herb", "herd", "hero", "hide", "high", "hike", "hill", "hilt", "hind", "hint", "hire", "hive", "hold", "home", "hone", "honk",
        "hood", "hoof", "hook", "hoop", "hope", "horn", "hose", "host", "hour", "howl", "huge", "hula", "hull", "hunt", "hush", "husk",
        "ibex", "ibis", "iced", "icon", "idea", "idle", "inch", "inky", "iota", "iris", "iron", "isle", "item", "jade", "jamb", "jazz",
        "jean", "jeep", "jest", "jive", "join", "joke", "jolt", "judo", "jump", "jury", "jute", "kale", "kava", "keel", "keen", "keep",
        "kelp", "kick", "kiln", "kilt", "kind", "kite", "kiwi", "knee", "knit", "knob", "knot", "know", "koan", "kohl", "koto", "kudu",
        "lace", "lacy", "lair", "lake", "lamb", "lamp", "land", "lane", "lark", "last", "late", "lava", "lawn", "lead", "leaf", "lean",
        "leap", "leek", "left", "lend", "lens", "less", "levy", "lido", "life", "lift", "like", "lilt", "lily", "limb", "lime", "line",
        "link", "lion", "list", "live", "load", "loaf", "loam", "loan", "lobe", "loch", "lock", "lode", "loft", "logo", "lone", "long",
        "look", "loom", "loon", "loop", "lore", "loud", "love", "luau", "luck", "lull", "lush", "lute", "lynx", "lyre", "mail", "main",
        "make", "mako", "mall", "malt", "mane", "mare", "mark", "mart", "masa", "mask", "mass", "mast", "mate", "math", "maze", "mead",
        "meal", "meek", "meet", "meld", "melt", "memo", "mend", "menu", "meow", "mere", "mesa", "mesh", "mica", "mice", "mild", "mile",
        "milk", "mill", "mind", "mine", "mink", "mint", "miso", "mist", "mitt", "moat", "mode", "mold", "mole", "molt", "monk", "mood",
        "moon", "moor", "moss", "mote", "moth", "move", "mule", "muse", "musk", "myna", "myth", "naan", "nail", "name", "navy", "near",
        "neat", "neck", "need", "nene", "neon", "nest", "newt", "next", "nice", "nine", "node", "nook", "noon", "nori", "norm", "nose",
        "note", "noun", "nova", "oboe", "okra", "onyx", "opal", "open", "oral", "orca", "oryx", "oval", "oven", "oxen", "pace", "pack",
        "pact", "page", "paid", "pail", "pair", "pale", "palm", "pane", "papa", "park", "part", "pass", "past", "path", "pave", "peak",
        "peal", "pear", "peat", "peck", "peek", "peel", "peer", "perk", "pick", "pier", "pika", "pike", "pile", "pine", "ping", "pink",
        "pint", "pipe", "pita", "plan", "play", "plea", "plod", "plot", "plow", "ploy", "plug", "plum", "plus", "poem", "poet", "pole",
        "polo", "pond", "pony", "pool", "port", "pose", "posh", "post", "pour", "prep", "prim", "prod", "prop", "prow", "puff", "pull",
        "pulp", "puma", "pump", "pure", "purr", "push", "quad", "quay", "quiz", "race", "rack", "raft", "raga", "rail", "rain", "rake",
        "ramp", "rare", "rate", "rave", "read", "real", "ream", "reap", "rear", "reed", "reef", "reel", "rein", "rely", "rent", "rest",
        "rice", "rich", "ride", "rift", "rill", "rime", "rind", "ring", "rink", "ripe", "rise", "road", "roam", "roan", "roar", "robe",
        "rock", "role", "roll", "roof", "rook", "room", "root", "rope", "rose", "rosy", "rote", "rove", "ruby", "ruff", "rule", "rune",
        "rung", "rush", "safe", "saga", "sage", "sago", "sail", "sake", "sale", "salt", "sand", "sane", "sari", "sash", "save", "scan",
        "scow", "seal", "seam", "seat", "seed", "seek", "seem", "self", "sell", "send", "shed", "ship", "shoe", "shop", "shot", "show",
        "side", "sift", "sign", "silk", "sill", "silo", "silt", "sing", "sink", "site", "size", "skim", "skin", "skip", "skit", "skua",
        "sled", "slim", "slip", "sloe", "slot", "slow", "snap", "snow", "snug", "soak", "soap", "soar", "soba", "sock", "soda", "sofa",
        "soft", "soil", "sole", "solo", "song", "soon", "sort", "soul", "soup", "span", "spar", "spin", "spot", "spry", "spud", "spur",
        "stag", "star", "stay", "stem", "step", "stew", "stir", "stop", "stow", "stud", "suit", "sumo", "sure", "surf", "swan", "swap",
        "sway", "swim", "tack", "taco", "tact", "tail", "take", "tako", "tale", "talk", "tall", "tame", "tang", "tank", "tape", "tarn",
        "taro", "task", "taxi", "teak", "teal", "team", "teem", "tell", "temp", "tend", "tent", "term", "tern", "test", "text", "thaw",
        "thin", "tide", "tidy", "tied", "tier", "tiki", "tile", "till", "tilt", "time", "tint", "tiny", "tipi", "tire", "toad", "tofu",
        "toga", "tome", "tone", "tong", "tool", "toss", "tote", "tour", "town", "tram", "tray", "tree", "trek", "trim", "trio", "trip",
        "trot", "true", "tuba", "tube", "tuck", "tuft", "tuna", "tune", "turf", "turn", "tusk", "tutu", "twig", "twin", "type", "udon",
        "unit", "urge", "vale", "vane", "vase", "vast", "veer", "veil", "vein", "veld", "vent", "verb", "vest", "vial", "vibe", "view",
        "vine", "viol", "visa", "vole", "volt", "vote", "wade", "wadi", "waft", "wage", "wait", "wake", "walk", "wall", "wand", "want",
        "ward", "ware", "warm", "warp", "wash", "watt", "wave", "wavy", "waxy", "wear", "weed", "week", "weft", "weld", "well", "west",
        "whey", "whim", "whir", "wick", "wide", "wiki", "wild", "wind", "wine", "wing", "wink", "wipe", "wire", "wiry", "wise", "wish",
        "wisp", "wolf", "wood", "woof", "wool", "word", "work", "wrap", "wren", "yard", "yarn", "yawl", "yawn", "year", "yeti", "yoga",
        "yogi", "yoke", "yolk", "yule", "yurt", "yuzu", "zany", "zeal", "zebu", "zero", "zest", "zeta", "zinc", "zone", "zoom", "zori",
    };
    @setEvalBranchQuota(10_000);
    var out: [words.len][4]u8 = undefined;
    for (words, 0..) |w, i| out[i] = w[0..4].*;
    break :blk out;
};

comptime {
    std.debug.assert(bank_v1.len == 1024);
}

/// The v1 name of a public key.
pub fn nameOf(public_key: [32]u8) Name {
    var d = Blake3.initKdf("grain kumara v1 name", .{});
    d.update(&public_key);
    var h: [32]u8 = undefined;
    d.final(&h);
    const x = std.mem.readInt(u32, h[0..4], .big) >> 2; // 30 bits
    var n: Name = undefined;
    inline for (0..3) |k| {
        const idx = (x >> @intCast(20 - 10 * k)) & 1023;
        @memcpy(n[k * 5 ..][0..4], &bank_v1[idx]);
        if (k < 2) n[k * 5 + 4] = '-';
    }
    return n;
}

/// The digest that is signed: the context and the message, each length-prefixed.
pub fn digest(context: []const u8, message: []const u8) [32]u8 {
    var d = Blake3.initKdf("grain kumara v1 sign", .{});
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, context.len, .little);
    d.update(&len);
    d.update(context);
    std.mem.writeInt(u64, &len, message.len, .little);
    d.update(&len);
    d.update(message);
    var h: [32]u8 = undefined;
    d.final(&h);
    return h;
}

pub fn keyPair(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}

/// Deterministic signatures (no noise): the same request gives the same
/// signature, which keeps runs reproducible.
pub fn sign(kp: Ed25519.KeyPair, context: []const u8, message: []const u8) ![64]u8 {
    const d = digest(context, message);
    return (try kp.sign(&d, null)).toBytes();
}

pub fn verify(public_key: [32]u8, context: []const u8, message: []const u8, signature: [64]u8) bool {
    const pk = Ed25519.PublicKey.fromBytes(public_key) catch return false;
    const d = digest(context, message);
    Ed25519.Signature.fromBytes(signature).verify(&d, pk) catch return false;
    return true;
}

test "the bank: 1024 distinct lowercase four-letter words, sorted" {
    for (bank_v1, 0..) |w, i| {
        for (w) |c| try std.testing.expect(c >= 'a' and c <= 'z');
        if (i > 0) try std.testing.expect(std.mem.order(u8, &bank_v1[i - 1], &w) == .lt);
    }
}

test "names, signing contexts" {
    var seed: [32]u8 = @splat(7);
    const kp = try keyPair(seed);
    const n = nameOf(kp.public_key.toBytes());
    try std.testing.expect(n[4] == '-' and n[9] == '-');
    // Stable: the same key always has the same name.
    try std.testing.expectEqualSlices(u8, &n, &nameOf(kp.public_key.toBytes()));
    seed[0] = 8;
    try std.testing.expect(!std.mem.eql(u8, &n, &nameOf((try keyPair(seed)).public_key.toBytes())));

    const sig = try sign(kp, "ledger", "entry 1");
    const pk = kp.public_key.toBytes();
    try std.testing.expect(verify(pk, "ledger", "entry 1", sig));
    try std.testing.expect(!verify(pk, "agent", "entry 1", sig));
    try std.testing.expect(!verify(pk, "ledger", "entry 2", sig));
}
