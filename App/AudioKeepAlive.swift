import AVFoundation
import Foundation

/// 静音音频保活。
///
/// # 为什么需要这个
///
/// iOS 的后台规则很简单：App 进入后台后，除了被授予的特权（蓝牙外设、音频播放、
/// 定位、VoIP……）之外，所有定时器和网络任务都会被挂起。这个 App 的闭环靠
/// 每 5 分钟一拍去读血糖、发微剂量——被挂起就等于停摆，而泵那边的胰岛素还在按
/// 自己的节奏走。
///
/// 蓝牙虽然开了 `bluetooth-central`，但它只保证"连接不被断开"能在后台维持，
/// 不保证你能按自己的节拍去轮询、去请求 bolus 权限。要稳定的节拍，只能叠一层
/// "正在播放音频"的身份。
///
/// # 具体做法
///
/// 播放一段自己生成的 1 秒静音 WAV，`numberOfLoops = -1` 无限循环，
/// 音频会话用 `.playback` + `.mixWithOthers`：不抢用户的音乐，也不触发打断。
/// 不走 `AVAudioEngine` 是因为它需要更细的会话管理，而这里要的只是"有个东西在放"。
///
/// # 代价（必须让用户知道）
///
/// - 锁屏状态栏可能出现"正在播放"的标识，取决于系统版本
/// - 耗电
/// - 这不是 App Store 允许的用途，只适合自签/侧载
final class AudioKeepAlive {

    static let shared = AudioKeepAlive()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {}

    /// 开启保活。返回 nil 表示成功，否则是给用户看的原因。
    @discardableResult
    func start() -> String? {
        if isRunning, player?.isPlaying == true { return nil }
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers：别人的音乐照放，我们不抢音频焦点
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player == nil {
                let url = try Self.silentWAVFile()
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                player = p
            }
            guard let p = player, p.play() else {
                return "静音播放启动失败：AVAudioPlayer 拒绝播放"
            }
            isRunning = true
            return nil
        } catch {
            isRunning = false
            return "静音播放启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 从后台回来、或者被打断之后重新起一次
    func ensureRunning() {
        guard isRunning, player?.isPlaying != true else { return }
        _ = start()
    }

    // MARK: - 生成静音 WAV

    /// 写一个 1 秒、44.1kHz、单声道、16bit 的静音 WAV 到临时目录。
    /// 不把文件放进 App 包里，是为了少一个资源、也避免它被当成"示例音频"。
    private static func silentWAVFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 44100
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frames = Int(sampleRate)
        let dataBytes = frames * Int(channels) * Int(bitsPerSample / 8)

        var data = Data()
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])                  // "RIFF"
        data.append(contentsOf: UInt32(36 + dataBytes).littleEndianBytes)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])                  // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])                  // "fmt "
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)                           // PCM
        data.append(contentsOf: channels.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: UInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)).littleEndianBytes)
        data.append(contentsOf: UInt16(channels * bitsPerSample / 8).littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])                  // "data"
        data.append(contentsOf: UInt32(dataBytes).littleEndianBytes)
        data.append(Data(count: dataBytes))                                // 全 0 = 静音

        try data.write(to: url)
        return url
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)] }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 24) & 0xFF)]
    }
}
