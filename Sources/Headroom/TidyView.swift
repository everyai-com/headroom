import SwiftUI
import HeadroomCore

/// The plan before a tidy: which folder each loose file goes into, what stays put and why.
/// Nothing moves until you press Tidy, and Put Back (or the toast's Undo) moves it all home.
struct TidySheet: View {
    @EnvironmentObject var library: LibraryModel
    var plan: AutoRules.TidyPlan
    @Environment(\.dismiss) private var dismiss

    var name: String { FileManager.default.displayName(atPath: plan.folder.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tidy \(name)?").font(.system(size: 17, weight: .semibold))
                Text("\(plan.moves.count) loose \(plan.moves.count == 1 ? "file goes" : "files go") into folders by kind, inside \(name)."
                     + (plan.folders > 0 ? " Your \(plan.folders) \(plan.folders == 1 ? "folder stays" : "folders stay") as \(plan.folders == 1 ? "it is" : "they are")." : "")
                     + " Nothing is deleted, and Undo or Put Back in Activity moves everything home.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Scrolling {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.groups, id: \.name) { g in group(g.name, g.moves) }
                    if !plan.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Left where \(plan.skipped.count == 1 ? "it is" : "they are")").font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                            ForEach(plan.skipped.prefix(6), id: \.self) { Text($0).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                            if plan.skipped.count > 6 { Text("and \(plan.skipped.count - 6) more").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary) }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxHeight: 340)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { library.tidyPlan = nil; dismiss() }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Tidy \(plan.moves.count) \(plan.moves.count == 1 ? "File" : "Files")") {
                    let p = plan
                    library.tidyPlan = nil
                    dismiss()
                    Task { await library.tidy(p) }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.surfaceRaised)
    }

    func group(_ folder: String, _ moves: [AutoRules.Move]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(folder)).font(.system(size: 12, weight: .bold)).foregroundStyle(tint(folder))
                .frame(width: 28, height: 28).background(Circle().fill(tint(folder).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder).font(.system(size: 13, weight: .semibold))
                    Text("\(moves.count)").font(Theme.number(11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.fill(0.07)))
                }
                Text(moves.prefix(3).map(\.from.lastPathComponent).joined(separator: ", ") + (moves.count > 3 ? ", …" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
    }

    var kinds: [String: FileKind] {
        ["Images": .image, "Screenshots": .image, "Videos": .video, "Music": .audio, "Documents": .document, "PDFs": .document,
         "Archives": .archive, "Installers": .archive, "Apps": .app]
    }

    func tint(_ folder: String) -> Color { kinds[folder].map(Theme.tint(for:)) ?? Theme.textSecondary }

    func symbol(_ folder: String) -> String {
        switch folder {
        case "Screenshots": "camera.viewfinder"
        case "Installers": "shippingbox"
        case "PDFs": "doc.richtext"
        default: kinds[folder]?.symbol ?? "folder"
        }
    }
}
