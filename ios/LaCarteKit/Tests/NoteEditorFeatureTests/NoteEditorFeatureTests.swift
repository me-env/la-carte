import APIClient
import ComposableArchitecture
import Foundation
import Testing

@testable import NoteEditorFeature

@MainActor
struct NoteEditorFeatureTests {
  let person = [Note].fixtures[0]
  let laCarte = [Note].fixtures[2]
  struct Offline: Error {}

  func d(_ prompt: String, _ answer: String...) -> Direction {
    Direction(prompt: [prompt], answer: answer)
  }

  var emptyPerson: NoteEditorFeature.State {
    var state = NoteEditorFeature.State()
    state.type = .person
    state.fields = ["photo": "", "name": "", "description": ""]
    state.directions = []
    return state
  }

  @Test func aNewNoteIsBasicWithOnlyFrontToBackOn() {
    let state = NoteEditorFeature.State()
    #expect(state.type == .basic)
    #expect(state.fields == ["front": "", "back": ""])
    #expect(state.directions == [d("front")])
    #expect(state.catalog == [d("front"), d("back")])
    #expect(!state.hasChanges)
  }

  @Test func editingPrefillsEveryFieldOfTheTypeAndItsDirections() {
    let state = NoteEditorFeature.State(note: laCarte)
    #expect(state.fields == ["front": "la carte", "back": "the menu — and the map"])
    #expect(state.directions == [d("front", "back"), d("back", "front")])

    let personState = NoteEditorFeature.State(note: person)
    #expect(personState.directions == personState.catalog)
    #expect(
      personState.catalog
        == [d("photo", "name", "description"), d("name", "photo", "description"), d("description", "photo", "name")]
    )
    #expect(!personState.hasChanges)
  }

  @Test func eachDirectionAsksForEveryOtherNonEmptyField() async {
    let store = TestStore(initialState: emptyPerson) { NoteEditorFeature() }

    await store.send(.fieldChanged("name", "Ada"))  {
      $0.fields["name"] = "Ada"
    }
    await store.send(.directionToggled(d("name"))) // nothing else to recall yet
    await store.send(.fieldChanged("description", "Mistral CEO")) {
      $0.fields["description"] = "Mistral CEO"
    }
    await store.send(.directionToggled(d("name", "description"))) {
      $0.directions = [self.d("name", "description")]
    }
    await store.send(.fieldChanged("photo", "https://example.com/a.png")) {
      $0.fields["photo"] = "https://example.com/a.png"
      $0.directions = [self.d("name", "photo", "description")]
    }
    #expect(store.state.canSave)
  }

  @Test func switchingToPersonSwapsTheFieldsAndTurnsEveryDirectionOff() async {
    let store = TestStore(initialState: NoteEditorFeature.State()) { NoteEditorFeature() }

    await store.send(.fieldChanged("front", "chat")) {
      $0.fields["front"] = "chat"
    }
    await store.send(.typeChanged(.person)) {
      $0.type = .person
      $0.fields = ["photo": "", "name": "", "description": ""]
      $0.directions = []
    }
    #expect(!store.state.hasChanges)
    #expect(!store.state.canSave)
    await store.send(.typeChanged(.basic)) {
      $0.type = .basic
      $0.fields = ["front": "", "back": ""]
      $0.directions = [self.d("front")]
    }
  }

  @Test func anExistingNotesTypeIsFixed() async {
    let store = TestStore(initialState: NoteEditorFeature.State(note: laCarte)) { NoteEditorFeature() }
    await store.send(.typeChanged(.person))
  }

  @Test func directionsTheNoteHasOutsideTheCatalogAreListedAndOn() {
    var note = person
    let extra = Direction(prompt: ["photo", "description"], answer: ["name"])
    note.cards.append(Note.Card(id: UUID(), prompt: extra.prompt, answer: extra.answer, due: note.createdAt))
    let state = NoteEditorFeature.State(note: note)
    #expect(state.catalog.last == extra)
    #expect(state.directions == state.catalog)
  }

  @Test func aDirectionWithAnEmptyPromptCantBeTurnedOnButOneAlreadyOnStaysOn() async {
    let store = TestStore(initialState: NoteEditorFeature.State()) { NoteEditorFeature() }

    #expect(store.state.isUnavailable(d("back")))
    await store.send(.directionToggled(d("back")))

    await store.send(.fieldChanged("front", "chat")) {
      $0.fields["front"] = "chat"
      $0.directions = [self.d("front")]
    }
    await store.send(.fieldChanged("back", "cat")) {
      $0.fields["back"] = "cat"
      $0.directions = [self.d("front", "back")]
    }
    await store.send(.directionToggled(d("back", "front"))) {
      $0.directions = [self.d("front", "back"), self.d("back", "front")]
    }
    await store.send(.fieldChanged("back", "")) {
      $0.fields["back"] = ""
      $0.directions = [self.d("front"), self.d("back", "front")]
    }
    #expect(!store.state.isUnavailable(d("back", "front")))
    #expect(!store.state.canSave)
    await store.send(.directionToggled(d("back", "front"))) {
      $0.directions = [self.d("front")]
    }
    #expect(store.state.isUnavailable(d("back", "front")))
  }

  @Test func directionsStayInCatalogOrder() async {
    var state = emptyPerson
    state.fields = ["photo": "https://example.com/a.png", "name": "Ada", "description": "baker"]
    let store = TestStore(initialState: state) { NoteEditorFeature() }

    await store.send(.directionToggled(d("description", "photo", "name"))) {
      $0.directions = [self.d("description", "photo", "name")]
    }
    await store.send(.directionToggled(d("photo", "name", "description"))) {
      $0.directions = [self.d("photo", "name", "description"), self.d("description", "photo", "name")]
    }
  }

  @Test func saveNeedsTheNameADirectionAndAnHTTPPhoto() {
    var state = emptyPerson
    #expect(!state.canSave)

    state.fields["name"] = "Ada"
    state.fields["description"] = "runs the bakery"
    #expect(!state.canSave)  // no direction

    state.directions = [d("description", "name")]
    #expect(state.canSave)

    state.fields["photo"] = "ftp://example.com/a.png"
    #expect(!state.canSave)
    #expect(state.photoURL == nil)
    state.fields["photo"] = "example.com/a.png"
    #expect(!state.canSave)
    state.fields["photo"] = " https://example.com/a.png "
    #expect(state.canSave)
    #expect(state.photoURL == URL(string: "https://example.com/a.png"))

    state.isSaving = true
    #expect(!state.canSave)
  }

  @Test func thePhotoANoteAlreadyHasStaysValid() {
    let state = NoteEditorFeature.State(note: person)
    #expect(state.canSave)
    #expect(state.photoURL != nil)
  }

  @Test func savingANewPersonAddsItWithTheChosenDirectionsAndDismisses() async {
    let added = LockIsolated<NoteDraft?>(nil)
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: NoteEditorFeature.State()) {
      NoteEditorFeature()
    } withDependencies: { [person] in
      $0.apiClient.addNote = { draft in
        added.setValue(draft)
        return person
      }
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.typeChanged(.person)) {
      $0.type = .person
      $0.fields = ["photo": "", "name": "", "description": ""]
      $0.directions = []
    }
    await store.send(.fieldChanged("name", " Ada ")) {
      $0.fields["name"] = " Ada "
    }
    await store.send(.fieldChanged("description", "baker")) {
      $0.fields["description"] = "baker"
    }
    await store.send(.directionToggled(d("description", "name"))) {
      $0.directions = [self.d("description", "name")]
    }
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved, person)
    #expect(
      added.value
        == NoteDraft(
          type: .person,
          fields: ["photo": "", "name": "Ada", "description": "baker"],
          directions: [d("description", "name")]
        )
    )
    #expect(dismissed.value)
  }

  @Test func savingAnEditSendsEveryFieldAndTheFullDirectionSet() async {
    let patched = LockIsolated<(Note.ID, NoteDraft)?>(nil)
    let store = TestStore(initialState: NoteEditorFeature.State(note: laCarte)) {
      NoteEditorFeature()
    } withDependencies: { [laCarte] in
      $0.apiClient.updateNote = { id, draft in
        patched.setValue((id, draft))
        return laCarte
      }
      $0.dismiss = DismissEffect {}
    }

    await store.send(.directionToggled(d("front", "back"))) {
      $0.directions = [self.d("back", "front")]
    }
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved)
    #expect(patched.value?.0 == laCarte.id)
    #expect(
      patched.value?.1
        == NoteDraft(
          type: .basic, fields: ["front": "la carte", "back": "the menu — and the map"],
          directions: [d("back", "front")]
        )
    )
  }

  @Test func saveFailureKeepsTheSheetAndShowsTheError() async {
    var state = NoteEditorFeature.State()
    state.fields = ["front": "chat", "back": "cat"]
    state.directions = [d("front", "back")]
    let store = TestStore(initialState: state) {
      NoteEditorFeature()
    } withDependencies: {
      $0.apiClient.addNote = { _ in throw Offline() }
    }

    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.failure) {
      $0.isSaving = false
      $0.saveFailed = true
    }
    #expect(store.state.canSave)
  }

  @Test func anyFieldOrDirectionChangeIsUnsaved() {
    var state = NoteEditorFeature.State(note: laCarte)
    #expect(!state.hasChanges)
    state.fields["front"] = " la carte\n"
    #expect(!state.hasChanges)
    state.fields["front"] = "la carte!"
    #expect(state.hasChanges)

    state = NoteEditorFeature.State(note: laCarte)
    state.directions = [d("front", "back")]
    #expect(state.hasChanges)

    state = NoteEditorFeature.State()
    state.directions = [d("front"), d("back")]
    #expect(state.hasChanges)
  }

  @Test func closeWithoutChangesDismissesWithoutCallingTheAPI() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: NoteEditorFeature.State(note: person)) {
      NoteEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.closeButtonTapped)
    #expect(dismissed.value)
  }

  @Test func closeWithChangesAsksBeforeDiscarding() async {
    let store = TestStore(initialState: NoteEditorFeature.State(note: person)) { NoteEditorFeature() }

    await store.send(.directionToggled(d("description", "photo", "name"))) {
      $0.directions = [self.d("photo", "name", "description"), self.d("name", "photo", "description")]
    }
    await store.send(.closeButtonTapped) {
      $0.isDiscardDialogPresented = true
    }
    await store.send(\.binding.isDiscardDialogPresented, false) {
      $0.isDiscardDialogPresented = false
    }
    #expect(store.state.directions == [d("photo", "name", "description"), d("name", "photo", "description")])
  }

  @Test func discardDismisses() async {
    let dismissed = LockIsolated(false)
    var state = NoteEditorFeature.State(note: person)
    state.fields["name"] = "Ada E."
    state.isDiscardDialogPresented = true
    let store = TestStore(initialState: state) {
      NoteEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.discardTapped)
    #expect(dismissed.value)
  }

  @Test func directionRowsHaveStableIdsAndReadableLabels() {
    #expect(NoteEditorView.identifier(d("photo"), type: .person) == "photo-name+description")
    #expect(NoteEditorView.identifier(d("name", "photo"), type: .person) == "name-photo+description")
    #expect(NoteEditorView.identifier(d("back", "front"), type: .basic) == "back-front")
    #expect(NoteEditorView.label(d("photo", "name"), type: .person, side: " → ", join: " + ") == "Photo")
    #expect(NoteEditorView.label(d("back", "front"), type: .basic, side: " → ", join: " + ") == "Back → Front")
    let extra = Direction(prompt: ["photo", "description"], answer: ["name"])
    #expect(NoteEditorView.identifier(extra, type: .person) == "photo+description-name")
    #expect(NoteEditorView.label(extra, type: .person, side: " to ", join: " and ") == "Photo and Description to Name")
  }
}
