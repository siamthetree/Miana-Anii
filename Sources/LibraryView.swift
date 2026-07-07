import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        Text("Library")
            .padding()
    }
}
