import ArgumentParser
import Foundation
import GatekeeprCore

@main
struct GatekeeprCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gatekeepr",
        abstract: "Shows when your Appgate SDP session expires.",
        discussion: """
        Works it out from Appgate's driver logs, which any user can read. No root, \
        no network. Unofficial and not affiliated with Appgate.

        Exit codes: 0 ok, 1 within the warn window, 2 expired or not signed in, \
        3 logs unreadable or in a format gatekeepr doesn't know.
        """,
        version: Gatekeepr.version,
        subcommands: [StatusCommand.self, HistoryCommand.self],
        defaultSubcommand: StatusCommand.self
    )
}

struct LogOptions: ParsableArguments {
    @Option(name: .customLong("log-dir"), help: ArgumentHelp("Where Appgate writes driver.log.", valueName: "path"))
    var logDirectory: String = LogDirectory.appgateDefault.path

    @Flag(help: "Print JSON instead of text.")
    var json = false

    var gatekeepr: Gatekeepr {
        Gatekeepr(logDirectory: URL(fileURLWithPath: logDirectory, isDirectory: true))
    }
}

struct WarnThreshold: ExpressibleByArgument {
    let seconds: TimeInterval

    init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    init?(argument: String) {
        guard let seconds = DurationText.parse(argument) else { return nil }
        self.seconds = seconds
    }

    var defaultValueDescription: String { DurationText.format(seconds) }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the current session: sign-in time, expiry and time left."
    )

    @OptionGroup var options: LogOptions

    @Flag(help: "Print only the time left, like 6h08m, for statuslines.")
    var short = false

    @Option(help: ArgumentHelp("Exit with 1 when this much time or less is left, e.g. 30m, 2h, 1h30m.", valueName: "duration"))
    var warn = WarnThreshold(seconds: 30 * 60)

    func validate() throws {
        if options.json && short {
            throw ValidationError("--json and --short can't be used together.")
        }
    }

    func run() throws {
        let status: Status
        do {
            status = try options.gatekeepr.status(warnThreshold: warn.seconds)
        } catch {
            try fail(error, json: options.json, short: short)
        }
        if options.json {
            print(try JSONReport.encode(StatusReport(status)))
        } else if short {
            print(TextOutput.short(status))
        } else {
            print(TextOutput.status(status, logDirectory: options.logDirectory))
        }
        if status.state.exitCode != 0 {
            throw ExitCode(status.state.exitCode)
        }
    }
}

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List past sessions with their measured lengths."
    )

    @OptionGroup var options: LogOptions

    func run() throws {
        let analysis: Analysis
        do {
            analysis = try options.gatekeepr.analyze()
        } catch {
            try fail(error, json: options.json, short: false)
        }
        if options.json {
            print(try JSONReport.encode(HistoryReport(analysis)))
        } else {
            print(TextOutput.history(analysis, logDirectory: options.logDirectory))
        }
    }
}

/// Reports an error the way the chosen output format expects, then exits 3.
func fail(_ error: Error, json: Bool, short: Bool) throws -> Never {
    let message = "\(error)"
    FileHandle.standardError.write(Data("gatekeepr: \(message)\n".utf8))
    if json {
        let payload: [String: Any] = ["state": "error", "exitCode": 3, "error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
    } else if short {
        print(StatusText.shortError)
    }
    throw ExitCode(3)
}
