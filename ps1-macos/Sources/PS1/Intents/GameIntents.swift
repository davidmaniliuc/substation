import AppIntents

/// Opens a game as Finder opening its first disc does: a running game is
/// asked about first, and a game with states is offered them. Spotlight runs
/// it when a game is picked.
struct PlayGameIntent: OpenIntent {
    static let title: LocalizedStringResource = "Play Game"
    static let description = IntentDescription("Opens a game from your library, offering to resume it.")

    @Parameter(title: "Game") var target: GameEntity
    @Dependency private var model: EmulatorViewModel

    @MainActor func perform() async throws -> some IntentResult {
        model.playFromIntent(try await model.intentGame(target))
        return .result()
    }
}

/// Straight back into a game's resume state, as the Continue button does.
/// With no game named, the one played last.
struct ResumeGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Game"
    static let description = IntentDescription(
        "Continues a game where you left it. With no game chosen, continues the one you played last.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: GameEntity?
    @Dependency private var model: EmulatorViewModel

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$game)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let games = try await model.intentGames()
        let chosen: GameGroup
        if let game {
            chosen = try await model.intentGame(game)
        } else if let last = GameCatalog.lastPlayed(games, stats: model.playStats.all) {
            chosen = last
        } else {
            throw IntentFailure.nothingPlayed
        }
        model.resumeFromIntent(chosen)
        return .result()
    }
}

struct OpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Library"
    static let description = IntentDescription("Brings the Substation library forward.")
    static let openAppWhenRun = true

    @Dependency private var model: EmulatorViewModel

    @MainActor func perform() async throws -> some IntentResult {
        model.openLibraryFromIntent()
        return .result()
    }
}
