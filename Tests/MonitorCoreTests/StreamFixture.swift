import Foundation

/// O trecho gravado do livestream (`Fixtures/stream.ts`) não vai para o repo público: tem
/// imagem e som de um ambiente real. Sem ele, os testes que o usam são pulados. Para rodá-los,
/// grave alguns segundos do stream (por exemplo com `latency-probe`) e salve nesse caminho.
let hasStreamFixture = Bundle.module.url(forResource: "stream", withExtension: "ts", subdirectory: "Fixtures") != nil
