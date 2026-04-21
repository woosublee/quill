import Foundation

struct TranscriptionModel: Identifiable, Hashable, Codable {
    let id: String           // mlx-whisper에 넘기는 모델 ID (또는 "apple-speech" 센티넬)
    let displayName: String  // UI에 표시되는 이름
    let description: String  // 설명

    static let all: [TranscriptionModel] = [
        TranscriptionModel(
            id: "apple-speech",
            displayName: "Apple Speech",
            description: "시스템 내장 · 온디바이스 · 빠름"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            description: "빠름 · 정확도 높음 (추천)"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-large-v3-mlx",
            displayName: "Whisper Large v3",
            description: "최고 정확도 · 느림"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-medium-mlx",
            displayName: "Whisper Medium",
            description: "중간 속도 · 중간 정확도"
        ),
        TranscriptionModel(
            id: "mlx-community/whisper-small-mlx",
            displayName: "Whisper Small",
            description: "빠름 · 정확도 낮음"
        ),
    ]

    var isAppleSpeech: Bool { id == "apple-speech" }

    static let `default` = all[0]

    static func find(id: String) -> TranscriptionModel {
        all.first { $0.id == id } ?? .default
    }

    // huggingface hub 캐시 경로에서 모델 ID를 폴더명으로 변환
    // e.g. "mlx-community/whisper-large-v3-turbo" → "models--mlx-community--whisper-large-v3-turbo"
    var cacheDirectoryName: String {
        "models--" + id.replacingOccurrences(of: "/", with: "--")
    }

    // 모델 가중치 파일이 존재하는지 확인 (snapshots 또는 blobs)
    var isInstalled: Bool {
        if isAppleSpeech { return true }

        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(cacheDirectoryName)

        // snapshots 폴더에서 weights.npz 확인
        let snapshotsDir = cacheDir.appendingPathComponent("snapshots")
        if let snapshots = try? FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) {
            for snapshot in snapshots {
                if FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("weights.npz").path) {
                    return true
                }
            }
        }

        // blobs 폴더에서 100MB 이상 파일 확인 (모델 가중치)
        let blobsDir = cacheDir.appendingPathComponent("blobs")
        if let blobs = try? FileManager.default.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for blob in blobs {
                let size = (try? blob.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 100_000_000 {
                    return true
                }
            }
        }

        return false
    }

    // mlx_whisper를 통해 모델 다운로드 (백그라운드)
    func download(whisperBin: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperBin)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin",
                "HOME": home
            ]
            // 빈 오디오 없이 모델만 다운로드하는 트릭: 존재하지 않는 파일로 실행하면 모델 다운로드 후 오류
            // 대신 python으로 snapshot_download 직접 호출
            let script = """
import sys
sys.path.insert(0, '\(home)/.local/pipx/venvs/mlx-whisper/lib/python3.14/site-packages')
from huggingface_hub import snapshot_download
snapshot_download('\(id)')
print('DONE')
"""
            let pythonBin = "\(home)/.local/pipx/venvs/mlx-whisper/bin/python"
            process.executableURL = URL(fileURLWithPath: pythonBin)
            process.arguments = ["-c", script]

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            try? process.run()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(output.contains("DONE"))
            }
        }
    }
}
