// Polyfill crypto.randomUUID for non-secure contexts (plain http on a LAN IP),
// where browsers gate the Web Crypto randomUUID API off. getRandomValues is
// available in every context, so we derive an RFC4122 v4 UUID from it.
const __dshCrypto = globalThis.crypto as any
if (__dshCrypto && typeof __dshCrypto.randomUUID !== "function") {
  __dshCrypto.randomUUID = function (): string {
    const __b = new Uint8Array(16)
    globalThis.crypto.getRandomValues(__b)
    __b[6] = (__b[6] & 0x0f) | 0x40
    __b[8] = (__b[8] & 0x3f) | 0x80
    const __h = Array.prototype.map.call(__b, function (x: number) {
      return x.toString(16).padStart(2, "0")
    })
    return __h[0] + __h[1] + __h[2] + __h[3] + "-" + __h[4] + __h[5] + "-" + __h[6] + __h[7] + "-" + __h[8] + __h[9] + "-" + __h[10] + __h[11] + __h[12] + __h[13] + __h[14] + __h[15]
  }
}
