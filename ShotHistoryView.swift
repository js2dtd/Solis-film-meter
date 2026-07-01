//
//  ShotHistoryView.swift
//  Solis film meter
//

// MARK: - 役割: 保存した撮影記録の一覧と削除画面
// MARK: - 目次
// 1. ShotHistoryView本体と撮影記録一覧
// 2. 空状態、ツールバー、削除確認
// 3. 個別/一括削除と写真ライブラリ連携削除
// 4. ShotDetailViewのコラージュ画像表示
// 5. ShotRecordRowのサムネイル/メモ表示

import SwiftUI
import Photos

struct ShotHistoryView: View {
    @ObservedObject var store: ShotRecordStore
    var refined: Bool = false
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecord: ShotRecord?
    @State private var pendingDeleteRequest: PendingDeleteRequest?
    @State private var deletionStatusMessage: DeletionStatusMessage?
    @State private var isDeleting = false

    private var isDeleteChoicePresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteRequest != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRequest = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                (refined ? Color.refinedBackground : Color.meterBackground).ignoresSafeArea()

                if store.records.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(refined ? .refinedTextSoft.opacity(0.35) : .meterSecondary.opacity(0.3))
                        Text("記録なし")
                            .font(.meterLabel(14))
                            .foregroundColor(refined ? .refinedTextSoft.opacity(0.45) : .meterSecondary.opacity(0.4))
                    }
                } else {
                    List {
                        ForEach(store.records) { record in
                            ShotRecordRow(record: record, refined: refined)
                                .listRowBackground(refined ? Color.refinedSurface : Color.meterCardBg)
                                .listRowSeparatorTint(refined ? Color.refinedStroke.opacity(0.6) : Color.meterSecondary.opacity(0.2))
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecord = record }
                        }
                        .onDelete(perform: requestDelete)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .disabled(isDeleting)
                }

                if isDeleting {
                    deletingOverlay
                }
            }
            .navigationTitle("撮影記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.records.isEmpty {
                        Button("全削除") { requestDeleteAll() }
                            .foregroundColor(.meterRed)
                            .font(.meterLabel(13))
                            .disabled(isDeleting)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { finishDismissal() }
                        .foregroundColor(refined ? .cyan : .meterAccent)
                        .font(.meterLabel(13))
                        .disabled(isDeleting)
                }
            }
            .toolbarBackground(refined ? Color.refinedSurface : Color.meterCardBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(refined ? .dark : .light, for: .navigationBar)
            .alert(
                pendingDeleteRequest?.title ?? "削除方法を選んでください",
                isPresented: isDeleteChoicePresented,
                presenting: pendingDeleteRequest
            ) { request in
                Button("アプリ内のみ削除", role: .destructive) {
                    performDeletion(request, deletePhotoLibraryAssets: false)
                }
                if request.hasPhotoLibraryLinkedRecords {
                    Button("写真アプリの画像も削除", role: .destructive) {
                        performDeletion(request, deletePhotoLibraryAssets: true)
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .alert(item: $deletionStatusMessage) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .fullScreenCover(item: $selectedRecord) { record in
                ShotDetailView(record: record)
            }
        }
        .preferredColorScheme(refined ? .dark : .light)
    }

    private func finishDismissal() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var deletingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(refined ? .cyan : .meterAccent)
            Text("削除中...")
                .font(.meterLabel(12))
                .foregroundColor(refined ? .refinedText : .meterSecondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(refined ? Color.refinedSurface.opacity(0.96) : Color.meterCardBg.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(refined ? Color.refinedStroke : Color.black.opacity(0.08), lineWidth: 0.6)
        )
    }

    private func requestDelete(at offsets: IndexSet) {
        guard !isDeleting else { return }
        let recordsToDelete = offsets.map { store.records[$0] }
        guard !recordsToDelete.isEmpty else { return }
        pendingDeleteRequest = PendingDeleteRequest(records: recordsToDelete, isClearAll: false)
    }

    private func requestDeleteAll() {
        guard !isDeleting, !store.records.isEmpty else { return }
        pendingDeleteRequest = PendingDeleteRequest(records: store.records, isClearAll: true)
    }

    private func performDeletion(_ request: PendingDeleteRequest, deletePhotoLibraryAssets: Bool) {
        pendingDeleteRequest = nil
        isDeleting = true

        guard deletePhotoLibraryAssets else {
            store.delete(records: request.records)
            isDeleting = false
            return
        }

        let linkedLocalIdentifiers = Array(Set(request.records.compactMap(\.photoAssetLocalIdentifier)))
        let containsUnlinkedRecords = request.records.contains { $0.photoAssetLocalIdentifier == nil }

        guard !linkedLocalIdentifiers.isEmpty else {
            store.delete(records: request.records)
            isDeleting = false
            deletionStatusMessage = DeletionStatusMessage(
                title: "写真アプリ内の削除対象がありません",
                message: "この撮影記録に紐づく写真アプリ内の画像が見つからなかったため、アプリ内の記録のみ削除しました。"
            )
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    store.delete(records: request.records)
                    isDeleting = false
                    deletionStatusMessage = DeletionStatusMessage(
                        title: "写真アプリの権限がありません",
                        message: "アプリ内の撮影記録は削除しましたが、写真アプリ内の画像は削除していません。設定で写真アクセスを許可すると削除できます。"
                    )
                }
                return
            }

            let assets = PHAsset.fetchAssets(withLocalIdentifiers: linkedLocalIdentifiers, options: nil)
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    store.delete(records: request.records)
                    isDeleting = false

                    if !success {
                        deletionStatusMessage = DeletionStatusMessage(
                            title: "一部削除できませんでした",
                            message: "アプリ内の撮影記録は削除しましたが、写真アプリ内の画像削除は完了しませんでした。"
                        )
                    } else if containsUnlinkedRecords {
                        deletionStatusMessage = DeletionStatusMessage(
                            title: "一部の写真は残っています",
                            message: "アプリ内の撮影記録は削除しましたが、古い記録など写真アプリと連携していない画像はそのまま残っています。"
                        )
                    }
                }
            }
        }
    }
}

private struct PendingDeleteRequest {
    let records: [ShotRecord]
    let isClearAll: Bool

    var hasPhotoLibraryLinkedRecords: Bool {
        records.contains { $0.photoAssetLocalIdentifier != nil }
    }

    var title: String {
        if isClearAll {
            return "全削除の方法を選んでください"
        }
        return records.count == 1 ? "削除方法を選んでください" : "\(records.count)件の削除方法を選んでください"
    }

    var message: String {
        let baseMessage = isClearAll
            ? "撮影記録とアプリ内コラージュ画像をすべて削除します。"
            : "選択した撮影記録とアプリ内コラージュ画像を削除します。"

        if hasPhotoLibraryLinkedRecords {
            return "\(baseMessage) 写真アプリに保存した画像も一緒に削除できます。"
        }
        return baseMessage
    }
}

private struct DeletionStatusMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - 撮影記録詳細 — コラージュ画像フルスクリーン表示
struct ShotDetailView: View {
    let record: ShotRecord
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color.black)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(.white.opacity(0.2))
                    Text("画像なし")
                        .font(.meterLabel(14))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(record.aperture)  \(record.shutterSpeed)  ISO \(record.iso)")
                        .font(.meterValue(16))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            image = record.loadCollageImage()
        }
    }
}

struct ShotRecordRow: View {
    let record: ShotRecord
    var refined: Bool = false
    @State private var thumbnail: UIImage?

    private var dateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        return fmt.string(from: record.date)
    }

    private var zoneLabel: String {
        let labels = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        let idx = max(0, min(10, record.zoneValue))
        return "Zone \(labels[idx])"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else if record.hasImage {
                RoundedRectangle(cornerRadius: 2)
                    .fill(refined ? Color.refinedPanel : Color.meterSurface)
                    .frame(width: 40, height: 54)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(dateString)
                        .font(.meterLabel(9))
                        .foregroundColor(refined ? .refinedTextSoft.opacity(0.6) : .meterSecondary.opacity(0.45))
                    Spacer()
                    if record.isIncident {
                        Text("入射光")
                            .font(.meterLabel(8))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 2).stroke(Color.cyan.opacity(0.5), lineWidth: 0.5))
                    }
                    Text("EV \(String(format: "%.1f", record.ev))")
                        .font(.meterValue(11))
                        .foregroundColor(refined ? .cyan : .meterAccent)
                    Text(zoneLabel)
                        .font(.meterLabel(9))
                        .foregroundColor(refined ? .refinedTextSoft.opacity(0.65) : .meterSecondary.opacity(0.5))
                }

                HStack(spacing: 10) {
                    labelValue("F", record.aperture)
                    labelValue("SS", record.shutterSpeed)
                    labelValue("ISO", "\(record.iso)")
                    if let focalLength = record.focalLength {
                        labelValue("FL", focalLength)
                    }
                    Text(record.exposureMode)
                        .font(.meterLabel(9))
                        .foregroundColor(refined ? .refinedTextSoft.opacity(0.55) : .meterSecondary.opacity(0.4))
                }

                if !record.note.isEmpty {
                    Text(record.note)
                        .font(.meterLabel(10))
                        .foregroundColor(refined ? .refinedTextSoft.opacity(0.78) : .meterSecondary.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .task {
            thumbnail = record.loadThumbnail()
        }
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.meterLabel(8))
                .foregroundColor(refined ? .refinedTextSoft.opacity(0.55) : .meterSecondary.opacity(0.4))
            Text(value)
                .font(.meterValue(13))
                .foregroundColor(refined ? .refinedText : .meterSecondary)
        }
    }
}
