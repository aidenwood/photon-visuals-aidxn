extension PreviewWorkspaceProvider {
    public func masterPreview() async throws -> PreviewSnapshot {
        try await pause()
        let visibleID = Self.layerIDs.first(where: {
            !bypassedLayers.contains($0) && (soloLayers.isEmpty || soloLayers.contains($0)) && activeClips[$0] != nil
        }).flatMap { activeClips[$0] }
        let media = try visibleID.map { try clip($0) } ?? MediaClip(
            id: "master-empty", title: "Master output", detail: "Preview", artwork: .empty
        )
        return PreviewSnapshot(clip: media, width: 1920, height: 1080)
    }

    public func layers(deckID: String?) async throws -> LayerStackSnapshot {
        try await pause()
        let deck = deckID ?? "afterlight"
        guard ["afterlight", "empty"].contains(deck) else { throw invalidLiveAction() }
        return LayerStackSnapshot(layers: Self.layerIDs.map { id in
            LayerSnapshot(
                id: id, title: "Layer \(id.split(separator: "-").last ?? "")", opacity: layerOpacities[id] ?? 1,
                bypass: bypassedLayers.contains(id), solo: soloLayers.contains(id),
                activeClipID: activeClips[id],
                // The clip's own fader, carried beside the layer's rather than
                // folded into it: the inspector shows them as two controls, so
                // the snapshot has to keep them as two values.
                clipOpacity: activeClips[id].flatMap { opacities[$0] } ?? 1,
                blendModeID: layerBlendModes[id] ?? BlendModeOption.defaultID,
                slots: (0..<columnCount).map { column in
                    let clip = deck == "afterlight" ? instances[Self.instanceID(layer: id, column: column)] : nil
                    return ClipSlotSnapshot(id: "\(deck)-\(id)-\(column)", column: column, clip: clip)
                }
            )
        }, columns: columnCount, deckID: deck, decks: [
            DeckDescriptor(id: "afterlight", title: deckTitle),
            DeckDescriptor(id: "empty", title: "Empty deck"),
        ])
    }

    public func master() async throws -> MasterSnapshot {
        try await pause()
        return MasterSnapshot(opacity: masterOpacity, blackout: blackedOut)
    }

    func performLive(_ action: WorkspaceAction) throws {
        switch action {
        case let .triggerClip(clipID, layerID):
            try requireLayer(layerID)
            _ = try clip(clipID)
            guard (0..<populatedColumns).contains(where: { Self.instanceID(layer: layerID, column: $0) == clipID }) else {
                throw invalidLiveAction()
            }
            activeClips[layerID] = clipID
            playing = true
        case let .triggerColumn(column, deckID):
            guard (0..<columnCount).contains(column) else { throw invalidLiveAction() }
            guard deckID == nil || ["afterlight", "empty"].contains(deckID ?? "") else { throw invalidLiveAction() }
            guard deckID != "empty", column < populatedColumns else { return }
            for id in Self.layerIDs {
                activeClips[id] = Self.instanceID(layer: id, column: column)
            }
            playing = true
        case let .setLayerOpacity(id, value):
            try requireLayer(id)
            guard value.isFinite, (0...1).contains(value) else { throw invalidLiveAction() }
            layerOpacities[id] = value
        case let .setLayerBlendMode(id, value):
            try requireLayer(id)
            // A mode the renderer never published would be dropped silently at
            // the seam and composite as Over, with the menu still showing the
            // name the operator picked. Refuse it here, visibly, instead.
            guard value == BlendModeOption.defaultID
                    || blendModeOptions.contains(where: { $0.id == value }) else {
                throw PanelIssue(title: "Change rejected", message: "This blend mode is unavailable.")
            }
            layerBlendModes[id] = value
        case let .setLayerBypass(id, value):
            try requireLayer(id)
            if value { bypassedLayers.insert(id) } else { bypassedLayers.remove(id) }
        case let .setLayerSolo(id, value):
            try requireLayer(id)
            if value { soloLayers.insert(id) } else { soloLayers.remove(id) }
        case let .setMasterOpacity(value):
            guard value.isFinite, (0...1).contains(value) else { throw invalidLiveAction() }
            masterOpacity = value
        case let .setBlackout(value):
            blackedOut = value
        default: throw invalidLiveAction()
        }
    }

    private func requireLayer(_ id: String) throws {
        guard Self.layerIDs.contains(id) else { throw invalidLiveAction() }
    }

    private func invalidLiveAction() -> PanelIssue {
        PanelIssue(title: "Change rejected", message: "The requested live control is unavailable.")
    }
}
