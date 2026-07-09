import Foundation
import IMKit

/// 文件消息的本地下载状态。「已下载」不入库，由确定性本地路径上
/// 文件是否存在推导（见 FileDownloadManager.localURL(for:)）。
enum FileDownloadState {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(URL)
}

/// App 层文件消息下载器：URLSession downloadTask + 进度回调。
/// 遵守项目无锁约定——所有方法只能从主队列调用，回调也落回主队列。
/// 同一消息重复调用 download 只更新回调，不重复起任务。
final class FileDownloadManager: NSObject {
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var currentProgress: [String: Double] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]
    private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]

    /// Documents/Files/<消息标识>/<文件名>。消息标识用服务端 uid（未 ack
    /// 回退本地 id），前缀 u/l 区分两个 id 空间避免碰撞。
    static func localURL(for row: StoredMessageRow) -> URL? {
        // 文件名来自对端 wire content，取 lastPathComponent 并拒绝 "."/".."，
        // 防止 ../ 路径穿越覆盖沙盒内其他文件
        guard let rawName = row.fileName else { return nil }
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let key = row.messageUid != 0 ? "u\(row.messageUid)" : "l\(row.localMessageId)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Files/\(key)/\(name)")
    }

    func state(for row: StoredMessageRow) -> FileDownloadState {
        guard let localURL = Self.localURL(for: row) else { return .notDownloaded }
        if FileManager.default.fileExists(atPath: localURL.path) { return .downloaded(localURL) }
        if tasks[localURL.path] != nil {
            return .downloading(progress: currentProgress[localURL.path] ?? 0)
        }
        return .notDownloaded
    }

    func download(
        row: StoredMessageRow,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let localURL = Self.localURL(for: row),
              let urlString = row.imageRemoteURL,
              let remoteURL = URL(string: urlString) else { return }
        let key = localURL.path
        progressHandlers[key] = progress
        completionHandlers[key] = completion
        guard tasks[key] == nil else { return }  // 已在下载，仅更新回调

        let task = URLSession.shared.downloadTask(with: remoteURL) { [weak self] tempURL, _, error in
            // 临时文件在本回调返回后即被系统删除，必须同步移动到目标路径。
            let result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let tempURL {
                do {
                    try FileManager.default.createDirectory(
                        at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.removeItem(at: localURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                    result = .success(localURL)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(URLError(.unknown))
            }
            DispatchQueue.main.async { self?.finish(key: key, result: result) }
        }
        observations[key] = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            DispatchQueue.main.async {
                guard let self, self.tasks[key] != nil else { return }
                self.currentProgress[key] = prog.fractionCompleted
                self.progressHandlers[key]?(prog.fractionCompleted)
            }
        }
        tasks[key] = task
        currentProgress[key] = 0
        task.resume()
    }

    private func finish(key: String, result: Result<URL, Error>) {
        observations[key]?.invalidate()
        observations[key] = nil
        tasks[key] = nil
        currentProgress[key] = nil
        let completion = completionHandlers[key]
        completionHandlers[key] = nil
        progressHandlers[key] = nil
        completion?(result)
    }
}
