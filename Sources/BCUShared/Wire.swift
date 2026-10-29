import Foundation

/// One request or response per line of JSON on the unix socket.
///
/// Request:  {"id": 1, "tool": "click", "args": {...}}
/// Response: {"id": 1, "ok": true, "text": "...", "images": [{"mime": "image/png", "data": "<base64>"}]}
///           {"id": 1, "ok": false, "error": "..."}
public typealias JSONObject = [String: Any]

public struct ToolImage {
    public var mime: String
    public var base64: String
    public init(mime: String, base64: String) {
        self.mime = mime
        self.base64 = base64
    }
}

public struct ToolResult {
    public var text: String
    public var images: [ToolImage]
    public var isError: Bool

    public init(text: String, images: [ToolImage] = [], isError: Bool = false) {
        self.text = text
        self.images = images
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(text: message, isError: true)
    }

    public func wire(id: Any) -> JSONObject {
        var out: JSONObject = ["id": id, "ok": !isError]
        if isError {
            out["error"] = text
        } else {
            out["text"] = text
            if !images.isEmpty {
                out["images"] = images.map { ["mime": $0.mime, "data": $0.base64] }
            }
        }
        return out
    }

    public init(wire: JSONObject) {
        let ok = wire["ok"] as? Bool ?? false
        if ok {
            text = wire["text"] as? String ?? ""
            images = (wire["images"] as? [JSONObject] ?? []).compactMap { img in
                guard let data = img["data"] as? String else { return nil }
                return ToolImage(mime: img["mime"] as? String ?? "image/png", base64: data)
            }
            isError = false
        } else {
            text = wire["error"] as? String ?? "unknown error"
            images = []
            isError = true
        }
    }
}

public enum WireCodec {
    public static func encodeLine(_ object: JSONObject) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: line)) as? JSONObject
    }
}
