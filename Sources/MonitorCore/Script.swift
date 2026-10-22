import Foundation

/// Roteiro colado em Markdown: blocos para a tela e palavras para acompanhar a fala.
///
/// Só o que um roteiro usa: títulos (`#`), parágrafos, listas (`-`, `*`, `1.`) e citações (`>`),
/// com negrito, itálico e código dentro da linha. As palavras são contadas no texto já
/// renderizado, então os intervalos de cada uma servem direto para pintar o `AttributedString`.
public struct Script: Equatable {
    public enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case bullet
        case numbered(String)
        case quote
    }

    public struct Block: Equatable, Identifiable {
        public var id: Int
        public var kind: Kind
        public var text: AttributedString
        /// Índices em `words` das palavras deste bloco.
        public var words: Range<Int>
    }

    public struct Word: Equatable {
        /// Forma de comparar com a fala: minúscula, sem acento.
        public var key: String
        public var block: Int
        /// Posição no texto do bloco, em caracteres.
        public var range: Range<Int>
        public var sentence: Int
    }

    public private(set) var blocks: [Block] = []
    public private(set) var words: [Word] = []
    /// Cada frase como intervalo de índices em `words`.
    public private(set) var sentences: [Range<Int>] = []

    public init(markdown: String) {
        for (kind, source) in Self.blockSources(markdown) {
            let text = Self.inline(source)
            let id = blocks.count
            let first = words.count
            appendWords(of: String(text.characters), block: id)
            blocks.append(Block(id: id, kind: kind, text: text, words: first..<words.count))
        }
    }

    public var isEmpty: Bool { words.isEmpty }

    /// Frase que contém a palavra `index`; no fim do roteiro, a última.
    public func sentence(containing index: Int) -> Int? {
        guard !words.isEmpty else { return nil }
        return words[min(max(index, 0), words.count - 1)].sentence
    }

    /// Normaliza uma palavra para comparar com o que o reconhecedor ouviu.
    public static func key(_ word: some StringProtocol) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Separa um texto qualquer (o que o reconhecedor devolve) nas mesmas chaves do roteiro.
    public static func keys(in text: String) -> [String] {
        tokens(in: text).map { key($0.text) }.filter { !$0.isEmpty }
    }

    // MARK: - Palavras e frases

    /// Cada bloco fecha a frase no fim, mesmo sem ponto: título e item de lista também contam.
    private mutating func appendWords(of text: String, block: Int) {
        var sentenceOpen = false
        for token in Self.tokens(in: text) {
            let key = Self.key(token.text)
            guard !key.isEmpty else { continue }
            if !sentenceOpen {
                sentences.append(words.count..<words.count)
                sentenceOpen = true
            }
            words.append(Word(key: key, block: block, range: token.range, sentence: sentences.count - 1))
            sentences[sentences.count - 1] = sentences[sentences.count - 1].lowerBound..<words.count
            if token.endsSentence { sentenceOpen = false }
        }
    }

    struct Token {
        var text: Substring
        var range: Range<Int>
        var endsSentence: Bool
    }

    /// Palavras são sequências de letras e números; apóstrofo e hífen entre letras ficam
    /// dentro ("d'água", "guarda-chuva"). Ponto, exclamação, interrogação e reticências depois
    /// da palavra fecham a frase.
    static func tokens(in text: String) -> [Token] {
        let chars = Array(text)
        var result: [Token] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isLetter || chars[i].isNumber else { i += 1; continue }
            var j = i + 1
            while j < chars.count {
                if chars[j].isLetter || chars[j].isNumber {
                    j += 1
                } else if "'’-".contains(chars[j]), j + 1 < chars.count, chars[j + 1].isLetter || chars[j + 1].isNumber {
                    j += 2
                } else {
                    break
                }
            }
            var k = j
            var ends = false
            while k < chars.count, !(chars[k].isLetter || chars[k].isNumber) {
                if ".!?…".contains(chars[k]) { ends = true }
                k += 1
            }
            let start = text.index(text.startIndex, offsetBy: i)
            let end = text.index(start, offsetBy: j - i)
            result.append(Token(text: text[start..<end], range: i..<j, endsSentence: ends))
            i = j
        }
        if !result.isEmpty { result[result.count - 1].endsSentence = true }
        return result
    }

    // MARK: - Markdown

    /// Divide o texto em blocos. Linhas seguidas formam um parágrafo; linha em branco, título,
    /// item de lista ou citação começam outro.
    static func blockSources(_ markdown: String) -> [(Kind, String)] {
        var result: [(Kind, String)] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append((.paragraph, paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || line == "---" || line == "***" {
                flush()
                continue
            }
            if let (level, rest) = heading(line) {
                flush()
                result.append((.heading(level), rest))
            } else if let rest = prefixed(line, by: ["- ", "* ", "+ "]) {
                flush()
                result.append((.bullet, rest))
            } else if let (number, rest) = numbered(line) {
                flush()
                result.append((.numbered(number), rest))
            } else if line.hasPrefix(">") {
                flush()
                result.append((.quote, String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func prefixed(_ line: String, by markers: [String]) -> String? {
        markers.first(where: line.hasPrefix).map { String(line.dropFirst($0.count)) }
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    /// Negrito, itálico, código e links dentro da linha; o que não for Markdown válido fica como texto.
    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}
