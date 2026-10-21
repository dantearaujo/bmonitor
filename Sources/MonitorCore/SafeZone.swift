import CoreGraphics

/// Faixas que a interface de cada rede cobre num vídeo vertical 9:16, com as medidas que a
/// própria rede publica. Nenhuma rede publica números para o vídeo orgânico: as medidas são as
/// das especificações de anúncio vertical, que é o que cada uma documenta. Conferidas em
/// 20/10/2026; as redes mudam a interface, então reveja as fontes de tempos em tempos.
public enum SafeZone: String, CaseIterable, Sendable {
    /// Instagram e Facebook, Reels e Stories: 14% em cima, 35% embaixo, 6% nas laterais.
    /// https://www.facebook.com/business/ads-guide/update/video/instagram-reels
    /// https://www.facebook.com/business/ads-guide/update/video/instagram-story
    case meta
    /// TikTok In-Feed: 240 px em cima, 660 embaixo, 120 nas laterais e a coluna de botões
    /// (300 px) à direita a partir de y = 840. Template oficial de 720x1280, escalado.
    /// https://ads.tiktok.com/help/article/tiktok-auction-in-feed-ads?lang=en
    case tiktok
    /// YouTube vertical, Shorts incluído: 288 px em cima, 672 embaixo, 48 à esquerda, 192 à direita.
    /// https://services.google.com/fh/files/misc/universalsafezones-youtube.pdf
    case shorts
    /// Grid do perfil do Instagram: Reels aparece num recorte 3:4 (1080x1440) no meio do quadro.
    /// https://www.threads.com/@creators/post/DFYwfNwRYRZ
    case profileGrid

    /// Quadro de referência das medidas, em pixels.
    static let reference = CGSize(width: 1080, height: 1920)

    /// Faixas cobertas, em pixels do quadro de referência. Podem se sobrepor nos cantos.
    private var referenceRects: [CGRect] {
        let w = Self.reference.width, h = Self.reference.height
        func band(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) -> [CGRect] {
            [
                CGRect(x: 0, y: 0, width: w, height: top),
                CGRect(x: 0, y: h - bottom, width: w, height: bottom),
                CGRect(x: 0, y: 0, width: left, height: h),
                CGRect(x: w - right, y: 0, width: right, height: h),
            ]
        }
        switch self {
        case .meta:
            return band(top: h * 0.14, bottom: h * 0.35, left: w * 0.06, right: w * 0.06)
        case .tiktok:
            return [
                CGRect(x: 0, y: 0, width: w, height: 240),
                CGRect(x: 0, y: h - 660, width: w, height: 660),
                CGRect(x: 0, y: 0, width: 120, height: h),
                CGRect(x: w - 120, y: 0, width: 120, height: 840),
                CGRect(x: w - 300, y: 840, width: 300, height: h - 840),
            ]
        case .shorts:
            return band(top: 288, bottom: 672, left: 48, right: 192)
        case .profileGrid:
            let cut = (h - 1440) / 2
            return [CGRect(x: 0, y: 0, width: w, height: cut), CGRect(x: 0, y: h - cut, width: w, height: cut)]
        }
    }

    /// Faixas cobertas num quadro vertical qualquer, na mesma proporção das medidas.
    public func covered(in frame: CGRect) -> [CGRect] {
        let sx = frame.width / Self.reference.width, sy = frame.height / Self.reference.height
        return referenceRects.map {
            CGRect(x: frame.minX + $0.minX * sx, y: frame.minY + $0.minY * sy, width: $0.width * sx, height: $0.height * sy)
        }
    }

    /// O maior quadro 9:16 no meio do vídeo: o vídeo inteiro quando ele está em pé, o recorte
    /// vertical quando ele está deitado.
    public static func verticalFrame(in video: CGSize) -> CGRect {
        let aspect = reference.width / reference.height
        if video.width / video.height <= aspect {
            let height = video.width / aspect
            return CGRect(x: 0, y: (video.height - height) / 2, width: video.width, height: height)
        }
        let width = video.height * aspect
        return CGRect(x: (video.width - width) / 2, y: 0, width: width, height: video.height)
    }
}
