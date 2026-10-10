#if os(macOS)
import Darwin

exit(SwifttydCommand.run(Array(CommandLine.arguments.dropFirst())))
#endif
