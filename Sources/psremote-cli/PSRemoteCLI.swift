import Foundation

@main
struct PSRemoteCLI {
    static let usage = """
    Usage: psremote-cli <command>
      discover [seconds]                Lists PS5 consoles on the local network (default 4 s)
      set-account <base64>              Saves the PSN Account-ID to the Keychain
      register "<console>" <PIN>        Registers this Mac with a PS5 (console: name, host id or ip)
      import-chiaki                     Imports chiaki-ng's existing registration and Account-ID
      list                              Lists registered consoles
      forget <host id>                  Deletes a registered console from the Keychain
      wake ["<console>"]                Wakes a registered PS5 and waits until it is 'ready' (30 s)
      stream ["<console>"] [seconds]    Opens video and audio in a window; play with a DualSense or the keyboard
                                        (WASD, arrows, Return, Escape, Tab). Log: ~/Library/Logs/PSRemote
    """

    /// Synchronous entry point: `stream` needs AppKit's run loop on the plain main thread (running it
    /// inside a main-actor job blocks the serial main queue, so no main-actor task could run).
    /// Every other command runs as a task while the main queue is serviced by dispatchMain().
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "stream" {
            StreamCommand.launch(arguments: Array(arguments.dropFirst()))
        }
        Task {
            await run(arguments)
            exit(0)
        }
        dispatchMain()
    }

    static func run(_ arguments: [String]) async {
        do {
            switch arguments.first {
            case "discover": try await DiscoverCommand.run(arguments: Array(arguments.dropFirst()))
            case "set-account": try AccountCommand.run(arguments: Array(arguments.dropFirst()))
            case "register": try await RegisterCommand.run(arguments: Array(arguments.dropFirst()))
            case "import-chiaki": try await ImportChiakiCommand.run()
            case "list": try ListCommand.run()
            case "forget": try ForgetCommand.run(arguments: Array(arguments.dropFirst()))
            case "wake": try await WakeCommand.run(arguments: Array(arguments.dropFirst()))
            default: fail(usage, code: 64)
            }
        } catch {
            fail("Error: \(error)")
        }
    }
}
