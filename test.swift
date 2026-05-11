import SwiftUI
struct TestView: View {
    var body: some View {
        Text("Hello")
            .toolbar { myToolbar }
    }
    
    @ToolbarContentBuilder
    private var myToolbar: some ToolbarContent {
        ToolbarItem {
            Text("Hi")
        }
    }
}
