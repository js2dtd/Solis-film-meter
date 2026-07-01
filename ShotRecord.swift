//
//  ShotRecord.swift
//  Solis film meter
//

// MARK: - 役割: 撮影記録データと保存ストア
// MARK: - 目次
// 1. ShotRecordモデルと表示用フォーマット
// 2. コラージュ画像/サムネイル保存先
// 3. 画像保存・読み込み・削除
// 4. ShotRecordStoreの追加/削除/更新
// 5. 最大100件のUserDefaults永続化

import Foundation
import SwiftUI
import Combine

// MARK: - 撮影記録モデル — 1ショット分の露出データ+コラージュ画像保存
struct ShotRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let aperture: String
    let shutterSpeed: String
    let iso: Int
    let ev: Double
    let evDifference: Double
    let exposureMode: String
    let meteringMode: String
    let exposureCompensation: Double
    let isIncident: Bool
    let zoneValue: Int
    let focalLength: String?
    let note: String
    var imageFileName: String?
    var photoAssetLocalIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case aperture
        case shutterSpeed
        case iso
        case ev
        case evDifference
        case exposureMode
        case meteringMode
        case exposureCompensation
        case isIncident
        case zoneValue
        case focalLength
        case note
        case imageFileName
        case photoAssetLocalIdentifier
    }

    init(
        aperture: String,
        shutterSpeed: String,
        iso: Int,
        ev: Double,
        evDifference: Double,
         exposureMode: String, meteringMode: String, exposureCompensation: Double,
         isIncident: Bool = false,
         zoneValue: Int = 5,
         focalLength: String? = nil,
         note: String = "",
         photoAssetLocalIdentifier: String? = nil,
         date: Date = Date()
    ) {
        self.id = UUID()
        self.date = date
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.ev = ev
        self.evDifference = evDifference
        self.exposureMode = exposureMode
        self.meteringMode = meteringMode
        self.exposureCompensation = exposureCompensation
        self.isIncident = isIncident
        self.zoneValue = zoneValue
        self.focalLength = focalLength
        self.note = note
        self.imageFileName = "\(self.id.uuidString).jpg"
        self.photoAssetLocalIdentifier = photoAssetLocalIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        aperture = try container.decode(String.self, forKey: .aperture)
        shutterSpeed = try container.decode(String.self, forKey: .shutterSpeed)
        iso = try container.decode(Int.self, forKey: .iso)
        ev = try container.decode(Double.self, forKey: .ev)
        evDifference = try container.decode(Double.self, forKey: .evDifference)
        exposureMode = try container.decode(String.self, forKey: .exposureMode)
        meteringMode = try container.decode(String.self, forKey: .meteringMode)
        exposureCompensation = try container.decode(Double.self, forKey: .exposureCompensation)
        isIncident = try container.decode(Bool.self, forKey: .isIncident)
        zoneValue = try container.decode(Int.self, forKey: .zoneValue)
        focalLength = try container.decodeIfPresent(String.self, forKey: .focalLength)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        photoAssetLocalIdentifier = try container.decodeIfPresent(String.self, forKey: .photoAssetLocalIdentifier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(aperture, forKey: .aperture)
        try container.encode(shutterSpeed, forKey: .shutterSpeed)
        try container.encode(iso, forKey: .iso)
        try container.encode(ev, forKey: .ev)
        try container.encode(evDifference, forKey: .evDifference)
        try container.encode(exposureMode, forKey: .exposureMode)
        try container.encode(meteringMode, forKey: .meteringMode)
        try container.encode(exposureCompensation, forKey: .exposureCompensation)
        try container.encode(isIncident, forKey: .isIncident)
        try container.encode(zoneValue, forKey: .zoneValue)
        try container.encodeIfPresent(focalLength, forKey: .focalLength)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encodeIfPresent(photoAssetLocalIdentifier, forKey: .photoAssetLocalIdentifier)
    }

    // コラージュ画像の保存先URL
    var imageURL: URL? {
        guard let fileName = imageFileName else { return nil }
        return ShotRecord.imageDirectory?.appendingPathComponent(fileName)
    }

    // サムネイルURL
    var thumbnailURL: URL? {
        guard let fileName = imageFileName else { return nil }
        return ShotRecord.imageDirectory?.appendingPathComponent("thumb_\(fileName)")
    }

    // 画像が存在するか（ディスク読み込みなし）
    var hasImage: Bool {
        guard let url = imageURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // コラージュ画像の読み込み（詳細表示用）
    func loadCollageImage() -> UIImage? {
        guard let url = imageURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // サムネイル読み込み（リスト表示用）
    func loadThumbnail() -> UIImage? {
        if let url = thumbnailURL, FileManager.default.fileExists(atPath: url.path) {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    // 画像保存ディレクトリ
    static var imageDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("ShotImages")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // コラージュ画像＋サムネイルを保存
    func saveCollageImage(_ image: UIImage) {
        guard let url = imageURL, let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: url)
        // サムネイル（80x108 = Retina 2x）
        if let thumbURL = thumbnailURL {
            let thumbSize = CGSize(width: 80, height: 108)
            let renderer = UIGraphicsImageRenderer(size: thumbSize)
            let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: thumbSize)) }
            if let thumbData = thumb.jpegData(compressionQuality: 0.6) {
                try? thumbData.write(to: thumbURL)
            }
        }
    }

    // 画像ファイルを削除
    func deleteImageFile() {
        if let url = imageURL { try? FileManager.default.removeItem(at: url) }
        if let url = thumbnailURL { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - 撮影記録ストア — 最大100件のShotRecord永続化（UserDefaults）
class ShotRecordStore: ObservableObject {
    @Published var records: [ShotRecord] = []
    private let storageKey = "shot_records_v1"

    init() { load() }

    func add(_ record: ShotRecord) {
        records.insert(record, at: 0)
        if records.count > 100 { records = Array(records.prefix(100)) }
        persist()
    }

    func delete(at offsets: IndexSet) {
        delete(records: offsets.map { records[$0] })
    }

    func clearAll() {
        delete(records: records)
    }

    func delete(records recordsToDelete: [ShotRecord]) {
        let idsToDelete = Set(recordsToDelete.map(\.id))
        for record in recordsToDelete { record.deleteImageFile() }
        records.removeAll { idsToDelete.contains($0.id) }
        persist()
    }

    func updatePhotoAssetLocalIdentifier(_ identifier: String, for recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].photoAssetLocalIdentifier = identifier
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ShotRecord].self, from: data) else { return }
        records = decoded
    }
}
