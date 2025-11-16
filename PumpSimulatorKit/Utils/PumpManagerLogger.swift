import OSLog

class PumpManagerLogger {
    private let logger: Logger
    
    init(subsystem: String, category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }
    
    func debug(_ msg: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = formatMessage(msg, file, function, line)
        logger.debug("\(message, privacy: .public)")
    }
    
    func info(_ msg: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = formatMessage(msg, file, function, line)
        logger.info("\(message, privacy: .public)")
    }
    
    func warning(_ msg: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = formatMessage(msg, file, function, line)
        logger.warning("\(message, privacy: .public)")
    }
    
    func error(_ msg: String, _ file: String = #file, _ function: String = #function, _ line: Int = #line) {
        let message = formatMessage(msg, file, function, line)
        logger.error("\(message, privacy: .public)")
    }
    
    private func formatMessage(_ msg: String, _ file: String, _ function: String, _ line: Int) -> String {
        return "\(file.file) - \(function)#\(line): \(msg)"
    }
}

private extension String {
    var file: String { components(separatedBy: "/").last ?? "" }
}
