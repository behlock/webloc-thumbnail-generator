import AppKit

@main
enum Application {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        if CommandLine.arguments.dropFirst().first != "--generate" { app.servicesProvider = delegate }
        withExtendedLifetime(delegate) { app.run() }
    }
}
