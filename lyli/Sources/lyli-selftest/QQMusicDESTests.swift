import Foundation
#if DEBUG
@testable import LyliCore

func runQQMusicDESTests() {
    let encrypted = "ee7befb746f93831d42dcdf2e21f0d5dd9fd95a45509a6454e1d4966f9a90d46e7194660c97edd28cf6058f22077b714b2acceeb198dbdf26fcb90f35de3f92d"
    let packed = "789cb3092c4af6cc4bcb2fb6b3f1a92cca04b315c02ce7fcbc92d4bc125ba56803032b03433d0383d88cd49c9c7c25057d3b1b7db83600e2d7159a"
    let xml = "<QrcInfos><LyricInfo LyricContent=\"[00:01.00]hello\" /></QrcInfos>"

    guard let output = QQMusicDES.decrypt(encrypted), let wrapped = Data(hex: packed) else {
        expectEqual(false, true, "QQ QRC 解密成功")
        return
    }
    expectEqual(Data(output.prefix(wrapped.count)), wrapped)
    expectEqual(output.count - wrapped.count, 5)
    expectEqual(zlibDecompress(wrapped).flatMap { String(data: $0, encoding: .utf8) }, xml)

    var corrupted = wrapped
    corrupted[corrupted.count - 1] ^= 1
    expectEqual(zlibDecompress(corrupted), nil, "Adler-32 校验拒绝损坏内容")
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        let chars = Array(hex)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            append(byte)
        }
    }
}
#else
func runQQMusicDESTests() {
    print("SKIP - internal QRC checks require a Debug build")
}
#endif
