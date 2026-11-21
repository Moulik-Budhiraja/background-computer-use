import Foundation

/// Which copy of `bcu` this is, by the app it was shipped inside.
public enum BCUCopy {
    /// The app `executable` is inside: the nearest `.app` folder above it.
    public static func app(containing executable: URL) -> Bundle? {
        var dir = executable.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app" { return Bundle(url: dir) }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Why `executable` won't run `bcu serve`, if it won't. (Every copy runs it for now.)
    public static func serveRefusal(_ executable: URL) -> String? { nil }
}
