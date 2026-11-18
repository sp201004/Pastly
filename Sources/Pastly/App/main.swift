import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}

if let idx = CommandLine.arguments.firstIndex(of: "--benchmark"), CommandLine.arguments.count > idx + 1 {   // developer check
    exit(Benchmark.run(source: CommandLine.arguments[idx + 1]) ? 0 : 1)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-screenshots") {
    let dir = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "website/img"
    exit(Screenshots.run(outputDir: dir) ? 0 : 1)
}

if let idx = CommandLine.arguments.firstIndex(of: "--render-settings") {   // developer check
    let path = CommandLine.arguments.count > idx + 1 ? CommandLine.arguments[idx + 1] : "/tmp/settings.png"
    exit(Screenshots.renderSettings(to: path) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
