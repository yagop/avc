import ArgumentParser

@main
struct AVC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "avc",
        abstract: "avconvert replacement: encode, remux, probe.",
        subcommands: [Encode.self, Remux.self, Probe.self]
    )
}
