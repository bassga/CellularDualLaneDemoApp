import SwiftUI
import CellularHTTP
//import Network

// MARK: - エントリ
@main
struct CellularDualLaneDemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - UI
struct ContentView: View {
    // 無料APIプリセット
    private let targets: [ApiTarget] = [
        .init(name: "httpbin /get", url: URL(string: "https://httpbin.org/get")!),
        .init(name: "JSONPlaceholder /todos/1", url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!),
        .init(name: "GitHub Zen", url: URL(string: "https://api.github.com/zen")!),
        .init(name: "catfact.ninja", url: URL(string: "https://catfact.ninja/fact")!),
        .init(name: "httpstat.us 200", url: URL(string: "https://httpstat.us/200")!)
    ]

    // SwiftUIの状態管理。ビューの再描画に使う
    @State private var selectedIndex: Int = 0  // 選択中のAPIターゲットのインデックス
    @State private var output: String = "Ready" // ネットワーク結果や状態表示用の文字列
    @State private var usedCellularLastTime = false // 前回のリクエストでセルラー回線が使われたかどうか
    @State private var wifiLocalString = "http://192.168.4.1/" // Wi-Fi経由で叩くローカルURL。任意で変更可能

//    private let http = CellularHttpClient()
    private let http = CellularHTTPClient() // CellularHTTPClientを使ってセルラー回線経由の通信を行う
    private let pathLogger = CellularPathMonitor() // ネットワーク経路監視用（起動・終了時に開始・停止）

    var body: some View {
        NavigationView {
            Form {
                // セクション1: Cellular回線を使った無料APIテスト
                Section(header: Text("Cellular: 無料APIテスト先")) {
                    // PickerでAPIターゲットを選択
                    Picker("ターゲット", selection: $selectedIndex) {
                        ForEach(targets.indices, id: \.self) { i in
                            Text(targets[i].name).tag(i)
                        }
                    }
                    // ボタン押下でセルラー回線を使った通信を開始
                    Button("セルラーで叩く") {
                        let url = targets[selectedIndex].url
                        output = "Cellular: requesting \(url.absoluteString)"
                        // Swiftの非同期処理(Task)を使い、awaitで通信完了を待つ
                        Task {
                            do {
                                // CellularHTTPClientの非同期getメソッドを呼び出し
                                let res = try await http.get(url: url)
                                // 結果からセルラー回線が使われたかを保持
                                usedCellularLastTime = res.usedCellular
                                // レスポンスボディの先頭200文字をUTF8でデコードし、改行をエスケープ
                                let bodyPreview = String(decoding: res.body.prefix(200), as: UTF8.self)
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                // 出力文字列を更新し、UIを再描画
                                output = """
                                status=\(res.status)
                                usedCellular=\(res.usedCellular)
                                body(len=\(res.body.count)) preview:
                                \(bodyPreview)
                                """
                            } catch {
                                // エラー発生時の表示
                                output = "Cellular ERROR: \(error.localizedDescription)"
                            }
                        }
//                        // POST (JSON)
//                        Task {
//                            let url = URL(string: "https://httpbin.org/post")!
//                            let json = try! JSONSerialization.data(withJSONObject: ["hello":"world"])
//                            let res = try await http.post(
//                                url: url,
//                                headers: ["Content-Type":"application/json"],
//                                body: json
//                            )
//                            print(res.status, res.usedCellular, res.body.count)
//                        }
                    }
                    .buttonStyle(.borderedProminent)

                    // セルラー通信が使われたかどうかを示すインジケータ
                    HStack(spacing: 8) {
                        Circle()
                            .fill(usedCellularLastTime ? Color.green : Color.gray) // trueなら緑、falseなら灰色
                            .frame(width: 10, height: 10)
                        Text("last usedCellular = \(usedCellularLastTime.description)")
                            .font(.footnote.monospaced())
                    }
                }

                // セクション2: Wi-Fi経由でローカルデバイスにアクセス（任意）
                Section(header: Text("Wi-Fi Local（任意：デバイスAPに対して）")) {
                    // TextFieldでWi-Fi経由のURLを入力
                    TextField("http://192.168.4.1/", text: $wifiLocalString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    // ボタン押下でURLSessionを使ってWi-Fi経由の通信を開始
                    Button("Wi-Fi経由で叩く（URLSession）") {
                        guard let url = URL(string: wifiLocalString) else {
                            output = "Wi-Fi Local ERROR: URL不正"
                            return
                        }
                        output = "Wi-Fi Local: requesting \(url.absoluteString)"
                        var req = URLRequest(url: url); req.timeoutInterval = 10
                        // URLSessionのdataTaskで非同期通信。完了時にクロージャが呼ばれる
                        URLSession.shared.dataTask(with: req) { data, resp, err in
                            DispatchQueue.main.async {
                                // UI更新はメインスレッドで行う必要があるためDispatchQueue.main.asyncで囲む
                                if let err = err {
                                    output = "Wi-Fi Local ERROR: \(err.localizedDescription)"
                                    return
                                }
                                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                                let bodyPreview = String(decoding: (data ?? Data()).prefix(200), as: UTF8.self)
                                    .replacingOccurrences(of: "\n", with: "\\n")
                                output = """
                                Wi-Fi Local OK: status=\(code)
                                body(len=\(data?.count ?? 0)) preview:
                                \(bodyPreview)
                                """
                            }
                        }.resume() // 通信開始
                    }
                }

                // セクション3: 結果表示用
                Section(header: Text("結果")) {
                    ScrollView {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced)) // 等幅フォントで表示
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled) // テキスト選択可能にする
                            .padding(.vertical, 4)
                    }.frame(minHeight: 160) // 最低高さを確保
                }
            }
            .navigationTitle("Dual Lane Demo")
            // ビュー表示時にネットワーク経路監視を開始
            .onAppear { pathLogger.start() }
            // ビュー非表示時に監視を停止
            .onDisappear { pathLogger.stop() }
        }
    }

    // APIターゲットの構造体
    struct ApiTarget { let name: String; let url: URL }
}
