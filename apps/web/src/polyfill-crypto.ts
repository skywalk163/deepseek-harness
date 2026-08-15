/** Polyfill crypto.randomUUID for non-secure contexts (plain http on a LAN IP),
 * where browsers gate the Web Crypto randomUUID API off. getRandomValues is
 * available in every context, so we derive an RFC4122 v4 UUID from it.
 */
const __dshCrypto = globalThis.crypto as any
if (__dshCrypto && typeof __dshCrypto.randomUUID !== "function") {
  __dshCrypto.randomUUID = function (): string {
    const bytes = new Uint8Array(16)
    globalThis.crypto.getRandomValues(bytes)
    bytes[6] = (bytes[6]! & 0x0f) | 0x40
    bytes[8] = (bytes[8]! & 0x3f) | 0x80
    const hex = Array.from(bytes, (b: number) => b.toString(16).padStart(2, "0"))
    return (
      hex.slice(0, 4).join("") +
      "-" +
      hex.slice(4, 6).join("") +
      "-" +
      hex.slice(6, 8).join("") +
      "-" +
      hex.slice(8, 10).join("") +
      "-" +
      hex.slice(10, 16).join("")
    )
  }
}
