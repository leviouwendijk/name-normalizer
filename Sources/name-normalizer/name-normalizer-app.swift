import Foundation
import ArgumentParser

struct NameNormalizerApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nn",
        abstract: "Name normalizing utility",
        subcommands: [
            NormalizeName.self,
        ],
        defaultSubcommand: NormalizeName.self
    )
}
