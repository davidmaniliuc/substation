import AppIntents
import CoreSpotlight
import Foundation

/// A library game as Spotlight, Shortcuts and Siri see it: one per merged
/// game, identified as `GameCatalog` identifies it.
struct GameEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = GameQuery()

    let id: String
    let title: String
    /// The disc count, or the date it was last played.
    let subtitle: String
    let cover: URL?
    /// Every disc's, so a serial typed in Spotlight finds the game.
    let serials: [String]

    /// With no cover there is no image, and Spotlight shows the app's icon.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                              image: cover.map { DisplayRepresentation.Image(url: $0) })
    }

    init(_ game: GameGroup, id: String, stats: PlayStats?, cover: URL?) {
        self.id = id
        title = game.title
        subtitle = LibraryFormat.entitySubtitle(discs: game.discs.count, lastPlayed: stats?.lastPlayed)
        self.cover = cover
        serials = game.discs.compactMap(\.serial)
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.displayName = title
        attributes.contentDescription = subtitle
        attributes.keywords = serials
        attributes.thumbnailURL = cover
        return attributes
    }
}

struct GameQuery: EntityStringQuery {
    @Dependency private var model: EmulatorViewModel

    @MainActor func entities(for identifiers: [String]) async throws -> [GameEntity] {
        let games = try await model.intentGames()
        return identifiers.compactMap { GameCatalog.game(id: $0, in: games) }.map { model.entity($0, in: games) }
    }

    @MainActor func entities(matching string: String) async throws -> [GameEntity] {
        let games = try await model.intentGames()
        return GameCatalog.matching(games, query: string).map { model.entity($0, in: games) }
    }

    @MainActor func suggestedEntities() async throws -> [GameEntity] {
        let games = try await model.intentGames()
        return GameCatalog.suggested(games, stats: model.playStats.all).map { model.entity($0, in: games) }
    }
}

extension EmulatorViewModel {
    func entity(_ game: GameGroup, in games: [GameGroup]) -> GameEntity {
        GameEntity(game, id: GameCatalog.id(of: game, in: games),
                   stats: playStats.stats(for: GameCatalog.key(of: game)),
                   cover: covers.coverURL(for: game.first))
    }

    /// The game an intent names, among `games` (`intentGames`).
    func intentGame(_ entity: GameEntity, in games: [GameGroup]) throws(IntentFailure) -> GameGroup {
        guard let game = GameCatalog.game(id: entity.id, in: games) else { throw .gameMissing }
        return game
    }

    /// Replaced whole, so a removed game leaves Spotlight.
    static func indexInSpotlight(_ entities: [GameEntity]) async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: GameEntity.self)
            try await index.indexAppEntities(entities)
        } catch {
            NSLog("Substation: Spotlight index failed: \(error)")
        }
        SubstationShortcuts.updateAppShortcutParameters()
    }
}

extension IntentFailure: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
