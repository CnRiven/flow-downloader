import SwiftUI
import FlowCore

struct EngineSetupView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.enginePreparing || model.engineSetupError != nil || model.paths.downloader == nil {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.engineSetupError == nil ? "arrow.down.circle" : "exclamationmark.circle")
                        .font(.system(size: 20)).foregroundStyle(model.engineSetupError == nil ? Palette.green : .orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.engineSetupError ?? model.engineProgress?.message ?? "正在准备下载引擎…")
                            .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                        Text("从 yt-dlp 官方发布下载到拾流目录，无需 Homebrew、Python 或管理员密码。")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Spacer(minLength: 4)
                    if model.enginePreparing {
                        Button("取消") { model.cancelEngineInstallation() }.buttonStyle(.plain).font(.system(size: 11))
                    } else {
                        Button("重试安装") { model.retryEngineInstallation() }.buttonStyle(ActionStyle(prominent: true))
                    }
                }
                if model.enginePreparing {
                    if let fraction = model.engineProgress?.fraction {
                        ProgressView(value: fraction).tint(Palette.green)
                    } else { ProgressView().progressViewStyle(.linear).tint(Palette.green) }
                }
            }.padding(17).background(Palette.mint.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.green.opacity(0.1)))
        }
    }
}
