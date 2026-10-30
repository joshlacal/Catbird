/// Tracks complete request identities shared by Search and timeline.
/// A removed request is cancelled only when its last exact owner departs.
struct TopicPreviewImagePrefetchOwnership<Request, Identity: Hashable> {
  private(set) var requests: [TopicPreviewPrefetchOwner: [Request]] = [:]

  mutating func append(_ candidates: [Request], owner: TopicPreviewPrefetchOwner,
    identity: (Request) -> Identity) -> [Request] {
    let existing = requests[owner] ?? []
    var seen = Set(existing.map(identity))
    var additions: [Request] = []
    for request in candidates {
      guard existing.count + additions.count < 36 else { break }
      if seen.insert(identity(request)).inserted { additions.append(request) }
    }
    if !additions.isEmpty { requests[owner] = existing + additions }
    return additions
  }

  mutating func remove(owner: TopicPreviewPrefetchOwner, identity: (Request) -> Identity) -> [Request] {
    let removed = requests.removeValue(forKey: owner) ?? []
    let retained = Set(requests.values.flatMap { $0 }.map(identity))
    return removed.filter { !retained.contains(identity($0)) }
  }

  mutating func removeAll() {
    requests.removeAll()
  }
}
