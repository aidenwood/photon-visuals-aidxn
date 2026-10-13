import SwiftUI

/// The browser's Effects tab: every effect the engine actually implements,
/// grouped by what it does to the picture.
///
/// The list is `model.effectDefinitions`, which the app builds straight from
/// `EffectKind.allCases`. It is not a second hand-written catalogue — one of
/// those existed here and listed effects the shader has never had, so a name
/// in this panel was no evidence the effect could run.
///
/// Category order is the order the engine declares, which is the order an
/// operator looks for things: Colour, Stylise, Distort, Texture, Key.
struct EffectsBrowser: View {
    let model: WorkspaceModel
    let query: String

    private var matches: [EffectDefinition] {
        model.effectDefinitions.filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    /// First-appearance order, so the engine owns the grouping, not this view.
    private var categories: [String] {
        matches.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
    }

    var body: some View {
        if model.effectDefinitions.isEmpty {
            PanelEmptyView(
                symbol: "fx",
                title: "No effects available",
                detail: "The render engine published no effects to this workspace."
            )
        } else if matches.isEmpty {
            PanelEmptyView(
                symbol: "magnifyingglass",
                title: "No matching effects",
                detail: "Try another name or category."
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                        ForEach(categories, id: \.self) { category in
                            Section {
                                ForEach(matches.filter { $0.category == category }) { definition in
                                    row(definition)
                                }
                            } header: {
                                header(category, count: matches.filter { $0.category == category }.count)
                            }
                        }
                    }
                }
                Text(target == nil
                     ? "Drag onto a layer, or select one to double-click."
                     : "Drag onto a layer, or double-click to add to \(targetLabel).")
                    .font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
                    .padding(.horizontal, PhotonTheme.contentInset)
                    .frame(height: PhotonTheme.controlHeight, alignment: .leading)
            }
        }
    }

    private func header(_ category: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(category.uppercased()).font(.system(size: 8, weight: .semibold)).tracking(1)
                .foregroundStyle(PhotonTheme.muted)
            Spacer(minLength: 0)
            Text("\(count)").font(.system(size: 8)).foregroundStyle(PhotonTheme.faint)
        }
        .padding(.horizontal, PhotonTheme.contentInset)
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .background(PhotonTheme.raised)
    }

    private func row(_ definition: EffectDefinition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "fx").font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
            Text(definition.name).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 0)
            // The second control's real name, so the operator knows before
            // adding it whether this effect has one knob or two.
            if let parameter = definition.parameterLabel {
                Text(parameter).font(.system(size: 9)).foregroundStyle(PhotonTheme.faint).lineLimit(1)
            }
        }
        .padding(.horizontal, PhotonTheme.contentInset)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhotonTheme.panel)
        .contentShape(Rectangle())
        .draggable(EffectDragPayload(definitionID: definition.id)) {
            Text(definition.name).font(.system(size: 11))
                .padding(.horizontal, 6).frame(height: 20)
                .background(PhotonTheme.raised)
        }
        .onTapGesture(count: 2) { add(definition) }
        .contextMenu {
            Button(target == nil ? "Add to selection" : "Add to \(targetLabel)") { add(definition) }
                .disabled(target == nil)
        }
        .help(definition.parameterLabel.map { "\(definition.name) · \(definition.category) · Amount, \($0)" }
              ?? "\(definition.name) · \(definition.category) · Amount")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(definition.name), \(definition.category)")
    }

    /// Double-click and the context menu both land in whatever the inspector is
    /// already showing. With nothing selected there is no chain to add to, and
    /// the action is disabled rather than guessing a layer.
    private var target: InspectorEffectScope? { model.currentEffectScope }

    private var targetLabel: String {
        switch target {
        case .composition: "the composition"
        case let .layer(id): model.layers.value?.layers.first { $0.id == id }?.title ?? "the layer"
        case let .clip(id): model.inspector.value?.clip.id == id
            ? (model.inspector.value?.clip.title ?? "the clip") : "the clip"
        case nil: "the selection"
        }
    }

    private func add(_ definition: EffectDefinition) {
        guard let target else { return }
        model.addEffect(definitionID: definition.id, scope: target)
    }
}
