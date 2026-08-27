import Foundation
import ImageIO

struct BingDailyWallpaper: Sendable {
  let data: Data
}

enum BingDailyWallpaperClient {
  static let market = "zh-CN"
  static let requestedWidth = 1080
  static let requestedHeight = 1920

  private static let bingBaseURL = URL(string: "https://www.bing.com")!
  private static let maximumMetadataBytes = 1_000_000
  private static let maximumImageBytes = 25_000_000

  static func fetchToday(using session: URLSession = .shared) async throws -> BingDailyWallpaper {
    let archiveURL = try makeArchiveURL()
    var archiveRequest = URLRequest(
      url: archiveURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 20
    )
    archiveRequest.setValue("application/json", forHTTPHeaderField: "Accept")

    let (archiveData, archiveResponse) = try await session.data(for: archiveRequest)
    try validateHTTPResponse(archiveResponse, maximumBytes: maximumMetadataBytes)
    guard archiveData.count <= maximumMetadataBytes else {
      throw BingWallpaperError.metadataTooLarge
    }

    let archive: ArchiveResponse
    do {
      archive = try JSONDecoder().decode(ArchiveResponse.self, from: archiveData)
    } catch {
      throw BingWallpaperError.invalidMetadata
    }
    guard let image = archive.images.first else {
      throw BingWallpaperError.wallpaperUnavailable
    }
    let imageURL = try validatedImageURL(from: image.url)

    var imageRequest = URLRequest(
      url: imageURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30
    )
    imageRequest.setValue("image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")

    let (imageData, imageResponse) = try await session.data(for: imageRequest)
    try validateHTTPResponse(imageResponse, maximumBytes: maximumImageBytes)
    guard imageData.count <= maximumImageBytes else {
      throw BingWallpaperError.imageTooLarge
    }
    guard
      let httpResponse = imageResponse as? HTTPURLResponse,
      httpResponse.mimeType?.lowercased().hasPrefix("image/") == true
    else {
      throw BingWallpaperError.invalidImageResponse
    }
    guard
      let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
    else {
      throw BingWallpaperError.invalidImageResponse
    }
    guard height.intValue > width.intValue else {
      throw BingWallpaperError.notPortrait
    }

    return BingDailyWallpaper(data: imageData)
  }

  private static func makeArchiveURL() throws -> URL {
    var components = URLComponents(
      url: bingBaseURL.appendingPathComponent("HPImageArchive.aspx"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "format", value: "js"),
      URLQueryItem(name: "idx", value: "0"),
      URLQueryItem(name: "n", value: "1"),
      URLQueryItem(name: "mkt", value: market),
      URLQueryItem(name: "uhd", value: "1"),
      URLQueryItem(name: "uhdwidth", value: String(requestedWidth)),
      URLQueryItem(name: "uhdheight", value: String(requestedHeight)),
    ]
    guard let url = components?.url else {
      throw BingWallpaperError.invalidRequest
    }
    return url
  }

  private static func validatedImageURL(from path: String) throws -> URL {
    guard
      let url = URL(string: path, relativeTo: bingBaseURL)?.absoluteURL,
      url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(),
      host == "bing.com" || host.hasSuffix(".bing.com")
    else {
      throw BingWallpaperError.invalidImageURL
    }
    return url
  }

  private static func validateHTTPResponse(_ response: URLResponse, maximumBytes: Int) throws {
    guard let response = response as? HTTPURLResponse else {
      throw BingWallpaperError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw BingWallpaperError.httpError(response.statusCode)
    }
    guard
      response.expectedContentLength <= 0
        || response.expectedContentLength <= Int64(maximumBytes)
    else {
      throw BingWallpaperError.responseTooLarge
    }
  }

  private struct ArchiveResponse: Decodable {
    let images: [ArchiveImage]
  }

  private struct ArchiveImage: Decodable {
    let url: String
  }
}

enum BingWallpaperError: LocalizedError {
  case invalidRequest
  case invalidResponse
  case httpError(Int)
  case responseTooLarge
  case metadataTooLarge
  case invalidMetadata
  case wallpaperUnavailable
  case invalidImageURL
  case imageTooLarge
  case invalidImageResponse
  case notPortrait

  var errorDescription: String? {
    switch self {
    case .invalidRequest:
      return "无法创建 Bing 每日壁纸请求。"
    case .invalidResponse:
      return "Bing 返回了无法识别的网络响应。"
    case .httpError(let statusCode):
      return "Bing 请求失败（HTTP \(statusCode)）。"
    case .responseTooLarge, .metadataTooLarge:
      return "Bing 返回的数据超过安全限制。"
    case .invalidMetadata:
      return "无法解析 Bing 每日壁纸信息。"
    case .wallpaperUnavailable:
      return "Bing 暂时没有提供今日壁纸。"
    case .invalidImageURL:
      return "Bing 返回了无效的壁纸地址。"
    case .imageTooLarge:
      return "Bing 壁纸超过 25 MB 安全限制。"
    case .invalidImageResponse:
      return "Bing 返回的内容不是有效图片。"
    case .notPortrait:
      return "Bing 没有返回竖屏壁纸，请稍后重试。"
    }
  }
}
