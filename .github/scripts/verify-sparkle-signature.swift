// Checks a Sparkle signature against the public key built into the app.
//
//   swift verify-sparkle-signature.swift <XCommander.app> <file> <base64 signature>
//
// sign_update signs with whatever private key it's given. If the release environment held
// the wrong one, every update would be rejected by the apps already installed, and nobody
// would find out until they tried to update. This catches it before the release exists.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: verify-sparkle-signature.swift <app> <file> <signature>")
    exit(2)
}
let info = URL(fileURLWithPath: arguments[1]).appending(path: "Contents/Info.plist")
guard let plist = NSDictionary(contentsOf: info),
      let publicKeyText = plist["SUPublicEDKey"] as? String,
      let publicKeyData = Data(base64Encoded: publicKeyText),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    print("::error::No valid SUPublicEDKey in \(info.path)")
    exit(1)
}
guard let signature = Data(base64Encoded: arguments[3]),
      let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[2])) else {
    print("::error::Couldn't read the file or the signature")
    exit(1)
}
if publicKey.isValidSignature(signature, for: file) {
    print("The Sparkle signature matches the app's public key.")
} else {
    print("::error::The Sparkle signature doesn't match the SUPublicEDKey in the app. Is SPARKLE_ED_PRIVATE_KEY the right key?")
    exit(1)
}
