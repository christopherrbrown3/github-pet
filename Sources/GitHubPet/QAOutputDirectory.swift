import Darwin
import Foundation
import ImageIO

/// The QA runner's output directory, used only through one O_NOFOLLOW directory descriptor.
/// Every read, write and removal is relative to that descriptor and never follows a link, so
/// swapping the path, the marker or a step file for a symlink between validation and use
/// cannot redirect a write outside the directory. Removal unlinks regular files only and
/// never recurses.
final class QAOutputDirectory {
    struct Failure: Error, CustomStringConvertible { let description: String }

    let url: URL
    private let fd: Int32

    /// Creates the final path component if missing (never through a link), then opens it.
    init(_ url: URL) throws {
        self.url = url
        if mkdir(url.path, 0o755) != 0 && errno != EEXIST {
            throw Failure(description: "cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw Failure(description: "\(url.path) is not a directory this runner can use (symlinks are refused): \(String(cString: strerror(errno)))")
        }
    }
    deinit { close(fd) }

    enum Kind { case regular, other }

    /// Entry names and kinds, read through the descriptor without following links.
    func entries() throws -> [(name: String, kind: Kind)] {
        let listing = dup(fd)
        guard listing >= 0, let dir = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            throw Failure(description: "cannot list \(url.path)")
        }
        defer { closedir(dir) }
        rewinddir(dir)
        var result: [(String, Kind)] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            result.append((name, kind(name) ?? .other))
        }
        return result
    }

    func kind(_ name: String) -> Kind? {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFREG ? .regular : .other
    }

    /// Writes (create or truncate) a regular file. A symlink, directory or other node is refused.
    func write(_ data: Data, name: String) throws {
        try Self.checkName(name)
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else {
            throw Failure(description: "refusing to write \(name): \(String(cString: strerror(errno))) (symlinks and directories are never written through)")
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure(description: "refusing to write \(name): not a regular file")
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw Failure(description: "write to \(name) failed: \(String(cString: strerror(errno)))") }
                offset += written
            }
        }
    }

    /// Removes one regular file. unlinkat(…, 0) never follows a link and never removes a
    /// directory, so even a swap after the check cannot delete anything outside or recursively.
    func removeRegularFile(_ name: String) throws {
        try Self.checkName(name)
        guard kind(name) == .regular else { throw Failure(description: "refusing to remove \(name): not a regular file") }
        guard unlinkat(fd, name, 0) == 0 else {
            throw Failure(description: "cannot remove \(name): \(String(cString: strerror(errno)))")
        }
    }

    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw Failure(description: "invalid output file name \(name)")
        }
    }

    /// A PNG is accepted only if it decodes to a non-empty image.
    static func validatedPNG(_ data: Data?) throws -> Data {
        guard let data, data.count > 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0 else {
            throw Failure(description: "render produced no valid PNG")
        }
        return data
    }
}
