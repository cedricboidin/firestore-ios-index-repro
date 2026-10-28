import FirebaseCore
import FirebaseFirestore
import SwiftUI

@main
struct ReproApp: App {
  init() {
    let options = FirebaseOptions(
      googleAppID: "1:123456789012:ios:0000000000000000",
      gcmSenderID: "123456789012"
    )
    options.projectID = "demo-repro"
    options.apiKey = "AIzaSyD-repro-repro-repro-repro-repro00"
    FirebaseApp.configure(options: options)

    if ProcessInfo.processInfo.arguments.contains("-firestoreDebugLogs") {
      Firestore.enableLogging(true)
    }

    Repro.configure(Firestore.firestore())
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

struct ContentView: View {
  @StateObject private var repro = Repro()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Firestore iOS cache index repro").font(.headline)
      Button(repro.running ? "Running… (about 2 min)" : "Run") {
        Task { await repro.run() }
      }
      .disabled(repro.running)
      .accessibilityIdentifier("run")
      if let verdict = repro.verdict {
        Text(verdict)
          .font(.subheadline.bold())
          .foregroundColor(repro.reproduced == true ? .red : .green)
          .accessibilityIdentifier("verdict")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(repro.lines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(.caption, design: .monospaced))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding()
    .task {
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("-autorun") {
        await repro.run()
      } else if arguments.contains("-recheck") {
        await repro.recheck()
      }
    }
  }
}
