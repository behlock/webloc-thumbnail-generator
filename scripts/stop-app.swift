import AppKit

let copies = NSRunningApplication.runningApplications(withBundleIdentifier: "com.behlock.webloc-thumbnails")
for app in copies { _ = app.terminate() }
let deadline = Date().addingTimeInterval(5)
while copies.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
if copies.contains(where: { !$0.isTerminated }) {
    fputs("Close Webloc Thumbnails before updating it.\n", stderr)
    exit(1)
}
