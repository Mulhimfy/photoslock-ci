// Built with the app's own modules/photoslock-cipher/ios/NotesCipherCore.swift:
// CryptoKit must open what the JS library sealed, seal the same bytes, and
// refuse a note under another id. Prints PASS / FAIL lines.
import Foundation

let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let vectors = try! JSONSerialization.jsonObject(with: data) as! [[String: String]]
func b(_ s: String?) -> Data { Data(base64Encoded: s ?? "")! }
var opened = 0, same = 0, refused = 0
for v in vectors {
  let key = b(v["key"]), nonce = b(v["nonce"]), plain = b(v["plain"]), aad = b(v["aad"]), sealed = b(v["sealed"])
  if let p = try? NotesCipherCore.open(key: key, nonce: nonce, sealed: sealed, aad: aad), p == plain { opened += 1 }
  if let s = try? NotesCipherCore.seal(key: key, nonce: nonce, plain: plain, aad: aad), s == sealed { same += 1 }
  if (try? NotesCipherCore.open(key: key, nonce: nonce, sealed: sealed, aad: Data("another-id".utf8))) == nil { refused += 1 }
}
let n = vectors.count
print(opened == n ? "PASS CryptoKit opens \(n)/\(n) notes the JS library sealed" : "FAIL CryptoKit opened \(opened)/\(n) notes the JS library sealed")
print(same == n ? "PASS CryptoKit seals the same bytes as the JS library (\(n)/\(n))" : "FAIL CryptoKit sealed the same bytes \(same)/\(n)")
print(refused == n ? "PASS a note under another id is refused (\(n)/\(n))" : "FAIL a note under another id opened \(n - refused)/\(n)")
