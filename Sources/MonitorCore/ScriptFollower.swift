import Foundation

/// Acompanha onde a fala está no roteiro.
///
/// A cada resultado do reconhecedor, compara as últimas palavras ouvidas com um trecho do
/// roteiro em volta da posição atual (alinhamento local, como Smith-Waterman) e move o
/// marcador para depois da última palavra que casou. O trecho começa na frase anterior, então
/// recomeçar uma frase leva o marcador de volta; pular uma fala inteira para a frente também
/// funciona, desde que várias palavras casem. Com pouca evidência, o marcador fica onde está:
/// perder o lugar é pior que não andar.
public struct ScriptFollower {
    /// Índice da próxima palavra a ser dita; as anteriores já foram faladas.
    public private(set) var position = 0

    private let keys: [String]
    private let sentenceOf: [Int]
    private let sentences: [Range<Int>]

    /// Quantas palavras ouvidas entram na comparação.
    static let tail = 8
    /// Quantas palavras à frente da posição o marcador pode saltar.
    static let lookahead = 40
    /// Quantas palavras atrás, no mínimo, uma regravação pode levar o marcador.
    static let lookbehind = 20

    public init(script: Script) {
        keys = script.words.map(\.key)
        sentenceOf = script.words.map(\.sentence)
        sentences = script.sentences
    }

    /// Leva o marcador para uma palavra (clique, teclado ou começo do roteiro).
    public mutating func move(to index: Int) {
        position = min(max(index, 0), keys.count)
    }

    /// Processa o que foi ouvido até agora, mais recente por último. Devolve se o marcador mudou.
    @discardableResult
    public mutating func follow(_ heard: [String]) -> Bool {
        let heard = Array(heard.suffix(Self.tail))
        guard !heard.isEmpty, !keys.isEmpty else { return false }
        // Para trás, a frase anterior inteira e pelo menos `lookbehind` palavras: frases curtas
        // ("E tem um bônus.") não podem esconder o começo de uma regravação.
        let current = sentenceOf[min(position, keys.count - 1)]
        let lower = max(min(sentences[max(current - 1, 0)].lowerBound, position - Self.lookbehind), 0)
        let upper = min(position + Self.lookahead, keys.count)
        guard lower < upper, let match = Self.align(heard, Array(keys[lower..<upper])) else { return false }

        let next = lower + match.end + 1
        // Voltar ou saltar longe pede mais evidência que seguir em frente.
        let backwards = next < position - 1
        let farAhead = next > position + 12
        let needed = backwards || farAhead ? 3 : 2
        guard match.matches >= needed, match.longMatches >= 1, next != position else { return false }
        position = next
        return true
    }

    struct Match {
        var score: Double
        /// Índice (no trecho) da última palavra do roteiro que casou.
        var end: Int
        var matches: Int
        var longMatches: Int
    }

    /// Alinhamento local das palavras ouvidas contra o trecho do roteiro. O melhor alinhamento
    /// precisa casar uma das duas últimas palavras ouvidas: é o fim da fala que diz onde estamos.
    static func align(_ heard: [String], _ script: [String]) -> Match? {
        let m = heard.count
        let n = script.count
        guard m > 0, n > 0 else { return nil }
        struct Cell {
            var score = 0.0
            var matches = 0
            var long = 0
            var end = -1
            /// Índice da última palavra ouvida que casou.
            var heard = -1
        }
        var table = Array(repeating: Array(repeating: Cell(), count: n + 1), count: m + 1)
        var best: Match?
        for i in 1...m {
            for j in 1...n {
                var cell = Cell()
                let diagonal = table[i - 1][j - 1]
                let similarity = similarity(heard[i - 1], script[j - 1], isLast: i == m)
                if similarity > 0 {
                    cell = Cell(
                        score: diagonal.score + similarity, matches: diagonal.matches + 1,
                        long: diagonal.long + (script[j - 1].count >= 4 ? 1 : 0), end: j - 1, heard: i - 1)
                } else {
                    cell = diagonal
                    cell.score -= 2
                }
                // Palavra ouvida que não está no roteiro ("é", "aí", erro do reconhecedor).
                let up = table[i - 1][j]
                if up.score - 1 > cell.score { cell = up; cell.score -= 1 }
                // Palavra do roteiro que não foi dita.
                let left = table[i][j - 1]
                if left.score - 1 > cell.score { cell = left; cell.score -= 1 }
                if cell.score <= 0 { cell = Cell() }
                table[i][j] = cell
                // O casamento tem de chegar ao que acabou de ser dito (no máximo uma palavra
                // estranha no fim); um trecho antigo que casa bem não vale como posição atual.
                guard cell.heard >= m - 2, cell.score >= 5 else { continue }
                if best == nil || cell.score > best!.score {
                    best = Match(score: cell.score, end: cell.end, matches: cell.matches, longMatches: cell.long)
                }
            }
        }
        return best
    }

    /// Peso de uma palavra igual: palavras curtas ("o", "de", "que") casam em qualquer lugar e
    /// valem menos. Parecida (um erro do reconhecedor) vale menos que igual; a última palavra
    /// ouvida pode estar pela metade, então começo de palavra também conta.
    static func similarity(_ heard: String, _ word: String, isLast: Bool) -> Double {
        let weight: Double = word.count <= 2 ? 1 : word.count == 3 ? 2 : 3
        if heard == word { return weight }
        if word.count >= 4, heard.count >= 4, editDistance(heard, word, limit: word.count >= 7 ? 2 : 1) {
            return weight * 0.7
        }
        if isLast, heard.count >= 3, word.count > heard.count, word.hasPrefix(heard) { return weight * 0.6 }
        return 0
    }

    /// Se a distância de edição entre as duas palavras é no máximo `limit`.
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Bool {
        let a = Array(a)
        let b = Array(b)
        guard abs(a.count - b.count) <= limit else { return false }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            guard row.min()! <= limit else { return false }
            previous = row
        }
        return previous[b.count] <= limit
    }
}
