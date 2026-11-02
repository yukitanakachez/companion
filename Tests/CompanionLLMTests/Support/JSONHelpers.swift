import CompanionCore
import Foundation

func json(_ literal: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
}

func bodyJSON(_ r: URLRequest) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data())
}
