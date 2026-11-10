// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerDomain
import WikimediaAccess

public protocol ResearchClient: Sendable {
    func search(_ input: SearchInput) async throws -> SearchPage
    func outline(_ input: OutlineInput) async throws -> Outline
    func section(_ input: SectionInput) async throws -> SectionPassage
    func references(_ input: ReferencesInput) async throws -> SectionReferences
}
extension ExplorerService: ResearchClient {}

/// Provider choice is an actual dependency, never an appearance preference.
public typealias ResearchSource = SourceProfile
public enum ResearchPhase: String, Sendable { case idle, searching, candidates, opening, outline, reading, references, section, empty, problem, cancelled }
