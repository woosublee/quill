import Foundation

// Window titles and in-app name labels follow the bundle name, so a
// "Quill Dev" build is never shown as "Quill".
@main
struct AppNameDisplaySourceTests {
    static func main() throws {
        let appDelegate = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
        let reminderOverlay = try String(contentsOfFile: "Sources/MeetingReminderOverlay.swift", encoding: .utf8)

        precondition(!appDelegate.contains(#"window.title = "Quill""#), "Note Browser title must follow the bundle name")
        precondition(
            appDelegate.components(separatedBy: "window.title = AppName.displayName").count - 1 == 3,
            "every app window uses the bundle name as its title"
        )
        precondition(!reminderOverlay.contains(#"Text(verbatim: "Quill")"#), "reminder overlay name must follow the bundle name")
        precondition(
            reminderOverlay.components(separatedBy: "Text(verbatim: AppName.displayName)").count - 1 == 2,
            "both reminder overlay layouts show the bundle name"
        )
        print("AppNameDisplaySourceTests passed")
    }
}
