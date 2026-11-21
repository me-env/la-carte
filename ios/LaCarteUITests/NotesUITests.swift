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
      XCTAssertEqual(dir(app, dirs[0]).label, "Photo → Name + Description")
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
      let prompt = app.staticTexts["runs the flower stall"].frame
      XCTAssertGreaterThan(photo.frame.minY, prompt.maxY, "answer photo not below the prompt")
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

  /// 014d #3 + #11 on the empty API: a person posted via `POST /notes` with an unreachable photo URL and 2
  /// directions; the app shows the placeholder ("Photo, not loaded"), reveals and rates; then the sibling is not in
  /// `GET /cards/due` (burying). The note is deleted again, so Study's empty-deck live check still holds.
  @MainActor
  func testNotesStudy_unreachablePhoto_liveAPI() throws {
    let url = try liveURL("LA_CARTE_EMPTY_API_URL")
    let body = #"{"type":"person","fields":{"photo":"http://127.0.0.1:9/nobody.png","name":"Robin Vale","#
      + #""description":"e2e test person"},"directions":[{"prompt":["photo"]},{"prompt":["description"]}]}"#
    let created = try XCTUnwrap(liveJSON(url + "/notes", method: "POST", body: body) as? [String: Any])
    let id = try XCTUnwrap(created["id"] as? String, "POST /notes: \(created)")
    defer { _ = liveStatus(url + "/notes/\(id)", method: "DELETE") }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 10), "no card")
    if el(app, "study.photo").exists {
      waitForLabel(el(app, "study.photo"), "Photo, not loaded", timeout: 15)
      snapshot("study-photo-failed", appearance: .light)
      el(app, "study.reveal").tap()
      assertTexts(app, in: "study.back", ["Robin Vale", "e2e test person"])
    } else {
      assertTexts(app, in: "study.front", ["e2e test person"])
      el(app, "study.reveal").tap()
      waitForLabel(el(app, "study.photo"), "Photo, not loaded", timeout: 15)
      snapshot("study-photo-failed", appearance: .light)
    }
    el(app, "study.rate.good").tap()
    _ = el(app, "study.message").waitFor(timeout: 10)
    let due = try liveJSON(url + "/cards/due") as? [Any] ?? []
    XCTAssertTrue(due.isEmpty, "sibling still due after rating: \(due)")
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
    let old = field.value as? String ?? ""
    field.tap()
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
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

