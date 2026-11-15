// Verify a Sparkle feed and archive using only the embedded public key.
// No Keychain or private signing material is read by this tool.
import Foundation
import CryptoKit

struct InvalidUpdate: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw InvalidUpdate(message: message) }
}

do {
    let args = CommandLine.arguments
    try require(args.count == 4, "Usage: verify_update.swift feed.json macos.xml archive.zip")
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: String]
    guard let rawKey = Data(base64Encoded: config?["publicKey"] ?? "") else {
        throw InvalidUpdate(message: "Invalid public key")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    try require(feed.count <= 4 * 1024 * 1024, "Feed exceeds the application download limit")
    guard let start = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let footer = String(data: feed[start.lowerBound...], encoding: .utf8) else {
        throw InvalidUpdate(message: "Missing feed signature")
    }
    let expression = try NSRegularExpression(pattern: "\\A<!-- sparkle-signatures:\\nedSignature: ([A-Za-z0-9+/=]+)\\nlength: ([0-9]+)\\n-->\\n?\\z")
    guard let match = expression.firstMatch(in: footer, range: NSRange(footer.startIndex..., in: footer)),
          let signature = Data(base64Encoded: (footer as NSString).substring(with: match.range(at: 1))),
          let length = Int((footer as NSString).substring(with: match.range(at: 2))) else {
        throw InvalidUpdate(message: "Invalid feed signature block")
    }
    try require(length == start.lowerBound && key.isValidSignature(signature, for: feed.prefix(length)), "Feed signature mismatch")
    // Parse XML only after its signature has passed, without external entities.
    let xml = try XMLDocument(data: feed.prefix(length), options: [.nodeLoadExternalEntitiesNever])
    let archiveURL = URL(fileURLWithPath: args[3])
    let enclosures = try xml.nodes(forXPath: "/rss/channel/item/enclosure").compactMap { $0 as? XMLElement }
    let matches = enclosures.filter { URL(string: $0.attribute(forName: "url")?.stringValue ?? "")?.lastPathComponent == archiveURL.lastPathComponent }
    try require(matches.count == 1, "Archive must appear exactly once in the signed feed")
    guard let item = matches.first,
          let archiveSignature = Data(base64Encoded: item.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue ?? ""),
          let archiveLength = Int(item.attribute(forName: "length")?.stringValue ?? "") else {
        throw InvalidUpdate(message: "Archive is missing from the signed feed")
    }
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(archive.count == archiveLength && key.isValidSignature(archiveSignature, for: archive), "Archive signature mismatch")
    print("Verified feed and archive with the public key; no Keychain access.")
} catch {
    let message = (error as? InvalidUpdate)?.message ?? error.localizedDescription
    FileHandle.standardError.write(Data(("Update verification failed: " + message + "\n").utf8))
    exit(1)
}
