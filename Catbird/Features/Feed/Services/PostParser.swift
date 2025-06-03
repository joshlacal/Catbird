//
//  PostParser.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/16/24.
//

import Foundation
import Petrel

struct URLCardResponse: Codable, Identifiable {
  var id: String { url }
  let error: String
  let likelyType: String
  let url: String
  let title: String
  let description: String
  let image: String

  enum CodingKeys: String, CodingKey {
    case error
    case likelyType = "likely_type"
    case url
    case title
    case description
    case image
  }
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

          let startOffset = utf8View.distance(
            from: utf8View.startIndex,
            to: utf8View.index(
              utf8View.startIndex,
              offsetBy: content.distance(from: content.startIndex, to: hashtagStart)))
          let endOffset = utf8View.distance(
            from: utf8View.startIndex,
            to: utf8View.index(
              utf8View.startIndex,
              offsetBy: content.distance(from: content.startIndex, to: currentIndex)))

          let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: startOffset, byteEnd: endOffset)
          let tagFeature = AppBskyRichtextFacet.Tag(tag: String(hashtag.dropFirst()))
          let facet = AppBskyRichtextFacet(
            index: byteSlice, features: [.appBskyRichtextFacetTag(tagFeature)])

          facets.append(facet)
        }
      } else if content[currentIndex] == "@" {
        let mentionStart = currentIndex
        currentIndex = content.index(after: currentIndex)

        while currentIndex < content.endIndex
          && (content[currentIndex].isLetter || content[currentIndex].isNumber
            || content[currentIndex] == ".") {
          currentIndex = content.index(after: currentIndex)
        }

        let mention = String(content[mentionStart..<currentIndex])
        if mention.count > 1 {  // Ensure it's not just a lone "@"
          let handle = String(mention.dropFirst())
          let startOffset = utf8View.distance(
            from: utf8View.startIndex,
            to: utf8View.index(
              utf8View.startIndex,
              offsetBy: content.distance(from: content.startIndex, to: mentionStart)))
          let endOffset = utf8View.distance(
            from: utf8View.startIndex,
            to: utf8View.index(
              utf8View.startIndex,
              offsetBy: content.distance(from: content.startIndex, to: currentIndex)))

          let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: startOffset, byteEnd: endOffset)

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
        let startIndex = content.startIndex
        let matchStartIndex = range.lowerBound
        let matchEndIndex = range.upperBound

        let utf8Start = content.utf8.distance(
          from: content.utf8.startIndex,
          to: content.utf8.index(
            content.utf8.startIndex,
            offsetBy: content.distance(from: startIndex, to: matchStartIndex)))
        let utf8End = content.utf8.distance(
          from: content.utf8.startIndex,
          to: content.utf8.index(
            content.utf8.startIndex,
            offsetBy: content.distance(from: startIndex, to: matchEndIndex)))

        let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: utf8Start, byteEnd: utf8End)
        // Fix URI creation
        let linkFeature = AppBskyRichtextFacet.Link(uri: URI(matchUrl)!)
        let facet = AppBskyRichtextFacet(
          index: byteSlice, features: [.appBskyRichtextFacetLink(linkFeature)])

        facets.append(facet)
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
