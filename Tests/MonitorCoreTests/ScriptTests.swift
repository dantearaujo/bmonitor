import Foundation
import Testing

@testable import MonitorCore

// MARK: - Markdown

@Test func parsesBlocksOfAScript() {
    let script = Script(markdown: """
        # Abertura

        Hoje eu vou te mostrar
        três coisas.

        - A **luz** primeiro.
        2. Depois o som
        > Fecha com o roteiro.
        """)
    #expect(script.blocks.map(\.kind) == [.heading(1), .paragraph, .bullet, .numbered("2"), .quote])
    #expect(String(script.blocks[1].text.characters) == "Hoje eu vou te mostrar três coisas.")
    // O negrito some do texto, e as palavras contam no texto renderizado.
    #expect(String(script.blocks[2].text.characters) == "A luz primeiro.")
    let luz = script.words[script.blocks[2].words.lowerBound + 1]
    #expect(luz.key == "luz" && luz.range == 2..<5)
}

@Test func sentencesEndAtPunctuationAndAtEveryBlock() {
    let script = Script(markdown: "# Título\n\nUma frase. Outra frase! E a última\n\n- item")
    let texts = script.sentences.map { $0.map { script.words[$0].key }.joined(separator: " ") }
    #expect(texts == ["titulo", "uma frase", "outra frase", "e a ultima", "item"])
}

@Test func keysIgnoreCaseAccentsAndPunctuation() {
    #expect(Script.keys(in: "Não, É ISSO... d'água guarda-chuva 3") == ["nao", "e", "isso", "dagua", "guardachuva", "3"])
}

// MARK: - Seguir a fala

private let sample = Script(markdown: """
    Hoje eu vou te mostrar três coisas sobre gravar com o iPhone.
    A primeira é a luz: uma janela vale mais que qualquer câmera cara.
    A segunda é o som, porque o público perdoa imagem ruim, mas não perdoa áudio ruim.
    """)

private func index(of key: String, after start: Int = 0) -> Int {
    sample.words.indices.first { $0 >= start && sample.words[$0].key == key }!
}

@Test func followsSpeechWordByWord() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar"))
    #expect(follower.position == index(of: "mostrar") + 1)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar três coisas sobre gravar"))
    #expect(follower.position == index(of: "gravar") + 1)
}

@Test func toleratesFillersAndRecognizerMistakes() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar três coisas sobre gravar com o iPhone"))
    // "aí" não está no roteiro e "janelas" veio com um erro.
    follower.follow(Script.keys(in: "aí a primeira é a luz uma janelas vale mais"))
    #expect(follower.position == index(of: "mais") + 1)
}

@Test func partialLastWordCounts() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar três coi"))
    #expect(follower.position == index(of: "coisas") + 1)
}

@Test func restartingASentenceMovesBack() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "a primeira é a luz uma janela vale mais que qualquer câmera cara a segunda é o som porque o público"))
    #expect(follower.position == index(of: "publico") + 1)
    follower.follow(Script.keys(in: "porque o público perdoa não pera a segunda é o som"))
    #expect(follower.position == index(of: "som") + 1)
}

@Test func skippingAheadNeedsSeveralWords() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar"))
    let before = follower.position
    // Duas palavras curtas soltas não bastam para pular uma frase inteira.
    follower.follow(Script.keys(in: "é o"))
    #expect(follower.position == before)
    // Uma frase inteira à frente basta.
    follower.follow(Script.keys(in: "a segunda é o som porque o público perdoa"))
    #expect(follower.position == index(of: "perdoa") + 1)
}

@Test func silenceOrUnrelatedTalkKeepsThePlace() {
    var follower = ScriptFollower(script: sample)
    follower.follow(Script.keys(in: "hoje eu vou te mostrar três coisas"))
    let before = follower.position
    follower.follow(Script.keys(in: "peraí deixa eu beber uma água rapidinho"))
    #expect(follower.position == before)
}

// MARK: - Take real

/// Um take real do autor (`Fixtures/roteiro/`, fora do repo público): o roteiro final, os
/// resultados do reconhecedor do macOS sobre o áudio e o instante de cada palavra na tomada
/// boa. O take tem frases repetidas e começos errados, como gravação de verdade.
private let realTake = Bundle.module.url(forResource: "script", withExtension: "md", subdirectory: "Fixtures/roteiro")

@Test(.enabled(if: realTake != nil, "Fixtures/roteiro ausente")) func followsARealTake() throws {
    let folder = realTake!.deletingLastPathComponent()
    let script = Script(markdown: try String(contentsOf: realTake!, encoding: .utf8))
    struct Event: Decodable { var end: Double; var final: Bool; var text: String }
    struct Line: Decodable { var times: [Double] }
    let events = try JSONDecoder().decode([Event].self, from: Data(contentsOf: folder.appending(path: "events.json")))
    let lines = try JSONDecoder().decode([Line].self, from: Data(contentsOf: folder.appending(path: "truth.json")))

    // Instante de cada palavra do roteiro na tomada boa; cada fala é um bloco.
    var spokenAt = Array(repeating: Double.infinity, count: script.words.count)
    var windows: [ClosedRange<Double>] = []
    for (block, line) in zip(script.blocks, lines) {
        let words = Array(block.words)
        for (k, word) in words.enumerated() {
            spokenAt[word] = line.times[min(k * line.times.count / words.count, line.times.count - 1)]
        }
        windows.append(line.times.first!...(line.times.last! + 1))
    }

    var follower = ScriptFollower(script: script)
    var finalized: [String] = []
    var errors: [Int] = []
    for event in events {
        let keys = Script.keys(in: event.text)
        if event.final { finalized += keys }
        follower.follow(event.final ? finalized : finalized + keys)
        // Só vale medir dentro da tomada boa de cada fala; nas repetições o lugar é ambíguo.
        let t = event.end
        guard windows.contains(where: { $0.contains(t) }) else { continue }
        let truth = spokenAt.filter { $0 <= t - 0.3 }.count
        errors.append(abs(follower.position - truth))
    }
    let close = Double(errors.filter { $0 <= 4 }.count) / Double(errors.count)
    let lost = errors.filter { $0 > 15 }.count
    print("take real: \(errors.count) medidas, \(Int(close * 100))% a até 4 palavras, \(lost) perdidas, erro máximo \(errors.max()!)")
    #expect(close >= 0.8)
    #expect(lost == 0)
}
