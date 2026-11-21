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

  let frontBack = Direction(prompt: ["front"], answer: ["back"])
  let backFront = Direction(prompt: ["back"], answer: ["front"])
  let photoName = Direction(prompt: ["photo"], answer: ["name"])
  let photoNameRole = Direction(prompt: ["photo"], answer: ["name", "role"])
  let roleName = Direction(prompt: ["role"], answer: ["name"])

  @Test func aNewNoteIsBasicWithOnlyFrontToBackOn() {
    let state = NoteEditorFeature.State()
    #expect(state.type == .basic)
    #expect(state.fields == ["front": "", "back": ""])
    #expect(state.directions == [frontBack])
    #expect(state.catalog == [frontBack, backFront])
    #expect(!state.hasChanges)
  }

  @Test func editingPrefillsEveryFieldOfTheTypeAndItsDirections() {
    let state = NoteEditorFeature.State(note: laCarte)
    #expect(state.fields == ["front": "la carte", "back": "the menu — and the map"])
    #expect(state.directions == [frontBack, backFront])

    var noRole = person
    noRole.fields["role"] = nil
    let personState = NoteEditorFeature.State(note: noRole)
    #expect(personState.fields["role"] == "")
    #expect(personState.directions == [photoName, roleName])
    #expect(personState.catalog == [photoName, photoNameRole, roleName])
  }

  @Test func switchingToPersonSwapsTheFieldsAndTurnsEveryDirectionOff() async {
    let store = TestStore(initialState: NoteEditorFeature.State()) { NoteEditorFeature() }

    await store.send(.fieldChanged("front", "chat")) {
      $0.fields["front"] = "chat"
    }
    await store.send(.typeChanged(.person)) {
      $0.type = .person
      $0.fields = ["photo": "", "name": "", "role": "", "context": ""]
      $0.directions = []
    }
    #expect(!store.state.hasChanges)
    #expect(!store.state.canSave)
    await store.send(.typeChanged(.basic)) {
      $0.type = .basic
      $0.fields = ["front": "", "back": ""]
      $0.directions = [self.frontBack]
    }
  }

  @Test func anExistingNotesTypeIsFixed() async {
    let store = TestStore(initialState: NoteEditorFeature.State(note: laCarte)) { NoteEditorFeature() }
    await store.send(.typeChanged(.person))
  }

  @Test func directionsTheNoteHasOutsideTheCatalogAreListedAndOn() {
    var note = person
    let contextName = Direction(prompt: ["context"], answer: ["name"])
    note.cards.append(Note.Card(id: UUID(), prompt: ["context"], answer: ["name"], due: note.createdAt))
    let state = NoteEditorFeature.State(note: note)
    #expect(state.catalog == [photoName, photoNameRole, roleName, contextName])
    #expect(state.directions == [photoName, roleName, contextName])
  }

  @Test func aDirectionWithEmptyFieldsCantBeTurnedOnButOneAlreadyOnStaysOn() async {
    let store = TestStore(initialState: NoteEditorFeature.State()) { NoteEditorFeature() }

    #expect(store.state.isUnavailable(backFront))
    #expect(!store.state.isUnavailable(frontBack))
    await store.send(.directionToggled(backFront))

    await store.send(.fieldChanged("front", "chat")) {
      $0.fields["front"] = "chat"
    }
    await store.send(.fieldChanged("back", "cat")) {
      $0.fields["back"] = "cat"
    }
    await store.send(.directionToggled(backFront)) {
      $0.directions = [self.frontBack, self.backFront]
    }
    await store.send(.fieldChanged("back", "")) {
      $0.fields["back"] = ""
    }
    #expect(!store.state.isUnavailable(backFront))
    #expect(store.state.directions == [frontBack, backFront])
    #expect(!store.state.canSave)
    await store.send(.directionToggled(backFront)) {
      $0.directions = [self.frontBack]
    }
    #expect(store.state.isUnavailable(backFront))
  }

  @Test func directionsStayInCatalogOrder() async {
    var state = NoteEditorFeature.State()
    state.type = .person
    state.fields = ["photo": "https://example.com/a.png", "name": "Ada", "role": "baker", "context": ""]
    state.directions = []
    let store = TestStore(initialState: state) { NoteEditorFeature() }

    await store.send(.directionToggled(roleName)) {
      $0.directions = [self.roleName]
    }
    await store.send(.directionToggled(photoName)) {
      $0.directions = [self.photoName, self.roleName]
    }
  }

  @Test func saveNeedsRequiredFieldsADirectionFilledDirectionsAndAnHTTPPhoto() {
    var state = NoteEditorFeature.State()
    state.type = .person
    state.fields = ["photo": "", "name": "", "role": "", "context": ""]
    state.directions = []
    #expect(!state.canSave)

    state.fields["name"] = "Ada"
    #expect(!state.canSave)  // no direction

    state.directions = [roleName]
    #expect(!state.canSave)  // role empty
    state.fields["role"] = "runs the bakery"
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
      $0.fields = ["photo": "", "name": "", "role": "", "context": ""]
      $0.directions = []
    }
    await store.send(.fieldChanged("name", " Ada ")) {
      $0.fields["name"] = " Ada "
    }
    await store.send(.fieldChanged("role", "baker")) {
      $0.fields["role"] = "baker"
    }
    await store.send(.directionToggled(roleName)) {
      $0.directions = [self.roleName]
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
          fields: ["photo": "", "name": "Ada", "role": "baker", "context": ""],
          directions: [roleName]
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

    await store.send(.directionToggled(frontBack)) {
      $0.directions = [self.backFront]
    }
    await store.send(.saveButtonTapped) {
      $0.isSaving = true
    }
    await store.receive(\.saveResponse.success)
    await store.receive(\.delegate.saved)
    #expect(patched.value?.0 == laCarte.id)
    #expect(
      patched.value?.1
        == NoteDraft(type: .basic, fields: ["front": "la carte", "back": "the menu — and the map"], directions: [backFront])
    )
  }

  @Test func saveFailureKeepsTheSheetAndShowsTheError() async {
    var state = NoteEditorFeature.State()
    state.fields = ["front": "chat", "back": "cat"]
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
    state.directions = [frontBack]
    #expect(state.hasChanges)

    state = NoteEditorFeature.State()
    state.directions = [frontBack, backFront]
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

    await store.send(.directionToggled(roleName)) {
      $0.directions = [self.photoName]
    }
    await store.send(.closeButtonTapped) {
      $0.isDiscardDialogPresented = true
    }
    await store.send(\.binding.isDiscardDialogPresented, false) {
      $0.isDiscardDialogPresented = false
    }
    #expect(store.state.directions == [photoName])
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

  @Test func directionLabelsUseFieldLabels() {
    #expect(NoteEditorView.label(photoNameRole, side: " → ", join: " + ") == "Photo → Name + Role")
    #expect(NoteEditorView.label(photoNameRole, side: " to ", join: " and ") == "Photo to Name and Role")
    #expect(NoteEditorView.label(backFront, side: " → ", join: " + ") == "Back → Front")
  }
}
