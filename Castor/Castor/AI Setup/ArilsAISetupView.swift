import SwiftUI

struct ArilsAISetupView: View {
    let palette: CastorPalette
    let openRigging: () -> Void

    @State private var step: Step = .referenceSet
    @State private var draft = ArilsAISettingsStore.current

    private var memoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Setting with AI", systemImage: "wand.and.stars")
                        .font(.title2.weight(.semibold))
                    Text("Castor prepares an Arils workflow, but every AI alignment still needs your approval.")
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Text("\(step.number) / 4")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    assistantBubble(step.question)
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            HStack {
                if step != .referenceSet {
                    Button("Back") { step.goBack() }
                }
                Spacer()
                Button("Start over") {
                    draft = ArilsAISettingsStore.current
                    step = .referenceSet
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: 720, maxHeight: 560)
        .castorGlassSurface(palette: palette, cornerRadius: 24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .referenceSet:
            choice(
                title: "One front image",
                detail: "Build Standard Arils first. You can add a Quality view later.",
                icon: "person.crop.rectangle"
            ) {
                draft.referenceSet = .frontOnly
                step = .provider
            }
            choice(
                title: "Front + three-quarter image",
                detail: "Prepare the same character around 60° left or right for the existing Quality path.",
                icon: "rectangle.on.rectangle"
            ) {
                draft.referenceSet = .frontAndThreeQuarter
                step = .provider
            }

        case .provider:
            Text("The image leaves this Mac only when you choose an external provider and confirm the send dialog.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            ForEach(ArilsAIProvider.allCases) { provider in
                choice(
                    title: provider.label,
                    detail: providerDescription(provider),
                    icon: providerIcon(provider)
                ) {
                    draft.provider = provider
                    step = .underpaint
                }
            }

        case .underpaint:
            Label("Detected memory: about \(memoryGB) GB", systemImage: "memorychip")
                .font(.callout.weight(.medium))
            Text("This is physical RAM, not currently free memory. Castor does not benchmark the LaMa model on this Mac, so the final choice remains yours.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            Text("LaMa does not decide face positions. It only improves hidden backing regions after you approve the alignment.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            choice(
                title: "Use LaMa underpaint",
                detail: "Requires the optional localhost LaMa helper. A failure still falls back to Arils standard repair.",
                icon: "paintbrush.pointed"
            ) {
                draft.useLaMa = true
                step = .review
            }
            choice(
                title: "Keep LaMa off",
                detail: "Use deterministic Arils repair with no additional model in memory.",
                icon: "cpu"
            ) {
                draft.useLaMa = false
                step = .review
            }

        case .review:
            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Images", draft.referenceSet.label)
                summaryRow("Alignment reviewer", draft.provider.label)
                summaryRow("Hidden-region repair", draft.useLaMa ? "LaMa with safe fallback" : "Standard Arils")
            }
            .padding(16)
            .background(palette.readoutBackground.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))

            Text("Next: import the front image in Rigging, start Arils, then choose “Suggest with AI” in the face-alignment sheet. The proposal stays temporary until you press the approval-and-build button.")
                .font(.callout)

            Button {
                ArilsAISettingsStore.current = draft
                LaMaInpaintingSettingsStore.isEnabled = draft.useLaMa
                openRigging()
            } label: {
                Label("Save setup and open Rigging", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(palette.accent)
                .frame(width: 28, height: 28)
                .background(palette.accent.opacity(0.12), in: Circle())
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
        }
        .padding(14)
        .background(palette.readoutBackground.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
    }

    private func choice(
        title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(palette.readoutBackground.opacity(0.76), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.readoutBorder, lineWidth: 1)
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.secondaryText)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func providerDescription(_ provider: ArilsAIProvider) -> String {
        switch provider {
        case .ollama:
            "Local image review using the selected vision-capable Ollama model and this Mac's RAM."
        case .codex:
            "Uses a small local bridge packet; the configured Codex account may process the image externally."
        case .claudeCode:
            "Uses a small local bridge packet; the configured Claude account may process the image externally."
        }
    }

    private func providerIcon(_ provider: ArilsAIProvider) -> String {
        switch provider {
        case .ollama: "desktopcomputer"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeCode: "terminal"
        }
    }

    private enum Step: Int {
        case referenceSet
        case provider
        case underpaint
        case review

        var number: Int { rawValue + 1 }

        var question: String {
            switch self {
            case .referenceSet:
                "How many views do you want to prepare? The current Quality path can use a front image plus a three-quarter reference."
            case .provider:
                "Who should visually review face-marker alignment? Manual adjustment remains available whichever you choose."
            case .underpaint:
                "Should Arils try LaMa when it builds hidden regions behind the moving head?"
            case .review:
                "Here is the setup I will use. Nothing is sent and no rig is changed until you explicitly request and approve an AI proposal."
            }
        }

        mutating func goBack() {
            self = Step(rawValue: max(0, rawValue - 1)) ?? .referenceSet
        }
    }
}
