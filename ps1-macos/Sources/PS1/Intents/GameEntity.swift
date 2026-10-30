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
    /// The tile's caption: the disc count, or when it was last played.
    let subtitle: String
    let cover: URL?

    /// With no cover there is no image, and Spotlight shows the app's icon.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)",
                              image: cover.map { DisplayRepresentation.Image(url: $0) })
    }

    init(_ game: GameGroup, stats: PlayStats?, cover: URL?) {
        id = GameCatalog.id(of: game)
        title = game.title
        subtitle = LibraryFormat.tileSubtitle(discs: game.discs.count, lastPlayed: stats?.lastPlayed)
        self.cover = cover
    }
}

struct GameQuery: EntityStringQuery {
    @Dependency private var model: EmulatorViewModel

    @MainActor func entities(for identifiers: [String]) async throws -> [GameEntity] {
        let games = try await model.intentGames()
        return identifiers.compactMap { GameCatalog.game(id: $0, in: games) }.map(model.entity)
    }

    @MainActor func entities(matching string: String) async throws -> [GameEntity] {
        GameCatalog.matching(try await model.intentGames(), query: string).map(model.entity)
    }

    @MainActor func suggestedEntities() async throws -> [GameEntity] {
        GameCatalog.suggested(try await model.intentGames(), stats: model.playStats.all).map(model.entity)
    }
}

extension EmulatorViewModel {
    func entity(_ game: GameGroup) -> GameEntity {
        GameEntity(game, stats: playStats.stats(for: GameCatalog.id(of: game)),
                   cover: covers.coverURL(for: game.first))
    }

    /// The game an intent names, from a fresh look at the library.
    func intentGame(_ entity: GameEntity) async throws(IntentFailure) -> GameGroup {
        guard let game = GameCatalog.game(id: entity.id, in: try await intentGames()) else {
            throw .gameMissing
        }
        return game
    }

    /// Spotlight's copy of the library and the App Shortcuts' parameters,
    /// replaced after every scan so a removed game leaves both.
    func publishGamesToSystem() {
        let entities = GameCatalog.games(library.entries).map(entity)
        Task {
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
}

extension IntentFailure: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
