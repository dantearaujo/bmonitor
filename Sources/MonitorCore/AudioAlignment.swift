import Accelerate
import Foundation

/// Acha onde o som do Mac cai na linha do tempo do vídeo comparando-o com o som que o próprio
/// iPhone gravou. Os dois microfones ouvem a mesma sala; a correlação cruzada com peso de fase
/// (GCC-PHAT) ignora a diferença de timbre entre eles e deixa um pico só no atraso certo.
public enum AudioAlignment {
    public struct Match: Equatable {
        /// Segundos do vídeo em que cai o instante zero do som do Mac.
        public var offset: Double
        /// Altura do pico dividida pela do maior pico fora dele; perto de 1 é chute.
        public var confidence: Double
    }

    /// Abaixo disso o pico não se destaca do resto e o resultado não é confiável.
    public static let minimumConfidence = 1.5

    /// `reference` é o som do vídeo, `candidate` o do Mac, os dois mono na mesma `sampleRate`.
    /// Procura o atraso em `expected ± window` segundos; sem `expected`, em qualquer ponto em que
    /// os dois se sobreponham.
    public static func match(
        reference: [Float], candidate: [Float], sampleRate: Double,
        expected: Double? = nil, window: Double? = nil, band: ClosedRange<Double> = 150...3_800
    ) -> Match? {
        guard reference.count > Int(sampleRate / 4), candidate.count > Int(sampleRate / 4) else { return nil }
        let length = reference.count + candidate.count
        let log2n = vDSP_Length(ceil(log2(Double(length))))
        let n = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var refReal = [Float](repeating: 0, count: n), refImag = [Float](repeating: 0, count: n)
        var canReal = [Float](repeating: 0, count: n), canImag = [Float](repeating: 0, count: n)
        refReal.replaceSubrange(0..<reference.count, with: reference)
        canReal.replaceSubrange(0..<candidate.count, with: candidate)
        fft(&refReal, &refImag, setup: setup, log2n: log2n, direction: FFTDirection(FFT_FORWARD))
        fft(&canReal, &canImag, setup: setup, log2n: log2n, direction: FFTDirection(FFT_FORWARD))

        // Espectro cruzado R · conj(C), normalizado para módulo 1 dentro da banda da voz.
        let low = Int(band.lowerBound / sampleRate * Double(n))
        let high = min(Int(band.upperBound / sampleRate * Double(n)), n / 2)
        var real = [Float](repeating: 0, count: n), imag = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let bin = k <= n / 2 ? k : n - k
            guard bin >= low, bin <= high else { continue }
            let re = refReal[k] * canReal[k] + refImag[k] * canImag[k]
            let im = refImag[k] * canReal[k] - refReal[k] * canImag[k]
            let magnitude = (re * re + im * im).squareRoot()
            guard magnitude > 1e-12 else { continue }
            real[k] = re / magnitude
            imag[k] = im / magnitude
        }
        fft(&real, &imag, setup: setup, log2n: log2n, direction: FFTDirection(FFT_INVERSE))

        // real[d] = Σ ref[m + d] · cand[m]; atraso negativo dá a volta para o fim do vetor.
        let maxPositive = reference.count - 1
        let maxNegative = candidate.count - 1
        var lower = -maxNegative, upper = maxPositive
        if let expected {
            let center = Int((expected * sampleRate).rounded())
            let span = Int(((window ?? 1) * sampleRate).rounded())
            lower = max(lower, center - span)
            upper = min(upper, center + span)
        }
        guard lower < upper else { return nil }
        func value(_ lag: Int) -> Float { real[lag >= 0 ? lag : n + lag] }

        var best = lower, peak = -Float.infinity
        for lag in lower...upper where value(lag) > peak {
            peak = value(lag)
            best = lag
        }
        // Segundo maior pico, longe o bastante (10 ms) para não ser o mesmo.
        let guardBand = Int(sampleRate / 100)
        var second: Float = 0
        for lag in lower...upper where abs(lag - best) > guardBand { second = max(second, value(lag)) }
        guard peak > 0 else { return nil }
        let confidence = second > 0 ? Double(peak / second) : .infinity
        return Match(offset: Double(best) / sampleRate, confidence: confidence)
    }

    private static func fft(
        _ real: inout [Float], _ imag: inout [Float], setup: FFTSetup, log2n: vDSP_Length, direction: FFTDirection
    ) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }
}
