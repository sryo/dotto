import Foundation

/// The words, phrases and substrings that mark a label or item text as risky, per SafetyRiskCategory.
/// Kept apart from SafetyGate: the vocabulary grows with new languages and apps, while the verdict rules change rarely.
enum SafetyRiskVocabulary {
    // Whole-word keywords, matched after lowercasing and stripping plural/-ing endings (see candidateStems).
    // Past tenses are deliberately not matched: "Deleted Items" and "Sent" are folders, not actions.
    static let riskCategoryByKeyword: [String: SafetyRiskCategory] = {
        var categoryByKeyword: [String: SafetyRiskCategory] = [:]
        func assign(_ category: SafetyRiskCategory, _ keywords: [String]) {
            for keyword in keywords { categoryByKeyword[keyword] = category }
        }
        assign(.sendingOrPublishing, [
            "send", "post", "publish", "schedule", "tweet", "retweet", "reply", "share",
            // es / pt
            "enviar", "envía", "envia", "publicar", "responder", "compartir", "compartilhar", "reenviar", "programar",
            // de
            "senden", "absenden", "versenden", "veröffentlichen", "posten", "antworten", "teilen", "weiterleiten",
            // fr
            "envoyer", "publier", "répondre", "partager", "transférer",
            // it
            "invia", "inviare", "pubblica", "pubblicare", "rispondi", "rispondere", "condividi", "condividere", "inoltra",
        ])
        assign(.deleting, [
            "delete", "remove", "trash", "erase", "discard", "archive", "unsubscribe", "destroy", "wipe", "purge",
            "eliminar", "borrar", "suprimir", "apagar", "excluir", "remover", "descartar", "archivar", "arquivar",
            "löschen", "entfernen", "verwerfen", "archivieren", "papierkorb",
            "supprimer", "effacer", "retirer", "archiver", "corbeille",
            "elimina", "eliminare", "cancella", "cancellare", "rimuovi", "rimuovere", "archivia", "cestino",
        ])
        assign(.payingOrBuying, [
            "pay", "buy", "purchase", "checkout", "transfer", "donate", "subscribe",
            "comprar", "pagar", "transferir", "suscribir",
            "kaufen", "bezahlen", "zahlen", "bestellen", "überweisen", "kasse",
            "acheter", "payer", "commander", "virement",
            "acquista", "acquistare", "compra", "paga", "pagare", "ordina", "ordinare", "bonifico",
        ])
        assign(.submittingOrApproving, [
            "submit", "confirm", "accept", "approve", "sign", "merge", "deploy", "upload", "replace", "grant", "authorize",
            "authorise", "allow", "agree", "finalize", "finalise",
            "confirmar", "aceptar", "aceitar", "aprobar", "aprovar", "firmar", "assinar", "reemplazar", "substituir",
            "bestätigen", "akzeptieren", "genehmigen", "unterschreiben", "zusammenführen", "ersetzen", "hochladen",
            "confirmer", "accepter", "approuver", "signer", "valider", "remplacer", "téléverser",
            "conferma", "confermare", "accetta", "accettare", "approva", "approvare", "firma", "firmare", "sostituisci",
        ])
        return categoryByKeyword
    }()

    /// Multi-word phrases, matched against the space-joined lowercase words (apostrophes removed, so "don't" is "dont").
    static let riskCategoryByPhrase: [String: SafetyRiskCategory] = [
        "place order": .payingOrBuying, "place your order": .payingOrBuying, "order now": .payingOrBuying,
        "check out": .payingOrBuying, "buy now": .payingOrBuying, "pay now": .payingOrBuying,
        "move to bin": .deleting, "move to trash": .deleting, "move to the bin": .deleting, "move to the trash": .deleting,
        "dont save": .deleting, "do not save": .deleting, "empty bin": .deleting, "empty trash": .deleting,
        "nicht sichern": .deleting, "nicht speichern": .deleting, "ne pas enregistrer": .deleting, "no guardar": .deleting,
    ]

    /// Scripts without spaces between words (Japanese, Chinese, Korean) are matched as substrings.
    static let riskCategoryBySubstring: [String: SafetyRiskCategory] = [
        "送信": .sendingOrPublishing, "投稿": .sendingOrPublishing, "返信": .sendingOrPublishing, "共有": .sendingOrPublishing,
        "発送": .sendingOrPublishing, "发送": .sendingOrPublishing, "發送": .sendingOrPublishing, "发布": .sendingOrPublishing,
        "發佈": .sendingOrPublishing, "回复": .sendingOrPublishing, "分享": .sendingOrPublishing, "傳送": .sendingOrPublishing,
        "보내기": .sendingOrPublishing, "전송": .sendingOrPublishing, "게시": .sendingOrPublishing,
        "削除": .deleting, "消去": .deleting, "删除": .deleting, "刪除": .deleting, "移除": .deleting, "ゴミ箱": .deleting,
        "삭제": .deleting,
        "購入": .payingOrBuying, "支払": .payingOrBuying, "注文": .payingOrBuying, "购买": .payingOrBuying, "購買": .payingOrBuying,
        "支付": .payingOrBuying, "付款": .payingOrBuying, "下单": .payingOrBuying, "转账": .payingOrBuying, "구매": .payingOrBuying,
        "결제": .payingOrBuying,
        "承認": .submittingOrApproving, "確定": .submittingOrApproving, "提交": .submittingOrApproving, "确认": .submittingOrApproving,
        "批准": .submittingOrApproving, "同意": .submittingOrApproving, "제출": .submittingOrApproving,
    ]

    /// The first match whose category asks the user, or else the first match: "Confirm and delete" must ask as a
    /// delete, not run as a confirmation.
    static func firstRiskMatch(in text: String) -> SafetyRiskMatch? {
        mostSevereRiskMatch(among: riskMatches(in: text))
    }

    /// Prefers a match whose category asks (`SafetyRiskCategory.asksUser`), keeping the order otherwise.
    static func mostSevereRiskMatch(among riskMatches: [SafetyRiskMatch]) -> SafetyRiskMatch? {
        riskMatches.first(where: \.riskCategory.asksUser) ?? riskMatches.first
    }

    /// Every match, in order: substrings, then phrases, then words.
    static func riskMatches(in text: String) -> [SafetyRiskMatch] {
        var riskMatches: [SafetyRiskMatch] = []
        let lowercasedText = text.lowercased()
        for riskySubstring in riskCategoryBySubstring.keys.sorted() where lowercasedText.contains(riskySubstring) {
            riskMatches.append(SafetyRiskMatch(matchedText: riskySubstring, riskCategory: riskCategoryBySubstring[riskySubstring] ?? .irreversibleItem))
        }
        let textWithoutApostrophes = lowercasedText.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        let lowercasedWords = textWithoutApostrophes.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let spaceJoinedWords = " " + lowercasedWords.joined(separator: " ") + " "
        for riskyPhrase in riskCategoryByPhrase.keys.sorted() where spaceJoinedWords.contains(" \(riskyPhrase) ") {
            riskMatches.append(SafetyRiskMatch(matchedText: riskyPhrase, riskCategory: riskCategoryByPhrase[riskyPhrase] ?? .irreversibleItem))
        }
        for word in lowercasedWords {
            if let riskCategory = candidateStems(of: word).lazy.compactMap({ riskCategoryByKeyword[$0] }).first {
                riskMatches.append(SafetyRiskMatch(matchedText: word, riskCategory: riskCategory))
            }
        }
        return riskMatches
    }

    /// "sends"/"publishes" → verb, "sending"/"deleting"/"submitting" → verb, so progressive button titles
    /// ("Sending…") and plural labels still match.
    private static func candidateStems(of word: String) -> [String] {
        var candidateStems = [word]
        if word.hasSuffix("s") { candidateStems.append(String(word.dropLast())) }
        if word.hasSuffix("es") { candidateStems.append(String(word.dropLast(2))) }
        if word.hasSuffix("ing"), word.count > 4 {
            let stemWithoutIng = String(word.dropLast(3))
            candidateStems.append(stemWithoutIng)
            candidateStems.append(stemWithoutIng + "e")
            if let lastCharacter = stemWithoutIng.last, stemWithoutIng.dropLast().last == lastCharacter {
                candidateStems.append(String(stemWithoutIng.dropLast()))
            }
        }
        return candidateStems
    }

    /// Scans everything the planner wrote for an item, including parameter names and values.
    static func firstRiskMatch(inChecklistItemLabel label: String, actionSummary: String,
                               parameters: [ChecklistItemParameter]) -> SafetyRiskMatch? {
        let checklistItemTexts = [label, actionSummary] + parameters.flatMap { [$0.name, $0.value] }
        return mostSevereRiskMatch(among: checklistItemTexts.flatMap { riskMatches(in: $0) })
    }
}
