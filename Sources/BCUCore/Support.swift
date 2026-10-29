import Foundation
import BCUShared

/// Plain file + stderr logger. One file per launch under ~/Library/Application Support/BackgroundComputerUse/logs.
public enum Log {
    private static let queue = DispatchQueue(label: "bcu.log")
    private static var handle: FileHandle? = {
        let dir = BCUPaths.logDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bcu.log")
        if FileManager.default.fileExists(atPath: url.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            handle?.write(Data(line.utf8))
        }
    }
}

/// Monotonic milliseconds.
public func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

public func sleepMs(_ ms: Double) {
    if ms > 0 { usleep(useconds_t(ms * 1000)) }
}

/// Typed access to tool arguments.
public struct Args {
    public let raw: JSONObject
    public init(_ raw: JSONObject) { self.raw = raw }

    public func int(_ key: String) -> Int? {
        if let v = raw[key] as? Int { return v }
        if let v = raw[key] as? Double { return Int(v) }
        if let v = raw[key] as? String { return Int(v) }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if let v = raw[key] as? Double { return v }
        if let v = raw[key] as? Int { return Double(v) }
        if let v = raw[key] as? String { return Double(v) }
        return nil
    }

    public func string(_ key: String) -> String? { raw[key] as? String }

    public func bool(_ key: String) -> Bool? {
        if let v = raw[key] as? Bool { return v }
        if let v = raw[key] as? String { return v == "true" }
        return nil
    }

    public func strings(_ key: String) -> [String]? {
        if let v = raw[key] as? [String] { return v }
        if let v = raw[key] as? String { return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    public func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw ToolError("missing integer argument `\(key)`") }
        return v
    }

    public func requireString(_ key: String) throws -> String {
        guard let v = string(key) else { throw ToolError("missing string argument `\(key)`") }
        return v
    }
}

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var short: String { "\(Int(origin.x)),\(Int(origin.y)) \(Int(width))x\(Int(height))" }
}
