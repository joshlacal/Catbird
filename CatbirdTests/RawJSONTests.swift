import Foundation
import Testing
@testable import Catbird

@Suite("RawJSON")
struct RawJSONTests {
  @Test func memberIsTheExactSubstring() {
    let value = #"{ "b" : [1, "x]}", {"c":"\"}"}], "d":null }"#
    let doc = #"{"a":1,  "value":"# + value + #" , "z":"A"}"#
    #expect(RawJSON.memberString("value", in: Data(doc.utf8)) == value)
    #expect(RawJSON.memberString("a", in: Data(doc.utf8)) == "1")
    #expect(RawJSON.memberString("z", in: Data(doc.utf8)) == #""A""#)
    #expect(RawJSON.memberString("missing", in: Data(doc.utf8)) == nil)
  }

  @Test func escapedMemberNamesMatch() {
    #expect(RawJSON.memberString("value", in: Data(#"{"value":true}"#.utf8)) == "true")
  }

  @Test func duplicateOrTruncatedInputIsRejected() {
    #expect(RawJSON.member("a", in: Data(#"{"a":1,"a":2}"#.utf8)) == nil)
    #expect(RawJSON.member("a", in: Data(#"{"a":{"b":1}"#.utf8)) == nil)
    #expect(RawJSON.member("a", in: Data(#"{"a":"open}"#.utf8)) == nil)
    #expect(RawJSON.member("a", in: Data(#"{"a":1} trailing"#.utf8)) == nil)
  }

  @Test func elementsAreExactSubstrings() {
    let elements = RawJSON.elements(in: Data(#"[ {"x":"]"} ,[1,2],"s" ]"#.utf8))
    #expect(elements?.map { String(decoding: $0, as: UTF8.self) } == [#"{"x":"]"}"#, "[1,2]", #""s""#])
    #expect(RawJSON.elements(in: Data("[]".utf8))?.isEmpty == true)
    #expect(RawJSON.elements(in: Data("[1,".utf8)) == nil)
  }
}
