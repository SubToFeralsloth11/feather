import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // The self-test runs without a Dock icon and never takes focus.
    app.setActivationPolicy(SelfTest.isActive ? .accessory : .regular)
    withExtendedLifetime(delegate) { app.run() }
}
