import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct EventSourcedMacro: MemberMacro, ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    [
      "public var sequenceNumber: Int64 = 0"
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let decl: DeclSyntax = "extension \(type.trimmed): EventSourced {}"
    return [decl.cast(ExtensionDeclSyntax.self)]
  }
}

@main
struct EventSourcingPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    EventSourcedMacro.self
  ]
}
