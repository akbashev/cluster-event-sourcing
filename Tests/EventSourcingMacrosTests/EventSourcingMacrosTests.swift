import EventSourcingMacros
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing

struct EventSourcingMacrosTests {
  @Test
  func testEventSourcedMacro() throws {
    let testMacros: [String: Macro.Type] = [
      "EventSourced": EventSourcedMacro.self
    ]

    assertMacroExpansion(
      """
      @EventSourced
      distributed actor MyActor {
      }
      """,
      expandedSource: """
        distributed actor MyActor {

            public var sequenceNumber: Int64 = 0
        }

        extension MyActor: EventSourced {
        }
        """,
      macros: testMacros
    )
  }
}
