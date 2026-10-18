import SwiftUI

/// A confirm shown as a window sheet. Same shape as `confirmationDialog`,
/// which on recent macOS anchors to the bottom of the window — under the Dock, with its buttons cut off.
extension View {
    func confirmSheet<T, A: View, M: View>(_ title: String, isPresented: Binding<Bool>, presenting data: T?,
                                           @ViewBuilder actions: @escaping (T) -> A,
                                           @ViewBuilder message: @escaping (T) -> M) -> some View {
        // A window sheet: placed by the window, not by this view — screens are taller than the window.
        sheet(isPresented: Binding(get: { isPresented.wrappedValue && data != nil }, set: { isPresented.wrappedValue = $0 })) {
            if let data {
                ConfirmCard(title: title, isPresented: isPresented, actions: { actions(data) }, message: { message(data) })
            }
        }
    }

    func confirmSheet<A: View, M: View>(_ title: String, isPresented: Binding<Bool>,
                                        @ViewBuilder actions: @escaping () -> A,
                                        @ViewBuilder message: @escaping () -> M) -> some View {
        sheet(isPresented: isPresented) {
            ConfirmCard(title: title, isPresented: isPresented, actions: actions, message: message)
        }
    }

    func confirmSheet<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        confirmSheet(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
}

private struct ConfirmCard<A: View, M: View>: View {
    var title: String
    @Binding var isPresented: Bool
    @ViewBuilder var actions: () -> A
    @ViewBuilder var message: () -> M

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                message().font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    actions()
                }
                // Each button runs its own action, then closes the card.
                .buttonStyle(ConfirmButtonStyle(dismiss: { isPresented = false }))
                .padding(.top, 4)
            }
            .padding(22)
            .frame(width: 420)
            .background(Theme.surfaceRaised)
            .onExitCommand { isPresented = false }
    }
}

/// Cancel is quiet and comes first; a destructive choice is red; anything else is the primary action.
/// A primitive style so the click runs the button's action *before* the card goes away.
private struct ConfirmButtonStyle: PrimitiveButtonStyle {
    var dismiss: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        let role = configuration.role
        let fill: Color = role == .destructive ? Theme.critical : role == .cancel ? Theme.fill(0.08) : Theme.accent
        return Button {
            configuration.trigger()
            dismiss()
        } label: {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(role == .cancel ? Theme.textPrimary : role == .destructive ? .white : Theme.minimal ? Theme.onAccent : .black)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
