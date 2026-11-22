import XCTest

/// Specs 014c (notes in the Deck + note editor) and 014d (a note's direction in Study, photo on the card face).
/// Mock = `LA_CARTE_API=mock-notes`: basics serendipity (…01), la carte (…02, + back → front), ephemeral (…03) and the
/// made-up person "Ada Example" / "runs the bakery" (…11, 3 directions, person cards due first).
/// Stub = `StubDeck` notes + a made-up PNG served at `/photos/*.png` (never a real person).
final class NotesUITests: XCTestCase {
  static let person = "00000000-0000-0000-0000-000000000011"
  static let laCarte = "00000000-0000-0000-0000-000000000002"
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]

  override func setUp() {
    continueAfterFailure = true  // QA: collect every deviation and still take the later screenshots
  }

  // MARK: - 014c Deck

  /// 014c #1–#3: one row per note (4), a person row with its photo thumbnail (44 pt circle left of the text,
  /// label "Photo"), "N directions" for multi-card notes. #4: "bakery" finds the person.
  @MainActor
  func testNotesDeck_listAndSearch() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mockNotes)
      openDeck(app)
      waitUntil("4 note rows") { self.rowIDs(app).count == 4 }
      XCTAssertTrue(rowIDs(app).contains(Self.person.uppercased()), "no person row: \(rowIDs(app))")
      assertPersonRow(app, Self.person, name: "Ada Example", description: "runs the bakery", state: "3 directions")
      waitForLabel(el(app, "deck.row.\(Self.laCarte).state"), "2 directions")
      snapshot("deck-notes", appearance: appearance)
      if appearance == .light {
        deckSearch(app).tap()
        deckSearch(app).typeText("bakery")
        waitUntil("only the person row") { self.rowIDs(app) == [Self.person.uppercased()] }
        snapshot("deck-notes-search", appearance: appearance)
      }
      app.terminate()
    }
  }

  // MARK: - 014c editor: create, edit, delete a person

  /// 014c #7–#13, #15, #5: new note → Person; empty person = no direction on, hint, Save off, toggles needing empty
  /// fields disabled; fill photo URL (live preview loads), name, description; pick 2 directions; save → POST /notes,
  /// row with thumbnail and "2 directions". Tap → "Edit person" (no type picker), swap a direction, edit the
  /// description, save → PATCH /notes/{id} with the full direction set. Swipe-delete → DELETE /notes/{id}, row gone.
  @MainActor
  func testNoteEditor_personCreateEditDelete() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let deck = StubDeck([.init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: "greeting", back: "hello")])
      let server = StubAPIServer(handler: deck.handle)
      try server.start()
      let app = launch(api: .live(server.url))
      openDeck(app)
      waitUntil("1 row") { self.rowIDs(app).count == 1 }

      // New note: Basic by default, then Person.
      el(app, "deck.add").tap()
      waitForSheet(app, "New card")
      let basic = typeSegment(app, "Basic"), person = typeSegment(app, "Person")
      XCTAssertTrue(basic.waitFor(timeout: 3), "editor.type has no Basic segment")
      XCTAssertTrue(basic.isSelected, "Basic not selected by default")
      XCTAssertTrue(el(app, "editor.direction.front-back").isSelected, "basic default: front-back off")
      XCTAssertFalse(el(app, "editor.direction.back-front").isSelected, "basic default: back-front on (no auto reverse)")
      snapshot("editor-basic-new", appearance: appearance)
      person.tap()
      waitForSheet(app, "New person")
      for field in ["photo", "name", "description"] {
        XCTAssertTrue(el(app, "editor.\(field)").exists, "editor.\(field) missing")
      }
      XCTAssertFalse(el(app, "editor.front").exists, "editor.front still shown for a person")
      let dirs = ["photo-name+description", "name-photo+description", "description-name+photo"]
      snapshot("editor-person-new", appearance: appearance)
      scrollIntoView(app, dir(app, dirs[2]))  // Form rows below the fold aren't in the tree
      for d in dirs {
        XCTAssertTrue(el(app, "editor.direction.\(d)").exists, "editor.direction.\(d) missing (spec 014c #9 id)")
        let toggle = dir(app, d)
        XCTAssertFalse(toggle.isSelected, "new person: \(d) on by default")
        XCTAssertFalse(toggle.isEnabled, "\(d) enabled while its fields are empty")
      }
      waitForLabel(el(app, "editor.directionsHint"), "Choose at least one direction")
      XCTAssertFalse(el(app, "editor.save").isEnabled, "save enabled for an empty person")
      snapshot("editor-person-new-directions", appearance: appearance)
      app.swipeDown()

      type(app, "editor.name", "Sam Rivera")
      type(app, "editor.description", "runs the flower stall")
      type(app, "editor.photo", server.url + "/photos/sam.png")
      waitForLabel(el(app, "editor.photoPreview"), "Photo")  // loaded ("Photo, not loaded" on failure)
      scrollIntoView(app, dir(app, dirs[2]))
      dir(app, dirs[0]).tap()
      dir(app, dirs[2]).tap()
      XCTAssertTrue(poll(timeout: 3) { self.dir(app, dirs[0]).isSelected }, "\(dirs[0]) not on")
      XCTAssertTrue(dir(app, dirs[2]).isSelected, "\(dirs[2]) not on")
      XCTAssertFalse(dir(app, dirs[1]).isSelected, "\(dirs[1]) on without a tap")
      XCTAssertTrue(el(app, "editor.save").isEnabled, "save disabled for a complete person")
      app.swipeDown()  // back to the top: photo preview in the shot
      snapshot("editor-person-filled", appearance: appearance)
      el(app, "editor.save").tap()
      waitForAbsence(editorBar(app), "editor still open after saving")

      let post = try XCTUnwrap(server.requests.last { $0.method == "POST" && StubDeck.route($0.path) == "/notes" },
                               "no POST /notes")
      let body = try json(post.body)
      XCTAssertEqual(body["type"] as? String, "person")
      let fields = body["fields"] as? [String: String] ?? [:]
      XCTAssertEqual(fields["name"], "Sam Rivera")
      XCTAssertEqual(fields["description"], "runs the flower stall")
      XCTAssertEqual(fields["photo"], server.url + "/photos/sam.png")
      XCTAssertEqual(prompts(body), [["photo"], ["description"]], "POST directions: \(post.body)")
      let id = try XCTUnwrap(deck.notes.first?.id, "stub has no person note").uppercased()
      waitUntil("person row on top") { self.rowIDs(app).first == id }
      assertPersonRow(app, id, name: "Sam Rivera", description: "runs the flower stall", state: "2 directions")
      snapshot("deck-person-added", appearance: appearance)

      // Edit: no type picker, prefilled, swap description-… for name-…, change the description.
      row(app, id).tap()
      waitForSheet(app, "Edit person")
      XCTAssertFalse(el(app, "editor.type").exists, "type picker shown when editing")
      XCTAssertEqual(el(app, "editor.name").value as? String, "Sam Rivera")
      replace(app, "editor.description", with: "sells flowers")
      scrollIntoView(app, dir(app, dirs[2]))
      XCTAssertTrue(dir(app, dirs[0]).isSelected && dir(app, dirs[2]).isSelected,
                    "existing directions not on in the editor")
      dir(app, dirs[2]).tap()
      dir(app, dirs[1]).tap()
      snapshot("editor-person-edit", appearance: appearance)
      el(app, "editor.save").tap()
      waitForAbsence(editorBar(app), "editor still open after saving the edit")
      let patch = try XCTUnwrap(server.requests.last { $0.method == "PATCH" }, "no PATCH")
      XCTAssertEqual(StubDeck.route(patch.path).lowercased(), "/notes/\(id.lowercased())")
      let patchBody = try json(patch.body)
      XCTAssertEqual((patchBody["fields"] as? [String: String])?["description"], "sells flowers")
      XCTAssertEqual(Set(prompts(patchBody)), [["photo"], ["name"]], "PATCH directions: \(patch.body)")
      waitUntil("row shows the new description") { self.rowText(app, id, "sells flowers").exists }
      waitForLabel(el(app, "deck.row.\(id).state"), "2 directions")

      // Delete (014c #5).
      row(app, id).swipeLeft()
      let delete = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier ==[c] %@", "deck.row.\(id).delete")).firstMatch
      XCTAssertTrue(delete.waitFor(timeout: 3), "no delete swipe action")
      delete.tap()
      waitUntil("person row gone") { !self.rowIDs(app).contains(id) }
      XCTAssertTrue(poll(timeout: 3) {
        server.requests.contains { $0.method == "DELETE" && StubDeck.route($0.path).lowercased() == "/notes/\(id.lowercased())" }
      }, "no DELETE /notes/\(id)")
      XCTAssertTrue(deck.notes.isEmpty, "stub still has the person note")
      app.terminate()
      server.stop()
    }
  }

  // MARK: - 014d Study

  /// 014d #3–#6, #8 (mock): the person's photo → name + description card shows only the photo (no name anywhere,
  /// label "Photo"), the hint "Name and description?"; reveal shows name + description; after rating, the next
  /// card is not a sibling.
  @MainActor
  func testNotesStudy_photoPromptMock() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mockNotes)
      let photo = el(app, "study.photo")
      XCTAssertTrue(photo.waitFor(timeout: 10), "first card has no study.photo")
      XCTAssertEqual(photo.label, "Photo")
      XCTAssertTrue(el(app, "study.front").frame.contains(photo.frame), "photo not inside study.front")
      XCTAssertEqual(photo.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "photo not centered")
      // Size (240 x 300 pt) is checked on the screenshot: the element's frame is 300 x 302, wider than the drawn photo.
      assertNoText(app, ["Ada Example", "runs the bakery"], "before reveal")
      assertNoURL(app)
      waitForLabel(el(app, "study.answerHint"), "Name and description?")
      snapshot("study-person-photo", appearance: appearance)

      el(app, "study.reveal").tap()
      assertTexts(app, in: "study.back", ["Ada Example", "runs the bakery"])
      XCTAssertEqual(el(app, "study.photo").frame, photo.frame, "photo moved on reveal")
      assertNoURL(app)
      snapshot("study-person-photo-revealed", appearance: appearance)

      el(app, "study.rate.good").tap()
      XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 5), "no next card")
      XCTAssertFalse(el(app, "study.photo").exists, "next card is a photo card (sibling not buried)")
      assertNoText(app, ["Ada Example", "runs the bakery"], "next card after rating the person")
      snapshot("study-after-person", appearance: appearance)
      app.terminate()
    }
  }

  /// 014d #1, #3, #6 (stub): description → name + photo shows the description, then the photo image (not the URL)
  /// plus the name; a photo → name + description card whose description is empty shows only the name after
  /// reveal (no empty block, no URL text).
  @MainActor
  func testNotesStudy_photoAnswerAndEmptyFieldSkipped() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let server = StubAPIServer()
      try server.start()  // first: the photo URLs need its port
      let base = Date(timeIntervalSince1970: 1_767_225_600)
      let photoURL = server.url + "/photos/lee.png"
      let sam = StubDeck.Note(type: "person", fields: [
        "photo": server.url + "/photos/sam.png", "name": "Sam Rivera", "description": "runs the flower stall"],
        cards: [.init(prompt: ["description"], answer: ["name", "photo"], due: base)])
      let lee = StubDeck.Note(type: "person", fields: ["photo": photoURL, "name": "Lee Park"],
                              cards: [.init(prompt: ["photo"], answer: ["name", "description"],
                                            due: base.addingTimeInterval(60))])
      let deck = StubDeck([], notes: [sam, lee])
      server.handler = deck.handle
      let app = launch(api: .live(server.url))

      // description → name + photo
      XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 10), "no card")
      assertTexts(app, in: "study.front", ["runs the flower stall"])
      XCTAssertFalse(el(app, "study.photo").exists, "photo shown before reveal on a description prompt")
      el(app, "study.reveal").tap()
      let photo = el(app, "study.photo")
      XCTAssertTrue(photo.waitFor(timeout: 5), "no study.photo in the answer")
      waitForLabel(photo, "Photo")  // loaded
      Thread.sleep(forTimeInterval: 0.8)  // 014d: the reveal moves the prompt (0.35 s) and fades the rows in; read frames after it
      let prompt = app.staticTexts["runs the flower stall"].frame
      // 014d design 2026-11-22: every direction ends as photo, name, description (the prompt moves under the photo).
      XCTAssertLessThan(photo.frame.maxY, prompt.minY, "answer photo not above the description prompt")
      assertTexts(app, in: "study.back", ["Sam Rivera"])
      assertNoURL(app)
      snapshot("study-person-description", appearance: appearance)
      el(app, "study.rate.good").tap()

      // photo → name + (empty) description
      XCTAssertTrue(poll(timeout: 10) { self.el(app, "study.photo").exists && self.el(app, "study.reveal").exists },
                    "photo prompt card not shown")
      waitForLabel(el(app, "study.photo"), "Photo")
      assertNoText(app, ["Lee Park"], "before reveal")
      assertNoURL(app)
      el(app, "study.reveal").tap()
      assertTexts(app, in: "study.back", ["Lee Park"])
      let backTexts = el(app, "study.back").staticTexts.allElementsBoundByIndex.filter { !$0.label.isEmpty }
      XCTAssertEqual(backTexts.map(\.label), ["Lee Park"], "answer shows more than the non-empty fields")
      assertNoURL(app)
      snapshot("study-person-empty-description", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - 014d person card text (design 2026-11-22)

  /// Made-up people, one note each (no sibling burying): every direction, short and long descriptions.
  static let longDescription = "coaches the under-twelve football team on Saturday mornings and keeps the club's kit in "
    + "a shed behind the bakery"

  enum PersonPrompt { case photo, name, description }

  struct PersonCase {
    var tag: String
    var name: String
    var description: String
    var prompt: PersonPrompt
    var long: Bool { description == NotesUITests.longDescription }
  }

  static let personCases: [PersonCase] = [
    .init(tag: "photo", name: "Mia Stone", description: "runs the bakery", prompt: .photo),
    .init(tag: "name", name: "Theo Lane", description: "teaches piano", prompt: .name),
    .init(tag: "description-prompt", name: "Nora Vale", description: "repairs bicycles", prompt: .description),
    .init(tag: "long-description-prompt", name: "Iris Moreau", description: longDescription, prompt: .description),
    .init(tag: "photo-long", name: "Owen Hart", description: longDescription, prompt: .photo),
    .init(tag: "name-long", name: "Lena Brook", description: longDescription, prompt: .name),
  ]

  /// A stub deck of person notes, due in `cases` order, photos from the stub server.
  @MainActor
  private func personDeck(_ server: StubAPIServer, _ cases: [PersonCase]) -> StubDeck {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let notes = cases.enumerated().map { i, c -> StubDeck.Note in
      let fields: [String: String] = ["photo": server.url + "/photos/p\(i).png", "name": c.name,
                                      "description": c.description]
      let (prompt, answer): ([String], [String]) = switch c.prompt {
      case .photo: (["photo"], ["name", "description"])
      case .name: (["name"], ["photo", "description"])
      case .description: (["description"], ["name", "photo"])
      }
      return StubDeck.Note(type: "person", fields: fields,
                           cards: [.init(prompt: prompt, answer: answer, state: "review",
                                         due: base.addingTimeInterval(Double(i) * 60))])
    }
    return StubDeck([], notes: notes)
  }

  private func text(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  /// 014d "Person card text" + "Text prompt: the question moves on reveal", Acceptance (QA), every direction,
  /// short and long descriptions, light + dark: hint/name/description/photo centred on `study.card` (± 1 pt);
  /// photo prompt: photo frame unchanged on reveal and `study.back` top = the hint's former top; text prompt: the
  /// prompt group then the revealed group vertically centred in `study.card`, `study.front` kept on the prompt;
  /// order photo, name, description; hint gone; a 3+-line description in a block centred on the photo, ≤ 288 pt.
  @MainActor
  func testNotesStudy_personTextLayout() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let server = StubAPIServer()
      try server.start()
      let deck = personDeck(server, Self.personCases)
      server.handler = deck.handle
      let app = launch(api: .live(server.url))
      for c in Self.personCases {
        XCTContext.runActivity(named: "\(c.tag) \(appearance == .dark ? "dark" : "light")") { _ in
          checkPersonCard(app, c, appearance: appearance)
        }
        el(app, "study.rate.good").tap()
      }
      app.terminate()
      server.stop()
    }
  }

  @MainActor
  private func checkPersonCard(_ app: XCUIApplication, _ c: PersonCase, appearance: XCUIDevice.Appearance) {
    let ctx = c.tag
    let hint = el(app, "study.answerHint")
    let front = el(app, "study.front")
    let card = el(app, "study.card")
    let promptLabel = c.prompt == .name ? c.name : c.description
    switch c.prompt {
    case .photo:
      XCTAssertTrue(poll(timeout: 10) { self.el(app, "study.photo").exists && self.el(app, "study.reveal").exists },
                    "\(ctx): photo prompt not shown")
      waitForLabel(el(app, "study.photo"), "Photo")
    case .name, .description:
      XCTAssertTrue(text(app, promptLabel).waitFor(timeout: 10), "\(ctx): prompt '\(promptLabel)' not shown")
      XCTAssertFalse(el(app, "study.photo").exists, "\(ctx): photo before reveal on a text prompt")
    }
    XCTAssertTrue(hint.waitFor(timeout: 5), "\(ctx): no study.answerHint")
    Thread.sleep(forTimeInterval: 0.5)  // the card's entrance settles
    let cardF = card.frame, hintF = hint.frame, frontF = front.frame
    let photoBefore = c.prompt == .photo ? el(app, "study.photo").frame : .null
    XCTContext.runActivity(named: "before: card \(cardF) front \(frontF) hint \(hintF) photo \(photoBefore)") { _ in }
    XCTAssertEqual(hintF.midX, cardF.midX, accuracy: 1, "\(ctx): hint not centred \(hintF) in card \(cardF)")
    if c.prompt != .photo {
      XCTAssertTrue(front.frame.contains(text(app, promptLabel).frame.insetBy(dx: 1, dy: 1)),
                    "\(ctx): prompt text not in study.front")
      let group = frontF.union(hintF)
      XCTAssertEqual(group.midY, cardF.midY, accuracy: 1, "\(ctx): prompt group \(group) not vertically centred in \(cardF)")
      XCTAssertGreaterThan(hintF.minY, frontF.maxY, "\(ctx): hint not under the prompt")
    } else {
      XCTAssertEqual(photoBefore.midX, cardF.midX, accuracy: 1, "\(ctx): photo not centred")
      XCTAssertGreaterThan(hintF.minY, photoBefore.maxY, "\(ctx): hint not under the photo")
    }
    snapshot("study-person-\(c.tag)", appearance: appearance)

    el(app, "study.reveal").tap()
    XCTAssertTrue(text(app, c.name).waitFor(timeout: 5), "\(ctx): name not shown after reveal")
    XCTAssertTrue(text(app, c.description).waitFor(timeout: 5), "\(ctx): description not shown after reveal")
    let photo = el(app, "study.photo")
    XCTAssertTrue(photo.waitFor(timeout: 5), "\(ctx): no photo after reveal")
    waitForLabel(photo, "Photo")
    Thread.sleep(forTimeInterval: 0.8)  // reveal animation (0.35 s) + inserted rows' fade done
    XCTAssertTrue(!hint.exists || !hint.isHittable, "\(ctx): hint still there after reveal")
    let back = el(app, "study.back").frame, photoF = photo.frame
    let nameF = text(app, c.name).frame, descF = text(app, c.description).frame
    let frontAfter = el(app, "study.front")
    XCTContext.runActivity(named: "after: back \(back) photo \(photoF) name \(nameF) desc \(descF) front \(frontAfter.frame)") { _ in }

    // study.front stays on the prompt field (text prompts), the inserted rows are study.back + study.photo.
    if c.prompt != .photo {
      XCTAssertTrue(frontAfter.frame.insetBy(dx: -1, dy: -1).contains(text(app, promptLabel).frame),
                    "\(ctx): study.front \(frontAfter.frame) no longer holds the prompt '\(promptLabel)'")
    }
    // Order: photo, name, description.
    XCTAssertLessThanOrEqual(photoF.maxY, nameF.minY + 1, "\(ctx): name not under the photo")
    XCTAssertLessThanOrEqual(nameF.maxY, descF.minY + 1, "\(ctx): description not under the name")
    // Centring on the column.
    XCTAssertEqual(photoF.midX, cardF.midX, accuracy: 1, "\(ctx): photo not centred after reveal")
    XCTAssertEqual(nameF.midX, cardF.midX, accuracy: 1, "\(ctx): name not centred \(nameF)")
    if !c.long {
      XCTAssertEqual(descF.midX, photoF.midX, accuracy: 1, "\(ctx): description not centred on the photo \(descF)")
      XCTAssertEqual(back.midX, photoF.midX, accuracy: 1, "\(ctx): study.back not centred on the photo \(back)")
      XCTAssertEqual(back.midX, cardF.midX, accuracy: 1, "\(ctx): study.back not centred on the card \(back)")
    } else {
      // The Text's frame is its widest line, leading-aligned in the block: the block (240 + 2 × 24 = 288 pt, centred
      // on the photo) starts at photo.midX - 144; the text must start there and end inside it.
      XCTAssertEqual(descF.minX, photoF.midX - 144, accuracy: 1, "\(ctx): caption lines don't start at the block's edge \(descF)")
      XCTAssertLessThanOrEqual(descF.maxX, photoF.midX + 144 + 1, "\(ctx): caption wider than the block \(descF)")
      XCTAssertGreaterThan(descF.height, 60, "\(ctx): long description not 3+ lines \(descF)")
    }
    switch c.prompt {
    case .photo:
      XCTAssertEqual(photoF, photoBefore, "\(ctx): photo moved on reveal")
      XCTAssertEqual(back.minY, hintF.minY, accuracy: 1, "\(ctx): study.back top \(back.minY) ≠ hint's former top \(hintF.minY)")
    case .name, .description:
      let group = CGRect(x: cardF.minX, y: photoF.minY, width: 1, height: max(back.maxY, frontAfter.frame.maxY) - photoF.minY)
      XCTAssertEqual(group.midY, cardF.midY, accuracy: 1, "\(ctx): revealed group \(group.minY)…\(group.maxY) not vertically centred in \(cardF)")
    }
    snapshot("study-person-\(c.tag)-revealed", appearance: appearance)
  }

  /// 014d Motion: the name-prompt and long-description-prompt reveals for a `--record` clip (light). Pauses around
  /// each tap so the clip shows the still states; timings in the activity names (seconds since the test began).
  @MainActor
  func testNotesStudy_personRevealMotion() throws {
    try recordPersonReveals(reduceMotion: false)
  }

  /// Same with Reduce Motion on (Settings › Accessibility › Motion, set back off at the end): cross-fade in place.
  @MainActor
  func testNotesStudy_personRevealMotionReduced() throws {
    setReduceMotion(true)
    defer { setReduceMotion(false) }
    try recordPersonReveals(reduceMotion: true)
  }

  @MainActor
  private func recordPersonReveals(reduceMotion: Bool) throws {
    XCUIDevice.shared.appearance = .light
    let cases = Self.personCases.filter { $0.tag == "name" || $0.tag == "long-description-prompt" }
    let server = StubAPIServer()
    try server.start()
    server.handler = personDeck(server, cases).handle
    let app = launch(api: .live(server.url))
    let start = Date()
    let suffix = reduceMotion ? "-reduce-motion" : ""
    for c in cases {
      let prompt = c.prompt == .name ? c.name : c.description
      XCTAssertTrue(text(app, prompt).waitFor(timeout: 10), "\(c.tag): prompt not shown")
      Thread.sleep(forTimeInterval: 1.5)
      let promptBefore = text(app, prompt).frame
      XCTContext.runActivity(named: String(format: "reveal %@ at %.2f s", c.tag, Date().timeIntervalSince(start))) { _ in }
      el(app, "study.reveal").tap()
      Thread.sleep(forTimeInterval: 1.5)
      let promptAfter = text(app, prompt).frame
      XCTContext.runActivity(named: "\(c.tag) prompt \(promptBefore) → \(promptAfter)") { _ in }
      XCTAssertNotEqual(promptBefore.minY, promptAfter.minY, "\(c.tag): the prompt didn't move into the composition")
      snapshot("study-person-motion-\(c.tag)\(suffix)", appearance: .light)
      el(app, "study.rate.good").tap()
    }
    app.terminate()
    server.stop()
  }

  /// Toggles Settings › Accessibility › Motion › Reduce Motion (a simulator setting: always set back off).
  @MainActor
  private func setReduceMotion(_ on: Bool) {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.terminate()
    settings.launch()
    let accessibility = settings.staticTexts["Accessibility"].firstMatch
    for _ in 0..<6 where !(accessibility.exists && accessibility.isHittable) { settings.swipeUp() }
    accessibility.tap()
    let motion = settings.staticTexts["Motion"].firstMatch
    for _ in 0..<6 where !(motion.exists && motion.isHittable) { settings.swipeUp() }
    motion.tap()
    let toggle = settings.switches["Reduce Motion"].firstMatch
    XCTAssertTrue(toggle.waitFor(timeout: 5), "Reduce Motion switch not found")
    let isOn = { (toggle.value as? String) == "1" }
    if isOn() != on { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
    XCTAssertTrue(poll(timeout: 3) { isOn() == on }, "Reduce Motion not set to \(on)")
    settings.terminate()
  }

  // MARK: - Live API

  /// 014c #17: create a person with 2 directions in the app → `GET /notes` has it with 2 cards; delete it from the
  /// deck → `GET /notes/{id}` is 404. Net zero on the seeded deck (runs before Study's live flow).
  @MainActor
  func testNoteEditor_personCreateDelete_liveAPI() throws {
    let url = try liveURL("LA_CARTE_API_URL")
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    openDeck(app)
    waitUntil("seeded rows") { !self.rowIDs(app).isEmpty }
    el(app, "deck.add").tap()
    waitForSheet(app, "New card")
    typeSegment(app, "Person").tap()
    waitForSheet(app, "New person")
    type(app, "editor.name", "Robin Vale")
    type(app, "editor.description", "e2e test person")
    scrollIntoView(app, dir(app, "description-name+photo"))
    dir(app, "name-photo+description").tap()
    dir(app, "description-name+photo").tap()
    el(app, "editor.save").tap()
    waitForAbsence(editorBar(app), "editor still open after saving")

    let notes = try liveJSON(url + "/notes?query=robin%20vale") as? [[String: Any]] ?? []
    XCTAssertEqual(notes.count, 1, "GET /notes: \(notes)")
    let note = try XCTUnwrap(notes.first)
    let id = try XCTUnwrap(note["id"] as? String)
    XCTAssertEqual(note["type"] as? String, "person")
    XCTAssertEqual((note["cards"] as? [Any])?.count, 2, "cards: \(note)")
    waitUntil("new row") { self.rowIDs(app).contains(id.uppercased()) }
    snapshot("deck-person-live", appearance: .light)

    row(app, id).swipeLeft()
    let delete = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier ==[c] %@", "deck.row.\(id).delete")).firstMatch
    XCTAssertTrue(delete.waitFor(timeout: 3), "no delete swipe action")
    delete.tap()
    waitUntil("row gone") { !self.rowIDs(app).contains(id.uppercased()) }
    XCTAssertTrue(poll(timeout: 5) { self.liveStatus(url + "/notes/\(id)") == 404 }, "GET /notes/\(id) is not 404")
  }

  /// 014d #3 + #11 on the empty API, as amended by 015b #13/#14: a person posted via `POST /notes` with an
  /// unreachable photo URL and 2 directions; the photo-prompt card is skipped (auto-reported), the description card
  /// shows the placeholder ("Photo, not loaded") in its answer and is rated; then nothing is due. The note is deleted again, so Study's empty-deck live check still holds.
  @MainActor
  func testNotesStudy_unreachablePhoto_liveAPI() throws {
    let url = try liveURL("LA_CARTE_EMPTY_API_URL")
    let body = #"{"type":"person","fields":{"photo":"http://127.0.0.1:9/nobody.png","name":"Robin Vale","#
      + #""description":"e2e test person"},"directions":[{"prompt":["photo"]},{"prompt":["description"]}]}"#
    let created = try XCTUnwrap(liveJSON(url + "/notes", method: "POST", body: body) as? [String: Any])
    let id = try XCTUnwrap(created["id"] as? String, "POST /notes: \(created)")
    // A teardown block, not `defer`: a failed assertion (continueAfterFailure = false) skips `defer`, and the
    // leftover note would break the next tests on the empty API.
    addTeardownBlock { _ = self.liveStatus(url + "/notes/\(id)", method: "DELETE") }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    // Spec 015b #13/#14 (amended): the photo → name card can't be asked, so it's skipped and reported
    // (broken_photo, held); the description card shows the placeholder in its answer, and is reported too.
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 10), "no card")
    assertTexts(app, in: "study.front", ["e2e test person"])
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.photo"), "Photo, not loaded", timeout: 15)
    snapshot("study-photo-failed", appearance: .light)
    el(app, "study.rate.good").tap()
    _ = el(app, "study.message").waitFor(timeout: 10)
    let due = try liveJSON(url + "/cards/due") as? [Any] ?? []
    XCTAssertTrue(due.isEmpty, "a broken-photo card still due: \(due)")
    snapshot("study-person-live-done", appearance: .light)
  }

  // MARK: - Helpers

  private func liveURL(_ name: String) throws -> String {
    guard let url = ProcessInfo.processInfo.environment[name], !url.isEmpty else {
      throw XCTSkip("\(name) not set — run scripts/e2e.sh")
    }
    return url
  }

  private func liveRequest(_ url: String, method: String = "GET", body: String? = nil) -> (Int, Data?) {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = Data(body.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    nonisolated(unsafe) var result: (Int, Data?) = (0, nil)
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
      result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
      done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    return result
  }

  private func liveJSON(_ url: String, method: String = "GET", body: String? = nil) throws -> Any {
    let data = try XCTUnwrap(liveRequest(url, method: method, body: body).1, "no response from \(url)")
    return try JSONSerialization.jsonObject(with: data)
  }

  private func liveStatus(_ url: String, method: String = "GET") -> Int { liveRequest(url, method: method).0 }

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForDeckTitle(app, file: file, line: line)
  }

  @MainActor
  private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { el(app, "deck.row.\(id.uppercased())") }

  @MainActor
  private func rowText(_ app: XCUIApplication, _ id: String, _ text: String) -> XCUIElement {
    row(app, id).staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
  }

  /// Note ids of the rows, top to bottom (sub-element ids like `.photo`, `.due` skipped).
  @MainActor
  private func rowIDs(_ app: XCUIApplication) -> [String] {
    guard let root = try? app.snapshot() else { return [] }
    var rows: [(String, CGFloat)] = []
    func walk(_ node: XCUIElementSnapshot) {
      let id = node.identifier
      if id.hasPrefix("deck.row."), id.dropFirst("deck.row.".count).count == 36, !node.frame.isEmpty,
         !rows.contains(where: { $0.0 == id }) {
        rows.append((id, node.frame.minY))
      }
      node.children.forEach(walk)
    }
    walk(root)
    return rows.sorted { $0.1 < $1.1 }.map { String($0.0.dropFirst("deck.row.".count)).uppercased() }
  }

  @MainActor
  private func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
    XCTAssertTrue(poll(timeout: timeout, condition), "timed out waiting for: \(what)", file: file, line: line)
  }

  /// Person row: name + description texts, `deck.row.<id>.photo` = a ~44 pt square labelled "Photo", left of the
  /// name and vertically centered in the row, and the state meta.
  @MainActor
  private func assertPersonRow(_ app: XCUIApplication, _ id: String, name: String, description: String, state: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    waitUntil("row \(id) shows \(name)", file: file, line: line) { self.rowText(app, id, name).exists }
    XCTAssertTrue(rowText(app, id, description).exists, "row \(id) lacks '\(description)'", file: file, line: line)
    let photo = el(app, "deck.row.\(id).photo")
    XCTAssertTrue(photo.waitFor(timeout: 5), "deck.row.\(id).photo missing", file: file, line: line)
    waitForLabel(photo, "Photo", file: file, line: line)
    // 44 pt circle (+ stroke: the element measures 46 wide; its height varies with the row, checked on screenshots).
    XCTAssertEqual(photo.frame.width, 44, accuracy: 2.5, "thumbnail \(photo.frame)", file: file, line: line)
    let nameFrame = rowText(app, id, name).frame
    XCTAssertLessThan(photo.frame.maxX, nameFrame.minX, "thumbnail not left of the name", file: file, line: line)
    XCTAssertEqual(photo.frame.midY, row(app, id).frame.midY, accuracy: 3, "thumbnail not vertically centered",
                   file: file, line: line)
    waitForLabel(el(app, "deck.row.\(id).state"), state, file: file, line: line)
  }

  /// The direction row by its spec id; falls back to the id the build uses (`description-photo+name`, field order) so
  /// the rest of the flow still runs after the id mismatch is recorded.
  @MainActor
  private func dir(_ app: XCUIApplication, _ spec: String) -> XCUIElement {
    let element = el(app, "editor.direction.\(spec)")
    if element.exists || spec != "description-name+photo" { return element }
    return el(app, "editor.direction.description-photo+name")
  }

  @MainActor
  private func typeSegment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    let control = app.segmentedControls.matching(identifier: "editor.type").firstMatch
    return control.exists ? control.buttons[label] : el(app, "editor.type").buttons[label]
  }

  @MainActor
  private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
    let field = el(app, id)
    scrollIntoView(app, field)
    field.tap()
    field.typeText(text)
  }

  @MainActor
  private func replace(_ app: XCUIApplication, _ id: String, with text: String) {
    let field = el(app, id)
    scrollIntoView(app, field)
    replaceText(field, with: text)
  }

  private func json(_ body: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any], "not JSON: \(body)")
  }

  private func prompts(_ body: [String: Any]) -> [[String]] {
    (body["directions"] as? [[String: Any]] ?? []).map { $0["prompt"] as? [String] ?? [] }
  }

  /// Each text is on screen inside the container `id`.
  @MainActor
  private func assertTexts(_ app: XCUIApplication, in id: String, _ texts: [String],
                           file: StaticString = #filePath, line: UInt = #line) {
    for text in texts {
      let t = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
      XCTAssertTrue(t.waitFor(timeout: 5), "'\(text)' not on screen", file: file, line: line)
      XCTAssertTrue(el(app, id).frame.insetBy(dx: -1, dy: -1).contains(t.frame), "'\(text)' \(t.frame) not in \(id)",
                    file: file, line: line)
    }
  }

  /// None of `texts` anywhere in the accessibility tree (labels or values).
  @MainActor
  private func assertNoText(_ app: XCUIApplication, _ texts: [String], _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    for text in texts {
      let hit = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
      XCTAssertFalse(hit.exists, "'\(text)' on screen \(context)", file: file, line: line)
    }
  }

  /// The photo URL is never rendered as text.
  @MainActor
  private func assertNoURL(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let hit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'http' OR label CONTAINS 'data:image'"))
      .firstMatch
    XCTAssertFalse(hit.exists, "URL shown as text: '\(hit.exists ? hit.label : "")'", file: file, line: line)
  }
}

