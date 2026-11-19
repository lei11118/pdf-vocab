import Foundation
import ZIPFoundation

/// Greedy averaged perceptron POS tagger using the MIT-licensed English NLTK
/// model. Feature names match the model's training representation.
struct EnglishReadingTagger: Sendable {
    static let bundled: Self? = {
        guard let url = Bundle.main.url(forResource: "EnglishPOSTagger", withExtension: "zip"),
              let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        let directory = "averaged_perceptron_tagger_eng"
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            guard let entry = archive["\(directory)/\(directory).\(name).json"],
                  entry.uncompressedSize <= 6_000_000 else { return nil }
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            _ = try archive.extract(entry) { data.append($0) }
            return try JSONDecoder().decode(type, from: data)
        }
        do {
            guard let classes = try decode([String].self, "classes"),
                  let tagDictionary = try decode([String: String].self, "tagdict"),
                  let weights = try decode([String: [String: Double]].self, "weights"),
                  !classes.isEmpty else { return nil }
            return Self(classes: classes.sorted(), tagDictionary: tagDictionary, weights: weights)
        } catch {
            return nil
        }
    }()

    private let classes: [String]
    private let tagDictionary: [String: String]
    private let weights: [String: [String: Double]]

    func tags(for words: [String]) -> [String] {
        var expanded: [String] = []
        var origins: [Int] = []
        for word in words {
            origins.append(expanded.count)
            let normalized = word.replacingOccurrences(of: "’", with: "'")
            if normalized.lowercased().hasSuffix("n't"), normalized.count > 3 {
                expanded.append(String(normalized.dropLast(3)))
                expanded.append("n't")
            } else {
                expanded.append(normalized)
            }
        }
        let start = "-START-"
        let nextStart = "-START2-"
        let context = [start, nextStart] + expanded.map(Self.normalized) + ["-END-", "-END2-"]
        var labels: [String] = []
        labels.reserveCapacity(expanded.count)
        var previous = start
        var earlier = nextStart
        for (offset, word) in expanded.enumerated() {
            let index = offset + 2
            let label: String
            if let known = tagDictionary[word] {
                label = known
            } else {
                let current = context[index]
                let left = context[index - 1]
                let right = context[index + 1]
                let features = [
                    "bias", "i suffix \(word.suffix(3))", "i pref1 \(word.prefix(1))",
                    "i-1 tag \(previous)", "i-2 tag \(earlier)", "i tag+i-2 tag \(previous) \(earlier)",
                    "i word \(current)", "i-1 tag+i word \(previous) \(current)",
                    "i-1 word \(left)", "i-1 suffix \(left.suffix(3))", "i-2 word \(context[index - 2])",
                    "i+1 word \(right)", "i+1 suffix \(right.suffix(3))", "i+2 word \(context[index + 2])"
                ]
                var scores: [String: Double] = [:]
                for feature in features {
                    guard let vector = weights[feature] else { continue }
                    for (tag, weight) in vector { scores[tag, default: 0] += weight }
                }
                label = classes.reduce(classes[0]) { best, tag in
                    (scores[tag, default: 0], tag) > (scores[best, default: 0], best) ? tag : best
                }
            }
            labels.append(label)
            earlier = previous
            previous = label
        }
        return origins.map { labels[$0] }
    }

    private static func normalized(_ word: String) -> String {
        if word.contains("-"), !word.hasPrefix("-") { return "!HYPHEN" }
        if word.count == 4, word.allSatisfy(\.isNumber) { return "!YEAR" }
        if word.first?.isNumber == true { return "!DIGITS" }
        return word.lowercased()
    }
}

