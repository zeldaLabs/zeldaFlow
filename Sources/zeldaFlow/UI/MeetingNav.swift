import Foundation
import Combine

/// Navigation seam between the app (pill chip click, menu bar, banner) and
/// the Meetings page: setting `openMeetingID` makes MeetingsPage swap its
/// list for that meeting's detail. A singleton, unlike HubNav, because the
/// deep-link sources live outside the Hub window's view tree.
@MainActor final class MeetingNav: ObservableObject {
    static let shared = MeetingNav()
    @Published var openMeetingID: UUID?
}
