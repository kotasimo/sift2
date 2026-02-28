//
//  ContentView.swift
//  sift
//
//  Created by Apex_Ventura on 2026/02/25.
//


import SwiftUI
import Foundation
import Combine
import UIKit

// =====================
// Models
// =====================

struct Card: Identifiable, Codable, Equatable {
    var id = UUID()
    var front: String
    var back: String
    // normalized position (0...1)
    var px: Double
    var py: Double
}

struct Box: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
    var children: [Box] = []
}

// =====================
// App State
// =====================

@MainActor
final class AppState: ObservableObject {
    @Published var root: Box
    // v2: because Card gained px/py and old JSON won't decode
    private let storageKey = "sift_root_v2"
    private var saveWorkItem: DispatchWorkItem?
    
    init() {
        if let loaded = Self.load(key: storageKey) {
            self.root = loaded
            return
        }
        self.root = Self.defaultRoot()
        scheduleSave()
    }
    
    // 連続操作でも重くならないようにちょい遅延保存
    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [root] in
            Self.save(root, key: self.storageKey)
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    
    // MARK: - Persistence (UserDefaults + JSON)
    
    private static func save(_ box: Box, key: String) {
        do {
            let data = try JSONEncoder().encode(box)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            print("Save failed:", error)
        }
    }
    
    private static func load(key: String) -> Box? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Box.self, from: data)
        } catch {
            print("Load failed:", error)
            return nil
        }
    }
    
    // MARK: - Defaults / Reset
    
    static func defaultRoot() -> Box {
        // Root has two child boxes A/B (like your current app)
        let boxA = Box(name: "A")
        let boxB = Box(name: "B")
        let boxC = Box(name: "C")
        let boxD = Box(name: "D")
        
        return Box(
            name: "Workspace",
            cards: [
                Card(front: "Tap to flip", back: "裏面だよ", px: 0.52, py: 0.22),
                Card(front: "Drag to sort", back: "Flick hard to send", px: 0.48, py: 0.36),
                Card(front: "Add cards below", back: "Back can be empty", px: 0.55, py: 0.50)
            ],
            children: [boxA, boxB, boxC, boxD]
        )
    }
    
    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        root = Self.defaultRoot()
        scheduleSave()
    }
}

// =====================
// ContentView
// =====================

struct ContentView: View {
    @StateObject private var state = AppState()
    @State private var path = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $path) {
            WorkspaceView(currentIndex: nil, state: state, path: $path)
                .navigationDestination(for: Int.self) { i in
                    WorkspaceView(currentIndex: i, state: state, path: $path)
                }
        }
    }
}

// =====================
// WorkspaceView (reused recursively)
// =====================

struct WorkspaceView: View {
    let currentIndex: Int?                // [] = root, [0] = A, [1] = B, [1,0] = nested...
    
    @ObservedObject var state: AppState
    @Binding var path: NavigationPath
    
    // input (always at bottom)
    @State private var draftText: String = ""
    
    // dragging
    @State private var draggingID: UUID? = nil
    @State private var hoverTarget: Int? = nil
    @State private var dragBase: (px: Double, py: Double)? = nil
    @State private var showingRename = false
    @State private var draftNames: [String] = ["A", "B", "C", "D"]
    // --- camera (workspace) ---
    @State private var canvasPan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var canvasScale: CGFloat = 1.0
    @State private var scaleStart: CGFloat = 1.0
    @State private var flipped: Set<UUID> = []
    
    @FocusState private var inputFocused: Bool
    
    enum EdgeSide { case top, bottom, left, right }
    
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    
    var body: some View {
        let box = bindingBox()
        
        ZStack {
            Color.yellow.opacity(0.5).ignoresSafeArea()
            
            GeometryReader { geo in
                let size = geo.size
                
                ZStack {
                    // ===== (A) 動くレイヤー：巨大背景 + カード =====
                    ZStack {
                        Rectangle()
                            .fill(Color(red: 0.94, green: 0.96, blue: 0.98))
                            .frame(width: size.width * 4, height: size.height * 4)
                            .position(x: size.width / 2, y: size.height / 2)
                            .contentShape(Rectangle())
                            .gesture(panGesture())
                            .simultaneousGesture(zoomGesture())
                        
                        cardBoard(box: bindingBox(), size: size)
                    }
                    .scaleEffect(canvasScale)
                    .offset(canvasPan)
                    
                    // ===== (C) 固定HUD：箱 + 入力 =====
                    cornerLabels(box: bindingBox(), size: size)
                    inputBar(box: bindingBox())
                }
                .navigationTitle(box.wrappedValue.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            state.resetToDefaults()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .accessibilityLabel("Reset")
                    }
                    
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if state.root.children.count >= 4 {
                                draftNames = (0..<4).map {state.root.children[$0].name}
                            }
                            showingRename = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("Rename boxes")
                    }
                }
                .toolbarBackground(headerColor(), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.light, for: .navigationBar)
            }
        }
        .sheet(isPresented: $showingRename) {
            RenameBoxesSheet(
                names: $draftNames,
                onSave: {
                    // 空白は弾く（or 元に戻す）
                    for i in 0..<min(4, state.root.children.count) {
                        let trimmed = draftNames[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            state.root.children[i].name = trimmed
                        }
                    }
                    state.scheduleSave()
                    showingRename = false
                },
                onCancel: {
                    showingRename = false
                }
            )
        }
        .onAppear {
            panStart = canvasPan
            scaleStart = canvasScale
        }
    }
    
    // MARK: - Desk (cards)
    
    private func cardBoard(box: Binding<Box>, size: CGSize) -> some View {
        ZStack {
            ForEach(Array(box.wrappedValue.cards.indices), id: \.self) { i in
                let card = box.wrappedValue.cards[i]
                let x = CGFloat(card.px) * size.width
                let y = CGFloat(card.py) * size.height
                let tint = tintForCurrentBox()
                
                cardView(front: card.front, back: card.back, isDragging: draggingID == card.id, isFlipped: flipped.contains(card.id), tint: tint)
                    .zIndex(draggingID == card.id ? 10 : 0)
                    .position(x: x, y: y)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // どのカードを掴んでるか
                                if draggingID != card.id {
                                    draggingID = card.id
                                    dragBase = (px: card.px, py: card.py)
                                }
                                // target 判定は translation のままでOK
                                hoverTarget = targetIndex(from: value.translation)
                                
                                // ここが核心：px/py を直接更新（アニメ無し）
                                guard let base = dragBase else { return }
                                
                                let dx = value.translation.width / canvasScale
                                let dy = value.translation.height / canvasScale
                                
                                let newX = CGFloat(base.px) * size.width + dx
                                let newY = CGFloat(base.py) * size.height + dy
                                
                                let clampedX = min(max(newX, 30), size.width - 30)
                                let clampedY = min(max(newY, 30), size.height - 200)
                                
                                var b = box.wrappedValue
                                guard let idx = b.cards.firstIndex(where: { $0.id == card.id }) else { return }
                                
                                var tx = Transaction()
                                tx.animation = nil
                                withTransaction(tx) {
                                    b.cards[idx].px = Double(clampedX / size.width)
                                    b.cards[idx].py = Double(clampedY / size.height)
                                    box.wrappedValue = b
                                }
                            }
                            .onEnded { value in
                                onDrop(cardID: card.id, translation: value.translation, predicted: value.predictedEndTranslation, box: box, size: size)
                                draggingID = nil
                                dragBase = nil
                                hoverTarget = nil
                            }
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            // ✅ タップで裏返すだけ
                            if flipped.contains(card.id) { flipped.remove(card.id) }
                            else { flipped.insert(card.id) }
                            inputFocused = false
                        }
                    )
            }
        }
        .animation(nil, value: draggingID)
    }
    
    private func cardView(
        front: String,
        back: String,
        isDragging: Bool,
        isFlipped: Bool,
        tint: Color?
    ) -> some View {
        let t = tint
        let base: Color = {
            guard let t = t else { return .white }
            return t.opacity(0.25)
        }()
        
        return ZStack {
            // ===== 表 =====
            RoundedRectangle(cornerRadius: 20)
                .fill(base)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke((t ?? .clear).opacity(t == nil ? 0.0 : 0.45), lineWidth: 2)
                )
                .overlay(
                    Text(front)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                )
                .opacity(isFlipped ? 0 : 1)
            
            // ===== 裏 =====
            RoundedRectangle(cornerRadius: 20)
                .fill(base.opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke((t ?? .clear).opacity(t == nil ? 0.0 : 0.35), lineWidth: 2)
                )
                .overlay(
                    Text(back.isEmpty ? " " : back) // 空なら何も出さない（見た目用）
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                )
                .opacity(isFlipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: 230, height: 125)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isFlipped)
    }
    
    private func targetIndex(from t: CGSize, threshold: CGFloat = 120) -> Int? {
        let dx = t.width
        let dy = t.height
        let ax = abs(dx)
        let ay = abs(dy)
        // どっちも弱いなら確定しない
        guard ax >= threshold || ay >= threshold else { return nil }
        
        // 斜めは「強い軸」だけ採用（= どっちか）
        if ax >= ay {
            return dx < 0 ? 0 : 1   // 左 / 右
        } else {
            return dy < 0 ? 2 : 3   // 上 / 下（上はマイナス）
        }
    }
    
    
    // MARK: - Input bar
    
    private func inputBar(box: Binding<Box>) -> some View {
        HStack(spacing: 12) {
            TextField("テキスト入力", text: $draftText, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            
                .toolbar{
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("done") {inputFocused = false}
                    }
                }
            
            Button {
                addCard(box: box)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add card")
        }
        .zIndex(1000)
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    
    private func addCard(box: Binding<Box>) {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var b = box.wrappedValue
        
        let px = min(max(0.5 + Double.random(in: -0.14...0.14), 0.08), 0.92)
        let py = min(max(0.35 + Double.random(in: -0.10...0.10), 0.08), 0.80)
        
        b.cards.append(Card(front: trimmed, back: "", px: px, py: py))
        box.wrappedValue = b
        
        draftText = ""
        haptic.impactOccurred()
    }
    
    // MARK: - Binding Box by Path
    
    private func bindingBox() -> Binding<Box> {
        Binding(
            get: {
                if let i = currentIndex, state.root.children.indices.contains(i) {
                    return state.root.children[i]
                } else {
                    return state.root
                }
            },
            set: { newValue in
                if let i = currentIndex, state.root.children.indices.contains(i) {
                    state.root.children[i] = newValue
                } else {
                    state.root = newValue
                }
                state.scheduleSave()
            }
        )
    }
    
    
    
    private func isFlick(actual: CGSize, predicted: CGSize, minBoost: CGFloat = 140) -> Bool {
        let dx = abs(predicted.width - actual.width)
        let dy = abs(predicted.height - actual.height)
        return max(dx, dy) > minBoost
    }
    
    private func onDrop(cardID: UUID, translation: CGSize, predicted: CGSize, box: Binding<Box>, size: CGSize) {
        let b = box.wrappedValue
        guard let idx = b.cards.firstIndex(where: { $0.id == cardID }) else { return }
        
        // フリック判定（勢いがある時だけ吸い込む）
        let boostX = abs(predicted.width - translation.width)
        let boostY = abs(predicted.height - translation.height)
        let isFlick = max(boostX, boostY) > 260  // ←吸われすぎるなら増やす（例: 320）
        
        guard state.root.children.count >= 4, isFlick, let tIndex = targetIndex(from: predicted) else {
            return
        }
        
        // 画面外へ飛ばす（吸い込み）
        let out = offscreenNormalizedPosition(from: b.cards[idx], target: tIndex)
        
        withAnimation(.easeIn(duration: 0.20)) {
            var b1 = box.wrappedValue
            guard let i1 = b1.cards.firstIndex(where: { $0.id == cardID }) else { return }
            b1.cards[i1].px = out.px
            b1.cards[i1].py = out.py
            box.wrappedValue = b1
        }
        
        haptic.impactOccurred()
        
        // アニメ後に本当に移動
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            // 1) 今見てるboxから抜く
            var from = box.wrappedValue
            guard let i2 = from.cards.firstIndex(where: { $0.id == cardID }) else { return }
            var moved = from.cards.remove(at: i2)
            box.wrappedValue = from   // 画面側に反映（ここで消える）
            
            // 2) rootのターゲット箱へ入れる
            moved.px = Double.random(in: 0.18...0.80)
            moved.py = Double.random(in: 0.20...0.70)
            state.root.children[tIndex].cards.append(moved)
            state.scheduleSave()            }
    }
    
    private func offscreenNormalizedPosition(from card: Card, target: Int) -> (px: Double, py: Double) {
        // target: 0=左 1=右 2=上 3=下
        switch target {
        case 0: return (px: -0.25, py: card.py)   // left
        case 1: return (px:  1.25, py: card.py)   // right
        case 2: return (px: card.px, py: -0.25)   // up
        default: return (px: card.px, py:  1.25)  // down
        }
    }
    
    private func cornerLabel(text: String, active: Bool, side: EdgeSide, index: Int) -> some View {
        
        let isVertical = (side == .left || side == .right)
        let c = boxColor(forIndex: index)
        let lift: CGFloat = active ? -6 : 0
        
        return ZStack {
            // ドロップ領域
            RoundedRectangle(cornerRadius: 28)
                .fill(c.opacity(active ? 0.50 : 0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(c.opacity(active ? 0.85 : 1.0), lineWidth: active ? 3 : 1.5)
                )
                .offset(y: lift)
                .shadow(color: c.opacity(active ? 0.7 : 0.25),
                        radius: active ? 16 : 8, x: 0, y: active ? 14 : 4)
                .shadow(color: Color.white.opacity(active ? 0.6 : 0.0), radius: active ? 18 : 0)
                .scaleEffect(active ? 1.035 : 1.0)
                .animation(.spring(response: 0.28, dampingFraction: 0.78), value: active)
            
            // 名前
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.black.opacity(0.95))
                .rotationEffect(.degrees(side == .left ? 90 :
                                            side == .right ? -90 : 0))
                .padding(16)
        }
        .frame(
            width: isVertical ? 80 : 420,
            height: isVertical ? 420 : 80
        )
    }
    
    private func openBoxReplace(_ i: Int) {
        path = NavigationPath()   // ←ここで“積み重なり”を消す
        path.append(i)            // ←開きたい箱だけ入れる（置き換え）
    }
    
    private func cornerLabels(box: Binding<Box>, size: CGSize) -> some View {
        ZStack {
            if state.root.children.count >= 4 {
                // 上
                Button {
                    openBoxReplace(2)
                } label: {
                    cornerLabel(text: state.root.children[2].name, active: hoverTarget == 2, side: .top, index: 2)
                }
                .buttonStyle(.plain)
                .position(x: size.width / 2, y: 55)
                
                // 下
                Button {
                    openBoxReplace(3)
                } label: {
                    cornerLabel(text: state.root.children[3].name, active: hoverTarget == 3, side: .bottom, index: 3)
                }
                .buttonStyle(.plain)
                .position(x: size.width / 2, y: size.height - 110)
                
                // 左
                Button {
                    openBoxReplace(0)
                } label: {
                    cornerLabel(text: state.root.children[0].name, active: hoverTarget == 0, side: .right, index: 0)
                }
                .buttonStyle(.plain)
                .position(x: 70, y: size.height / 2)
                
                // 右
                Button {
                    openBoxReplace(1)
                } label: {
                    cornerLabel(text: state.root.children[1].name, active: hoverTarget == 1, side: .left, index: 1)
                }
                .buttonStyle(.plain)
                .position(x: size.width - 70, y: size.height / 2)
            }
        }
    }
    
    private func boxColor(forIndex i: Int) -> Color {
        switch i {
        case 0:   return .cyan      // A
        case 1:  return .orange    // B
        case 2:    return .purple    // C
        case 3: return .green     // D
        default: return .gray
        }
    }
    
    private func tintForCurrentBox() -> Color? {
        guard let i = currentIndex else { return nil } // rootは無色
        switch i {
        case 0: return .cyan
        case 1: return .orange
        case 2: return .purple
        case 3: return .green
        default: return nil
        }
    }
    
    private func headerColor() -> Color {
        guard let i = currentIndex else {
            return Color.blue.opacity(0.25)   // root は薄い青
        }
        return boxColor(forIndex: i).opacity(0.85)
    }
    
    private func panGesture() -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard draggingID == nil else { return } // カード掴んでる時はパンしない
                canvasPan = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                panStart = canvasPan
            }
    }
    
    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { m in
                // 拡大方向（m > 1）は無視する
                guard m <= 1.0 else {
                    canvasScale = min(canvasScale, 1.0)
                    return
                }
                let next = scaleStart * m
                canvasScale = max(next, 0.4)   // 下限だけ効かせる（上限は guard で殺してる）
            }
            .onEnded { _ in
                // 念のため 1.0 を超えない状態で確定
                canvasScale = min(canvasScale, 1.0)
                scaleStart = canvasScale
            }
    }
}

struct RenameBoxesSheet: View {
    @Binding var names: [String]
    let onSave: () -> Void
    let onCancel: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                ForEach(0..<4, id: \.self) { i in
                    TextField("Name", text: Binding(
                        get: { names.count > i ? names[i] : "" },
                        set: { newValue in
                            if names.count <= i {
                                names += Array(repeating: "", count: i - names.count + 1)
                            }
                            names[i] = newValue
                        }
                    ))
                }
            }
            .navigationTitle("Rename boxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                }
            }
        }
    }
}

struct CloudPocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        
        path.addEllipse(in: CGRect(x: w*0.05, y: h*0.35, width: w*0.45, height: h*0.55))
        path.addEllipse(in: CGRect(x: w*0.35, y: h*0.15, width: w*0.45, height: h*0.65))
        path.addEllipse(in: CGRect(x: w*0.60, y: h*0.40, width: w*0.35, height: h*0.50))
        
        return path
    }
}

// =====================
// Preview
// =====================

#Preview {
    ContentView()
}


