import Darwin
import Foundation
import ImageIO

/// The QA runner's output directory, used only through one O_NOFOLLOW directory descriptor.
/// Every read, write and removal is relative to that descriptor and never follows a link, so
/// swapping the path, the marker or a step file for a symlink between validation and use
/// cannot redirect a write outside the directory. Writes replace entries with fresh inodes,
/// never truncate an existing inode (which could have an outside hard link). Removal unlinks
/// single-link regular files only and never recurses.
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
        return Self.isRegularOutput(info) ? .regular : .other
    }

    static func isRegularOutput(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
    }

    /// Writes only to an exclusively created inode, then atomically replaces the final entry.
    /// The destination checks reject known unsafe entries; safety does not depend on them:
    /// renameat never follows or truncates a destination swapped in after the last check.
    func write(_ data: Data, name: String) throws {
        try Self.checkName(name)
        try checkDestination(name)
        let temporary = ".github-pet-qa-write-\(UUID().uuidString)"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            throw Failure(description: "cannot create fresh output for \(name): \(String(cString: strerror(errno)))")
        }
        defer {
            close(file)
            // Also runs on failure; unlinkat never follows a swapped link or recurses.
            unlinkat(fd, temporary, 0)
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure(description: "write to \(name) failed: \(String(cString: strerror(errno)))") }
                offset += written
            }
        }
        try checkDestination(name)
        guard renameat(fd, temporary, fd, name) == 0 else {
            throw Failure(description: "cannot replace \(name): \(String(cString: strerror(errno)))")
        }
    }

    private func checkDestination(_ name: String) throws {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Failure(description: "cannot inspect \(name): \(String(cString: strerror(errno)))")
        }
        guard Self.isRegularOutput(info) else {
            throw Failure(description: "refusing to write \(name): not a single-link regular file")
        }
    }

    /// Removes one regular file. unlinkat(…, 0) never follows a link and never removes a
    /// directory, so even a swap after the check cannot delete anything outside or recursively.
    func removeRegularFile(_ name: String) throws {
        try Self.checkName(name)
        guard kind(name) == .regular else { throw Failure(description: "refusing to remove \(name): not a single-link regular file") }
        guard unlinkat(fd, name, 0) == 0 else {
            throw Failure(description: "cannot remove \(name): \(String(cString: strerror(errno)))")
        }
    }

    private static func checkName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
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
