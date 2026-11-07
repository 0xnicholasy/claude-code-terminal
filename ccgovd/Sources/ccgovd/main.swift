import Foundation
import CCGovCore

umask(0o077) // db, WAL and log files hold cwds and session names: owner-only

exit(CLI.main(Array(CommandLine.arguments.dropFirst())))
