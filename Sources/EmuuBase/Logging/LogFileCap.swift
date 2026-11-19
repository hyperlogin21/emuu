import Darwin
import Foundation

/// Bounds a log file that another process (or another descriptor in this one) keeps writing to.
///
/// The writer must hold the file open with `O_APPEND` (`ProcessRequest.Output.file` does): after an
/// in-place truncation its next write lands at the new end of file instead of at the old offset, which would
/// otherwise leave a sparse hole as large as the old file.
public enum LogFileCap {
    /// When `url` is larger than `limit`, copies it to `<name>.1.<ext>` (replacing an older copy) and truncates
    /// the live file to zero length in place. Returns true when it truncated. Never throws: a log that cannot
    /// be capped is not worth failing for.
    @discardableResult
    public static func capInPlace(_ url: URL, limit: UInt64) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, UInt64(st.st_size) > limit else { return false }
        let ext = url.pathExtension
        let rotated = url.deletingPathExtension().appendingPathExtension(ext.isEmpty ? "1" : "1.\(ext)")
        let fm = FileManager.default
        try? fm.removeItem(at: rotated)
        try? fm.copyItem(at: url, to: rotated)
        return truncate(url.path, 0) == 0
    }
}
