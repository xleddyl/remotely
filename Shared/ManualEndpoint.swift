import Foundation

struct ManualEndpoint: Equatable {
    let host: String
    let port: UInt16

    var displayText: String { "\(host):\(port)" }
}

enum ManualEndpointProblem: Equatable {
    case missingHost
    case malformedHost
    case missingPort
    case malformedPort

    var message: String {
        switch self {
        case .missingHost:
            return "Enter the host name or IP address your Mac is reachable at."
        case .malformedHost:
            return "The host may not contain spaces, slashes or a URL scheme."
        case .missingPort:
            return "Enter the port your Mac listens on (\(ManualEndpointParser.defaultPort) by default)."
        case .malformedPort:
            return "The port must be a whole number between 1 and 65535."
        }
    }
}

enum ManualEndpointValidation: Equatable {
    case valid(ManualEndpoint)
    case invalid(ManualEndpointProblem)

    var endpoint: ManualEndpoint? {
        if case .valid(let endpoint) = self { return endpoint }
        return nil
    }

    var problem: ManualEndpointProblem? {
        if case .invalid(let problem) = self { return problem }
        return nil
    }

    var isValid: Bool { endpoint != nil }
}

enum ManualEndpointParser {
    static let defaultPort = "9000"

    private static let forbiddenHostCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "/\\@?#[]"))

    static func normalizedHost(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    static func normalizedPort(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(host rawHost: String, port rawPort: String) -> ManualEndpointValidation {
        let host = normalizedHost(rawHost)
        guard !host.isEmpty else { return .invalid(.missingHost) }
        guard host.rangeOfCharacter(from: forbiddenHostCharacters) == nil else {
            return .invalid(.malformedHost)
        }
        let portText = normalizedPort(rawPort)
        guard !portText.isEmpty else { return .invalid(.missingPort) }
        guard portText.allSatisfy({ $0.isNumber && $0.isASCII }),
              let port = UInt16(portText), port > 0 else {
            return .invalid(.malformedPort)
        }
        return .valid(ManualEndpoint(host: host, port: port))
    }

    static func endpoint(host: String, port: String) -> ManualEndpoint? {
        validate(host: host, port: port).endpoint
    }
}
