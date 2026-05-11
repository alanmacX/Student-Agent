import SwiftUI

struct ChaoxingLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var qrUUID: String = ""
    @State private var qrEnc: String = ""
    @State private var qrImage: NSImage? = nil
    @State private var status: QRState = .loading
    @State private var pollingTask: Task<Void, Never>? = nil

    enum QRState {
        case loading, waiting, scanned, confirmed, expired, failed(String)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("学习通 扫码登录")
                .font(.title2.bold())

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)

                Group {
                    switch status {
                    case .loading:
                        ProgressView()
                    case .waiting, .scanned:
                        if let img = qrImage {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 200, height: 200)
                                .overlay {
                                    if case .scanned = status {
                                        ZStack {
                                            Color.black.opacity(0.45)
                                            VStack(spacing: 6) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 36))
                                                    .foregroundStyle(.white)
                                                Text("已扫码，请在手机上确认")
                                                    .font(.caption)
                                                    .foregroundStyle(.white)
                                                    .multilineTextAlignment(.center)
                                            }
                                        }
                                    }
                                }
                        } else {
                            ProgressView()
                        }
                    case .confirmed:
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            Text("登录成功")
                                .font(.headline)
                        }
                    case .expired:
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("二维码已过期")
                                .font(.caption)
                            Button("刷新") { startLogin() }
                                .buttonStyle(.borderedProminent)
                        }
                    case .failed(let msg):
                        VStack(spacing: 8) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 36))
                                .foregroundStyle(.red)
                            Text(msg)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                            Button("重试") { startLogin() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(width: 200, height: 200)
            }
            .shadow(radius: 4)

            Group {
                switch status {
                case .waiting:
                    Text("请使用学习通 App 扫描二维码")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .scanned:
                    Text("请在手机上点击确认登录")
                        .foregroundStyle(.orange)
                        .font(.callout)
                case .confirmed:
                    let name = ChaoxingService.shared.userName
                    Text("欢迎回来，\(name.isEmpty ? "用户" : name)！")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            .frame(height: 24)

            HStack {
                Button("取消") {
                    pollingTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if case .confirmed = status {
                    Button("完成") {
                        pollingTask?.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 320)
        .onAppear { startLogin() }
        .onDisappear { pollingTask?.cancel() }
    }

    private func startLogin() {
        pollingTask?.cancel()
        status = .loading
        qrImage = nil
        qrUUID = ""
        qrEnc = ""

        pollingTask = Task {
            do {
                let (uuid, enc, img) = try await ChaoxingService.shared.createQRSession()
                guard !Task.isCancelled else { return }
                qrUUID = uuid
                qrEnc = enc
                qrImage = img
                status = .waiting
                await pollLoop(uuid: uuid, enc: enc)
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func pollLoop(uuid: String, enc: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            do {
                let result = try await ChaoxingService.shared.pollQR(uuid: uuid, enc: enc)
                guard !Task.isCancelled else { return }
                switch result {
                case .waiting:   break
                case .scanned:   status = .scanned
                case .confirmed: status = .confirmed; return
                case .expired:   status = .expired;   return
                case .error(let msg): status = .failed(msg); return
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(error.localizedDescription)
                return
            }
        }
    }
}

// MARK: - Status chip for settings

struct ChaoxingStatusRow: View {
    @ObservedObject var service = ChaoxingService.shared
    @State private var showLogin = false

    var body: some View {
        HStack {
            Image(systemName: service.isLoggedIn ? "checkmark.circle.fill" : "qrcode")
                .foregroundStyle(service.isLoggedIn ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("学习通")
                    .font(.callout.weight(.medium))
                Text(service.isLoggedIn
                     ? (service.userName.isEmpty ? "已登录" : service.userName)
                     : "未登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if service.isLoggedIn {
                Button("退出") { service.logout() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.callout)
            } else {
                Button("登录") { showLogin = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $showLogin) {
            ChaoxingLoginSheet()
        }
    }
}
