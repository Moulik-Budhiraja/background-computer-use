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

    /// Why `executable` won't run `bcu serve`, if it won't: it's the menu
    /// bar app's own `bcu`. That app runs the engine itself, and an engine
    /// started from its copy kept the app from starting while it ran.
    /// `serve` is for apps that ship their own `bcu`.
    public static func serveRefusal(_ executable: URL) -> String? {
        guard app(containing: executable)?.bundleIdentifier == BCUPaths.bundleID else { return nil }
        return "bcu: serve is for apps that bundle their own bcu; \(BCUPaths.appName) runs its engine itself, so open the app instead."
    }
}
