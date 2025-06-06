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
            return "Machine-readable JSON format with full data structure"
        case .csv:
            return "Spreadsheet-compatible CSV with privacy safeguards"
        case .html:
            return "Human-readable HTML report with experimental warnings"
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