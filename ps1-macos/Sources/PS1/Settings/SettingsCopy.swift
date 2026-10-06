import Foundation

/// Every word the Settings window shows, in one place.
///
/// House style, enforced by `SettingsCopyTests`: plain, complete sentences;
/// no em or en dashes; British spelling, to match the menus ("Colour").
/// Game names in `helps` and `caution` come from one of two sources, never
/// from illustration, and the wording says which:
///
/// - Stated plainly ("In Spyro the Dragon it removes..."): measured on this
///   core, recorded in the `ps1-pgxp` skill.
/// - "Reported" or "known to": DuckStation's per-game compatibility database
///   (`data/resources/gamedb.yaml`, checked 2026-10-02) and its own setting
///   descriptions. Not verified here, and this core's PGXP differs from
///   DuckStation's in places, so the hedge is deliberate.
///
/// Change the copy when a setting's behaviour changes.
enum SettingsCopy {

    // MARK: General

    static let speed = SettingInfo(
        title: "Speed",
        summary: "How fast games run. Above 1× the sound is time-stretched so it keeps its original pitch.",
        details: "The speed actually reached depends on your Mac. The frame rate shown in the game overlay is the true figure. Also available from Machine ▸ Speed (⌥⌘1 to ⌥⌘4)."
    )

    static let fastForward = SettingInfo(
        title: "Fast-Forward Speed",
        summary: "The speed used while you hold the Tab key.",
        details: "Useful for skipping long dialogue, cutscenes or repetitive sections. Releasing Tab returns the game to its normal speed."
    )

    static let cpuEngine = SettingInfo(
        title: "CPU Engine",
        summary: "How the PlayStation's processor is emulated. The recompiler is the fastest.",
        details: "Recompiler translates the game's code into native code for your Mac. Cached Interpreter is slower and works on every Mac. Interpreter is the slowest and the most exact: it handles interrupts and timing one instruction at a time, where the other two handle them between short runs of code. A change applies straight away, without restarting the game.",
        helps: "If a game misbehaves, try Interpreter. If that fixes it, the difference is worth reporting."
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

    static let saveOnExit = SettingInfo(
        title: "Save Progress When Leaving a Game",
        details: "Saves your exact place when you quit, eject or close the window, and offers to continue from there next time. This is separate from saving inside the game. In-game saves always go to the virtual memory card, which is shared by every game in your library."
    )

    // MARK: Library

    static let gamesFolder = SettingInfo(
        title: "Games Folder",
        summary: "The folder containing your disc images. Subfolders are included.",
        details: "Each .cue file is listed as a game. A .bin file is listed on its own only when there is no .cue file beside it."
    )

    static let biosFolder = SettingInfo(
        title: "BIOS Folder",
        summary: "The folder containing your PlayStation BIOS files, such as SCPH-1001.",
        details: "The BIOS is the console's system software and must be dumped from a console you own. Substation identifies each file by its contents and chooses the correct region for every disc automatically."
    )

    static let rescan = SettingInfo(
        title: "Refresh Library",
        summary: "Checks the games folder for discs added since it was last read (⇧⌘R)."
    )

    static let mergeMultiDisc = SettingInfo(
        title: "Merge Multi-Disc Games",
        summary: "Shows a game that shipped on several discs as a single tile.",
        details: "When the game asks for the next disc, choose it from Machine ▸ Change Disc."
    )

    static let coverStyle = SettingInfo(
        title: "Cover Style",
        summary: "Flat scans of the case front, or rendered 3D boxes with a spine.",
        details: "While covers download automatically, changing the style downloads the new one for every game. Covers you chose yourself are kept, and a game the collection has no cover for in the new style keeps the one it has."
    )

    static let autoCovers = SettingInfo(
        title: "Download Covers Automatically",
        summary: "Downloads missing covers after each library scan.",
        details: "Covers are matched by the serial number recorded on each disc, not by file name, so a renamed file still finds the right cover. Covers you chose yourself are never replaced."
    )

    static let missingCovers = SettingInfo(
        title: "Missing Covers",
        summary: "Downloads a cover for every game that does not have one yet.",
        details: "To use your own image instead, right-click a game in the library and select Choose Cover Image."
    )

    // MARK: Video

    static let internalResolution = SettingInfo(
        title: "Internal Resolution",
        summary: "Renders 3D at a multiple of the console's resolution for sharper edges and finer detail.",
        details: "1× matches the original console output exactly. Each step up asks more of your Mac's graphics processor. Shortcut: ⌘1 to ⌘8."
    )

    static let dithering = SettingInfo(
        title: "Dithering",
        summary: "The console could show only 32 shades of each colour and disguised the steps with a fine checkerboard pattern. This chooses how that pattern is handled.",
        // Every mode at once, so they can be compared before choosing one.
        details: DitherMode.allCases.map(ditherMode).joined(separator: "\n\n")
    )

    static let textureFiltering = SettingInfo(
        title: "Texture Filtering",
        summary: "Smooths textures on 3D surfaces so they no longer break up into visible squares up close.",
        details: "Nearest-Neighbour shows each texture pixel as a sharp square, as the console did. Bilinear blends neighbouring texture pixels into a smooth surface. It applies to 3D surfaces only: 2D sprites, menus and text follow Sprite Texture Filtering, and the cut-out edges of things like foliage and fences stay sharp. It changes only the picture you see, never what the game itself reads back."
    )

    static let spriteTextureFiltering = SettingInfo(
        title: "Sprite Texture Filtering",
        summary: "Smooths 2D graphics: sprites, menus, text and anything else the game draws flat on the screen.",
        details: "Nearest-Neighbour keeps 2D graphics as sharp squares, as the console drew them. Bilinear blends neighbouring texture pixels, which softens 2D characters, backgrounds, menus and text. 3D surfaces follow Texture Filtering instead, and cut-out edges stay sharp in both. It changes only the picture you see, never what the game itself reads back."
    )

    static func ditherMode(_ mode: DitherMode) -> String {
        switch mode {
        case .trueColor:
            return "True Colour (recommended): no pattern. Shading is calculated with full 8-bit colour, so skies, lighting and fog become smooth gradients."
        case .scaled:
            return "Scaled: keeps the pattern but makes it as fine as the display allows, so it blends into a smooth gradient at higher resolutions."
        case .native:
            return "Native: the pattern exactly as the console drew it. The most authentic option, though at higher resolutions it appears as visible cross-hatching."
        case .off:
            return "Off: no pattern and no extra colour, so gradual shading shows visible bands. Useful mainly for comparison."
        }
    }

    // MARK: Enhancements (PGXP)

    static let pgxp = SettingInfo(
        title: "PGXP Geometry Correction",
        summary: "Keeps 3D geometry at sub-pixel precision, removing the wobble and jitter the PlayStation is known for.",
        details: "The PlayStation rounds every corner of every polygon to a whole pixel before drawing it, so models shake as they move and surfaces shimmer. PGXP keeps the precise positions the console calculated and draws with those instead. It is an enhancement: the original hardware never looked like this, which is why it starts off.",
        helps: "Any 3D game, most clearly during slow camera movement and on large models. Crash Bandicoot, Spyro the Dragon, Croc, Silent Hill and Tomb Raider all benefit.",
        caution: "2D and 2.5D games gain nothing, including Final Fantasy IV to VI, Lunar and Doom. Games that calculate their 3D without the geometry chip, such as Descent and Duke Nukem: Total Meltdown, are reported to draw incorrectly with it on. When a game is only partly corrected, polygons that should meet can show fine dotted cracks along their edges. If you see any of this, turn the setting off for that game."
    )

    static let pgxpOffFooter = "Turn on PGXP Geometry Correction to change these settings. Each one adjusts how PGXP behaves and has no effect on its own."

    static let usePresets = SettingInfo(
        title: "Per-Game Fixes",
        summary: "Adjusts PGXP for games known to need it, while that game runs.",
        details: "The adjustments come from a built-in list of about 500 discs. A setting a fix changes is greyed out while the game runs. Your own settings are kept and apply again in every other game.",
        helps: "Known fixes include turning PGXP off for Doom and Final Doom, turning Culling Correction off for Spyro the Dragon, and a 3 px Tolerance for Tekken 3 and Driver 2.",
        caution: "A fix is not certain to help in every case. It never turns CPU Mode off. Turn this off to use exactly your own settings in every game."
    )

    /// The footer while a game's preset is in force, listing what it set.
    static func presetFooter(_ changes: [String]) -> String {
        "Per-game fixes for this game: \(changes.joined(separator: ", "))."
    }

    static let textureCorrection = SettingInfo(
        title: "Texture Correction",
        summary: "Draws textures with correct perspective, so floors and walls stop bending and swimming as the camera moves.",
        details: "The console stretches each texture across its polygon without allowing for distance, which makes large surfaces warp. This setting uses the depth PGXP recovers to draw textures the way a modern graphics card does.",
        helps: "Large surfaces seen at an angle, such as the beach in Crash Bandicoot, the floors and walls of Tomb Raider, and the ice and hillsides in Croc. Recommended for every game.",
        caution: "Flat sprites, text and 2D backgrounds are never changed. A polygon is corrected only when the depth of every corner is known, so a small number of polygons may stay uncorrected."
    )

    static let colorCorrection = SettingInfo(
        title: "Colour Correction",
        summary: "Applies the same perspective correction to lighting and shading across each polygon.",
        details: "Games light their models by giving each corner of a polygon its own colour and blending between them. This blends those colours with correct perspective. Polygons drawn in a single colour are never changed.",
        helps: "Games with extensive smooth shading on large polygons, such as Spyro the Dragon and Silent Hill, can show slightly more even lighting.",
        caution: "The effect is subtle, and some games were designed around the original look. It is reported to break shadows in Crash Bandicoot: Warped, which is why it starts off. Turn it off if lighting or shadows look patchy or different from what you remember."
    )

    static let culling = SettingInfo(
        title: "Culling Correction",
        summary: "Uses precise positions to decide which polygons face away from the camera, reducing holes and flickering in geometry.",
        details: "Games hide the back of every model by checking which way each polygon faces. With whole-pixel corners that check is unreliable for small and thin polygons, which can leave holes. This setting makes it exact. It only applies to polygons with a known depth, so menus and on-screen displays are unaffected.",
        helps: "Detailed models and distant scenery, where thin polygons are common. Recommended for most games.",
        caution: "The game reads the result of this check, so it can behave differently from the original console. It is reported to corrupt the view through portals in Spyro the Dragon, and to cause crashes in Cool Boarders and in the first mission of Astro Trooper Vanark. Turn it off if a game shows broken geometry or stops responding."
    )

    static let disable2d = SettingInfo(
        title: "Disable on 2D",
        summary: "Draws polygons that have a precise position but no depth at their original whole-pixel position.",
        details: "Some games build menus, text and on-screen displays from polygons that never pass through the 3D pipeline. PGXP can still refine their positions, which can leave text misaligned or small gaps between the pieces of an interface.",
        helps: "Fixes misaligned text in the WipEout series and Xenogears.",
        caution: "It also catches some genuine 3D polygons, which then lose their correction. In Spyro the Dragon it removes correction from several thousand vertices. Leave it off unless it fixes a problem you can see."
    )

    static let depthBuffer = SettingInfo(
        title: "Depth Buffer",
        summary: "Sorts overlapping polygons pixel by pixel using their real depth, instead of the order the game drew them in.",
        details: "The PlayStation has no depth buffer. Games sort their polygons themselves, approximately, so intersecting objects can poke through each other. This setting adds a depth buffer built from the depth PGXP recovers.",
        helps: "Objects that intersect other geometry. In Crash Bandicoot, a crab's leg dipping into the sand is correctly hidden.",
        caution: "Many games rely on their own drawing order and look wrong with it on. In Crash Bandicoot, smashed crate fragments sink into the ground. In Spyro the Dragon, backdrop mountains can be layered incorrectly and parts of Spyro can disappear. In Silent Hill, bright seams appear across the foggy ground. There is no general fix, so it starts off and is best tried one game at a time."
    )

    static let transparentDepth = SettingInfo(
        title: "Transparent Depth",
        summary: "Lets see-through effects such as fog, water and shadows be hidden behind solid objects. Requires Depth Buffer.",
        details: "Without it, transparent polygons are always drawn in the game's own order. With it, they are tested against the depth buffer but never change it, so whatever lies behind them stays visible.",
        helps: "Removes the bright seam lines across the foggy ground in Silent Hill.",
        caution: "Many games place transparent effects behind objects on purpose and rely on drawing order to show them in front. Shadows commonly sink into the ground, and in Silent Hill the fog effect on Harry himself breaks. Leave it off unless you are fixing a specific problem."
    )

    static let cpuMode = SettingInfo(
        title: "CPU Mode",
        summary: "Follows precise positions through the game's own calculations as well as the geometry chip's. Most games need this.",
        details: "Many games move and copy vertex positions using ordinary processor arithmetic after the geometry chip has produced them. Without this setting PGXP loses track of those vertices, and they fall back to whole pixels.",
        helps: "Essential for Croc, Spyro the Dragon, Resident Evil and Metal Gear Solid. In testing it raised the share of corrected vertices from 13% to over 99% in Croc, and from 42% to over 99% in Spyro the Dragon. Driver 2, Tekken 3, Vagrant Story, the WipEout series and the Tony Hawk's Pro Skater series are also known to need it.",
        caution: "It makes emulation slower, by an amount that depends on the game and your Mac. Turning it off leaves many games only partly corrected, which can look worse than PGXP off. Other emulators turn it on per game. It is on by default here because it helped every game tested."
    )

    static let preserveProjection = SettingInfo(
        title: "Preserve Projection Precision",
        summary: "Calculates screen positions from the geometry chip's full internal precision instead of its rounded results.",
        details: "A small refinement on top of PGXP. Positions are still kept within the pixel the console would have drawn them in, so nothing moves visibly out of place.",
        helps: "Reported to reduce jitter on character models in Vagrant Story and Evil Dead: Hail to the King, and to improve the floor tiles in Ghost in the Shell.",
        caution: "Reported to open holes in geometry in Crash Team Racing and Persona. More vertices reach the edge of their pixel and are held there, particularly in Tomb Raider and Silent Hill, and combined with a Tolerance limit it causes far more positions to be rejected. Off matches standard PGXP behaviour."
    )

    static let vertexCache = SettingInfo(
        title: "Vertex Cache",
        summary: "Recovers precise positions by remembering the last precise vertex seen at each screen position.",
        details: "A fallback for vertices PGXP cannot follow by any other means. It finds a vertex by where it appears on screen rather than by tracking it, which makes it a guess.",
        helps: "Syphon Filter 3 is known to need it. With CPU Mode on, every other game tested is already well covered, so it rarely helps.",
        caution: "When two different vertices share a screen position the guess can be wrong, producing sparkles, stray polygons or missing faces. Positions it recovers carry no depth, so they receive no texture correction. It uses about 83 MB of memory while on."
    )

    static let tolerance = SettingInfo(
        title: "Tolerance",
        summary: "How far a precise position may stray from the console's own before it is discarded.",
        details: "A safety limit on PGXP's positions, intended as a per-game workaround. When one corner of a polygon is discarded, the whole polygon returns to whole pixels.",
        helps: "Reported fixes: 2 px for the minimap in Motor Toon Grand Prix, 3 px for car shadows in Driver 2, for glitching polygons in Spider-Man and for spiky polygons as characters leave the screen in Tekken 3, and 4 px for the targeting line in Vagrant Story.",
        caution: "A strict limit removes far more correction than it protects. At 1 px, Croc loses almost all of its texture correction. Leave it off unless a game shows the problem a limit is known to fix."
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
        summary: "PlayStation, Xbox and other controllers supported by macOS work as soon as they connect, over Bluetooth or USB, with no setup."
    )

    // MARK: For the style test

    static let allInfo: [SettingInfo] = [
        speed, fastForward, cpuEngine, volume, mute, libraryTheme, saveOnExit,
        gamesFolder, biosFolder, rescan, mergeMultiDisc, coverStyle, autoCovers, missingCovers,
        internalResolution, dithering, textureFiltering, spriteTextureFiltering,
        pgxp, usePresets, textureCorrection, colorCorrection, culling, disable2d,
        depthBuffer, transparentDepth, cpuMode, preserveProjection, vertexCache, tolerance,
        fastForwardKey, pauseKey, resetKey, ejectKey, controllers,
    ]

    static var allText: [String] {
        allInfo.flatMap(\.allText)
            + [pgxpOffFooter, presetFooter(["Culling Correction off", "Tolerance 3 px"])]
    }
}
