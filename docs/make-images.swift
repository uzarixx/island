// Draws the README images into docs/images: mockups of the island with made-up content (real
// screenshots would show someone's music, meetings and clipboard).
//
//   SDKROOT=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk | tail -1) \
//     swiftc -O docs/make-images.swift -o /tmp/make-images && /tmp/make-images

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "docs/images")
let green = Color(red: 0.12, green: 0.84, blue: 0.38)
let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)

// MARK: - Pieces

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bottom = min(bottomRadius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius), control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Aurora wallpaper.
struct Wallpaper: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.45, 0.55], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.10, green: 0.08, blue: 0.25), Color(red: 0.16, green: 0.10, blue: 0.36), Color(red: 0.06, green: 0.16, blue: 0.30),
            Color(red: 0.30, green: 0.12, blue: 0.42), Color(red: 0.07, green: 0.30, blue: 0.42), Color(red: 0.05, green: 0.40, blue: 0.40),
            Color(red: 0.55, green: 0.20, blue: 0.45), Color(red: 0.10, green: 0.22, blue: 0.45), Color(red: 0.05, green: 0.12, blue: 0.22),
        ])
    }
}

struct MenuBar: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "applelogo").font(.system(size: 14, weight: .semibold))
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go", "Window"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "magnifyingglass")
            Text("Tue 29 Sep  9:41")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 20)
        .frame(height: 32)
        .background(.black.opacity(0.28))
    }
}

struct Artwork: View {
    let colors: [Color]
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.35), lineWidth: size * 0.04)
                    .frame(width: size * 0.5, height: size * 0.5)
                    .offset(x: size * 0.12, y: size * 0.1)
            )
            .overlay(Circle().fill(.white.opacity(0.18)).frame(width: size * 0.22).offset(x: -size * 0.2, y: -size * 0.18))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .frame(width: size, height: size)
    }
}

struct Equalizer: View {
    var levels: [CGFloat] = [0.45, 0.9, 0.6, 1, 0.5, 0.75]
    var height: CGFloat = 14
    var barWidth: CGFloat = 2.4

    var body: some View {
        LinearGradient(colors: [green, cyan], startPoint: .bottomLeading, endPoint: .topTrailing)
            .mask(
                HStack(spacing: barWidth * 0.7) {
                    ForEach(levels.indices, id: \.self) { index in
                        Capsule().frame(width: barWidth, height: height * levels[index])
                    }
                }
                .frame(height: height)
            )
            .frame(width: CGFloat(levels.count) * barWidth * 1.7, height: height)
    }
}

struct Rail: View {
    let selected: Int
    let icons = ["music.note", "tray.full.fill", "bubble.left.and.bubble.right.fill", "link", "video.fill", "doc.on.clipboard.fill", "note.text"]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(icons.indices, id: \.self) { index in
                Image(systemName: icons[index])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(index == selected ? 1 : 0.45))
                    .frame(width: 40, height: 29)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(index == selected ? 0.14 : 0))
                    )
            }
        }
    }
}

struct Separator: View {
    var body: some View { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
}

/// The open island hanging from the top edge, with a tab's content.
struct Island<Content: View>: View {
    var width: CGFloat = 760
    var height: CGFloat = 262
    let tab: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NotchShape(topRadius: 14, bottomRadius: 28).fill(.black)
            HStack(spacing: 12) {
                Rail(selected: tab)
                Separator()
                content()
            }
            .padding(.top, 38)
            .padding(.horizontal, 26)
            .padding(.bottom, 14)
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 8)
                .padding(.trailing, 34)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
    }
}

// MARK: - Tabs

struct Player: View {
    var body: some View {
        HStack(spacing: 16) {
            Artwork(colors: [Color(red: 1, green: 0.37, blue: 0.56), Color(red: 1, green: 0.7, blue: 0.28), Color(red: 0.55, green: 0.3, blue: 0.95)], size: 96, radius: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Neon Harbor").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text("Coastline Radio").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(green)
                }
                VStack(spacing: 4) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(LinearGradient(colors: [green, cyan], startPoint: .leading, endPoint: .trailing)).frame(width: 70)
                    }
                    .frame(height: 4)
                    HStack {
                        Text("1:42"); Spacer(); Text("-2:21")
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 6)
                HStack(spacing: 22) {
                    Image(systemName: "shuffle").font(.system(size: 12, weight: .semibold)).foregroundStyle(green)
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.system(size: 22))
                    Image(systemName: "forward.fill")
                    Image(systemName: "repeat").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
    }
}

struct Segmented: View {
    let options: [String]
    let selected: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index])
                    .font(.system(size: 12, weight: index == selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(index == selected ? 1 : 0.7))
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(Capsule().fill(.white.opacity(index == selected ? 0.2 : 0)))
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

struct QueueRow: View {
    let title: String
    let artist: String
    let colors: [Color]
    var current = false
    var time = ""

    var body: some View {
        HStack(spacing: 8) {
            Artwork(colors: colors, size: 28, radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(current ? green : .white)
                Text(artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if current {
                Equalizer().scaleEffect(0.8)
            } else {
                Text(time).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(current ? 0.08 : 0)))
    }
}

struct Queue: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Segmented(options: ["Queue", "Playlists", "Search"], selected: 0).frame(maxWidth: .infinity)
            label("Now playing")
            QueueRow(title: "Neon Harbor", artist: "Coastline Radio", colors: [Color(red: 1, green: 0.37, blue: 0.56), Color(red: 1, green: 0.7, blue: 0.28)], current: true)
            label("Next in queue")
            QueueRow(title: "Glass Tides", artist: "Aurora Drive", colors: [.blue, .cyan], time: "3:48")
            QueueRow(title: "Paper Moons", artist: "Low Orbit", colors: [.purple, .pink], time: "4:12")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 6).padding(.top, 2)
    }
}

struct ShelfCard: View {
    let name: String
    let detail: String
    let preview: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            preview.frame(maxWidth: .infinity).frame(height: 64)
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Text(detail).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
        }
        .padding(8)
        .frame(width: 128, height: 116)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }
}

struct Shelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Shelf").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Text("4 files · 18.2 MB").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                pill("square.stack.3d.up.fill", "All 4")
                pill("square.and.arrow.up", "AirDrop")
                pill("doc.zipper", "ZIP")
            }
            HStack(spacing: 8) {
                ShelfCard(name: "Design review.pdf", detail: "PDF · 2.4 MB", preview: AnyView(
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 46, height: 60)
                        .overlay(VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<6) { i in Capsule().fill(.black.opacity(0.18)).frame(width: i == 0 ? 30 : 36, height: 3) }
                        })
                ))
                ShelfCard(name: "Sunset.heic", detail: "HEIC · 3.1 MB", preview: AnyView(
                    RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().fill(.yellow.opacity(0.9)).frame(width: 16).offset(y: 6))
                        .frame(width: 96, height: 62)
                ))
                ShelfCard(name: "Invoices", detail: "Folder", preview: AnyView(
                    Image(systemName: "folder.fill").font(.system(size: 46)).foregroundStyle(.cyan)
                ))
                ShelfCard(name: "Archive.zip", detail: "ZIP · 12.7 MB", preview: AnyView(
                    Image(systemName: "doc.zipper").font(.system(size: 40)).foregroundStyle(.white.opacity(0.8))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func pill(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(title) }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.09)))
    }
}

struct MeetingRow: View {
    let time: String
    let title: String
    let detail: String
    let color: Color
    var joinable = false

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(color).frame(width: 3, height: 26).padding(.trailing, -4)
            Text(time).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white).frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                HStack(spacing: 4) {
                    Image(systemName: joinable ? "alarm" : "bell"); Image(systemName: "calendar"); Text(detail)
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                if joinable { Text("Join") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(joinable ? .black : .white.opacity(0.8))
            .padding(.horizontal, joinable ? 10 : 8)
            .frame(height: 22)
            .background(Capsule().fill(joinable ? green : .white.opacity(0.1)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
    }
}

struct Meetings: View {
    var body: some View {
        VStack(spacing: 4) {
            MeetingRow(time: "10:00", title: "Daily standup", detail: "Work · in 4 min", color: .blue, joinable: true)
            MeetingRow(time: "13:30", title: "Design review", detail: "Work · today", color: .orange)
            MeetingRow(time: "17:00", title: "1:1 with Sam", detail: "Personal · today", color: green)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Collapsed states

struct CollapsedPill<Leading: View, Trailing: View>: View {
    let side: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading().frame(width: side)
            Spacer(minLength: 0)
            trailing().frame(width: side)
        }
        .padding(.horizontal, 6)
        .frame(width: 185 + side * 2 + 12, height: 32)
        .background(NotchShape(topRadius: 6, bottomRadius: 10).fill(.black))
    }
}

// MARK: - Compositions

struct Hero: View {
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                MenuBar()
                Spacer()
            }
            Island(tab: 0) {
                Player()
                Separator()
                Queue()
            }
            VStack(spacing: 12) {
                Image(nsImage: NSImage(contentsOf: root.appending(path: "Resources/AppIcon.png"))!)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Island")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Your MacBook notch, finally useful.")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 318)
        }
        .frame(width: 1280, height: 640)
    }
}

struct Showcase<Content: View>: View {
    let tab: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            Rectangle().fill(.black.opacity(0.28)).frame(height: 32)
            Island(tab: tab, content: content)
        }
        .frame(width: 900, height: 330)
    }
}

struct States: View {
    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 34) {
                state("Now playing") {
                    CollapsedPill(side: 40) {
                        Artwork(colors: [Color(red: 1, green: 0.37, blue: 0.56), Color(red: 1, green: 0.7, blue: 0.28)], size: 18, radius: 4)
                    } trailing: { Equalizer() }
                }
                state("Charging") {
                    CollapsedPill(side: 40) {
                        Image(systemName: "bolt.fill").font(.system(size: 13)).foregroundStyle(green)
                    } trailing: {
                        Text("80%").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(green)
                    }
                }
                state("Recording a voice note") {
                    CollapsedPill(side: 40) {
                        Circle().fill(.red).frame(width: 9)
                    } trailing: {
                        Text("0:12").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.red)
                    }
                }
                state("Color picked") {
                    CollapsedPill(side: 76) {
                        Circle().fill(Color(red: 0.13, green: 0.83, blue: 0.93)).overlay(Circle().stroke(.white.opacity(0.3))).frame(width: 16)
                    } trailing: {
                        Text("#22D3EE").font(.system(size: 11, weight: .semibold).monospaced()).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: 900, height: 420)
    }

    func state<Pill: View>(_ title: String, @ViewBuilder pill: () -> Pill) -> some View {
        HStack(spacing: 28) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 200, alignment: .trailing)
            pill().scaleEffect(1.5).frame(width: 540)
        }
    }
}

// MARK: - Rendering

@MainActor
func render<V: View>(_ view: V, _ name: String) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("couldn't render \(name)") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let url = output.appending(path: name)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
    print("Wrote \(url.path)")
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    render(Hero(), "hero.png")
    render(States(), "states.png")
    render(Showcase(tab: 1) { Shelf() }, "shelf.png")
    render(Showcase(tab: 4) { Meetings() }, "meetings.png")
}
