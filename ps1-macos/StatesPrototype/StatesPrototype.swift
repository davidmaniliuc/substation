// PROTOTYPE, throwaway. The launch sheet's resume prompt and the floating Spotlight
// launch panel, redone without the Cancel row and the dashed Start Fresh tile.
// Thumbnails and covers are the real ones in Application Support. Nothing is
// wired to the core. Run: ps1-macos/StatesPrototype/run.sh
import AppKit
import SwiftUI

// MARK: - Data

let support = FileManager.default.homeDirectoryForCurrentUser
  .appending(path: "Library/Application Support/Substation")

struct SavedState: Identifiable, Hashable {
  let id: String
  let title: String
  let date: Date
  let image: NSImage?
  var isResume: Bool { id == "resume" }
}

struct Game: Identifiable, Hashable {
  let id: String
  let title: String
  let cover: NSImage?
  let states: [SavedState]
  func slot(_ n: Int) -> SavedState? { states.first { $0.id == "slot\(n)" } }
  var resume: SavedState? { states.first { $0.isResume } }
}

func state(_ id: String, _ title: String, _ url: URL) -> SavedState? {
  guard FileManager.default.fileExists(atPath: url.path) else { return nil }
  let date =
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    ?? .now
  return SavedState(id: id, title: title, date: date, image: NSImage(contentsOf: url))
}

func loadGames() -> [Game] {
  let rows = [
    ("SCES-00344", "Crash Bandicoot"), ("SCES-00967", "Crash Bandicoot 3: Warped"),
    ("SLUS-00707", "Silent Hill"), ("SCUS-94163", "Final Fantasy VII"),
    ("SLUS-00530", "Hot Wheels Turbo Racing"), ("SLES-02966", "Final Fantasy IX"),
  ]
  return rows.compactMap { serial, title in
    let resume = support.appending(path: "ResumeStates")
    var states = [
      state("resume", "Resume", resume.appending(path: "\(serial).png")),
      state("previous", "Previous Resume", resume.appending(path: "\(serial).prev.png")),
    ]
    for n in 1...6 {
      states.append(
        state("slot\(n)", "Slot \(n)", support.appending(path: "SaveStates/\(serial)/slot\(n).png"))
      )
    }
    let found = states.compactMap { $0 }
    guard !found.isEmpty else { return nil }
    let cover = NSImage(contentsOf: support.appending(path: "Covers/\(serial).png"))
    return Game(id: serial, title: title, cover: cover, states: found)
  }
}

func savedAt(_ date: Date) -> String {
  let time = date.formatted(date: .omitted, time: .shortened)
  if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
  if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
  return date.formatted(.dateTime.day().month(.abbreviated).year()) + ", \(time)"
}

// MARK: - Shared pieces

struct Screenshot: View {
  let image: NSImage?
  var radius: CGFloat = 8
  var body: some View {
    RoundedRectangle(cornerRadius: radius).fill(.black)
      .overlay {
        if let image { Image(nsImage: image).resizable().interpolation(.high) }
      }
      .aspectRatio(4 / 3, contentMode: .fit)
      .clipShape(.rect(cornerRadius: radius))
      // The hairline every system thumbnail has, so a dark frame keeps its edge.
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
  }
}

struct Cover: View {
  let image: NSImage?
  let side: CGFloat
  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
      } else {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
          .overlay(Image(systemName: "opticaldisc").foregroundStyle(.secondary))
      }
    }
    .frame(width: side, height: side)
    .clipShape(.rect(cornerRadius: 4))
    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
  }
}

/// Finder's and Photos' selection: an accent rounded rect round the picture,
/// the caption on an accent capsule. No ring for the hover, which only reveals
/// the trash.
struct SelectableTile: View {
  let state: SavedState
  let selected: Bool
  let width: CGFloat
  let select: () -> Void
  let open: () -> Void
  let delete: () -> Void
  @State private var hover = false

  var body: some View {
    VStack(spacing: 5) {
      Screenshot(image: state.image)
        .frame(width: width)
        .padding(3)
        .background(
          RoundedRectangle(cornerRadius: 11)
            .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 11)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .bottomTrailing) {
          if hover {
            TrashButton(help: "Delete \(state.title)…", action: delete).padding(9)
              .transition(.opacity)
          }
        }
      VStack(spacing: 1) {
        Text(state.title).font(.system(size: 12, weight: .medium))
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(Capsule().fill(selected ? Color.accentColor : .clear))
          .foregroundStyle(selected ? .white : .primary)
        Text(savedAt(state.date)).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }
    .contentShape(.rect)
    .onTapGesture(count: 2, perform: open)
    .simultaneousGesture(TapGesture().onEnded(select))
    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    .contextMenu {
      Button("Load \(state.title)", action: open)
      Divider()
      Button("Delete \(state.title)…", role: .destructive, action: delete)
    }
  }
}

/// Clear glass over the picture (HIG Materials: a control over media).
struct TrashButton: View {
  let help: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white).frame(width: 24, height: 24).contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.clear.interactive(), in: Circle())
    .help(help)
  }
}

// MARK: - Resume sheet, A: select, then one button bar

/// A real dialog: header, a selectable strip, and a bar with Start Fresh
/// leading and the default button trailing. The default names what it loads.
/// No Cancel: Escape closes, as does a click outside.
struct SheetA: View {
  let game: Game
  let choose: (String) -> Void
  @State private var selection = "resume"

  var body: some View {
    let states = game.states
    let picked = states.first { $0.id == selection } ?? states[0]
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Cover(image: game.cover, side: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(game.title).font(.system(size: 15, weight: .semibold))
          Text("Choose where to continue.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 14) {
          ForEach(states) { s in
            SelectableTile(
              state: s, selected: s.id == selection, width: 148,
              select: { selection = s.id },
              open: { choose("Load \(s.title)") },
              delete: { choose("Ask: delete \(s.title)") })
          }
        }
      }
      .scrollIndicators(.never)
      .frame(width: CGFloat(min(states.count, 3)) * 168 + (states.count > 3 ? 30 : 0))
      HStack {
        Button("Start Fresh") { choose("Boot the disc") }
        Spacer()
        Button(picked.isResume ? "Resume" : "Load \(picked.title)") {
          choose("Load \(picked.title)")
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
      .buttonStyle(.glass)
      .controlSize(.large)
    }
    .padding(22)
    .fixedSize()
  }
}

// MARK: - Resume sheet, B: tiles, Start Fresh as the game's cover

/// The current strip, minus the Cancel row. Start Fresh is the disc itself:
/// its cover on a blur of its own colours, the same 4:3 as a screenshot.
/// A close button sits where every Tahoe sheet keeps it.
struct SheetB: View {
  let game: Game
  let choose: (String) -> Void
  @State private var selection = "resume"

  var body: some View {
    let states = game.states
    VStack(spacing: 16) {
      ZStack {
        VStack(spacing: 2) {
          Text(game.title).font(.system(size: 15, weight: .semibold))
          Text("Pick up where you left off").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        HStack {
          Button {
            choose("Close")
          } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
          .help("Close (esc)")
          Spacer()
        }
      }
      HStack(alignment: .top, spacing: 14) {
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 14) {
            ForEach(states) { s in
              SelectableTile(
                state: s, selected: s.id == selection, width: 148,
                select: { selection = s.id },
                open: { choose("Load \(s.title)") },
                delete: { choose("Ask: delete \(s.title)") })
            }
          }
        }
        .scrollIndicators(.never)
        .frame(width: CGFloat(min(states.count, 3)) * 168 + (states.count > 3 ? 30 : 0))
        Divider().frame(height: 100).padding(.top, 8)
        FreshCoverTile(cover: game.cover) { choose("Boot the disc") }
      }
    }
    .padding(20)
    .fixedSize()
  }
}

struct FreshCoverTile: View {
  let cover: NSImage?
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        ZStack {
          if let cover {
            Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
              .blur(radius: 18).saturation(1.2).opacity(0.7)
            Image(nsImage: cover).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
              .clipShape(.rect(cornerRadius: 3))
              .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
              .padding(16)
          } else {
            Color.black.opacity(0.3)
            Image(systemName: "opticaldisc").font(.system(size: 28)).foregroundStyle(.secondary)
          }
          Color.black.opacity(hover ? 0.15 : 0)
        }
        .frame(width: 148, height: 111)
        .clipShape(.rect(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .padding(3)
        VStack(spacing: 1) {
          Text("Start Fresh").font(.system(size: 12, weight: .medium)).padding(.vertical, 1)
          Text("From the beginning").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
  }
}

// MARK: - Resume sheet, C: a list

/// A table, as the HIG prefers once a collection is mostly text: a row per
/// state, the selection a full accent row, Start Fresh and the default in the
/// bar under it.
struct SheetC: View {
  let game: Game
  let choose: (String) -> Void
  @State private var selection = "resume"

  var body: some View {
    let picked = game.states.first { $0.id == selection } ?? game.states[0]
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Cover(image: game.cover, side: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(game.title).font(.system(size: 15, weight: .semibold))
          Text("Choose where to continue.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
      ScrollView {
        VStack(spacing: 2) {
          ForEach(game.states) { s in row(s, selected: s.id == selection) }
        }
        .padding(4)
      }
      .scrollIndicators(.automatic)
      .frame(height: min(CGFloat(game.states.count), 4) * 74 + 8)
      .background(.black.opacity(0.18), in: .rect(cornerRadius: 10))
      HStack {
        Button("Start Fresh") { choose("Boot the disc") }
        Spacer()
        Button(picked.isResume ? "Resume" : "Load \(picked.title)") {
          choose("Load \(picked.title)")
        }
        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
      }
      .buttonStyle(.glass).controlSize(.large)
    }
    .padding(22)
    .frame(width: 440)
  }

  private func row(_ s: SavedState, selected: Bool) -> some View {
    HStack(spacing: 12) {
      Screenshot(image: s.image, radius: 5).frame(width: 85)
      VStack(alignment: .leading, spacing: 2) {
        Text(s.title).font(.system(size: 13, weight: .medium))
        Text(savedAt(s.date)).font(.system(size: 11))
          .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
      }
      Spacer()
    }
    .padding(5)
    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
    .contentShape(.rect)
    .onTapGesture(count: 2) { choose("Load \(s.title)") }
    .simultaneousGesture(TapGesture().onEnded { selection = s.id })
    .contextMenu {
      Button("Load \(s.title)") { choose("Load \(s.title)") }
      Divider()
      Button("Delete \(s.title)…", role: .destructive) { choose("Ask: delete \(s.title)") }
    }
  }
}

// MARK: - Resume sheet, as shipped

struct SheetCurrent: View {
  let game: Game
  var body: some View {
    VStack(spacing: 16) {
      VStack(spacing: 2) {
        Text(game.title).font(.title3.weight(.semibold))
        Text("Pick up where you left off").foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 12) {
        ForEach(game.states.prefix(3)) { s in
          VStack(alignment: .leading, spacing: 6) {
            Screenshot(image: s.image, radius: 10).frame(width: 150)
              .overlay(
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(s.isResume ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(s.title).font(.callout.weight(s.isResume ? .semibold : .regular))
            Text(savedAt(s.date)).font(.caption).foregroundStyle(.secondary)
          }
          .frame(width: 150)
        }
        Divider().frame(height: 112)
        VStack(alignment: .leading, spacing: 6) {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(.white.opacity(0.25)).aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
              Image(systemName: "power").font(.system(size: 26)).foregroundStyle(.secondary)
            }
          Text("Start Fresh").font(.callout)
          Text("Boot the disc").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 150)
      }
      Button("Cancel") {}.buttonStyle(.glass).controlSize(.large)
    }
    .padding(20)
    .fixedSize()
  }
}

// MARK: - Resume sheet, D: the resume as a hero

/// What Return will do, shown big: the resume's own frame on the left, the
/// game and two buttons on the right. Every other state is one pull-down
/// away, a system control, instead of a strip to scroll.
struct SheetD: View {
  let game: Game
  let choose: (String) -> Void

  var body: some View {
    let hero = game.resume ?? game.states[0]
    let others = game.states.filter { $0 != hero }
    HStack(alignment: .top, spacing: 20) {
      Screenshot(image: hero.image, radius: 12).frame(width: 320)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Cover(image: game.cover, side: 40)
          Text(game.title).font(.system(size: 15, weight: .semibold))
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        Text(
          hero.isResume
            ? "Last played \(savedAt(hero.date))" : "\(hero.title), \(savedAt(hero.date))"
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(.top, 10)
        if !others.isEmpty {
          Menu("Other States") {
            ForEach(others) { s in
              Button("\(s.title) · \(savedAt(s.date))") { choose("Load \(s.title)") }
            }
          }
          .menuStyle(.button)
          .buttonStyle(.glass)
          .fixedSize()
          .padding(.top, 12)
        }
        Spacer(minLength: 16)
        HStack(spacing: 8) {
          Button("Start Fresh") { choose("Boot the disc") }
          Button(hero.isResume ? "Resume" : "Load") { choose("Load \(hero.title)") }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
      }
      .frame(width: 220, alignment: .leading)
    }
    .padding(20)
    .fixedSize()
  }
}

// MARK: - Resume sheet, E: a Spotlight-wide bar

/// Low and wide, as a quick-entry panel floats: one header row carrying the
/// game and both buttons, the states as small selectable frames under it.
struct SheetE: View {
  let game: Game
  let choose: (String) -> Void
  @State private var selection = "resume"

  var body: some View {
    let picked = game.states.first { $0.id == selection } ?? game.states[0]
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Cover(image: game.cover, side: 36)
        VStack(alignment: .leading, spacing: 1) {
          Text(game.title).font(.system(size: 14, weight: .semibold))
          Text("\(picked.title) · \(savedAt(picked.date))").font(.system(size: 11)).foregroundStyle(
            .secondary)
        }
        Spacer(minLength: 24)
        Button("Start Fresh") { choose("Boot the disc") }
        Button(picked.isResume ? "Resume" : "Load \(picked.title)") {
          choose("Load \(picked.title)")
        }
        .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
      }
      .buttonStyle(.glass)
      .controlSize(.large)
      ScrollView(.horizontal) {
        HStack(spacing: 10) {
          ForEach(game.states) { s in
            Screenshot(image: s.image, radius: 6)
              .frame(width: 112)
              .padding(3)
              .overlay(
                RoundedRectangle(cornerRadius: 9)
                  .strokeBorder(s.id == selection ? Color.accentColor : .clear, lineWidth: 2)
              )
              .contentShape(.rect)
              .onTapGesture(count: 2) { choose("Load \(s.title)") }
              .simultaneousGesture(TapGesture().onEnded { selection = s.id })
              .help("\(s.title), \(savedAt(s.date))")
              .contextMenu {
                Button("Load \(s.title)") { choose("Load \(s.title)") }
                Divider()
                Button("Delete \(s.title)…", role: .destructive) {
                  choose("Ask: delete \(s.title)")
                }
              }
          }
        }
      }
      .scrollIndicators(.never)
    }
    .padding(18)
    .frame(width: 620)
  }
}

// MARK: - Resume sheet, F: hero + list

/// The hero follows the selection in a native list beside it. The list is a
/// real `List(selection:)`, so it takes the keyboard (arrows), shows the
/// system focus ring and the accent selection, and greys the selection when
/// it loses focus. Return presses the default button, whose title names the
/// selected state; a double click loads a row, ⌫ asks to delete it.
enum HeaderStyle: String, CaseIterable, Identifiable {
  case cover = "Cover + title"
  case detail = "Title + detail"
  case top = "Title on top"
  var id: String { rawValue }
}

enum FooterLead: String, CaseIterable, Identifiable {
  case delete = "Left: Delete", always = "Left: Always resume", none = "Left: nothing"
  var id: String { rawValue }
}

struct SheetF: View {
  let game: Game
  var header = HeaderStyle.cover
  /// Things' Quick Entry: the buttons in a darker strip of their own under
  /// a hairline, the disc named at its leading end as Things names the list.
  var footer = true
  var lead = FooterLead.delete
  let choose: (String) -> Void
  @State private var selection: SavedState.ID? = "resume"
  @FocusState private var listFocused: Bool
  @State private var alwaysResume = false

  private static let hero: CGFloat = 360
  private static let radius: CGFloat = 26

  var body: some View {
    let picked = game.states.first { $0.id == selection } ?? game.states[0]
    VStack(spacing: 0) {
      VStack(spacing: 14) {
        if header == .top {
          Marquee(text: game.title, font: .system(size: 15, weight: .semibold))
            .frame(width: Self.hero + 20 + 270)
        }
        HStack(alignment: .top, spacing: 20) {
          Screenshot(image: picked.image, radius: 12)
            .frame(width: Self.hero)
            .animation(.easeOut(duration: 0.15), value: picked)
          VStack(alignment: .leading, spacing: 12) {
            title
            list(picked)
            if !footer { buttons(picked) }
          }
          .frame(width: 270, height: Self.hero * 3 / 4)
        }
      }
      .padding(20)
      if footer {
        Rectangle().fill(.black.opacity(0.35)).frame(height: 1)
        HStack(spacing: 8) {
          switch lead {
          case .delete:
            // The selected state's delete, visible: never only behind the
            // context menu or ⌫ (HIG Context Menus). Confirmed by an alert.
            // Borderless, as Things' "Inbox": icon and title in red, the
            // HIG's destructive role, and no bezel to compete with the
            // default button.
            Button(role: .destructive) { choose("Ask: delete \(picked.title)") } label: {
              Label("Delete", systemImage: "trash")
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(HoverOutline())
            .foregroundStyle(.red)
            .help("Delete \(picked.title)")
          case .always:
            // The exit sheet's idiom: the checkbox IS the setting.
            Toggle("Always resume without asking", isOn: $alwaysResume)
              .toggleStyle(.checkbox)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          case .none:
            EmptyView()
          }
          Spacer(minLength: 0)
          buttons(picked)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.22))
      }
    }
    .clipShape(.rect(cornerRadius: Self.radius))
    .fixedSize()
    .onAppear { listFocused = true }
  }

  @ViewBuilder private var title: some View {
    switch header {
    case .cover:
      HStack(spacing: 10) {
        Cover(image: game.cover, side: 40)
        Marquee(text: game.title, font: .system(size: 15, weight: .semibold))
      }
    case .detail:
      VStack(alignment: .leading, spacing: 1) {
        Marquee(text: game.title, font: .system(size: 15, weight: .semibold))
        Text("\(game.states.count) saved states").font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    case .top:
      EmptyView()
    }
  }

  private func list(_ picked: SavedState) -> some View {
    List(game.states, selection: $selection) { s in
      HStack(spacing: 10) {
        Screenshot(image: s.image, radius: 3).frame(width: 40)
        VStack(alignment: .leading, spacing: 1) {
          Text(s.title).font(.system(size: 13))
          Text(savedAt(s.date)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 2)
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .alternatingRowBackgrounds(.disabled)
    .background(.black.opacity(0.15), in: .rect(cornerRadius: 8))
    .focused($listFocused)
    .contextMenu(forSelectionType: SavedState.ID.self) { ids in
      if let id = ids.first, let s = game.states.first(where: { $0.id == id }) {
        Button("Load \(s.title)") { choose("Load \(s.title)") }
        Divider()
        Button("Delete \(s.title)…", role: .destructive) { choose("Ask: delete \(s.title)") }
      }
    } primaryAction: { ids in
      if let id = ids.first, let s = game.states.first(where: { $0.id == id }) {
        choose("Load \(s.title)")
      }
    }
    .onDeleteCommand { choose("Ask: delete \(picked.title)") }
  }

  private func buttons(_ picked: SavedState) -> some View {
    HStack(spacing: 8) {
      Button("Start Fresh") { choose("Boot the disc") }
      if !footer { Spacer(minLength: 0) }
      Button(picked.title) {
        choose("Load \(picked.title)")
      }
      .buttonStyle(.glassProminent)
      .keyboardShortcut(.defaultAction)
    }
    .buttonStyle(.glass)
    .controlSize(.large)
  }
}

/// Things' footer button: bare at rest, a hairline capsule with a faint fill
/// under the pointer, a firmer fill while pressed (HIG: every custom button
/// has a press state; on a Mac, hover brightens, never moves).
struct HoverOutline: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverOutlineBody(configuration: configuration)
  }

  private struct HoverOutlineBody: View {
    let configuration: Configuration
    @State private var hover = false

    var body: some View {
      configuration.label
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : hover ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(.white.opacity(hover || configuration.isPressed ? 0.22 : 0), lineWidth: 1))
        .contentShape(Capsule())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
  }
}

// MARK: - Shell

enum Mockup: String, CaseIterable, Identifiable {
  case f = "F · Hero + List"
  case a = "A · Select"
  case b = "B · Cover tile"
  case c = "C · List"
  case d = "D · Hero"
  case e = "E · Bar"
  case now = "Now"
  var id: String { rawValue }
}

enum Place: String, CaseIterable, Identifiable {
  case floating = "Floating (Spotlight)"
  case window = "In the window"
  var id: String { rawValue }
}

let wallpaper = NSImage(
  contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic")

struct Root: View {
  let games = loadGames()
  @State private var mockup =
    Mockup(rawValue: ProcessInfo.processInfo.environment["MOCKUP"] ?? "") ?? .f
  @State private var place = Place.floating
  @State private var gameID = loadGames().first?.id ?? ""
  @State private var last = ""
  @State private var header = HeaderStyle.cover
  @State private var longTitle = false
  @State private var footer = true
  @State private var lead = FooterLead.delete

  var body: some View {
    let base = games.first { $0.id == gameID } ?? games[0]
    let game =
      longTitle
      ? Game(
        id: base.id, title: base.title + ": The Director's Cut Special Edition", cover: base.cover,
        states: base.states)
      : base
    let choose: (String) -> Void = { last = $0 }
    VStack(spacing: 0) {
      HStack {
        Picker("", selection: $mockup) {
          ForEach(Mockup.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize()
        Picker("", selection: $place) {
          ForEach(Place.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).fixedSize()
        Picker("Game", selection: $gameID) {
          ForEach(games) { Text("\($0.title) (\($0.states.count))").tag($0.id) }
        }
        .fixedSize()
        if mockup == .f {
          Picker("", selection: $header) {
            ForEach(HeaderStyle.allCases) { Text($0.rawValue).tag($0) }
          }
          .fixedSize()
        }
        if mockup == .f {
          Toggle("Footer bar", isOn: $footer)
          Picker("", selection: $lead) { ForEach(FooterLead.allCases) { Text($0.rawValue).tag($0) } }
            .fixedSize()
        }
        Toggle("Long title", isOn: $longTitle)
        Spacer()
      }
      .padding(10)
      // Above the stage: whatever spills out of it must not take the bar's clicks.
      .zIndex(1)
      .background(.bar)
      ZStack {
        Group {
          switch mockup {
          case .f: SheetF(game: game, header: header, footer: footer, lead: lead, choose: choose)
          case .a: SheetA(game: game, choose: choose)
          case .b: SheetB(game: game, choose: choose)
          case .c: SheetC(game: game, choose: choose)
          case .d: SheetD(game: game, choose: choose)
          case .e: SheetE(game: game, choose: choose)
          case .now: SheetCurrent(game: game)
          }
        }
        .id("\(mockup)-\(gameID)-\(header)")
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        if !last.isEmpty {
          Text("→ \(last)")
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(16)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // A background, not a ZStack layer: a filling image sizes the
      // stack past the window and pushes the bar off the top.
      .background { backdrop(game).allowsHitTesting(false) }
      .clipped()
      .background(.black)
    }
    .frame(minWidth: 1000, minHeight: 720)
    .preferredColorScheme(.dark)
    .onExitCommand { last = "Escape: close" }
  }

  /// Floating: the desktop, since a Spotlight launch has no window yet.
  /// In the window: the game's black picture under the dimming.
  @ViewBuilder private func backdrop(_ game: Game) -> some View {
    switch place {
    case .floating:
      if let wallpaper {
        Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
      }
    case .window:
      Color.black.overlay(Color.black.opacity(0.35))
    }
  }
}

@main
struct StatesPrototypeApp: App {
  init() { NSApplication.shared.setActivationPolicy(.regular) }
  var body: some Scene {
    WindowGroup("Resume Prompt Mockups") { Root() }
  }
}

// MARK: - Copied from Sources/PS1/Marquee.swift

/// One line that scrolls sideways when it does not fit, as Music's
/// now-playing title does: it rests, scrolls one length plus a gap, and rests
/// again on the same text. A line that fits never moves; under Reduce Motion
/// it truncates instead. A new text starts again from rest.
struct Marquee: View {
  let text: String
  let font: Font

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var textWidth: CGFloat = 0
  @State private var boxWidth: CGFloat = 0
  @State private var start = Date()

  private let gap: CGFloat = 32
  /// Points per second.
  private let speed: CGFloat = 30
  /// Seconds still at the start of each pass.
  private let rest: Double = 2.5
  private let fade: CGFloat = 12

  private var overflows: Bool { textWidth > boxWidth + 0.5 }

  var body: some View {
    // The plain line sets the height and reports the box's width.
    Text(text).font(font).lineLimit(1).hidden()
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        boxWidth = $0
      }
      .overlay(alignment: .leading) {
        if overflows && !reduceMotion {
          scrolling
        } else {
          Text(text).font(font).lineLimit(1).truncationMode(.tail)
        }
      }
      .background(alignment: .leading) {
        Text(text).font(font).fixedSize().hidden()
          .onGeometryChange(for: CGFloat.self) {
            $0.size.width
          } action: {
            textWidth = $0
          }
      }
      .onChange(of: text) { start = Date() }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
  }

  /// At rest only the trailing edge fades, so the first letters read
  /// clean; while it moves, both edges do.
  private var scrolling: some View {
    TimelineView(.animation) { context in
      let x = offset(at: context.date)
      HStack(spacing: gap) {
        Text(text).font(font).fixedSize()
        Text(text).font(font).fixedSize()
      }
      .offset(x: x)
      .frame(width: boxWidth, alignment: .leading)
      .clipped()
      .mask {
        HStack(spacing: 0) {
          LinearGradient(
            colors: [x < 0 ? .clear : .black, .black],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: fade)
          Color.black
          LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: fade)
        }
      }
    }
  }

  private func offset(at date: Date) -> CGFloat {
    let distance = textWidth + gap
    let travel = Double(distance / speed)
    let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: rest + travel)
    guard t > rest else { return 0 }
    return -CGFloat(t - rest) * speed
  }
}
