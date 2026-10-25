import InkSweepCore

extension AvailableUpdate {
    /// InkSweep can install it itself: a signed feed update that is not an
    /// installer package. Everything else is opened for the user.
    var canInstallHere: Bool {
        guard case .sparkle(let item) = source, let url = item.url else { return false }
        return item.edSignature != nil && app.edPublicKey != nil
            && !["pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }
}
