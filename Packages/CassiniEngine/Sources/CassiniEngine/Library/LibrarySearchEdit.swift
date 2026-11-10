/// What an edit of the Library search's text view means for the query. The field wraps, so Search on the keyboard
/// arrives as a new line in its text rather than as a submit; a line break ends the search instead.
///
/// The view's own text is the truth here, not the query bound to it: on iPadOS 18 a wrapping SwiftUI field under load
/// stopped passing edits to its binding (the query stayed at "Thur" while the field held "Thursday" and a new line, and
/// the keyboard stayed up), so the Library reads every edit from the text view as well.
public enum LibrarySearchEdit: Equatable, Sendable {
    /// The query already holds the text.
    case none
    /// The query should hold the text: the binding missed an edit.
    case follow(String)
    /// A line break was typed (Search) or pasted: the text without line breaks is the query, and editing ends.
    case submit(String)

    public init(text: String, query: String) {
        if text.contains(where: \.isNewline) {
            self = .submit(text.filter { !$0.isNewline })
        } else if text != query {
            self = .follow(text)
        } else {
            self = .none
        }
    }
}
