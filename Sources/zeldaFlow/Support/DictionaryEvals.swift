import Foundation

/// Deterministic pins for the learn-from-corrections loop (ADR 0037): the
/// correction detector's word diff, the fail-closed guards, the LearnedWords
/// correction records, the replacement engine, the prompt glossary cap, and
/// the one interaction that could silently eat speech — a growing dictionary
/// versus HallucinationFilter's prompt-echo scrub.
/// Run with `zeldaFlow --evaldictionary`. No LLM, no AX, no permissions.
enum DictionaryEvals {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print(pass ? "  ok  \(name)" : "FAIL  \(name)")
            if !pass { failures += 1 }
        }
        func detect(_ inserted: String, _ field: String,
                    words: [String] = [], reps: [String: String] = [:])
            -> CorrectionDetector.Candidate? {
            CorrectionDetector.detect(inserted: inserted, fieldValue: field,
                                      knownWords: words, knownReplacements: reps)
        }

        print("zeldaFlow dictionary evals")

        // ---- Detection: the happy path -------------------------------------
        var c = detect("I met the cubecon organizers today",
                       "Some earlier text. I met the KubeCon organizers today. More typing after.")
        check("single retype detected inside a larger field",
              c?.from == "cubecon" && c?.to == "KubeCon")

        c = detect("please ping the sindy team about it",
                   "please ping the Cindy team about it")
        check("respelled name detected", c?.from == "sindy" && c?.to == "Cindy")

        c = detect("we use the github actions runner",
                   "we use the GitHub actions runner")
        check("case-only correction detected", c?.from == "github" && c?.to == "GitHub")

        c = detect("I met the cubecon organizers today",
                   "I met the KubeCon organizers today. Then I wrote two more sentences. Completely unrelated words follow here.")
        check("anchor tolerance: detection survives trailing typing",
              c?.from == "cubecon" && c?.to == "KubeCon")

        // ---- Fail closed ---------------------------------------------------
        check("unchanged text → nil",
              detect("I met the coupon organizers today",
                     "Notes so far. I met the coupon organizers today.") == nil)
        check("empty field → nil", detect("I met the coupon organizers today", "") == nil)
        check("unrelated field (no anchors) → nil",
              detect("I met the coupon organizers today",
                     "A shopping list. Milk, eggs, coffee beans, some bread.") == nil)
        check("short insert (under four words) → nil",
              detect("hi coupon team", "hi KubeCon team") == nil)
        check("full rewrite of the region → nil",
              detect("we should ship the beta on monday morning I think",
                     "we should completely rework everything about scheduling honestly speaking friends") == nil)
        check("privacy bound: span grown past the insert → nil",
              detect("I met the coupon organizers today",
                     "I met the actual real conference which is called KubeCon and its many organizers plus stragglers today") == nil)

        // ---- Similarity gate ----------------------------------------------
        check("content edit rejected (tomorrow→Friday)",
              !CorrectionDetector.isLikelyCorrection(from: "tomorrow", to: "Friday"))
        check("case-only accepted (github→GitHub)",
              CorrectionDetector.isLikelyCorrection(from: "github", to: "GitHub"))
        check("capitalization accepted (kubernetes→Kubernetes)",
              CorrectionDetector.isLikelyCorrection(from: "kubernetes", to: "Kubernetes"))
        check("phonetic respelling accepted (cubecon→KubeCon)",
              CorrectionDetector.isLikelyCorrection(from: "cubecon", to: "KubeCon"))
        check("sound-alike first-letter change accepted (sindy→Cindy)",
              CorrectionDetector.isLikelyCorrection(from: "sindy", to: "Cindy"))
        check("identical word rejected",
              !CorrectionDetector.isLikelyCorrection(from: "same", to: "same"))
        check("different first letter rejected (cat→hat is a content edit)",
              !CorrectionDetector.isLikelyCorrection(from: "cat", to: "hat"))
        check("known dictionary word produces no candidate",
              detect("I met the kubecon organizers today",
                     "I met the KubeCon organizers today", words: ["KubeCon"]) == nil)
        check("already-mapped word produces no candidate",
              detect("I met the cubecon organizers today",
                     "I met the KubeCon organizers today",
                     reps: ["cubecon": "KubeCon"]) == nil)

        // ---- LearnedWords correction records (scratch store) ---------------
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zf-dict-evals-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("learned-words.json")

        let learned = LearnedWords(file: store)
        learned.recordCorrection(from: "coupon", to: "KubeCon")
        learned.recordCorrection(from: "coupon", to: "KubeCon")
        check("correction recorded once, count bumped",
              learned.correctionSuggestions.count == 1
              && learned.correctionSuggestions.first?.count == 2)
        learned.dismissCorrection(from: "coupon", to: "KubeCon")
        learned.recordCorrection(from: "Coupon", to: "kubecon")
        check("pair dismissal permanent and case-insensitive",
              learned.correctionSuggestions.isEmpty)

        let reloaded = LearnedWords(file: store)
        reloaded.recordCorrection(from: "coupon", to: "KubeCon")
        check("dismissal survives reload", reloaded.correctionSuggestions.isEmpty)

        // Old-format blob (no correction fields) must still decode.
        let oldBlob = #"{"counts":{"Kubernetes":3},"dismissed":["zelda"]}"#
        let oldFile = dir.appendingPathComponent("old-learned-words.json")
        try? oldBlob.data(using: .utf8)?.write(to: oldFile)
        let old = LearnedWords(file: oldFile)
        old.recordCorrection(from: "sindy", to: "Cindy")
        check("pre-0037 learned-words.json decodes; corrections start empty then record",
              old.correctionSuggestions.count == 1)

        // ---- Glossary distinctiveness bar ----------------------------------
        check("short word stays replacement-only", !LearnedWords.belongsInGlossary("Bo"))
        check("common word stays replacement-only", !LearnedWords.belongsInGlossary("their"))
        check("distinctive word earns the glossary", LearnedWords.belongsInGlossary("KubeCon"))

        // ---- Replacement engine -------------------------------------------
        let reps = ["coupon": "KubeCon"]
        check("replacement maps case-insensitively",
              Replacements.apply(reps, to: "The Coupon talk") == "The KubeCon talk")
        check("replacement is whole-word (coupons survives)",
              Replacements.apply(reps, to: "clip those coupons") == "clip those coupons")
        check("empty from-key ignored",
              Replacements.apply(["": "x"], to: "unchanged") == "unchanged")

        // ---- Prompt glossary cap (HallucinationFilter kill radius) ---------
        let hundred = (1...100).map { "Word\($0)" }
        let capped = AppSettings.sttPrompt(base: "Base.", dictionary: hundred)
        check("prompt carries only the newest \(AppSettings.promptGlossaryCap) words",
              !capped.contains("Word60") && capped.contains("Word61")
              && capped.contains("Word100"))
        check("empty dictionary adds no glossary clause",
              AppSettings.sttPrompt(base: "Base.", dictionary: []) == "Base.")

        // ---- Filter interaction: a learned word must not eat real speech ---
        let prompt = AppSettings.sttPrompt(
            base: "This is a carefully punctuated dictated note.",
            dictionary: ["zeldaFlow", "KubeCon"])
        check("legit sentence with a glossary word survives the final scrub",
              HallucinationFilter.scrubFinal("I'll be at KubeCon next week.", prompt: prompt)
              == "I'll be at KubeCon next week.")
        check("glossary recitation is still scrubbed",
              HallucinationFilter.scrubFinal("Glossary: zeldaFlow, KubeCon.", prompt: prompt)
                .isEmpty)
        check("looped glossary echo is still scrubbed",
              HallucinationFilter.scrubFinal("KubeCon, KubeCon.", prompt: prompt).isEmpty)

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        return failures == 0 ? 0 : 1
    }
}
