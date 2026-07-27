import Foundation

// Extracted from AppState (MAK-32 ratchet): a self-contained download helper
// with no AppState state — it lived at the bottom of AppState.swift only for
// historical reasons.

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    /// Called as bytes arrive with (totalBytesWritten, totalBytesExpectedToWrite).
    /// `totalBytesExpectedToWrite` is `NSURLSessionTransferSizeUnknown` (-1) when
    /// the server does not advertise a Content-Length.
    private var progressHandler: ((Int64, Int64) -> Void)?

    static func download(from url: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        let downloader = ModelDownloader()
        return try await downloader.download(from: url, progress: progress)
    }

    private func download(from url: URL, progress: ((Int64, Int64) -> Void)?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.progressHandler = progress
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession delivers this for ANY completed transfer, including 404/403/5xx
        // (the error body is what got written to disk). Installing an error page as
        // the model file would break every subsequent transcription with no in-app
        // recovery, so fail the download instead.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation?.resume(throwing: ModelDownloadError(message: "Server returned HTTP \(http.statusCode)"))
            continuation = nil
            session.invalidateAndCancel()
            return
        }
        do {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("openwhisp-model-\(UUID().uuidString).download")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: location, to: tempURL)
            continuation?.resume(returning: tempURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }
}

extension URL {
    func createDirectories() throws {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true, attributes: nil)
    }
}
