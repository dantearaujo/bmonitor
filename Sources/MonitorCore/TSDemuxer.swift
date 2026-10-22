import Foundation

/// Um PES de vídeo completo: um quadro codificado em Annex B.
public struct VideoAccessUnit {
    public var data: Data
    /// PTS em 90 kHz.
    public var pts: Int64?
    /// Instante (ns, relógio monotônico) em que o primeiro pacote TS do quadro chegou.
    public var firstPacketAt: UInt64
    /// H.264 em vez de HEVC: o iPhone transmite no codec da gravação quando ela é H.264.
    public var isH264 = false
}

/// Um PES de áudio: um ou mais quadros AAC com cabeçalho ADTS.
public struct AudioAccessUnit {
    public var data: Data
    /// PTS em 90 kHz.
    public var pts: Int64?
}

/// Demultiplexador MPEG-TS mínimo: acha vídeo e áudio pela PAT/PMT e entrega cada quadro.
///
/// O PES de vídeo costuma vir sem tamanho. Esperar o próximo início de PES custaria um quadro
/// inteiro de atraso, então o quadro sai assim que chega o pacote com enchimento no campo de
/// adaptação, que marca o fim do PES.
public final class TSDemuxer {
    public static let hevc: UInt8 = 0x24
    public static let h264: UInt8 = 0x1B
    public static let adtsAAC: UInt8 = 0x0F

    public var onVideo: ((VideoAccessUnit) -> Void)?
    public var onAudio: ((AudioAccessUnit) -> Void)?
    public private(set) var videoStreamType: UInt8 = 0

    private var pending = Data()
    private var pmtPID = -1
    private var videoPID = -1
    private var pes = Data()
    private var inPES = false
    private var pesStartedAt: UInt64 = 0
    private var audioPID = -1
    private var audioPES = Data()
    /// Tamanho total do PES de áudio (o áudio traz `PES_packet_length`), ou 0 se não veio.
    private var audioPESLength = 0

    public init() {}

    public func feed(_ bytes: UnsafeRawBufferPointer) {
        pending.append(contentsOf: bytes)
        var offset = 0
        pending.withUnsafeBytes { p in
            while offset + 188 <= p.count {
                if p[offset] != 0x47 { offset += 1; continue }
                packet(UnsafeRawBufferPointer(rebasing: p[offset..<offset + 188]))
                offset += 188
            }
        }
        pending.removeFirst(offset)
    }

    private func packet(_ p: UnsafeRawBufferPointer) {
        let pusi = p[1] & 0x40 != 0
        let pid = Int(p[1] & 0x1F) << 8 | Int(p[2])
        let afc = (p[3] >> 4) & 0x3
        guard afc & 0x1 != 0 else { return }

        var start = 4
        var stuffed = false
        if afc == 3 {
            let afLength = Int(p[4])
            if afLength > 0 {
                let flags = p[5]
                var required = 1
                if flags & 0x10 != 0 { required += 6 }  // PCR
                if flags & 0x08 != 0 { required += 6 }  // OPCR
                if flags & 0x04 != 0 { required += 1 }  // splice countdown
                stuffed = flags & 0x07 == 0 && afLength > required
            }
            start += 1 + afLength
        }
        guard start < 188 else { return }
        let payload = UnsafeRawBufferPointer(rebasing: p[start..<188])

        if pid == 0 {
            parsePAT(payload, pusi)
        } else if pid == pmtPID {
            parsePMT(payload, pusi)
        } else if pid == videoPID {
            video(payload, pusi: pusi, last: stuffed && !pusi)
        } else if pid == audioPID {
            audio(payload, pusi: pusi)
        }
    }

    private func parsePAT(_ p: UnsafeRawBufferPointer, _ pusi: Bool) {
        guard pusi, p.count > 1 else { return }
        let s = 1 + Int(p[0])
        guard s + 8 < p.count, p[s] == 0x00 else { return }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let end = min(s + 3 + sectionLength - 4, p.count)
        var i = s + 8
        while i + 4 <= end {
            let program = Int(p[i]) << 8 | Int(p[i + 1])
            if program != 0 {
                pmtPID = Int(p[i + 2] & 0x1F) << 8 | Int(p[i + 3])
                return
            }
            i += 4
        }
    }

    private func parsePMT(_ p: UnsafeRawBufferPointer, _ pusi: Bool) {
        // Lido a cada PMT, não só o primeiro: o demuxer vive a sessão inteira e o stream pode
        // voltar em outro codec depois de uma troca de formato.
        guard pusi, p.count > 1 else { return }
        let s = 1 + Int(p[0])
        guard s + 12 < p.count, p[s] == 0x02 else { return }
        let sectionLength = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let programInfoLength = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        let end = min(s + 3 + sectionLength - 4, p.count)
        var i = s + 12 + programInfoLength
        while i + 5 <= end {
            let streamType = p[i]
            let pid = Int(p[i + 1] & 0x1F) << 8 | Int(p[i + 2])
            let esInfoLength = Int(p[i + 3] & 0x0F) << 8 | Int(p[i + 4])
            if streamType == Self.hevc || streamType == Self.h264 {
                if pid != videoPID || streamType != videoStreamType {
                    videoPID = pid
                    videoStreamType = streamType
                    inPES = false
                }
            } else if streamType == Self.adtsAAC, pid != audioPID {
                audioPID = pid
                audioPES.removeAll(keepingCapacity: true)
            }
            i += 5 + esInfoLength
        }
    }

    private func video(_ payload: UnsafeRawBufferPointer, pusi: Bool, last: Bool) {
        if pusi {
            if inPES { emit() }
            pes.removeAll(keepingCapacity: true)
            pesStartedAt = DispatchTime.now().uptimeNanoseconds
            inPES = true
        }
        guard inPES else { return }
        pes.append(contentsOf: payload)
        if last { emit() }
    }

    /// O PES de áudio sai quando completa o tamanho declarado; sem tamanho, no próximo início.
    private func audio(_ payload: UnsafeRawBufferPointer, pusi: Bool) {
        if pusi {
            if !audioPES.isEmpty { emitAudio() }
            audioPES.append(contentsOf: payload)
            audioPESLength = audioPES.count >= 6 ? Int(audioPES[4]) << 8 | Int(audioPES[5]) : 0
            if audioPESLength > 0 { audioPESLength += 6 }
        } else if !audioPES.isEmpty {
            audioPES.append(contentsOf: payload)
        }
        if audioPESLength > 0, audioPES.count >= audioPESLength { emitAudio() }
    }

    private func emitAudio() {
        defer { audioPES.removeAll(keepingCapacity: true) }
        if audioPESLength > 0, audioPES.count > audioPESLength { audioPES.removeSubrange(audioPESLength...) }
        guard let (pts, start) = Self.pesHeader(audioPES) else { return }
        onAudio?(AudioAccessUnit(data: Data(audioPES[start...]), pts: pts))
    }

    /// PTS e início dos dados de um PES, ou nil se o cabeçalho não fecha.
    static func pesHeader(_ pes: Data) -> (pts: Int64?, start: Int)? {
        guard pes.count > 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return nil }
        let flags = pes[7]
        let dataStart = 9 + Int(pes[8])
        guard dataStart < pes.count else { return nil }
        var pts: Int64?
        if flags & 0x80 != 0 {
            pts = Int64(pes[9] & 0x0E) << 29 | Int64(pes[10]) << 22 | Int64(pes[11] & 0xFE) << 14
                | Int64(pes[12]) << 7 | Int64(pes[13]) >> 1
        }
        return (pts, dataStart)
    }

    private func emit() {
        inPES = false
        guard let (pts, dataStart) = Self.pesHeader(pes) else { return }
        onVideo?(
            VideoAccessUnit(
                data: Data(pes[dataStart...]), pts: pts, firstPacketAt: pesStartedAt, isH264: videoStreamType == Self.h264))
    }
}
