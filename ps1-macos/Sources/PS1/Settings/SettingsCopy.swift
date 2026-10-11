/// Settings labels and optional descriptions, kept together for consistency.
/// Use British spelling and complete sentences for descriptions.
enum SettingsCopy {

    // MARK: General

    static let speed = SettingInfo(
        title: "Game Speed"
    )

    static let fastForward = SettingInfo(
        title: "Fast-Forward Speed"
    )

    static let cpuEngine = SettingInfo(
        title: "Emulation Engine",
        description: "Use Interpreter if a game has problems with the recompiler."
    )

    static let runahead = SettingInfo(
        title: "Runahead",
        description: "Reduces the delay between pressing a button and seeing the result. Higher values require more processing power."
    )

    static let rewind = SettingInfo(
        title: "Rewind",
        description: "Hold the rewind key to go back and try again."
    )

    static let rewindMemory = SettingInfo(
        title: "Rewind Memory",
        description: "More memory lets you rewind further."
    )

    static let rewindPadButton = SettingInfo(
        title: "Rewind Button",
        description: "The selected controller button will no longer perform its usual action in games."
    )

    static let volume = SettingInfo(
        title: "Volume"
    )

    static let mute = SettingInfo(
        title: "Mute"
    )

    static let libraryTheme = SettingInfo(
        title: "Theme"
    )

    static let gameWindow = SettingInfo(
        title: "Open Games In"
    )

    static let gameWindowFullScreen = SettingInfo(
        title: "Open in Full Screen"
    )

    static let saveOnExit = SettingInfo(
        title: "Save on Exit",
        description: "Saves your place when you leave a game so you can continue next time."
    )

    static let autoSave = SettingInfo(
        title: "Automatic Saves",
        description: "Saves your place at regular intervals while you play."
    )

    static let fastBoot = SettingInfo(
        title: "Skip Startup Logos"
    )

    static let savingFooter = "These saves are separate from in-game memory card saves."

    // MARK: Library

    static let gamesFolder = SettingInfo(
        title: "Games Folder",
        description: "Games in subfolders are included."
    )

    static let biosFolder = SettingInfo(
        title: "BIOS Folder",
        description: "PlayStation system software required to run games."
    )

    static let rescan = SettingInfo(
        title: "Refresh Library"
    )

    static let mergeMultiDisc = SettingInfo(
        title: "Group Multi-Disc Games",
        description: "Show all discs for a game as one library item."
    )

    static let coverStyle = SettingInfo(
        title: "Cover Style"
    )

    static let autoCovers = SettingInfo(
        title: "Download Covers Automatically"
    )

    static let missingCovers = SettingInfo(
        title: "Download Missing Covers"
    )

    // MARK: Video

    static let internalResolution = SettingInfo(
        title: "Internal Resolution",
        description: "Higher resolutions make 3D graphics sharper."
    )

    static let dithering = SettingInfo(
        title: "Dithering",
        description: "Choose how colour gradients appear."
    )

    static func ditherOptionTitle(_ mode: DitherMode) -> String {
        switch mode {
        case .off:
            "Off (Colour Bands)"
        case .native:
            "Native (Original Pattern)"
        case .scaled:
            "Scaled (Finer Pattern)"
        case .trueColor:
            "True Colour (Smooth Gradients)"
        }
    }

    static let textureFiltering = SettingInfo(
        title: "Texture Filtering",
        description: "Smooths textures on 3D objects."
    )

    static let spriteTextureFiltering = SettingInfo(
        title: "Sprite Filtering",
        description: "Smooths 2D graphics, including menus and text."
    )

    // MARK: Enhancements (PGXP)

    static let pgxp = SettingInfo(
        title: "Geometry Correction (PGXP)",
        description: "Reduces wobbling and jitter in 3D graphics."
    )

    static let pgxpOffFooter = "Turn on Geometry Correction to use these settings."

    static let usePresets = SettingInfo(
        title: "Automatic Game Fixes",
        description: "Applies recommended settings for recognised games. Your preferences are restored afterwards."
    )

    /// The footer while a game's preset is in force, listing what it set.
    static func presetFooter(_ changes: [String]) -> String {
        "Applied for this game: \(changes.joined(separator: ", "))."
    }

    static let textureCorrection = SettingInfo(
        title: "Texture Correction",
        description: "Reduces texture warping on floors, walls and other 3D surfaces."
    )

    static let colorCorrection = SettingInfo(
        title: "Colour Correction",
        description: "Adjusts shading perspective. May cause incorrect lighting or shadows in some games."
    )

    static let culling = SettingInfo(
        title: "Culling Correction",
        description: "Reduces holes and flickering in 3D objects. May cause problems in some games."
    )

    static let disable2d = SettingInfo(
        title: "Preserve 2D Graphics",
        description: "Keeps menus and other flat graphics at their original positions. May also reduce correction in some 3D scenes."
    )

    static let depthBuffer = SettingInfo(
        title: "Depth Buffer",
        description: "Reduces objects showing through each other, but may hide some objects or effects incorrectly."
    )

    static let transparentDepth = SettingInfo(
        title: "Transparent Depth",
        description: "Allows solid objects to hide transparent effects. May cause missing shadows or incorrect fog."
    )

    static let cpuMode = SettingInfo(
        title: "CPU Mode",
        description: "Extends geometry correction to more objects. Requires more processing power."
    )

    static let preserveProjection = SettingInfo(
        title: "Preserve Projection Precision",
        description: "Further reduces jitter in some games. May introduce gaps in 3D objects."
    )

    static let vertexCache = SettingInfo(
        title: "Vertex Cache",
        description: "May correct objects that still wobble. Can introduce visual glitches."
    )

    static let tolerance = SettingInfo(
        title: "Tolerance",
        description: "Limits how far corrected positions can move. Lower values may reduce visual glitches but leave more wobble."
    )

    // MARK: Controls

    static let fastForwardKey = SettingInfo(
        title: "Fast-Forward"
    )

    static let pauseKey = SettingInfo(
        title: "Pause or Resume"
    )

    static let resetKey = SettingInfo(
        title: "Reset"
    )

    static let ejectKey = SettingInfo(
        title: "Eject Disc"
    )

    static let controllers = SettingInfo(
        title: "Game Controllers",
        description: "Connect a supported controller using Bluetooth or USB."
    )

    static let pauseMenuKey = SettingInfo(
        title: "Pause Menu"
    )

    static let vibration = SettingInfo(
        title: "Vibration"
    )

    // MARK: For the style test

    static let allInfo: [SettingInfo] = [
        speed, fastForward, cpuEngine, runahead, rewind, rewindMemory, rewindPadButton, volume, mute, libraryTheme, gameWindow, gameWindowFullScreen, saveOnExit, autoSave, fastBoot,
        gamesFolder, biosFolder, rescan, mergeMultiDisc, coverStyle, autoCovers, missingCovers,
        internalResolution, dithering, textureFiltering, spriteTextureFiltering,
        pgxp, usePresets, textureCorrection, colorCorrection, culling, disable2d,
        depthBuffer, transparentDepth, cpuMode, preserveProjection, vertexCache, tolerance,
        fastForwardKey, pauseKey, resetKey, ejectKey, controllers, pauseMenuKey, vibration,
    ]

    static var allText: [String] {
        allInfo.flatMap(\.allText)
            + DitherMode.allCases.map(ditherOptionTitle)
            + [savingFooter, pgxpOffFooter, presetFooter(["Culling Correction off", "Tolerance 3 px"])]
    }
}
