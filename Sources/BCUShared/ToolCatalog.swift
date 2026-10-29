import Foundation

/// Tool definitions as MCP sees them. The app implements each one by name.
public enum ToolCatalog {
    public static let serverInstructions = """
    Background Computer Use lets you operate the user's real Mac apps, with their logins, without ever \
    disturbing them. You work in windows on a private virtual display the user never sees. The user keeps \
    their focus, cursor and keystrokes the whole time.

    How to work:
    1. Call `status` once to learn the user's default browser. When a task needs a browser, use that one.
    2. `open_window` opens a new window of an app on your display (for a browser, a new window in the \
    user's own profile). Use `borrow_window` only for single-window apps.
    3. `get_window_state` returns the window's accessibility tree with numbered elements and a screenshot. \
    Act on elements by number. Use x/y (window points, matching the screenshot pixels) only when no element fits.
    4. Prefer `set_value` and `click` on an element: they work through accessibility and never touch \
    keyboard focus. `type_text`, `press_key` and pixel clicks briefly make your window the app's key window, \
    so if the user is using that same app they wait until the user switches away.
    5. Check the result with `get_window_state` after each meaningful step.
    6. When finished, `release_window` every window you opened or borrowed.
    7. If you need the user (a login, 2FA, a decision), call `handoff` with a reason and stop.
    Never ask the user to watch or click on your display. Never use other tools that take over the screen.
    """

    public static let tools: [JSONObject] = [
        tool("status",
             "Display size, the user's default browser, permissions, pause state and your open windows.",
             [:]),
        tool("list_apps",
             "Running apps with their pid, bundle id and window count.",
             [:]),
        tool("open_window",
             "Open a NEW window of an app on your virtual display and return its window_id. Launches the app if needed. The user's existing windows are untouched. For browsers this is a new window in the user's own profile.",
             ["app": prop("string", "App name (e.g. \"Helium\", \"Notes\") or bundle id.")],
             required: ["app"]),
        tool("list_windows",
             "Your windows. With `app`, also lists that app's other windows so you can pick one to borrow.",
             ["app": prop("string", "Optional app name or bundle id.")]),
        tool("borrow_window",
             "Move one of the user's existing windows onto your display. Use only for single-window apps; release_window puts it back exactly where it was.",
             ["window_id": prop("integer", "Window id from list_windows.")],
             required: ["window_id"]),
        tool("release_window",
             "Finish with a window: closes windows you opened, returns borrowed ones to the user.",
             ["window_id": prop("integer", "Your window."),
              "keep_open": prop("boolean", "Leave an opened window open on your display instead of closing it.")],
             required: ["window_id"]),
        tool("get_window_state",
             "Accessibility tree of your window with numbered elements, plus a screenshot. Element numbers stay valid until the next get_window_state for that window.",
             ["window_id": prop("integer", "Your window."),
              "screenshot": prop("boolean", "Include a screenshot (default true)."),
              "max_elements": prop("integer", "Cap on listed elements (default 250).")],
             required: ["window_id"]),
        tool("screenshot",
             "Screenshot of one of your windows, or of your whole display when window_id is omitted.",
             ["window_id": prop("integer", "Optional window.")]),
        tool("click",
             "Click an element (by number) or a point (x, y in window points). Element clicks use accessibility actions when the element supports them.",
             ["window_id": prop("integer", "Your window."),
              "element": prop("integer", "Element number from get_window_state."),
              "x": prop("number", "Window-relative x, if no element."),
              "y": prop("number", "Window-relative y, if no element."),
              "button": prop("string", "left (default) or right."),
              "count": prop("integer", "1 (default) or 2 for double-click.")],
             required: ["window_id"]),
        tool("set_value",
             "Replace the value of a text field, slider or similar element through accessibility. Never touches keyboard focus.",
             ["window_id": prop("integer", "Your window."),
              "element": prop("integer", "Element number."),
              "value": prop("string", "New value.")],
             required: ["window_id", "element", "value"]),
        tool("perform_action",
             "Perform a named accessibility action on an element, e.g. AXPress, AXShowMenu, AXConfirm, AXIncrement, AXDecrement, AXRaise, AXCancel.",
             ["window_id": prop("integer", "Your window."),
              "element": prop("integer", "Element number."),
              "action": prop("string", "Action name from the element's action list.")],
             required: ["window_id", "element", "action"]),
        tool("type_text",
             "Type text into your window. With `element`, that element is focused first. Uses accessibility insertion when it works, otherwise keystrokes (which wait if the user is in the same app).",
             ["window_id": prop("integer", "Your window."),
              "text": prop("string", "Text to type. \\n presses Return."),
              "element": prop("integer", "Optional element to focus first.")],
             required: ["window_id", "text"]),
        tool("press_key",
             "Press a key or shortcut in your window, e.g. key \"return\", or key \"l\" with modifiers [\"cmd\"]. Waits if the user is in the same app.",
             ["window_id": prop("integer", "Your window."),
              "key": prop("string", "Key name: a letter or digit, return, tab, space, escape, delete, forward_delete, up, down, left, right, home, end, page_up, page_down, f1-f12, or a punctuation character."),
              "modifiers": ["type": "array", "items": ["type": "string"], "description": "Any of cmd, shift, option, ctrl, fn."] as JSONObject],
             required: ["window_id", "key"]),
        tool("scroll",
             "Scroll in your window at an element or point. Positive dy scrolls down.",
             ["window_id": prop("integer", "Your window."),
              "element": prop("integer", "Optional element to scroll at."),
              "x": prop("number", "Window-relative x."),
              "y": prop("number", "Window-relative y."),
              "dx": prop("integer", "Horizontal lines (positive = right)."),
              "dy": prop("integer", "Vertical lines (positive = down).")],
             required: ["window_id"]),
        tool("drag",
             "Drag from one window point to another.",
             ["window_id": prop("integer", "Your window."),
              "from_x": prop("number", ""), "from_y": prop("number", ""),
              "to_x": prop("number", ""), "to_y": prop("number", "")],
             required: ["window_id", "from_x", "from_y", "to_x", "to_y"]),
        tool("press_menu_item",
             "Choose a menu bar item of the window's app, applied to your window, e.g. path [\"File\", \"Save…\"].",
             ["window_id": prop("integer", "Your window."),
              "path": ["type": "array", "items": ["type": "string"], "description": "Menu titles from the menu bar down."] as JSONObject],
             required: ["window_id", "path"]),
        tool("handoff",
             "Ask the user to take over a window (login, 2FA, a decision). Moves it onto the user's screen without activating it and shows your reason in the menu bar. Stop after calling this.",
             ["window_id": prop("integer", "Your window."),
              "reason": prop("string", "One sentence for the user.")],
             required: ["window_id", "reason"]),
        tool("take_back",
             "Move a handed-off window back onto your display once the user is done.",
             ["window_id": prop("integer", "Your window.")],
             required: ["window_id"]),
        tool("guard_report",
             "Focus-guard events: anything that touched the user's focus, cursor or screen, with the action that caused it.",
             [:]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: JSONObject, required: [String] = []) -> JSONObject {
        var schema: JSONObject = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func prop(_ type: String, _ description: String) -> JSONObject {
        description.isEmpty ? ["type": type] : ["type": type, "description": description]
    }
}
