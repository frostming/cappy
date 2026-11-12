import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--selftest") {
    let directory = arguments.count > index + 1 ? arguments[index + 1] : NSTemporaryDirectory()
    exit(SelfTest.run(outputDirectory: directory) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
