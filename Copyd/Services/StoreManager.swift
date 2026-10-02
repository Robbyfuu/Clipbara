import Foundation
import os.log

enum StoreManager {

    static let logger = Logger(
        subsystem: "com.robbyfuu.copyd",
        category: "StoreManager"
    )

    // Kept from Clipbara: the store lives at this path inside the com.robbyfuu.copyd container; renaming it would orphan existing history.
    private static let storeDirectoryName = "com.minsang.PasteClip"
    private static let storeFileName = "PasteClip.store"
    private static let legacyStoreFileName = "default.store"
    // SwiftData external storage: .{storeName_without_ext}_SUPPORT/_EXTERNAL_DATA/
    private static let legacySupportDirName = ".default_SUPPORT"
    private static let newSupportDirName = ".PasteClip_SUPPORT"

    /// 정식 store URL을 반환. 기존 default.store가 있으면 자동 마이그레이션.
    static func resolveStoreURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(storeDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)

        let newStoreURL = appDir.appendingPathComponent(storeFileName)

        if fm.fileExists(atPath: newStoreURL.path) {
            logger.info("Using existing store at \(newStoreURL.path)")
            return newStoreURL
        }

        // 기존 default.store에서 마이그레이션
        let legacyURL = appSupport.appendingPathComponent(legacyStoreFileName)
        if fm.fileExists(atPath: legacyURL.path) {
            logger.info("Found legacy store, migrating...")
            migrateStore(from: legacyURL, to: newStoreURL, fm: fm)
        } else {
            logger.info("No existing store found, creating fresh")
        }

        return newStoreURL
    }

    /// store + WAL + SHM + external storage 모두 백업
    static func backupStore(at storeURL: URL) {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent

        for suffix in ["", "-wal", "-shm"] {
            let src = dir.appendingPathComponent(name + suffix)
            let dst = dir.appendingPathComponent(name + ".backup" + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        let srcSupport = dir.appendingPathComponent(newSupportDirName)
        let dstSupport = dir.appendingPathComponent(newSupportDirName + ".backup")
        if fm.fileExists(atPath: srcSupport.path) {
            try? fm.removeItem(at: dstSupport)
            try? fm.copyItem(at: srcSupport, to: dstSupport)
        }

        logger.info("Backup created")
    }

    /// 손상 복구용: store 및 관련 파일 모두 삭제
    static func deleteStore(at storeURL: URL) {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent

        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name + suffix))
        }
        try? fm.removeItem(at: dir.appendingPathComponent(newSupportDirName))
        // Stale CloudKit change tokens would stop the emptied store from re-downloading.
        try? fm.removeItem(at: dir.appendingPathComponent("SyncState.data"))
        logger.info("Deleted store at \(storeURL.path)")
    }

    // MARK: - Private

    private static func migrateStore(from source: URL, to destination: URL, fm: FileManager) {
        let sourceDir = source.deletingLastPathComponent()
        let destDir = destination.deletingLastPathComponent()
        let sourceName = source.lastPathComponent
        let destName = destination.lastPathComponent

        // .store, -wal, -shm 이동
        for suffix in ["", "-wal", "-shm"] {
            let src = sourceDir.appendingPathComponent(sourceName + suffix)
            let dst = destDir.appendingPathComponent(destName + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.moveItem(at: src, to: dst)
                logger.info("Moved \(src.lastPathComponent)")
            } catch {
                logger.error("Failed to move \(src.lastPathComponent): \(error.localizedDescription)")
                if suffix.isEmpty { return } // 메인 store 실패 시 중단
            }
        }

        // External storage 디렉토리 이동
        let srcSupport = sourceDir.appendingPathComponent(legacySupportDirName)
        let dstSupport = destDir.appendingPathComponent(newSupportDirName)
        if fm.fileExists(atPath: srcSupport.path) {
            do {
                try fm.moveItem(at: srcSupport, to: dstSupport)
                logger.info("Moved external storage directory")
            } catch {
                logger.error("Failed to move external storage: \(error.localizedDescription)")
            }
        }

        // 레거시 백업 정리
        for suffix in [".backup", ".backup-wal", ".backup-shm"] {
            try? fm.removeItem(at: sourceDir.appendingPathComponent(sourceName + suffix))
        }

        logger.info("Migration complete")
    }
}
