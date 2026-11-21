import CoreMedia

/// Linha do tempo da cópia no Mac. Segue o PTS do iPhone enquanto ele anda junto com o relógio
/// do Mac; quando o iPhone não dá conta do formato, puxa a linha para o relógio do Mac.
///
/// O iPhone 14 a 60 fps manda só uns 72% do stream (49% gravando) e numera o que manda sem
/// buracos: o PTS anda 0,72 s a cada segundo de verdade, para imagem e som. Gravado como veio,
/// o take sai acelerado e o som do Mac, que anda no relógio de verdade, se perde dele. Medido em
/// 2026-11-21; a 30 fps o stream vem inteiro e o PTS anda junto com o relógio.
///
/// Cada quadro avança o que o PTS avançou. Se a linha fica atrás da chegada (pelo relógio do Mac)
/// mais que `deadband` no quadro que chegou mais cedo do último `window`, uma fração `gain` do
/// excesso entra no quadro. Atraso de rede só atrasa a chegada, e um engasgo da Wi‑Fi termina
/// numa rajada que chega cedo: os dois ficam de fora, e um stream inteiro sai com o PTS do
/// iPhone intacto. Só o stream que vem de fato mais devagar puxa a linha.
struct StreamTimeline {
    static let deadband = 0.08
    static let gain = 0.1
    static let window = 1.0

    private var last: (stream: Double, out: Double)?
    /// Menor (chegada − linha) visto: a chegada mais rápida é a referência.
    private var arrivalOffset = Double.infinity
    /// Atraso da linha em cada chegada do último `window`.
    private var recent: [(host: Double, lag: Double)] = []
    /// Para medir quanto do tempo de verdade o stream cobriu.
    private(set) var streamSpan = 0.0
    private(set) var outSpan = 0.0

    /// Posição na linha do quadro com esse PTS, chegado em `host`.
    mutating func map(stream: CMTime, host: CMTime) -> CMTime {
        guard stream.isNumeric else { return stream }
        let s = stream.seconds
        let h = host.isNumeric ? host.seconds : .nan
        guard let last, s > last.stream else {
            // Primeiro quadro ou stream reiniciado: a linha recomeça no PTS do iPhone.
            self = Self()
            self.last = (s, s)
            if h.isFinite { arrivalOffset = h - s }
            return stream
        }
        let step = s - last.stream
        var out = last.out + step
        if h.isFinite {
            arrivalOffset = min(arrivalOffset, h - out)
            recent.append((h, (h - arrivalOffset) - out))
            recent.removeFirst(recent.prefix { h - $0.host > Self.window }.count)
            let lag = recent.map(\.lag).min() ?? 0
            if lag > Self.deadband { out += Self.gain * (lag - Self.deadband) }
        }
        out = max(out, last.out + 0.001)
        streamSpan += step
        outSpan += out - last.out
        self.last = (s, out)
        return CMTime(seconds: out, preferredTimescale: 90_000)
    }

    /// Posição na linha de um PTS do som do iPhone, pela relação do último quadro de vídeo.
    func position(of stream: CMTime) -> CMTime? {
        guard let last, stream.isNumeric else { return nil }
        return CMTime(seconds: stream.seconds + last.out - last.stream, preferredTimescale: 90_000)
    }

    /// Um ponto da linha no PTS do iPhone (para guardar e comparar dentro de um take).
    var mark: (stream: Double, out: Double)? { last.map { ($0.stream, $0.out) } }
}
