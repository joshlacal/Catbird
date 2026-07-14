import Foundation

enum CapturedMedia {
  case photo(Data)
  case video(URL)
}

enum CameraCaptureMode: Identifiable {
  case photo
  case video

  var id: Int {
    switch self {
    case .photo: 0
    case .video: 1
    }
  }
}
