import SwiftUI
import Network

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

    @State private var selectedIndex: Int = 0
    @State private var output: String = "Ready"
    @State private var usedCellularLastTime = false
    @State private var wifiLocalString = "http://192.168.4.1/" // 手元の機器IPに変えてOK

    private let http = CellularHttpClient()
    private let pathLogger = PathLogger()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Cellular: 無料APIテスト先")) {
                    Picker("ターゲット", selection: $selectedIndex) {
                        ForEach(targets.indices, id: \.self) { i in
                            Text(targets[i].name).tag(i)
                        }
                    }
                    Button("セルラーで叩く") {
                        let url = targets[selectedIndex].url
                        output = "Cellular: requesting \(url.absoluteString)"
                        http.get(url: url) { result in
                            DispatchQueue.main.async {
                                switch result {
                                case .failure(let err):
                                    output = "Cellular ERROR: \(err.localizedDescription)"
                                case .success(let res):
                                    usedCellularLastTime = res.usedCellular
                                    let bodyPreview = String(decoding: res.body.prefix(200), as: UTF8.self)
                                        .replacingOccurrences(of: "\n", with: "\\n")
                                    output = """
                                    status=\(res.status)
                                    usedCellular=\(res.usedCellular)
                                    body(len=\(res.body.count)) preview:
                                    \(bodyPreview)
                                    """
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(usedCellularLastTime ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text("last usedCellular = \(usedCellularLastTime.description)")
                            .font(.footnote.monospaced())
                    }
                }

                Section(header: Text("Wi-Fi Local（任意：デバイスAPに対して）")) {
                    TextField("http://192.168.4.1/", text: $wifiLocalString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    Button("Wi-Fi経由で叩く（URLSession）") {
                        guard let url = URL(string: wifiLocalString) else {
                            output = "Wi-Fi Local ERROR: URL不正"
                            return
                        }
                        output = "Wi-Fi Local: requesting \(url.absoluteString)"
                        var req = URLRequest(url: url); req.timeoutInterval = 10
                        URLSession.shared.dataTask(with: req) { data, resp, err in
                            DispatchQueue.main.async {
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
                        }.resume()
                    }
                }

                Section(header: Text("結果")) {
                    ScrollView {
                        Text(output)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }.frame(minHeight: 160)
                }
            }
            .navigationTitle("Dual Lane Demo")
            .onAppear { pathLogger.start() }
            .onDisappear { pathLogger.stop() }
        }
    }

    struct ApiTarget { let name: String; let url: URL }
}

// MARK: - セルラー強制HTTPクライアント（GET最小実装）
final class CellularHttpClient {
    struct Response {
        let status: Int
        let headers: [String:String]
        let body: Data
        let usedCellular: Bool
    }

    func get(url: URL,
             headers: [String:String] = [:],
             completion: @escaping (Result<Response, Error>) -> Void) {
        guard let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))) else {
            completion(.failure(NSError(domain: "bad_url", code: -1)))
            return
        }

        let params = NWParameters.tcp
        params.requiredInterfaceType = .cellular // ★ セルラー強制
        if url.scheme == "https" {
            let tls = NWProtocolTLS.Options()
            params.defaultProtocolStack.applicationProtocols.insert(tls, at: 0)
        }

        let conn = NWConnection(host: .name(host, nil), port: port, using: params)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let usedCellular = conn.currentPath?.usesInterfaceType(.cellular) ?? false
                let req = self.buildGet(url: url, host: host, extraHeaders: headers)
                conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                    if let err = err { completion(.failure(err)); return }
                    self.receiveAll(on: conn) { result in
                        switch result {
                        case .failure(let e): completion(.failure(e))
                        case .success(let raw):
                            let parsed = self.parseHttp(raw)
                            completion(.success(.init(status: parsed.status,
                                                      headers: parsed.headers,
                                                      body: parsed.body,
                                                      usedCellular: usedCellular)))
                        }
                    }
                })
            case .failed(let err):
                completion(.failure(err))
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func buildGet(url: URL, host: String, extraHeaders: [String:String]) -> String {
        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
        var s = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nUser-Agent: CellularHttpClient/1\r\n"
        for (k,v) in extraHeaders { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return s
    }

    private func receiveAll(on conn: NWConnection, completion: @escaping (Result<Data,Error>) -> Void) {
        var buf = Data()
        func loop() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64*1024) { data, _, finished, error in
                if let error = error { completion(.failure(error)); return }
                if let data = data { buf.append(data) }
                if finished { conn.cancel(); completion(.success(buf)) } else { loop() }
            }
        }
        loop()
    }

    private func parseHttp(_ raw: Data) -> (status: Int, headers: [String:String], body: Data) {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return (0, [:], raw) }
        let head = raw[..<sep.lowerBound]
        let body = raw[sep.upperBound...]
        let headerStr = String(decoding: head, as: UTF8.self)
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        let status = (lines.first?.split(separator: " ").dropFirst().first).flatMap { Int($0) } ?? 0
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return (status, headers, Data(body))
    }
}

// MARK: - 回線状況ログ（Xcodeコンソール出力）
final class PathLogger {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "path.logger")
    func start() {
        monitor.pathUpdateHandler = { path in
            print("Path status=\(path.status) ipv4=\(path.supportsIPv4) ipv6=\(path.supportsIPv6)")
            print("  wifi available=\(path.availableInterfaces.contains { $0.type == .wifi }) usesWifi=\(path.usesInterfaceType(.wifi))")
            print("  cell available=\(path.availableInterfaces.contains { $0.type == .cellular }) usesCell=\(path.usesInterfaceType(.cellular))")
            print("  expensive=\(path.isExpensive) constrained=\(path.isConstrained)")
        }
        monitor.start(queue: queue)
    }
    func stop() { monitor.cancel() }
}
