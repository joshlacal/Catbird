//
//  PostParser.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/16/24.
//

import Foundation
import Petrel

struct URLCardResponse: Codable, Identifiable, Hashable {
  var id: String { url }
  let error: String
  let likelyType: String
  let url: String
  let title: String
  let description: String
  let image: String
  
  /// Original URL detected in the composer text. Card service may canonicalize `url`,
  /// so keep the full user-provided link for embeds and local caching.
  var sourceURL: String? = nil
  
  /// Cached thumbnail blob after upload (not persisted)
  var thumbnailBlob: Blob? = nil

  enum CodingKeys: String, CodingKey {
    case error
    case likelyType = "likely_type"
    case url
    case title
    case description
    case image
    // thumbnailBlob is excluded from coding
  }

  /// URL string to use when preserving the exact user-provided link.
  var resolvedURL: String { sourceURL ?? url }
}

struct PostParser {
  static func parsePostContent(
    _ content: String, resolvedProfiles: [String: AppBskyActorDefs.ProfileViewBasic]
  ) -> (text: String, hashtags: [String], facets: [AppBskyRichtextFacet], urls: [String], detectedLanguage: String?) {
    var hashtags: [String] = []
    var facets: [AppBskyRichtextFacet] = []
    var urls: [String] = []

    let utf8View = content.utf8
    var currentIndex = content.startIndex

    while currentIndex < content.endIndex {
      if content[currentIndex] == "#" {
        let hashtagStart = currentIndex
        currentIndex = content.index(after: currentIndex)

        while currentIndex < content.endIndex
          && (content[currentIndex].isLetter || content[currentIndex].isNumber) {
          currentIndex = content.index(after: currentIndex)
        }

        let hashtag = String(content[hashtagStart..<currentIndex])
        if hashtag.count > 1 {  // Ensure it's not just a lone "#"
          hashtags.append(String(hashtag.dropFirst()))

          let utf8Start = content[..<hashtagStart].utf8.count
          let utf8End = utf8Start + content[hashtagStart..<currentIndex].utf8.count

          let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: utf8Start, byteEnd: utf8End)
          let tagFeature = AppBskyRichtextFacet.Tag(tag: String(hashtag.dropFirst()))
          let facet = AppBskyRichtextFacet(
            index: byteSlice, features: [.appBskyRichtextFacetTag(tagFeature)])

          facets.append(facet)
        }
      } else if content[currentIndex] == "@" {
        let mentionStart = currentIndex
        currentIndex = content.index(after: currentIndex)

        // Parse mention handle - only consume valid handle characters
        // Handles can contain letters, numbers, dots, and hyphens
        // BUT must be terminated by whitespace, punctuation, or end of string
        while currentIndex < content.endIndex {
          let char = content[currentIndex]
          
          // Valid handle characters: alphanumeric, dot, hyphen
          let isValidHandleChar = char.isLetter || char.isNumber || char == "." || char == "-"
          
          // Check if next character would break the mention
          // Whitespace, punctuation (except . and -), or special chars terminate mentions
          if !isValidHandleChar {
            break
          }
          
          currentIndex = content.index(after: currentIndex)
        }

        let mention = String(content[mentionStart..<currentIndex])
        if mention.count > 1 {  // Ensure it's not just a lone "@"
          let handle = String(mention.dropFirst())
          let utf8Start = content[..<mentionStart].utf8.count
          let utf8End = utf8Start + content[mentionStart..<currentIndex].utf8.count

          let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: utf8Start, byteEnd: utf8End)

          if let profile = resolvedProfiles[handle] {
            let mentionFeature = AppBskyRichtextFacet.Mention(did: profile.did)
            let facet = AppBskyRichtextFacet(
              index: byteSlice, features: [.appBskyRichtextFacetMention(mentionFeature)])
            facets.append(facet)
          }
        }
      } else {
        currentIndex = content.index(after: currentIndex)
      }
    }

    // Add URL detection
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    if let detector = detector {
      let matches = detector.matches(
        in: content, options: [], range: NSRange(location: 0, length: content.utf16.count))

      for match in matches {
        guard let range = Range(match.range, in: content),
          let matchUrl = match.url?.absoluteString
        else {
          continue
        }

        urls.append(matchUrl)

        // Convert range to UTF-8 byte offsets for facet
        // Calculate UTF-8 byte positions directly to handle multi-byte characters (emoji, etc.)
        let matchStartIndex = range.lowerBound
        let matchEndIndex = range.upperBound

        let utf8Start = content[..<matchStartIndex].utf8.count
        let utf8End = utf8Start + content[matchStartIndex..<matchEndIndex].utf8.count

        let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: utf8Start, byteEnd: utf8End)
        // Create link facet only for well-formed URLs with a non-empty scheme
        if let url = URL(string: matchUrl), let scheme = url.scheme, !scheme.isEmpty {
        let safeURI = URI(uriString: matchUrl) 
          let linkFeature = AppBskyRichtextFacet.Link(uri: safeURI)
          let facet = AppBskyRichtextFacet(
            index: byteSlice, features: [.appBskyRichtextFacetLink(linkFeature)])
          facets.append(facet)
        } else {
          // Skip malformed URLs (e.g., "//") to avoid crashes in URI parsing
          continue
        }
      }
    }

    // Detect language
    let detectedLanguage = LanguageDetector.shared.detectLanguage(for: content)

    return (content, hashtags, facets, urls, detectedLanguage)
  }
}

class URLCardService {
    static func fetchURLCard(for url: String) async throws -> URLCardResponse {
        guard let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let requestURL = URL(string: "https://cardyb.bsky.app/v1/extract?url=\(encodedURL)")
        else {
            throw URLError(.badURL)
        }
        
        // Create a URL request with custom headers
        var request = URLRequest(url: requestURL)
        request.setValue("blue.catbird/1.0 (iOS; Swift)", forHTTPHeaderField: "User-Agent")
        
        // Use the request with URLSession instead of just the URL
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(URLCardResponse.self, from: data)
    }
}
