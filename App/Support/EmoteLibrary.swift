import AppKit
import CryptoKit
import ImageIO
import LPCore
import UniformTypeIdentifiers

enum EmoteImportError: Error {
    case notAnImage, tooLarge, animationTooLarge, cannotProcess, libraryFull, alreadyAdded, cannotSave
}

/// What to draw for an emote.
enum EmoteArt {
    /// One of the animations that ship with the app.
    case bundled(Emote)
    /// A picture from the user's own library; `loops` when it is an animation.
    case image(URL, loops: Bool)
    /// Nothing usable here (someone else's picture, or a file that has gone): a "?" bubble stands in.
    case missing
}

/// The user's own emote pictures, kept in the `emotes` folder of the app's data folder. Each picture is stored as a
/// small still (`<hash>.png`), plus the untouched original (`<hash>.anim`) when it is an animation.
final class EmoteLibrary {
    private enum Limit {
        static let fileBytes = 8 * 1024 * 1024
        static let side = 8192
        static let animationBytes = 5 * 1024 * 1024
        static let animationSide = 1024
        static let stillSide = 160
    }

    private static let accepted: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier]

    let folder: URL
    private var stillCache: [String: CGImage] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    private func stem(_ id: String) -> String { String(id.dropFirst(2)) }
    private func stillFile(_ id: String) -> URL { folder.appendingPathComponent(stem(id) + ".png") }
    private func animationFile(_ id: String) -> URL { folder.appendingPathComponent(stem(id) + ".anim") }

    /// The small still of one of the user's pictures.
    func still(_ id: String) -> CGImage? {
        if let cached = stillCache[id] { return cached }
        guard ImportedEmote.isValidId(id), let image = ImageStore.decode(stillFile(id)) else { return nil }
        stillCache[id] = image
        return image
    }

    /// What to draw for `ref`. `fromRoom`: it came from someone else, so only its still is shown, and only when the
    /// same picture happens to be in this library too (pictures themselves are never sent).
    func art(for ref: String, among imported: [ImportedEmote], fromRoom: Bool) -> EmoteArt {
        if let emote = EmoteCatalog[ref] { return .bundled(emote) }
        guard let mine = imported.first(where: { $0.id == ref }) else { return .missing }
        let loops = mine.animated && !fromRoom
        return .image(loops ? animationFile(ref) : stillFile(ref), loops: loops)
    }

    /// The entries whose still is on disk. If the folder itself can't be listed, nothing is known, and the list is
    /// left as it is rather than emptied.
    func existing(_ imported: [ImportedEmote]) -> [ImportedEmote] {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path), (try? manager.contentsOfDirectory(atPath: folder.path)) == nil { return imported }
        return imported.filter { manager.fileExists(atPath: stillFile($0.id).path) }
    }

    /// Adds a picture. The id comes from the still's contents, so adding the same picture twice is noticed.
    func add(_ url: URL, to imported: [ImportedEmote]) -> Result<ImportedEmote, EmoteImportError> {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Limit.fileBytes {
            return .failure(Self.looksLikeImage(url) ? .tooLarge : .notAnImage)
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.cannotSave) }
        // Judged by what the file contains, not by what it is called.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              Self.accepted.contains(type) else { return .failure(.notAnImage) }
        // Dimensions come from the header: a few kilobytes can claim to be a picture that would take gigabytes to decode.
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return .failure(.notAnImage) }
        let longest = max(width, height)
        if longest > Limit.side { return .failure(.tooLarge) }
        let animated = type != UTType.png.identifier && type != UTType.jpeg.identifier && CGImageSourceGetCount(source) > 1
        if animated && (data.count > Limit.animationBytes || longest > Limit.animationSide) { return .failure(.animationTooLarge) }

        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Limit.stillSide, longest),
        ]
        guard let still = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else { return .failure(.notAnImage) }
        let png = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return .failure(.cannotProcess) }
        CGImageDestinationAddImage(writer, still, nil)
        guard CGImageDestinationFinalize(writer) else { return .failure(.cannotProcess) }

        let digest = SHA256.hash(data: png as Data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = "c:" + digest
        if imported.contains(where: { $0.id == id }) { return .failure(.alreadyAdded) }
        if imported.count >= ImportedEmote.limit { return .failure(.libraryFull) }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: animationFile(id)) // from an earlier copy of this picture
            try (png as Data).write(to: stillFile(id), options: .atomic)
            if animated { try data.write(to: animationFile(id), options: .atomic) }
        } catch {
            discard(id)
            return .failure(.cannotSave)
        }
        return .success(ImportedEmote(id: id, name: url.deletingPathExtension().lastPathComponent, animated: animated))
    }

    /// Deletes a picture's files. A file that won't go is harmless: adding the picture again overwrites it.
    func discard(_ id: String) {
        guard ImportedEmote.isValidId(id) else { return }
        stillCache[id] = nil
        try? FileManager.default.removeItem(at: stillFile(id))
        try? FileManager.default.removeItem(at: animationFile(id))
    }

    private static func looksLikeImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) as String? else { return false }
        return accepted.contains(type)
    }
}
