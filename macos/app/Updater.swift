import Foundation
import Security

/// Installs an update from the release download (TeamsBusyLight-macOS.zip).
///
/// Only an app that is signed with the same certificate as the running one is
/// installed: the new app must satisfy the designated requirement of the
/// running app (`certificate leaf = H"…"`). macOS does not need to trust the
/// self-signed certificate for this. Builds signed ad hoc offer no update.
enum Updater {
    static let assetName = "TeamsBusyLight-macOS.zip"
    private static let maxDownloadSize = 50 * 1024 * 1024

    /// Designated requirement of the running app, if it is pinned to a certificate
    static let ownRequirement: SecRequirement? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text = text as String?, text.contains("certificate leaf = H\""), !text.contains("cdhash")
        else { return nil }
        return requirement
    }()

    static var isSupported: Bool { ownRequirement != nil }

    /// Folder for downloads, on the volume of the app (for the atomic swap)
    private static func makeWorkFolder() throws -> URL {
        let app = Bundle.main.bundleURL
        return try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true
        )
    }

    /// Downloads, checks and installs the update into the place of the running
    /// app. Calls `completion` on the main queue with nil on success (the
    /// caller then restarts) or the reason.
    static func install(from url: URL, version: String, completion: @escaping (String?) -> Void) {
        let finish = { (reason: String?) in DispatchQueue.main.async { completion(reason) } }
        Log.write("Downloading update \(version) from \(url.absoluteString)")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        URLSession.shared.downloadTask(with: request) { location, response, error in
            if let error {
                finish(error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                finish("HTTP \(http.statusCode)")
                return
            }
            guard let location else {
                finish("no download")
                return
            }
            var work: URL?
            do {
                let folder = try makeWorkFolder()
                work = folder
                let zip = folder.appendingPathComponent(assetName)
                try FileManager.default.moveItem(at: location, to: zip)
                try installZip(zip, in: folder, version: version)
                try? FileManager.default.removeItem(at: folder)
                Log.write("Update \(version) installed")
                finish(nil)
            } catch {
                if let work {
                    try? FileManager.default.removeItem(at: work)
                }
                finish((error as? UpdateError)?.reason ?? error.localizedDescription)
            }
        }.resume()
    }

    struct UpdateError: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private static func installZip(_ zip: URL, in folder: URL, version: String) throws {
        let fileManager = FileManager.default
        let size = (try fileManager.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        guard size > 0, size <= maxDownloadSize else { throw UpdateError("unexpected download size (\(size) bytes)") }

        // No entries outside the folder
        let listing = try run("/usr/bin/zipinfo", ["-1", zip.path])
        for entry in listing.split(separator: "\n") {
            if entry.hasPrefix("/") || entry.split(separator: "/").contains("..") {
                throw UpdateError("invalid path in the ZIP file: \(entry)")
            }
        }
        let extracted = folder.appendingPathComponent("extracted")
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])

        let newApp = extracted.appendingPathComponent("TeamsBusyLight-macOS/Teams Busy Light.app")
        guard fileManager.fileExists(atPath: newApp.path) else { throw UpdateError("Teams Busy Light.app is missing in the download") }

        try checkSignature(of: newApp)

        // Exactly the offered version, so an older signed release cannot be
        // passed off as the new one
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { throw UpdateError("the download contains a different app") }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        guard newVersion == version else { throw UpdateError("the download contains version \(newVersion) instead of \(version)") }

        // Swap atomically; the old app ends up in the work folder and is removed
        let current = Bundle.main.bundleURL
        let result = newApp.withUnsafeFileSystemRepresentation { new in
            current.withUnsafeFileSystemRepresentation { old in
                renamex_np(new!, old!, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw UpdateError("cannot replace \(current.path): \(String(cString: strerror(errno)))")
        }
    }

    /// The new app must be valid (all architectures, strict) and satisfy the
    /// designated requirement of the running app
    static func checkSignature(of app: URL) throws {
        guard let requirement = ownRequirement else { throw UpdateError("this version is not signed with a certificate") }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("cannot read the signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &errors)
        guard status == errSecSuccess else {
            errors?.release()
            let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            throw UpdateError("the signature is not valid or not ours (\(detail))")
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    /// Starts the installed (new) app; it waits until this instance has quit
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--replaces", String(getpid())]
        do {
            try process.run()
        } catch {
            Log.write("Cannot start the new version: \(error.localizedDescription)")
        }
    }
}
