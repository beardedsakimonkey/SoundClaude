import SwiftUI

struct HomeView: View {
    var body: some View {
        ContentUnavailableView(
            "Home",
            systemImage: "house",
            description: Text("Home content will appear here.")
        )
        .navigationTitle("Home")
    }
}
