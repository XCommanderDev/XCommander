import Testing
@testable import XCommanderCore

// MARK: - the format

@Suite("TOML reader")
struct TOMLTests {

    @Test("keys carry the line they were written on")
    func lineNumbers() {
        let (doc, problems) = TOML.parse("""
        version = 1

        [keys]
        "m m" = "make.build"
        "c d" = "code.definition"
        """, source: "config.toml")

        #expect(problems.isEmpty)
        #expect(doc.entry(at: ["keys", "m m"])?.line == 4)
        #expect(doc.entry(at: ["keys", "c d"])?.line == 5)
        #expect(doc.tables.first?.line == 3)
    }

    @Test("comments, arrays and inline tables")
    func values() {
        let (doc, problems) = TOML.parse("""
        # a comment
        version = 1
        [unbind]
        keys = ["g X", "q X"]   # too easy to hit
        [layouts.debugging]
        panes = [
          { position = 1, file = "Tests/" },
          { position = 2, file = "Sources/" },
        ]
        """, source: "config.toml")

        #expect(problems.isEmpty)
        #expect(doc.value(at: ["unbind", "keys"])?.arrayValue?.count == 2)
        #expect(doc.value(at: ["layouts", "debugging", "panes"])?.arrayValue?.count == 2)
        #expect(doc.subtables(of: ["layouts"]).first?.name == "debugging")
    }

    @Test("a broken line is reported and does not stop the rest of the file")
    func recovers() {
        let (doc, problems) = TOML.parse("""
        version = 1
        [keys]
        "m m" = make.build
        "m r" = "make.run"
        """, source: "config.toml")

        #expect(problems.count == 1)
        #expect(problems[0].line == 3)
        #expect(doc.entry(at: ["keys", "m r"]) != nil)
    }
}

// MARK: - the key syntax

@Suite("Key sequences")
struct KeySequenceTests {

    @Test("what the panel shows is what the file writes")
    func roundTrip() throws {
        for (sequence, _) in DefaultKeymap.bindings {
            let written = KeySequence.render(sequence)
            #expect(try KeySequence.parse(written) == sequence,
                    "round trip failed for \(written)")
        }
    }

    @Test("every offered leader survives the round trip")
    func leaders() throws {
        for choice in LeaderChoice.allCases {
            let written = KeySequence.render([choice.event])
            #expect(try KeySequence.parseKey(written) == choice.event)
        }
    }

    @Test("modifiers and named keys")
    func parsing() throws {
        #expect(try KeySequence.parseKey("⌥RET") == KeyEvent(.return, [.option]))
        #expect(try KeySequence.parseKey("m") == KeyEvent("m"))
        #expect(try KeySequence.parse("m m").count == 2)
        #expect(throws: KeySequence.ParseError.self) { try KeySequence.parseKey("meta") }
        #expect(throws: KeySequence.ParseError.self) { try KeySequence.parseKey("⌥") }
        #expect(throws: KeySequence.ParseError.self) { try KeySequence.parse("") }
    }
}

// MARK: - decoding one file

@Suite("Config decoder")
struct ConfigDecoderTests {

    private func decode(_ text: String) -> (ConfigDocument, [ConfigDiagnostic]) {
        ConfigDecoder.decode(ConfigSource(name: "config.toml", text: text))
    }

    @Test("a file must declare the version it was written against")
    func versionRequired() {
        let (_, problems) = decode("[keys]\n\"m m\" = \"make.build\"")
        #expect(problems.hasErrors)
        #expect(problems.contains { $0.message.contains("version = 1") })
    }

    @Test("a version this build does not understand is refused, not guessed at")
    func versionMismatch() {
        let (_, problems) = decode("version = 99")
        #expect(problems.errors.first?.message.contains("version 1") == true)
    }

    @Test("the leader is limited to the vetted list, as it is in the settings window")
    func leaderIsVetted() {
        let (good, none) = decode("version = 1\n[general]\nleader = \"⌘ESC\"")
        #expect(!none.hasErrors)
        #expect(good.leader == .commandEscape)

        let (_, problems) = decode("version = 1\n[general]\nleader = \"a\"")
        #expect(problems.errors.first?.message.contains("not an available leader") == true)
    }

    @Test("out-of-range timings are refused with the range in the message")
    func ranges() {
        let (_, problems) = decode("version = 1\n[general]\npanel-delay = 5")
        #expect(problems.errors.first?.message.contains("between 50 and 1000") == true)
    }

    @Test("ESC cannot be bound")
    func escapeIsSacred() {
        let (_, problems) = decode("version = 1\n[keys]\n\"ESC\" = \"quit.companion\"")
        #expect(problems.errors.first?.message.contains("ESC cannot be bound") == true)
    }

    @Test("an unknown section is a typo, and the message says what exists")
    func unknownSection() {
        let (_, problems) = decode("version = 1\n[kesy]\n\"m m\" = \"make.build\"")
        #expect(problems.errors.first?.message.contains("no section called [kesy]") == true)
        #expect(problems.errors.first?.message.contains("keys") == true)
    }

    @Test("unimplemented sections are recorded rather than dropped")
    func gatedSectionsAreCarried() {
        let (document, _) = decode("version = 1\n[layouts.debugging]\ndebug-area = true")
        #expect(document.gated.count == 1)
        #expect(document.gated.first?.capability.section == "layouts")
        #expect(document.gated.first?.line == 2)
    }
}

// MARK: - resolving several files against the shipped keymap

@Suite("Config resolver")
struct ConfigResolverTests {

    private let registry = DefaultKeymap.build().registry

    private func resolve(_ files: [(String, String)]) -> ConfigResolution {
        ConfigResolver.resolve(files.map { ConfigSource(name: $0.0, text: $0.1) },
                               blueprint: DefaultKeymap.blueprint,
                               registry: registry)
    }

    @Test("no files at all is the shipped keymap")
    func noConfig() {
        let resolution = resolve([])
        #expect(resolution.isUsable)
        #expect(resolution.diagnostics.isEmpty)
        #expect(resolution.keymap == DefaultKeymap.build().keymap)
    }

    @Test("a binding in the file replaces the shipped one at that sequence")
    func override() throws {
        let resolution = resolve([("config.toml", """
        version = 1
        [keys]
        "m m" = "make.test"
        """)])

        let keymap = try #require(resolution.keymap)
        #expect(keymap.entry(at: try KeySequence.parse("m m")) == .command("make.test"))
        // and everything else is still there
        #expect(keymap.entry(at: try KeySequence.parse("m r")) == .command("make.run"))
    }

    @Test("binding a prefix replaces the whole group under it")
    func replacingAGroup() throws {
        let resolution = resolve([("config.toml", """
        version = 1
        [keys]
        "m" = "make.build"
        """)])

        let keymap = try #require(resolution.keymap)
        #expect(keymap.entry(at: try KeySequence.parse("m")) == .command("make.build"))
        #expect(keymap.entry(at: try KeySequence.parse("m r")) == nil)
        #expect(resolution.diagnostics.contains { $0.severity == .notice })
    }

    @Test("unbind removes a shipped binding, and says so if there was nothing there")
    func unbind() throws {
        let resolution = resolve([("config.toml", """
        version = 1
        [unbind]
        keys = ["q X", "z z"]
        """)])

        let keymap = try #require(resolution.keymap)
        #expect(keymap.entry(at: try KeySequence.parse("q X")) == nil)
        #expect(keymap.entry(at: try KeySequence.parse("q q")) != nil)
        #expect(resolution.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("nothing to unbind")
        })
    }

    @Test("a typo in a command id names the near miss")
    func unknownCommand() {
        let resolution = resolve([("config.toml", """
        version = 1
        [keys]
        "m m" = "make.buidl"
        """)])

        #expect(!resolution.isUsable)
        #expect(resolution.diagnostics.errors.first?.message.contains("make.build") == true)
    }

    @Test("a broken file yields no keymap at all, never half of one")
    func allOrNothing() {
        let resolution = resolve([("config.toml", """
        version = 1
        [keys]
        "m m" = "make.test"
        "c d" = "code.nope"
        """)])

        #expect(resolution.keymap == nil)
        #expect(resolution.summary?.contains("Using the last good configuration") == true)
    }

    @Test("a project file layers over the global one")
    func layering() throws {
        let resolution = resolve([
            ("config.toml", "version = 1\n[keys]\n\"m m\" = \"make.build\"\n"),
            (".xcommander.toml", "version = 1\n[keys]\n\"m m\" = \"make.testNoBuild\"\n"),
        ])

        let keymap = try #require(resolution.keymap)
        #expect(keymap.entry(at: try KeySequence.parse("m m")) == .command("make.testNoBuild"))
        #expect(resolution.diagnostics.contains {
            $0.source == ".xcommander.toml" && $0.message.contains("overrides")
        })
    }

    @Test("group titles from the file reach the which-key panel")
    func groupTitles() throws {
        let resolution = resolve([("config.toml", """
        version = 1
        [groups]
        m = "build"
        [keys]
        "m z" = "make.clean"
        """)])

        let keymap = try #require(resolution.keymap)
        let rows = keymap.rows(at: [], in: registry)
        #expect(rows.contains { $0.key == "m" && $0.title == "build" })
    }

    @Test("an unimplemented section is announced and ignored, and the rest still loads")
    func unimplementedSection() {
        let text = """
        version = 1
        [keys]
        "m m" = "make.test"
        [layouts.debugging]
        debug-area = true
        """
        let resolution = resolve([("config.toml", text)])
        #expect(resolution.isUsable)
        #expect(resolution.diagnostics.contains {
            $0.severity == .warning && $0.message.contains("not implemented in this version")
        })
    }

    @Test("general settings come back for the app to apply")
    func generalSettings() {
        let resolution = resolve([("config.toml", """
        version = 1
        [general]
        leader = "⌃SPC"
        panel-delay = 200
        sequence-timeout = 15
        """)])

        #expect(resolution.leader == .controlSpace)
        #expect(resolution.overlayDelay == 0.2)
        #expect(resolution.sequenceTimeout == 15)
    }
}

@Suite("Suggestions")
struct SuggestionTests {

    @Test("a transposition is caught, which is what the fuzzy matcher cannot do")
    func transposition() {
        let ids = ["make.build", "make.run", "code.definition"]
        #expect(Suggestion.nearest("make.buidl", in: ids) == "make.build")
        // The palette's matcher is a subsequence test, and a transposition defeats it.
        #expect(FuzzyMatcher.match(query: "make.buidl", candidate: "make.build") == nil)
    }

    @Test("nothing is suggested when nothing is close")
    func noWildGuesses() {
        #expect(Suggestion.nearest("wibble", in: ["make.build", "code.definition"]) == nil)
    }
}
