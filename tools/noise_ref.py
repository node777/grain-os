#!/usr/bin/env python3
"""An independent Noise_XX_25519_ChaChaPoly_BLAKE2s, written from the Noise
specification (revision 34) with Python's `cryptography`, to check
grain/lib/noise.zig: it runs the handshake of noise.zig's first test (the
same fixed keys and payloads) and prints the handshake hash and the
transport message, which that test expects byte for byte.

    python3 tools/noise_ref.py
"""
import hashlib
import hmac

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

NAME = b"Noise_XX_25519_ChaChaPoly_BLAKE2s"


def H(data):
    return hashlib.blake2s(data).digest()


def hkdf(ck, ikm):
    temp = hmac.new(ck, ikm, hashlib.blake2s).digest()
    o1 = hmac.new(temp, b"\x01", hashlib.blake2s).digest()
    o2 = hmac.new(temp, o1 + b"\x02", hashlib.blake2s).digest()
    return o1, o2


def nonce(n):
    return b"\x00" * 4 + n.to_bytes(8, "little")


class Party:
    def __init__(self, static_seed, eph_seed, prologue):
        self.s = X25519PrivateKey.from_private_bytes(static_seed)
        self.e = X25519PrivateKey.from_private_bytes(eph_seed)
        self.h = H(NAME)  # longer than 32 bytes: hashed
        self.ck = self.h
        self.k = None
        self.n = 0
        self.mix_hash(prologue)

    @staticmethod
    def pub(k):
        return k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)

    def mix_hash(self, d):
        self.h = H(self.h + d)

    def mix_key(self, ikm):
        self.ck, self.k = hkdf(self.ck, ikm)
        self.n = 0

    def dh(self, priv, pub):
        self.mix_key(priv.exchange(X25519PublicKey.from_public_bytes(pub)))

    def enc(self, p):
        if self.k is None:
            c = p
        else:
            c = ChaCha20Poly1305(self.k).encrypt(nonce(self.n), p, self.h)
            self.n += 1
        self.mix_hash(c)
        return c

    def dec(self, c):
        if self.k is None:
            p = c
        else:
            p = ChaCha20Poly1305(self.k).decrypt(nonce(self.n), c, self.h)
            self.n += 1
        self.mix_hash(c)
        return p


def main():
    pro = b"grain comlink v1"
    i = Party(bytes([1]) * 32, bytes([3]) * 32, pro)
    r = Party(bytes([2]) * 32, bytes([4]) * 32, pro)
    # -> e
    ie = Party.pub(i.e)
    i.mix_hash(ie)
    m1 = ie + i.enc(b"hi")
    r.re = m1[:32]
    r.mix_hash(r.re)
    assert r.dec(m1[32:]) == b"hi"
    # <- e, ee, s, es
    re_ = Party.pub(r.e)
    r.mix_hash(re_)
    r.dh(r.e, r.re)
    m2 = re_ + r.enc(Party.pub(r.s))
    r.dh(r.s, r.re)
    m2 += r.enc(b"responder")
    i.re = m2[:32]
    i.mix_hash(i.re)
    i.dh(i.e, i.re)
    i.rs = i.dec(m2[32:80])
    i.dh(i.e, i.rs)
    assert i.dec(m2[80:]) == b"responder"
    # -> s, se
    m3 = i.enc(Party.pub(i.s))
    i.dh(i.s, i.re)
    m3 += i.enc(b"initiator")
    r.rs = r.dec(m3[:48])
    r.dh(r.e, r.rs)
    assert r.dec(m3[48:]) == b"initiator"
    assert i.h == r.h
    k1, k2 = hkdf(i.ck, b"")
    first = (0).to_bytes(8, "little") + ChaCha20Poly1305(k1).encrypt(nonce(0), b"first", b"")
    print("handshake_hash", i.h.hex())
    print("first_transport", first.hex())


if __name__ == "__main__":
    main()
