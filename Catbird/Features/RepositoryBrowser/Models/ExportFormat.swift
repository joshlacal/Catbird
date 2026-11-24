import Foundation

enum ExportFormat: String, CaseIterable {
    case json = "JSON"
    case csv = "CSV"
    case html = "HTML"

    var fileExtension: String {
        switch self {
        case .json:
            return "json"
        case .csv:
            return "csv"
        case .html:
            return "html"
        }
    }

    var description: String {
        switch self {
        case .json:
            return String(
                localized: "Machine-readable JSON format with full data structure",
                comment: "Description of the JSON repository export format."
            )
        case .csv:
            return String(
                localized: "Spreadsheet-compatible CSV with privacy safeguards",
                comment: "Description of the CSV repository export format."
            )
        case .html:
            return String(
                localized: "Human-readable HTML report with experimental warnings",
                comment: "Description of the HTML repository export report format."
            )
        }
    }

    var mimeType: String {
        switch self {
        case .json:
            return "application/json"
        case .csv:
            return "text/csv"
        case .html:
            return "text/html"
        }
    }
}
