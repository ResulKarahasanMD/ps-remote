import Foundation

@main
struct PSRemoteCLI {
    static let usage = """
    Kullanım: psremote-cli <komut>
      discover [saniye]                 Yerel ağdaki PS5'leri listeler (varsayılan 4 sn)
      set-account <base64>              PSN Account-ID'yi Anahtar Zinciri'ne kaydeder
      register "<konsol>" <PIN>         PS5'e bu Mac'i kaydeder (konsol: ad, host id ya da ip)
      import-chiaki                     chiaki-ng'nin mevcut kaydını ve Account-ID'sini aktarır
      list                              Kayıtlı konsolları listeler
      forget <host id>                  Kayıtlı konsolu Anahtar Zinciri'nden siler
      wake ["<konsol>"]                 Kayıtlı PS5'i uyandırır ve 'hazır' olmasını bekler (30 sn)
      stream ["<konsol>"] [saniye]      Görüntü ve sesi pencerede açar; DualSense ya da klavye ile oynanır
                                        (WASD, oklar, Enter, Esc, Tab). Günlük: ~/Library/Logs/PSRemote
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
            fail("Hata: \(error)")
        }
    }
}
