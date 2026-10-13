import SwiftUI

struct BrowserPanel: View {
    let model: WorkspaceModel
    @State private var query = ""
    @State private var scope: BrowserScope = .files

    var body: some View {
        PanelChrome(title: "Browser", panelID: .browser) {
            VStack(spacing: 0) {
                PanelTabs(tabs: BrowserScope.allCases, selection: scope, title: { $0.rawValue }) {
                    scope = $0
                    query = ""
                }
                VStack(spacing: 2) {
                TextField(scope == .effects ? "Search effects" : "Search \(scope.rawValue.lowercased())", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, PhotonTheme.contentInset).frame(height: PhotonTheme.controlHeight)
                    .background(PhotonTheme.background, in: Rectangle())
                switch scope {
                case .files: mediaList
                case .effects: EffectsBrowser(model: model, query: query)
                case .sources:
                    PanelEmptyView(symbol: "waveform.path", title: "No sources connected", detail: "Generators and signal inputs will appear here.")
                case .compositions:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Afterlight").font(.system(size: 12, weight: .medium))
                        Text("Current preview composition").font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                        Spacer()
                    }.padding(PhotonTheme.contentInset).frame(maxWidth: .infinity, alignment: .leading)
                }
                }.frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var mediaList: some View {
        PanelBoundary(model: model.library, retry: { model.reloadLibrary() }) { snapshot in
            let matches = snapshot.clips.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            if matches.isEmpty {
                PanelEmptyView(symbol: "magnifyingglass", title: "No matching media", detail: "Try a different search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { clip in
                            LibraryClipRow(clip: clip, selected: selectedAssetID == clip.id, select: { model.selectClip(clip.id) })
                        }
                    }
                }
            }
        } skeleton: { LibrarySkeleton() }
    }

    private var selectedAssetID: String? {
        model.inspector.value?.clip.assetID ?? model.selectedClipID
    }
}
